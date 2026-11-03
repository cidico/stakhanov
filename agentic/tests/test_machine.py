#!/usr/bin/env python3
"""campaign machine (lib/machine.sh): what a machine offers a task. Local readings use a repository of their own; the
--fleet ones use the fake fleet of test_fleet.py (ssh to folders that act as other machines)."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

import test_fleet
from test_campaign import Repo


class MachineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-machine-")
        self.base = Path(self.temp.name)
        self.repos = []
        self.held = []

    def tearDown(self):
        for handle in self.held:
            handle.close()
        for repo in self.repos:
            repo.close()
        self.temp.cleanup()

    def repo(self, settings=None, **env):
        repo = Repo(settings=settings or {"name": "proof"})
        self.repos.append(repo)
        repo.env.update(AGENTIC_STATE=str(self.base / "state"), **env)
        return repo

    def machine(self, repo, *arguments, check=True, env=None):
        result = repo.command("machine", *arguments, check=check, env=env)
        return json.loads(result.stdout) if "--json" in arguments and check else result

    def slot_files(self):
        path = self.base / "state" / "slots"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def hold(self, index, kind="provider", label="TSK-001"):
        """Takes slot INDEX from this test process and names the holder in its file, as a round does."""
        handle = open(self.slot_files() / f"slot.{index}", "a")
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.truncate(0)
        handle.write(json.dumps({"pid": os.getpid(), "kind": kind, "label": label, "since": "2026-11-01T12:00:00Z"}) + "\n")
        handle.flush()
        self.held.append(handle)
        return handle

    def test_the_reading_has_the_machine_load_and_defaults(self):
        report = self.machine(self.repo(), "--json")
        self.assertEqual(sorted(report), ["accepts", "accounts", "at", "capabilities", "cpus", "load1", "mem_available_mb",
                                          "name", "slots"])
        self.assertTrue(report["name"])
        self.assertRegex(report["at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertGreater(report["cpus"], 0)
        self.assertGreaterEqual(report["load1"], 0)
        self.assertGreater(report["mem_available_mb"], 0)
        self.assertIsNone(report["accounts"])
        self.assertEqual(report["capabilities"], [])
        self.assertIs(report["accepts"], True)

    def test_free_slots_and_the_ones_a_process_holds(self):
        repo = self.repo(AGENTIC_SLOTS="3")
        self.assertEqual(self.machine(repo, "--json")["slots"], {"capacity": 3, "used": 0, "free": 3, "holders": []})
        self.hold(1, kind="validation", label="final of x")
        # The file of a slot nobody holds only has leftovers: it is free whatever it says.
        (self.slot_files() / "slot.0").write_text('{"pid":1,"kind":"provider","label":"gone","since":"2020-01-01T00:00:00Z"}\n')
        slots = self.machine(repo, "--json")["slots"]
        self.assertEqual(slots, {"capacity": 3, "used": 1, "free": 2, "holders": [
            {"slot": 1, "kind": "validation", "label": "final of x", "since": "2026-11-01T12:00:00Z"}]})
        # A holder that has the lock and has not named itself yet is still a holder.
        self.hold(2, label="late")
        (self.slot_files() / "slot.2").write_text("")
        slots = self.machine(repo, "--json")["slots"]
        self.assertEqual((slots["used"], slots["free"]), (2, 1))
        self.assertEqual(slots["holders"][1], {"slot": 2, "kind": None, "label": None, "since": None})
        for handle in self.held:
            handle.close()
        self.held.clear()
        self.assertEqual(self.machine(repo, "--json")["slots"], {"capacity": 3, "used": 0, "free": 3, "holders": []})
        # Reading a slot never leaves it taken.
        self.hold(0)

    def test_a_full_machine_has_no_free_slot(self):
        repo = self.repo(AGENTIC_SLOTS="2")
        self.hold(0)
        self.hold(1, label="TSK-002")
        slots = self.machine(repo, "--json")["slots"]
        self.assertEqual((slots["capacity"], slots["used"], slots["free"]), (2, 2, 0))
        self.assertEqual([holder["label"] for holder in slots["holders"]], ["TSK-001", "TSK-002"])
        text = self.machine(repo).stdout
        self.assertIn("slots: 0 free of 2", text)
        self.assertIn("slot 1: provider TSK-002 since 2026-11-01T12:00:00Z", text)

    def test_without_a_limit_the_capacity_and_the_free_slots_are_null(self):
        repo = self.repo()
        slots = self.machine(repo, "--json")["slots"]
        self.assertEqual(slots, {"capacity": None, "used": 0, "free": None, "holders": []})
        # AGENTIC_SLOTS=0 is no limit as well; a round still holding a slot from before is shown.
        self.hold(0)
        slots = self.machine(repo, "--json", env={"AGENTIC_SLOTS": "0"})["slots"]
        self.assertEqual((slots["capacity"], slots["used"], slots["free"]), (None, 1, None))
        self.assertIn("slots: no limit, 1 in use", self.machine(repo, env={"AGENTIC_SLOTS": "0"}).stdout)

    def test_a_bad_capacity_is_an_error_not_no_limit(self):
        result = self.machine(self.repo(AGENTIC_SLOTS="many"), "--json", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("AGENTIC_SLOTS must be", result.stderr)

    def test_capabilities_are_proofs_run_here(self):
        repo = self.repo({"name": "proof", "capabilities": {
            "present": ["true"],
            "failing": ["sh", "-c", "echo; echo 'no docker daemon' >&2; echo second >&2; exit 3"],
            "silent": ["sh", "-c", "exit 4"],
            "absent": ["no-such-command-for-the-machine-test"],
            "literal": ["echo", "$(touch should-not-exist)", ";", "false"],
        }}, AGENTIC_MACHINE_PROBE_SECONDS="5")
        report = self.machine(repo, "--json")
        by_name = {item["name"]: item for item in report["capabilities"]}
        self.assertEqual([item["name"] for item in report["capabilities"]], ["present", "failing", "silent", "absent", "literal"])
        self.assertEqual(by_name["present"], {"name": "present", "proven": True, "reason": None})
        self.assertEqual(by_name["failing"], {"name": "failing", "proven": False, "reason": "no docker daemon"})
        self.assertEqual(by_name["silent"], {"name": "silent", "proven": False, "reason": "exit 4"})
        self.assertFalse(by_name["absent"]["proven"])
        self.assertIn("no-such-command-for-the-machine-test", by_name["absent"]["reason"])
        # No shell is involved: the words are the argv as they are.
        self.assertTrue(by_name["literal"]["proven"])
        self.assertFalse((repo.root / "should-not-exist").exists())
        text = self.machine(repo).stdout
        self.assertIn("present ok", text)
        self.assertIn("failing NOT PROVEN (no docker daemon)", text)

    def test_a_proof_that_overruns_its_deadline_is_not_proven(self):
        marker = self.base / "survivor"
        repo = self.repo({"name": "proof", "capabilities": {
            "slow": ["sh", "-c", f"sleep 1.5; touch {marker}"], "fast": ["true"]}}, AGENTIC_MACHINE_PROBE_SECONDS="1")
        report = self.machine(repo, "--json")
        self.assertEqual(report["capabilities"][0], {"name": "slow", "proven": False, "reason": "timed out after 1s"})
        self.assertTrue(report["capabilities"][1]["proven"])
        # The proof is stopped, not left running.
        time.sleep(2)
        self.assertFalse(marker.exists())

    def test_the_settings_refuse_a_capability_that_is_not_an_argv(self):
        for capabilities in (["dotnet"], {"dotnet": "dotnet --version"}, {"dotnet": []}, {"dotnet": ["dotnet", 1]},
                             {"dotnet": [""]}, {"bad name": ["true"]}):
            repo = self.repo({"name": "proof", "capabilities": capabilities})
            result = repo.command("machine", "--json", check=False)
            self.assertEqual(result.returncode, 2, capabilities)
            self.assertIn("invalid settings", result.stderr)

    def account_hook(self, repo, script):
        folder = self.base / "hook-bin"
        folder.mkdir(exist_ok=True)
        hook = folder / "accounts-hook"
        hook.write_text("#!/bin/sh\n" + script)
        hook.chmod(0o755)
        repo.env.update(AGENTIC_CLAUDE_ACCOUNTS="accounts-hook", PATH=f"{folder}:{repo.env['PATH']}")

    def test_the_accounts_are_what_the_hook_lists(self):
        repo = self.repo()
        listing = [{"key": "work", "path": "/x/.claude-work", "logged_in": True, "onboarded": True, "status": "ok"},
                   {"key": "spare", "path": "/x/.claude-spare", "logged_in": False, "onboarded": False, "status": "out"}]
        self.account_hook(repo, f'[ "$1 $2 $3" = "account list --json" ] && {{ echo \'{json.dumps(listing)}\'; exit 0; }}\n'
                                'echo should-not-be-used; exit 1\n')
        self.assertEqual(self.machine(repo, "--json")["accounts"], listing)
        self.assertIn("2 listed (work, spare)", self.machine(repo).stdout)

    def test_a_hook_without_list_gives_enabled_and_current(self):
        repo = self.repo()
        script = ('case "$1 $2" in\n"account list") exit 2 ;;\n"account enabled") exit 0 ;;\n'
                  '"account current") echo work; exit 0 ;;\nesac\nexit 1\n')
        self.account_hook(repo, script)
        self.assertEqual(self.machine(repo, "--json")["accounts"], {"enabled": True, "current": "work"})
        # Something that is not a JSON list is not understood either; the hook turned off says so.
        self.account_hook(repo, 'case "$1 $2" in\n"account list") echo not json; exit 0 ;;\n"account enabled") exit 1 ;;\n'
                                '"account current") echo spare; exit 0 ;;\nesac\nexit 1\n')
        self.assertEqual(self.machine(repo, "--json")["accounts"], {"enabled": False, "current": "spare"})
        self.assertIn("accounts: hook off, current spare", self.machine(repo).stdout)

    def test_a_hook_that_is_not_installed_is_off(self):
        repo = self.repo(AGENTIC_CLAUDE_ACCOUNTS="no-such-hook-for-the-machine-test")
        self.assertEqual(self.machine(repo, "--json")["accounts"], {"enabled": False, "current": None})

    def test_a_hook_that_hangs_does_not_hang_the_reading(self):
        repo = self.repo(AGENTIC_MACHINE_PROBE_SECONDS="1")
        self.account_hook(repo, "sleep 30\n")
        self.assertEqual(self.machine(repo, "--json")["accounts"], {"enabled": False, "current": None})

    def test_the_hook_comes_from_the_settings_env_too(self):
        repo = self.repo({"name": "proof", "env": {"AGENTIC_CLAUDE_ACCOUNTS": "accounts-hook"}})
        self.account_hook(repo, 'case "$1 $2" in\n"account list") echo \'[{"key":"a"}]\'; exit 0 ;;\nesac\nexit 1\n')
        del repo.env["AGENTIC_CLAUDE_ACCOUNTS"]
        self.assertEqual(self.machine(repo, "--json")["accounts"], [{"key": "a"}])

    def test_accepts_comes_from_the_fleet_file(self):
        repo = self.repo(AGENTIC_MACHINE_ID="machine-one", AGENTIC_FLEET=str(self.base / "fleet.json"))
        fleet = self.base / "fleet.json"

        def write(accepts):
            entry = {"ssh": "one", "id": "machine-one", **({} if accepts is None else {"accepts": accepts})}
            fleet.write_text(json.dumps({"machines": {"one": entry}, "projects": {}}))

        write(None)
        report = self.machine(repo, "--json")
        self.assertEqual((report["name"], report["accepts"]), ("one", True))
        write(False)
        self.assertIs(self.machine(repo, "--json")["accepts"], False)
        self.assertIn("takes tasks: no", self.machine(repo).stdout)
        write(True)
        self.assertIs(self.machine(repo, "--json")["accepts"], True)
        write("no")
        result = self.machine(repo, "--json", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("machines.one.accepts", result.stderr)

    def test_an_unknown_option_is_refused(self):
        result = self.machine(self.repo(), "--bogus", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown machine option", result.stderr)


class MachineFleetTests(unittest.TestCase):
    """The fake fleet of test_fleet.py: this machine is "here" and the folder "box" another one."""

    def setUp(self):
        # Its helpers and fake hosts, without its tests (importing the class by name would run them here too).
        self.f = test_fleet.FleetTests("test_without_a_fleet")
        self.f.setUp()
        self.addCleanup(self.f.tearDown)
        self.repo = self.f.repo
        # Both machines hold the project's settings, which the clone of box gets with the join.
        settings = self.repo.root / ".agentic" / "project.json"
        settings.write_text(json.dumps({"name": "proof", "capabilities": {"present": ["true"], "missing": ["false"]}}))
        self.repo.git("add", ".agentic/project.json")
        self.repo.git("commit", "-m", "capabilities")
        self.f.join()

    def fleet_report(self, *extra, env=None):
        return json.loads(self.repo.command("machine", "--fleet", "--json", *extra, env=env).stdout)

    def box(self, report):
        return next(machine for machine in report["machines"] if machine["name"] == "box")

    def test_every_machine_of_the_fleet_is_read_over_ssh(self):
        # What box says of itself comes from its own settings: its slots and whether it takes tasks are in its fleet file.
        path = Path(self.f.envs["box"]["AGENTIC_FLEET"])
        fleet = json.loads(path.read_text())
        fleet["machines"]["box"].update(slots=2, accepts=False)
        path.write_text(json.dumps(fleet))
        report = self.fleet_report()
        self.assertEqual([machine["name"] for machine in report["machines"]], ["here", "box"])
        here, box = report["machines"]
        self.assertTrue(here["self"] and here["reachable"])
        self.assertTrue(box["reachable"])
        self.assertFalse(box["self"])
        self.assertEqual(box["slots"], {"capacity": 2, "used": 0, "free": 2, "holders": []})
        self.assertIs(box["accepts"], False)
        self.assertIs(here["accepts"], True)
        self.assertIsNone(here["slots"]["capacity"])
        for machine in (here, box):
            self.assertEqual([(item["name"], item["proven"]) for item in machine["capabilities"]],
                             [("present", True), ("missing", False)])
            self.assertGreater(machine["cpus"], 0)
        self.assertIn("seen_at", box)
        text = self.repo.command("machine", "--fleet").stdout
        self.assertIn("== here", text)
        self.assertIn("== box", text)
        self.assertIn("slots: 2 free of 2", text)

    def test_a_machine_that_is_down_shows_its_last_reading(self):
        first = self.box(self.fleet_report())
        self.assertTrue(first["reachable"])
        (self.f.hosts / "box" / "env").unlink()
        report = self.fleet_report()
        box = self.box(report)
        self.assertFalse(box["reachable"])
        self.assertIn("Connection refused", box["error"])
        self.assertEqual(box["seen_at"], first["seen_at"])
        self.assertTrue(box["seen_local_time"])
        # The last reading is the one it gave, with the time it was read.
        self.assertEqual(box["at"], first["at"])
        self.assertEqual(box["slots"], first["slots"])
        self.assertEqual(box["capabilities"], first["capabilities"])
        # Here is still read live.
        self.assertTrue(report["machines"][0]["reachable"])
        text = self.repo.command("machine", "--fleet").stdout
        self.assertIn("== box — unreachable", text)
        self.assertIn("last seen", text)
        self.assertIn("capabilities: present ok; missing NOT PROVEN", text)

    def test_a_machine_never_seen_has_only_its_error(self):
        (self.f.hosts / "box" / "env").unlink()
        box = self.box(self.fleet_report())
        self.assertFalse(box["reachable"])
        self.assertIsNone(box["seen_at"])
        self.assertNotIn("slots", box)
        self.assertIn("never seen", self.repo.command("machine", "--fleet").stdout)

    def test_the_survey_is_cached_and_does_not_lose_the_overview_seen(self):
        self.f.init_on("box", "remote-one")
        self.repo.command("overview", "--fleet", "--json")
        log = self.f.counting_ssh()
        env = {"AGENTIC_FLEET_CACHE_SECONDS": "30"}
        self.fleet_report(env=env)
        warm = self.f.calls(log)
        self.assertGreater(warm, 0)
        self.fleet_report(env=env)
        self.assertEqual(self.f.calls(log), warm)
        # The cache of the machine report is not the overview's.
        seen = json.loads(next(Path(self.repo.cache.name).glob("*/fleet-seen.json")).read_text())
        self.assertEqual([c["slug"] for c in seen["box"]["overview"]["campaigns"]], ["remote-one"])
        self.assertIn("machine", seen["box"])
        (self.f.hosts / "box" / "env").unlink()
        overview = json.loads(self.repo.command("overview", "--fleet", "--json").stdout)
        box = next(machine for machine in overview["machines"] if machine["name"] == "box")
        self.assertEqual([c["slug"] for c in box["campaigns"]], ["remote-one"])

    def test_without_a_fleet_only_this_machine_is_read(self):
        self.f.repo.command("fleet", "leave", "box")
        report = self.fleet_report()
        self.assertEqual(len(report["machines"]), 1)
        self.assertTrue(report["machines"][0]["self"])
        self.assertIn("slots", report["machines"][0])

    def test_the_fleet_file_refuses_an_accepts_that_is_not_a_boolean(self):
        path = Path(self.f.envs["here"]["AGENTIC_FLEET"])
        fleet = json.loads(path.read_text())
        fleet["machines"]["box"]["accepts"] = "yes"
        path.write_text(json.dumps(fleet))
        result = self.repo.command("machine", "--fleet", "--json", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("accepts must be true or false", result.stderr)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""A finalize that failed resumes without running again what passed on the same commit, and says while it validates."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unittest

from test_campaign import Repo, ticket


class FinalizeResumeTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.repo.init_campaign()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.repo.configure([ticket(status="done")])
        self.cache = Path(self.repo.cache.name)
        self.out = self.cache / "out"
        self.out.mkdir()

    def tearDown(self):
        self.repo.close()

    def step(self, name, condition="true"):
        """A final command that counts its runs, then succeeds or not by the condition."""
        return ["sh", "-c", f"echo {name} >> {self.out}/{name}.count; {condition}"]

    def runs(self, name):
        path = self.out / f"{name}.count"
        return len(path.read_text().splitlines()) if path.exists() else 0

    def set_final(self, commands):
        manifest = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(manifest.read_text())
        plan["final"] = commands
        manifest.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "final plan", cwd=self.repo.worktree)

    def finalize(self, env=None):
        return self.repo.command("finalize", cwd=self.repo.worktree, check=False, env=env)

    def receipt(self, suffix=""):
        found = list(self.cache.glob(f"*/{self.repo.slug}/validation/campaign.final.json{suffix}"))
        self.assertEqual(len(found), 1, found)
        return json.loads(found[0].read_text())

    def markers(self):
        return list(self.cache.glob("*/finalizing/*.json"))

    def tip(self):
        return self.repo.git("rev-parse", "HEAD", cwd=self.repo.worktree).stdout.strip()

    def test_a_failed_final_reuses_what_passed_on_the_same_commit(self):
        gate3, gate4 = self.out / "gate3", self.out / "gate4"
        self.set_final([self.step("one"), self.step("two"), self.step("three", f"test -f {gate3}"),
                        self.step("four", f"test -f {gate4}")])
        first = self.finalize()
        self.assertNotEqual(first.returncode, 0)
        self.assertIn("final validation failed", first.stderr)
        failed = self.receipt()
        self.assertEqual((failed["status"], failed["tip"], len(failed["evidence"])), ("FAIL", self.tip(), 3))

        gate3.touch()
        second = self.finalize()
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual([self.runs(name) for name in ("one", "two", "three", "four")], [1, 1, 2, 1])
        self.assertEqual(second.stdout.count("campaign final: reusing the PASS of sh -c echo "), 2)
        self.assertIn(f"(same commit {self.tip()[:9]})", second.stdout)
        again = self.receipt()
        self.assertEqual([record.get("reused", False) for record in again["evidence"]], [True, True, False, False])
        self.assertEqual(again["evidence"][0]["startedAt"], failed["evidence"][0]["startedAt"])
        # Only the first save of a run rotates: the receipt kept as .previous is the first run's final one.
        previous = self.receipt(".previous")
        self.assertEqual((previous["status"], len(previous["evidence"])), ("FAIL", 3))

        gate4.touch()
        third = self.finalize()
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertIn("campaign final: PASS (4 commands, 3 reused)", third.stdout)
        self.assertEqual([self.runs(name) for name in ("one", "two", "three", "four")], [1, 1, 2, 2])
        self.assertNotIn("campaign/harness-sample", self.repo.git("branch", "--list").stdout)

    def test_nothing_is_reused_after_the_main_branch_moved(self):
        gate = self.out / "gate"
        self.set_final([self.step("one"), self.step("two", f"test -f {gate}")])
        self.assertNotEqual(self.finalize().returncode, 0)
        old_tip = self.tip()
        self.repo.git("commit", "--allow-empty", "-q", "-m", "main moved")
        gate.touch()
        second = self.finalize()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.runs("one"), self.runs("two")), (2, 2))
        self.assertNotIn("reusing", second.stdout)
        self.assertIn("main moved", self.repo.git("log", "--format=%s", "main").stdout.splitlines())
        self.assertNotEqual(old_tip, self.repo.git("rev-parse", "main").stdout.strip())

    def test_a_tracked_change_in_the_tree_reuses_nothing(self):
        gate = self.out / "gate"
        self.set_final([self.step("one"), self.step("two", f"test -f {gate}")])
        self.assertNotEqual(self.finalize().returncode, 0)
        (self.repo.worktree / "README.md").write_text("edited after the failure\n")
        self.assertNotEqual(self.finalize().returncode, 0)
        self.assertEqual(self.runs("one"), 2)
        self.assertTrue(self.receipt()["dirty"])

    def test_a_run_killed_in_the_middle_leaves_a_receipt_that_the_next_run_reuses(self):
        gate = self.out / "gate"
        # The third command kills the validation process (what the OS does to a test host) until the gate exists.
        self.set_final([self.step("one"), self.step("two"), self.step("three", f"[ -f {gate} ] || kill -9 $PPID"),
                        self.step("four")])
        first = self.finalize()
        self.assertNotEqual(first.returncode, 0)
        killed = self.receipt()
        self.assertEqual((killed["status"], len(killed["evidence"]), killed["tip"]), ("RUNNING", 2, self.tip()))
        self.assertEqual(self.runs("four"), 0)

        gate.touch()
        second = self.finalize()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual([self.runs(name) for name in ("one", "two", "three", "four")], [1, 1, 2, 1])
        self.assertIn("campaign final: PASS (4 commands, 2 reused)", second.stdout)

    def probe(self):
        """A final command that records what the validation sees of its finalize: marker, modes, environment, listing."""
        script = self.cache / "probe.sh"
        script.write_text("""\
set -u
marker=$(ls @CACHE@/*/finalizing/@SLUG@.json)
cp "$marker" @OUT@/marker.json
stat -c %a "$marker" "$(dirname "$marker")" > @OUT@/modes
printf %s "${AGENTIC_FINALIZE-unset}" > @OUT@/env
.agentic/bin/campaign finalizing > @OUT@/listing; echo $? > @OUT@/listing-rc
tr '\\0' ' ' < "/proc/$(jq -r .pid "$marker")/cmdline" > @OUT@/cmdline
""".replace("@CACHE@", str(self.cache)).replace("@SLUG@", self.repo.slug).replace("@OUT@", str(self.out)))
        return ["sh", str(script)]

    def test_the_marker_exists_while_the_final_validation_runs_and_is_gone_after_a_fail_and_a_pass(self):
        gate = self.out / "gate"
        self.set_final([self.probe(), self.step("two", f"test -f {gate}")])
        self.assertEqual(self.markers(), [])
        first = self.finalize()
        self.assertNotEqual(first.returncode, 0)
        marker = json.loads((self.out / "marker.json").read_text())
        self.assertEqual((marker["slug"], marker["tree"]), (self.repo.slug, str(self.repo.worktree.resolve())))
        self.assertIsInstance(marker["pid"], int)
        self.assertRegex(marker["startedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual((self.out / "modes").read_text().split(), ["600", "700"])
        self.assertEqual((self.out / "env").read_text(), self.repo.slug)
        self.assertIn("campaign", (self.out / "cmdline").read_text())
        self.assertEqual((self.out / "listing-rc").read_text().strip(), "0")
        self.assertRegex((self.out / "listing").read_text().strip(), rf"^{self.repo.slug} since .+ \(pid {marker['pid']}\)$")
        self.assertEqual(self.markers(), [])
        self.assertEqual(self.repo.command("finalizing", cwd=self.repo.worktree, check=False).returncode, 1)

        gate.touch()
        second = self.finalize()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.markers(), [])
        self.assertEqual(self.repo.command("finalizing", check=False).returncode, 1)

    def test_a_finalize_that_is_hung_up_removes_its_marker(self):
        script = self.cache / "hangup.sh"
        script.write_text(f'kill -HUP "$(jq -r .pid {self.cache}/*/finalizing/{self.repo.slug}.json)"; sleep 1\n')
        self.set_final([["sh", str(script)]])
        result = self.finalize()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.markers(), [])


class FinalizingCommandTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        identity = os.path.realpath(self.repo.root / ".git")
        self.dir = Path(os.path.realpath(self.repo.cache.name)) / hashlib.sha256(identity.encode()).hexdigest()[:16] / "finalizing"
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            process.kill()
            process.wait()
        self.repo.close()

    def marker(self, slug, pid, started="2026-01-05T15:30:00Z"):
        self.dir.mkdir(parents=True, exist_ok=True)
        path = self.dir / f"{slug}.json"
        path.write_text(json.dumps({"slug": slug, "pid": pid, "startedAt": started, "tree": "/nowhere"}))
        return path

    def process(self, name):
        """A live process; its command line holds the name."""
        process = subprocess.Popen(["bash", "-c", "sleep 60; true", name])
        self.processes.append(process)
        deadline = time.time() + 5
        while name not in Path(f"/proc/{process.pid}/cmdline").read_text() and time.time() < deadline:
            time.sleep(0.05)
        return process.pid

    def finalizing(self, *args, **options):
        return self.repo.command("finalizing", *args, check=False, **options)

    def test_without_markers_it_says_nothing_and_exits_1(self):
        result = self.finalizing()
        self.assertEqual((result.returncode, result.stdout), (1, ""))

    def test_a_live_finalize_is_listed_in_the_display_zone_and_exits_0(self):
        pid = self.process("campaign-fake")
        path = self.marker("big-feature", pid)
        result = self.finalizing(env={"AGENTIC_DISPLAY_TZ": "America/Sao_Paulo"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"big-feature since 12:30 (05/01) (pid {pid})\n")
        self.assertTrue(path.exists())

    def test_it_works_from_any_worktree_of_the_project(self):
        pid = self.process("campaign-fake")
        self.marker("big-feature", pid)
        self.repo.init_campaign()
        for where in (self.repo.root, self.repo.worktree):
            result = self.finalizing(cwd=where)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("big-feature since ", result.stdout)

    def test_a_marker_of_a_process_that_is_gone_is_removed(self):
        gone = subprocess.Popen(["true"])
        gone.wait()
        path = self.marker("old-one", gone.pid)
        result = self.finalizing()
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertFalse(path.exists())

    def test_a_marker_of_a_live_process_that_is_not_a_finalize_is_removed(self):
        pid = self.process("something-else")
        path = self.marker("reused-pid", pid)
        result = self.finalizing()
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertFalse(path.exists())

    def test_only_the_live_ones_are_listed_and_the_stale_ones_go(self):
        live = self.process("campaign-fake")
        gone = subprocess.Popen(["true"])
        gone.wait()
        stale = self.marker("stale", gone.pid)
        self.marker("live", live)
        broken = self.dir / "broken.json"
        broken.write_text("not json")
        result = self.finalizing()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertRegex(result.stdout, rf"^live since .+ \(pid {live}\)$")
        self.assertFalse(stale.exists() or broken.exists())

    def test_it_takes_no_option_but_help(self):
        helped = self.finalizing("--help")
        self.assertEqual(helped.returncode, 0)
        self.assertIn("campaign finalizing", helped.stdout)
        for args in (("--json",), ("slug",)):
            result = self.finalizing(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("finalizing", result.stderr)
        self.assertIn("finalizing", self.repo.command("help").stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)

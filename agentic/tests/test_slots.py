#!/usr/bin/env python3
"""Machine slots (lib/slots.sh): one limit for every round of a ticket and every final validation on a machine, without
leaks or deadlocks. Mock providers only; every test has a slot state of its own."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from test_campaign import Repo, ticket


class SlotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-slots-")
        self.state = Path(self.temp.name) / "state"
        self.repos = []
        self.held = {}
        self.leftovers = []

    def tearDown(self):
        for pid in self.leftovers:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for handle in self.held.values():
            handle.close()
        for repo in self.repos:
            if hasattr(repo, "worktree") and repo.worktree.is_dir():
                repo.command("stop", "--now", cwd=repo.worktree, check=False)
            repo.close()
        self.temp.cleanup()

    def campaign(self, tickets, slots="2", **env):
        repo = Repo()
        self.repos.append(repo)
        repo.init_campaign()
        repo.configure(tickets)
        repo.mock_provider()
        repo.env.update(AGENTIC_STATE=str(self.state), AGENTIC_SLOT_POLL_SECONDS="0.1", AGENTIC_SLOT_CHECK_SECONDS="1", **env)
        if slots is not None:
            repo.env["AGENTIC_SLOTS"] = slots
        return repo

    def run_campaign(self, repo, *extra, timeout=120):
        return subprocess.run([str(repo.binary(repo.worktree)), "run", "--provider", "mock", *extra], cwd=repo.worktree,
                              env=repo.env, text=True, capture_output=True, timeout=timeout)

    def status(self, repo):
        return json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)

    def states(self, repo):
        return {item["id"]: item["status"] for item in self.status(repo)["tickets"]}

    def events(self, repo):
        path = next(Path(repo.cache.name).rglob("campaign.ndjson"))
        return [json.loads(line) for line in path.read_text().splitlines()]

    def wait(self, condition, seconds=60, message="condition"):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if condition():
                return
            time.sleep(0.1)
        self.fail(f"timed out waiting for {message}")

    def slots(self):
        return self.state / "slots"

    def hold(self, index):
        """Takes slot INDEX from this test process, as another round would hold it."""
        self.slots().mkdir(parents=True, exist_ok=True)
        handle = open(self.slots() / f"slot.{index}", "a")
        fcntl.flock(handle, fcntl.LOCK_EX)
        self.held[index] = handle

    def let_go(self, index):
        self.held.pop(index).close()

    def free(self, index):
        path = self.slots() / f"slot.{index}"
        if not path.exists():
            return True
        with open(path, "a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.flock(handle, fcntl.LOCK_UN)
            return True

    def assert_nothing_stuck(self, capacity):
        self.assertEqual(sorted(path.name for path in (self.slots() / "queue").iterdir()), [])
        for index in range(capacity):
            self.assertTrue(self.free(index), f"slot.{index} is still held")
            self.assertEqual((self.slots() / f"slot.{index}").read_text(), "", f"slot.{index} still names a holder")

    def shell(self, repo, script, *arguments, env=None):
        """Runs SCRIPT with lib/common.sh and lib/slots.sh loaded, in the repository."""
        merged = dict(repo.env)
        merged.update(env or {})
        prelude = 'source "$0/.agentic/lib/common.sh"; source "$0/.agentic/lib/slots.sh"\n'
        return subprocess.Popen(["bash", "-c", prelude + script, str(repo.root), *arguments], cwd=repo.root, env=merged,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_two_campaigns_never_run_more_rounds_than_the_machine_has_slots(self):
        track = Path(self.temp.name) / "track"
        repos = [self.campaign([ticket(f"TST-00{i}", collision=(f"domain-{i}",)) for i in (1, 2)],
                               MOCK_TRACK_DIR=str(track), MOCK_SLEEP="1") for _ in range(2)]
        for repo in repos:
            repo.command("run", "--provider", "mock", "--mode", "unattended", "--workers", "2", cwd=repo.worktree)
        for repo in repos:
            self.wait(lambda: not self.status(repo)["runner"]["active"], seconds=120, message="both campaigns to end")
            self.assertEqual(set(self.states(repo).values()), {"done"})
        self.assertLessEqual(int((track / "max").read_text()), 2)
        types = [event["type"] for repo in repos for event in self.events(repo)]
        self.assertEqual(types.count("slot-taken"), 4)
        self.assertIn("waiting-slot", types)
        started = [event["message"] for repo in repos for event in self.events(repo) if event["type"] == "runner-started"]
        self.assertEqual(started, ["provider=mock workers=2 machine_slots=2"] * 2)
        self.assert_nothing_stuck(2)

    def test_a_grandchild_left_running_never_keeps_the_slot(self):
        """A worker that leaves a grandchild running does not hold the slot of the next round. This alone does not prove
        the descriptor is not inherited: provider_deadline.py closes the descriptors of the adapter, so the adapter never
        receives it. The proof is test_nothing_the_holder_starts_inherits_the_slot, which starts the background command
        from bash."""
        grandchildren = Path(self.temp.name) / "grandchildren"
        repo = self.campaign([ticket(f"TST-00{i}", collision=(f"domain-{i}",)) for i in (1, 2)], slots="1",
                             MOCK_GRANDCHILD=str(grandchildren))
        # With the slot leaked to the first worker's grandchild, the second round would wait for it forever.
        result = self.run_campaign(repo, "--workers", "2")
        pids = [int(line) for line in grandchildren.read_text().split()]
        self.leftovers += pids
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(self.states(repo).values()), {"done"})
        self.assertEqual(len(pids), 2)
        for pid in pids:
            os.kill(pid, 0)
        self.assertTrue(self.free(0))
        types = [event["type"] for event in self.events(repo)]
        self.assertEqual(types.count("slot-taken"), 2)
        self.assertIn("waiting-slot", types)

    def test_nothing_the_holder_starts_inherits_the_slot(self):
        """The providers and validation commands start through Python (which closes descriptors anyway); here the holder
        starts a background command straight from bash, then ends as offload does: by exec."""
        repo = Repo()
        self.repos.append(repo)
        pid_file = Path(self.temp.name) / "server.pid"
        env = dict(AGENTIC_STATE=str(self.state), AGENTIC_SLOTS="1", PID_FILE=str(pid_file))
        holder = self.shell(repo, 'slot_take validation server\n'
                                  'sleep 600 >/dev/null 2>&1 & printf "%s\\n" "$!" >>"$PID_FILE"\n'
                                  'exec bash -c \'sleep 600 >/dev/null 2>&1 & printf "%s\\n" "$!" >>"$PID_FILE"\'\n',
                            env=env)
        holder.communicate(timeout=30)
        self.leftovers += [int(line) for line in pid_file.read_text().split()]
        self.assertEqual(holder.returncode, 0)
        self.assertEqual(len(self.leftovers), 2)
        for pid in self.leftovers:
            os.kill(pid, 0)
        self.wait(lambda: self.free(0), seconds=5, message="the slot to come back without the holder")

    def test_a_worker_offloading_inside_its_round_does_not_wait_for_another_slot(self):
        seen = Path(self.temp.name) / "offload-slot"
        repo = self.campaign([ticket()], slots="1", MOCK_OFFLOAD=str(seen))
        result = self.run_campaign(repo, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual(seen.read_text(), "0\n")
        self.assert_nothing_stuck(1)

    def test_a_round_killed_with_sigkill_gives_its_slot_back_and_the_next_round_enters(self):
        """Only the round (the holder, whose pid the slot file names) is killed; the guard that keeps the lock is left alone
        and ends by itself, within the second `tail --pid` takes to look."""
        track = Path(self.temp.name) / "track"
        first = self.campaign([ticket()], slots="1", MOCK_TRACK_DIR=str(track), MOCK_SLEEP="60")
        first.command("run", "--provider", "mock", "--mode", "unattended", cwd=first.worktree)
        self.wait(lambda: (track / "active").exists() and (track / "active").read_text() == "1",
                  message="the worker to start")
        self.assertFalse(self.free(0))
        holder = json.loads((self.slots() / "slot.0").read_text())["pid"]
        os.kill(holder, signal.SIGKILL)
        # The provider runs in a session of its own and outlives the round; it never held the slot.
        try:
            self.wait(lambda: self.free(0), seconds=3, message="the slot to come back")
        finally:
            self.kill_sessions_of(first)
        second = self.campaign([ticket()], slots="1")
        result = self.run_campaign(second, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(second), {"TST-001": "done"})
        self.assert_nothing_stuck(1)

    def test_an_orphan_round_waiting_for_a_slot_ends_and_frees_the_runner_lock(self):
        repo = self.campaign([ticket()], slots="1")
        self.hold(0)
        repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=repo.worktree)
        self.wait(lambda: "waiting-slot" in [event["type"] for event in self.events(repo)], message="the round to wait")
        runtime = next(Path(repo.cache.name).rglob("runner.pid")).parent
        engine = int((runtime / "runner.pid").read_text())
        # Only the engine dies: the round, its child, goes on as an orphan with the runner.lock it inherited.
        os.kill(engine, signal.SIGKILL)
        self.wait(lambda: self.lock_free(runtime / "runner.lock"), seconds=15,
                  message="the orphan round to end and free the runner.lock")
        messages = [event["message"] for event in self.events(repo) if event["type"] == "waiting-slot"]
        self.assertIn("the engine that started this round is gone", messages[-1])
        self.assertNotIn("provider-started", [event["type"] for event in self.events(repo)])
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        # The slot was never taken by the orphan, and the relaunched campaign goes through once it is free.
        self.let_go(0)
        result = self.run_campaign(repo, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assert_nothing_stuck(1)

    def test_a_capacity_that_cannot_be_read_fails_everywhere_and_never_turns_the_limit_off(self):
        repo = Repo()
        self.repos.append(repo)
        repo.env.update(AGENTIC_STATE=str(self.state), AGENTIC_SLOTS="many")
        marker = Path(self.temp.name) / "ran"
        result = subprocess.run([str(repo.root / ".agentic" / "bin" / "offload"), "--", "touch", str(marker)],
                                cwd=repo.root, env=repo.env, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AGENTIC_SLOTS must be", result.stderr)
        self.assertFalse(marker.exists())
        # slot_take answers 2 for it, 1 for a wait ended by slot_stopping.
        process = self.shell(repo, 'rc=0; slot_take validation x || rc=$?; echo "rc=$rc"', env={"AGENTIC_SLOTS": "many"})
        out, err = process.communicate(timeout=30)
        self.assertEqual(out.strip(), "rc=2", err)
        self.hold(0)
        process = self.shell(repo, 'slot_stopping() { return 0; }; rc=0; slot_take validation x || rc=$?; echo "rc=$rc"',
                             env={"AGENTIC_STATE": str(self.state), "AGENTIC_SLOTS": "1", "AGENTIC_SLOT_CHECK_SECONDS": "0"})
        out, err = process.communicate(timeout=30)
        self.assertEqual(out.strip(), "rc=1", err)
        # A finalize fails too, before it validates anything.
        campaign = self.campaign([ticket()], slots="many")
        finalize = subprocess.run([str(campaign.binary(campaign.worktree)), "finalize"], cwd=campaign.worktree,
                                  env=campaign.env, text=True, capture_output=True, timeout=60)
        self.assertNotEqual(finalize.returncode, 0)
        self.assertIn("AGENTIC_SLOTS must be", finalize.stderr)

    def test_a_free_slot_that_still_names_a_dead_holder_is_emptied_by_the_next_take(self):
        repo = Repo()
        self.repos.append(repo)
        self.slots().mkdir(parents=True)
        (self.slots() / "slot.1").write_text('{"pid":999999,"kind":"provider","label":"dead","since":"2020-01-01T00:00:00Z"}\n')
        process = self.shell(repo, 'slot_take validation x; echo "slot=$AGENTIC_SLOT"',
                             env={"AGENTIC_STATE": str(self.state), "AGENTIC_SLOTS": "2"})
        out, err = process.communicate(timeout=30)
        self.assertEqual(out.strip(), "slot=0", err)
        self.assertEqual((self.slots() / "slot.1").read_text(), "")

    def lock_free(self, path):
        with open(path, "a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            return True

    def kill_sessions_of(self, repo):
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if repo.cache.name in (entry / "cmdline").read_bytes().decode(errors="replace"):
                    os.killpg(os.getpgid(int(entry.name)), signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass

    def test_twenty_requests_with_two_slots_all_pass_in_order(self):
        repo = Repo()
        self.repos.append(repo)
        log = Path(self.temp.name) / "log"
        env = dict(AGENTIC_STATE=str(self.state), AGENTIC_SLOTS="2", AGENTIC_SLOT_POLL_SECONDS="0.05",
                   AGENTIC_SLOT_CHECK_SECONDS="1", LOG=str(log))
        # The hook runs inside slot_take, before the request leaves the queue: the log has the order of the queue.
        script = ('slot_taken() { printf "taken %s\\n" "$label" >>"$LOG"; }\n'
                  'slot_waiting() { :; }\n'
                  'slot_take validation "request $1"\n'
                  'sleep 0.1; printf "end %s\\n" "$1" >>"$LOG"\n'
                  'slot_release\n')
        self.hold(0)
        self.hold(1)
        processes = []
        for number in range(20):
            processes.append(self.shell(repo, script, str(number), env=env))
            self.wait(lambda: len(list((self.slots() / "queue").glob("[0-9]*"))) == number + 1, seconds=10,
                      message=f"request {number} in the queue")
        # A waiter that dies in the queue is dropped; the ones behind it go on.
        processes[7].kill()
        processes[7].communicate()
        self.let_go(0)
        self.let_go(1)
        for number, process in enumerate(processes):
            if number == 7:
                continue
            out, err = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, err)
        lines = log.read_text().split("\n")[:-1]
        expected = [f"request {number}" for number in range(20) if number != 7]
        self.assertEqual([line.removeprefix("taken ") for line in lines if line.startswith("taken ")], expected)
        running = highest = 0
        for line in lines:
            running += 1 if line.startswith("taken ") else -1
            highest = max(highest, running)
        self.assertEqual(highest, 2)
        self.assert_nothing_stuck(2)

    def test_without_a_capacity_nothing_changes(self):
        repo = self.campaign([ticket()], slots=None)
        result = self.run_campaign(repo, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.events(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertFalse({"waiting-slot", "slot-taken"} & {event["type"] for event in events})
        self.assertEqual([event["message"] for event in events if event["type"] == "runner-started"],
                         ["provider=mock workers=2"])
        offload = subprocess.run([str(repo.root / ".agentic" / "bin" / "offload"), "--", "sh", "-c",
                                  'printf "%s" "${AGENTIC_SLOT:-none}"'], cwd=repo.root, env=repo.env, text=True,
                                 capture_output=True, timeout=30)
        self.assertEqual((offload.returncode, offload.stdout), (0, "none"), offload.stderr)
        self.assertFalse(self.slots().exists())

    def test_the_overview_shows_a_round_waiting_for_a_slot_and_a_stop_ends_the_wait(self):
        repo = self.campaign([ticket()], slots="1")
        self.hold(0)
        repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=repo.worktree)

        def phase():
            overview = json.loads(repo.command("overview", "--json", cwd=repo.worktree).stdout)
            tickets = overview["campaigns"][0]["tickets"]
            return tickets[0].get("phase"), tickets[0].get("phase_note")

        self.wait(lambda: phase()[0] == "waiting-for-slot", message="the round to wait for a slot")
        self.assertIn("position=1", phase()[1])
        repo.command("stop", cwd=repo.worktree)
        self.wait(lambda: not self.status(repo)["runner"]["active"], message="the runner to stop")
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        messages = [event["message"] for event in self.events(repo) if event["type"] == "waiting-slot"]
        self.assertIn("stop requested", messages[-1])
        self.assertNotIn("provider-started", [event["type"] for event in self.events(repo)])
        # Once the slot is free, the next run goes through.
        self.let_go(0)
        result = self.run_campaign(repo, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assert_nothing_stuck(1)

    def test_an_offload_from_a_terminal_waits_for_a_slot_and_runs_in_it(self):
        repo = Repo()
        self.repos.append(repo)
        repo.env.update(AGENTIC_STATE=str(self.state), AGENTIC_SLOTS="1", AGENTIC_SLOT_POLL_SECONDS="0.1")
        command = [str(repo.root / ".agentic" / "bin" / "offload"), "--", "sh", "-c", 'printf "%s" "${AGENTIC_SLOT:-none}"']
        self.hold(0)
        waiting = subprocess.Popen(command, cwd=repo.root, env=repo.env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        # An offloaded command (or an executor run) never asks for one.
        nested = subprocess.run(command, cwd=repo.root, env=dict(repo.env, AGENTIC_OFFLOAD="1"), text=True,
                                capture_output=True, timeout=30)
        self.assertEqual((nested.returncode, nested.stdout), (0, "none"), nested.stderr)
        time.sleep(1)
        self.assertIsNone(waiting.poll())
        self.let_go(0)
        out, err = waiting.communicate(timeout=30)
        self.assertEqual((waiting.returncode, out), (0, "0"), err)
        self.assertIn("offload: waiting for a machine slot (1 of 1 in the queue, 1 slots)", err)
        self.wait(lambda: self.free(0), seconds=5, message="the slot to come back after the command")

    def test_finalize_waits_for_a_slot_before_its_final_validation(self):
        repo = self.campaign([ticket()], slots="1")
        self.assertEqual(self.run_campaign(repo, timeout=90).returncode, 0)
        self.hold(0)
        finalize = subprocess.Popen([str(repo.binary(repo.worktree)), "finalize"], cwd=repo.worktree, env=repo.env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(1.5)
        self.assertIsNone(finalize.poll())
        self.let_go(0)
        out, err = finalize.communicate(timeout=90)
        self.assertEqual(finalize.returncode, 0, err)
        self.assertIn("campaign: waiting for a machine slot (1 of 1 in the queue, 1 slots)", err)
        self.assertIn("finalized", out)
        self.assert_nothing_stuck(1)

    def test_the_capacity_comes_from_the_environment_else_the_fleet(self):
        repo = Repo()
        self.repos.append(repo)
        fleet = Path(self.temp.name) / "fleet.json"
        fleet.write_text(json.dumps({"machines": {"here": {"ssh": "here", "id": "test-machine", "slots": 3}},
                                     "projects": {}}))
        base = dict(AGENTIC_FLEET=str(fleet), AGENTIC_MACHINE_ID="test-machine")

        def capacity(**env):
            process = self.shell(repo, "slot_capacity", env={**base, **env})
            out, err = process.communicate(timeout=30)
            return process.returncode, out.strip(), err

        self.assertEqual(capacity()[:2], (0, "3"))
        self.assertEqual(capacity(AGENTIC_SLOTS="2")[:2], (0, "2"))
        self.assertEqual(capacity(AGENTIC_SLOTS="0")[:2], (0, ""))
        self.assertEqual(capacity(AGENTIC_MACHINE_ID="another")[:2], (0, ""))
        self.assertIn("AGENTIC_SLOTS must be", capacity(AGENTIC_SLOTS="many")[2])
        fleet.write_text(json.dumps({"machines": {"here": {"ssh": "here", "id": "test-machine", "slots": "four"}},
                                     "projects": {}}))
        self.assertIn("machines.here.slots", capacity()[2])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Controlling a running campaign: stop (drained or at once), restart, the desired state, and the supervisor that
relaunches a campaign that should be running. Mock providers only."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

from test_campaign import Repo, ticket


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.repo.init_campaign()

    def tearDown(self):
        # A runner left behind by a failed test must not outlive it.
        if hasattr(self, "repo"):
            self.repo.command("stop", "--now", cwd=self.repo.worktree, check=False)
            self.repo.close()

    def status(self):
        return json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)

    def states(self):
        return {item["id"]: item["status"] for item in self.status()["tickets"]}

    def wait(self, condition, seconds=30, message="condition"):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if condition():
                return
            time.sleep(0.2)
        self.fail(f"timed out waiting for {message}")

    def events(self):
        path = next(Path(self.repo.cache.name).rglob("campaign.ndjson"))
        return [json.loads(line) for line in path.read_text().splitlines()]

    def slow(self, seconds):
        self.repo.env.update(MOCK_TRACK_DIR=str(Path(self.repo.cache.name) / "track"), MOCK_SLEEP=str(seconds))

    def run_campaign(self, *extra):
        return self.repo.command("run", "--provider", "mock", "--mode", "unattended", *extra, cwd=self.repo.worktree)

    def test_run_refuses_a_plan_that_is_not_committed_and_starts_no_engine(self):
        self.repo.configure([ticket("TST-001")])
        self.repo.mock_provider()
        extra = self.repo.worktree / "campaigns" / self.repo.slug / "tickets" / "TST-002.md"
        extra.write_text(ticket("TST-002"))
        validation = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(validation.read_text())
        plan["tickets"]["TST-002"] = plan["tickets"]["TST-001"]
        validation.write_text(json.dumps(plan))
        (self.repo.worktree / "campaigns" / self.repo.slug / "codex-effort.json").write_text("{}\n")
        result = self.repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not committed", result.stderr)
        self.assertIn("campaigns/harness-sample/tickets/TST-002.md", result.stderr)
        self.assertIn("campaigns/harness-sample/codex-effort.json", result.stderr)
        self.assertNotIn("TST-001.md", result.stderr)
        self.assertIn("git add campaigns/harness-sample/", result.stderr)
        self.assertIn("git commit -m 'docs(agentic):", result.stderr)
        # No engine: nothing runs, no runner starts, the ticket stays todo.
        self.assertFalse(self.status()["runner"]["active"])
        self.assertEqual([], list(Path(self.repo.cache.name).rglob("runner.pid")))
        self.assertEqual([], list(Path(self.repo.cache.name).rglob("agentic/bin/campaign")))
        self.assertEqual(self.states(), {"TST-001": "todo", "TST-002": "todo"})
        self.assertIn("campaigns/harness-sample/validation.json", result.stderr)
        # Committed, the plan runs; a later change to a committed plan file is refused the same way.
        self.repo.git("add", ".", cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "plan", cwd=self.repo.worktree)
        validation.write_text(validation.read_text() + "\n")
        result = self.repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("campaigns/harness-sample/validation.json", result.stderr)

    def test_run_with_the_plan_committed_goes_on_as_before(self):
        self.repo.configure([ticket("TST-001")])
        self.repo.mock_provider()
        # Work that is not the plan (a scratch file) does not stop the run.
        (self.repo.worktree / "scratch.txt").write_text("not part of the plan\n")
        result = self.run_campaign()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.wait(lambda: not self.status()["runner"]["active"], message="the runner to end")
        self.assertEqual(set(self.states().values()), {"done"})

    def test_finalize_lists_the_files_that_leave_the_worktree_dirty(self):
        self.repo.configure([ticket("TST-001", status="done")])
        (self.repo.worktree / "campaigns" / self.repo.slug / "validation.json").write_text("{}\n")
        (self.repo.worktree / "stray.txt").write_text("x\n")
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("campaign worktree is dirty", result.stderr)
        self.assertIn("campaigns/harness-sample/validation.json", result.stderr)
        self.assertIn("stray.txt", result.stderr)
        for index in range(25):
            (self.repo.worktree / f"many-{index:02d}.txt").write_text("x\n")
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        listed = [line for line in result.stderr.splitlines() if line.startswith(("??", " M", "M ", "A "))]
        self.assertEqual(len(listed), 20)
        self.assertIn("and 7 more", result.stderr)

    def test_stop_lets_the_running_ticket_end_and_starts_no_other(self):
        self.repo.configure([ticket("TST-001", collision=("one",)), ticket("TST-002", collision=("two",))])
        self.repo.mock_provider()
        self.slow(3)
        self.run_campaign("--workers", "1")
        self.wait(lambda: "in-progress" in self.states().values(), message="a ticket in progress")
        result = self.repo.command("stop", cwd=self.repo.worktree)
        self.assertIn("no new ticket starts", result.stdout)
        self.assertIn("stopping", self.repo.command("status", cwd=self.repo.worktree).stdout)
        self.wait(lambda: not self.status()["runner"]["active"], message="the runner to stop")
        self.assertEqual(sorted(self.states().values()), ["done", "todo"])
        self.assertIn("runner-stopped", [event["type"] for event in self.events()])
        self.assertEqual(self.status()["runner"]["desired"], "stopped")
        self.assertIn("Runner: inactive, stopped", self.repo.command("status", cwd=self.repo.worktree).stdout)
        # campaign run takes it up again.
        self.repo.env["MOCK_SLEEP"] = "0"
        self.run_campaign("--workers", "1")
        self.wait(lambda: not self.status()["runner"]["active"], message="the second run to end")
        self.assertEqual(set(self.states().values()), {"done"})
        self.assertEqual(self.status()["runner"]["desired"], "running")

    def test_stop_now_ends_the_runner_at_once_and_the_next_run_finishes(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.slow(60)
        self.run_campaign()
        self.wait(lambda: (Path(self.repo.cache.name) / "track" / "active").exists(), message="the worker to start")
        started = time.time()
        result = self.repo.command("stop", "--now", cwd=self.repo.worktree)
        self.assertLess(time.time() - started, 15)
        self.assertIn("Stopped harness-sample at once", result.stdout)
        self.assertFalse(self.status()["runner"]["active"])
        self.assertIn("stopped at once", [e["message"] for e in self.events() if e["type"] == "runner-stopped"][-1])
        self.repo.env["MOCK_SLEEP"] = "0"
        self.run_campaign()
        self.wait(lambda: not self.status()["runner"]["active"], message="the run to end")
        self.assertEqual(self.states(), {"TST-001": "done"})

    def test_a_run_before_the_runner_stops_cancels_the_stop(self):
        self.repo.configure([ticket("TST-001", collision=("one",)), ticket("TST-002", collision=("two",))])
        self.repo.mock_provider()
        self.slow(2)
        self.run_campaign("--workers", "1")
        self.wait(lambda: "in-progress" in self.states().values(), message="a ticket in progress")
        self.repo.command("stop", cwd=self.repo.worktree)
        result = self.run_campaign("--workers", "1")
        self.assertIn("stop of harness-sample is cancelled", result.stdout)
        self.wait(lambda: not self.status()["runner"]["active"], seconds=40, message="the runner to end")
        self.assertEqual(set(self.states().values()), {"done"})

    def test_restart_runs_again_with_the_last_settings(self):
        self.repo.configure([ticket("TST-001", collision=("one",)), ticket("TST-002", collision=("two",))])
        self.repo.mock_provider()
        self.slow(60)
        self.run_campaign("--workers", "1")
        self.wait(lambda: (Path(self.repo.cache.name) / "track" / "active").exists(), message="the worker to start")
        self.repo.env["MOCK_SLEEP"] = "0"
        # The first run's settings come back with restart.
        first = json.loads(next(Path(self.repo.cache.name).rglob("run-config.json")).read_text())
        first["env"]["AGENTIC_CLAUDE_EFFORT"] = "low"
        next(Path(self.repo.cache.name).rglob("run-config.json")).write_text(json.dumps(first))
        result = self.repo.command("restart", "--now", cwd=self.repo.worktree)
        self.assertIn("started detached", result.stdout)
        self.wait(lambda: not self.status()["runner"]["active"], message="the restarted run to end")
        self.assertEqual(set(self.states().values()), {"done"})
        config = json.loads(next(Path(self.repo.cache.name).rglob("run-config.json")).read_text())
        self.assertEqual((config["provider"], config["workers"]), ("mock", 1))
        self.assertEqual(config["env"]["AGENTIC_CLAUDE_EFFORT"], "low")

    def test_the_settings_of_a_run_leave_out_what_belongs_to_the_machine(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.repo.env.update(AGENTIC_SLOT="2", AGENTIC_STATE="/machine/state", AGENTIC_CLAUDE_EFFORT="low")
        self.run_campaign("--workers", "1")
        self.wait(lambda: not self.status()["runner"]["active"], message="the run to end")
        env = json.loads(next(Path(self.repo.cache.name).rglob("run-config.json")).read_text())["env"]
        self.assertEqual(env["AGENTIC_CLAUDE_EFFORT"], "low")
        self.assertNotIn("AGENTIC_SLOT", env)
        self.assertNotIn("AGENTIC_STATE", env)

    def test_status_overview_and_run_say_where_the_campaign_is_and_how_to_open_it(self):
        self.repo.configure([ticket()])
        tree = str(self.repo.worktree)
        location = self.status()["location"]
        self.assertEqual((location["worktree"], location["project"]), (tree, str(self.repo.root)))
        self.assertEqual(location["open"], f"cd {tree} && claude")
        self.assertTrue(location["machine"])
        text = self.repo.command("status", cwd=self.repo.worktree).stdout
        self.assertIn(f"Worktree: {tree}", text)
        self.assertIn(f"Open: cd {tree} && claude", text)
        self.repo.mock_provider()
        result = self.run_campaign()
        self.assertIn(f"Open: cd {tree} && mock", result.stdout)
        overview = json.loads(self.repo.command("overview", "--json").stdout)["campaigns"][0]
        self.assertEqual((overview["worktree"], overview["project"], overview["open"]), (tree, str(self.repo.root), f"cd {tree} && mock"))
        self.assertIn(f"  open: cd {tree} && mock", self.repo.command("overview").stdout)

    def test_a_ticket_waits_for_quota_and_runs_again_without_spending_an_attempt(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.repo.env.update(MOCK_QUOTA_ONCE=str(Path(self.repo.cache.name) / "quota"), MOCK_QUOTA_SECONDS="2",
                             AGENTIC_QUOTA_MIN_WAIT_SECONDS="1")
        self.run_campaign()
        self.wait(lambda: not self.status()["runner"]["active"], seconds=60, message="the run to end")
        self.assertEqual(self.states(), {"TST-001": "done"})
        types = [event["type"] for event in self.events()]
        self.assertIn("provider-quota-wait", types)
        self.assertIn("provider-quota-back", types)
        self.assertNotIn("provider-failed", types)
        waits = [e["message"] for e in self.events() if e["type"] == "provider-quota-wait"]
        self.assertIn("out of quota; the ticket waits until", waits[0])

    def test_a_stop_ends_the_wait_for_quota_and_keeps_the_ticket_for_the_next_run(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.repo.env.update(MOCK_QUOTA_ONCE=str(Path(self.repo.cache.name) / "quota"), MOCK_QUOTA_SECONDS="600")
        self.run_campaign()
        self.wait(lambda: "provider-quota-wait" in [e["type"] for e in self.events()], message="the wait for quota")
        progress = json.loads(self.repo.command("overview", "--json").stdout)["campaigns"][0]["tickets"][0]
        self.assertEqual(progress["phase"], "waiting-for-quota")
        self.assertIn("the ticket waits until", progress["phase_note"])
        self.repo.command("stop", cwd=self.repo.worktree)
        self.wait(lambda: not self.status()["runner"]["active"], seconds=40, message="the runner to stop")
        self.assertIn("stop requested during the wait for quota",
                      " ".join(e["message"] for e in self.events() if e["type"] == "provider-quota-wait"))
        self.assertNotEqual(self.states()["TST-001"], "done")
        self.repo.env.update(MOCK_QUOTA_SECONDS="1", AGENTIC_QUOTA_MIN_WAIT_SECONDS="1")
        self.run_campaign()
        self.wait(lambda: not self.status()["runner"]["active"], seconds=60, message="the next run to end")
        self.assertEqual(self.states(), {"TST-001": "done"})

    def test_restart_needs_a_previous_run_or_a_provider(self):
        self.repo.configure([ticket()])
        result = self.repo.command("restart", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("never ran here", result.stderr)

    def supervise(self):
        return self.repo.command("_supervise", "--once", env={"AGENTIC_SUPERVISOR_DELAY_SECONDS": "0"})

    def test_the_supervisor_relaunches_a_campaign_that_should_be_running(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.slow(60)
        self.run_campaign()
        self.wait(lambda: (Path(self.repo.cache.name) / "track" / "active").exists(), message="the worker to start")
        self.repo.command("stop", "--now", cwd=self.repo.worktree)
        # As after a reboot: the campaign should run, and its runner is gone.
        campaign = next(Path(self.repo.cache.name).rglob("campaign.json"))
        campaign.write_text(json.dumps(dict(json.loads(campaign.read_text()), desired="running")))
        self.repo.env["MOCK_SLEEP"] = "0"
        self.supervise()
        self.wait(lambda: not self.status()["runner"]["active"], message="the relaunched run to end")
        self.assertEqual(self.states(), {"TST-001": "done"})
        relaunches = [e for e in self.events() if e["type"] == "supervisor-relaunch"]
        self.assertEqual(len(relaunches), 1)
        self.assertIn("relaunch 1/3", relaunches[0]["message"])

    def test_the_supervisor_leaves_a_stopped_campaign_alone(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.slow(60)
        self.run_campaign()
        self.wait(lambda: (Path(self.repo.cache.name) / "track" / "active").exists(), message="the worker to start")
        self.repo.command("stop", "--now", cwd=self.repo.worktree)
        self.supervise()
        time.sleep(1)
        self.assertFalse(self.status()["runner"]["active"])
        self.assertNotIn("supervisor-relaunch", [event["type"] for event in self.events()])

    def test_the_supervisor_leaves_a_campaign_that_waits_for_its_coordinator(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider(worker="BLOCKED")
        self.run_campaign()
        self.wait(lambda: not self.status()["runner"]["active"], message="the runner to pause")
        self.assertIn(self.states()["TST-001"], ("blocked", "needs-human"))
        self.supervise()
        time.sleep(1)
        self.assertNotIn("supervisor-relaunch", [event["type"] for event in self.events()])


class QuotaJitterTests(unittest.TestCase):
    """The time wait_for_quota gives to the rounds waiting for the same quota gets a random delay."""

    BACK = 4_000_000_000
    PROVIDER = Path(__file__).resolve().parents[1] / "lib" / "provider.sh"

    def back_times(self, runs, seed, jitter=None):
        # The stub of desired_state ends each wait at once; the stub of in_display_tz shows the time as epoch seconds.
        script = r'''
            source "$1"
            campaign_slug() { echo slug; }
            desired_state() { echo stopped; }
            in_display_tz() { printf '%s' "${3#@}"; }
            event() { printf '%s\n' "$2"; }
            printf 'accounts-back-at=%s\n' "$2" > "$3"
            RANDOM=$4
            for _ in $(seq "$5"); do wait_for_quota TST-001 "$3" worker || true; done
        '''
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ)
            env.pop("AGENTIC_QUOTA_JITTER_SECONDS", None)
            if jitter is not None:
                env["AGENTIC_QUOTA_JITTER_SECONDS"] = jitter
            result = subprocess.run(["bash", "-c", script, "_", str(self.PROVIDER), str(self.BACK),
                                     str(Path(directory) / "log"), str(seed), str(runs)],
                                    env=env, text=True, capture_output=True, check=True)
        found = [int(m.group(1)) for line in result.stdout.splitlines() if (m := re.search(r"waits until (\d+) and", line))]
        self.assertEqual(len(found), runs)
        return [value - self.BACK for value in found]

    def test_the_default_delay_is_between_zero_and_120_seconds_and_varies(self):
        delays = self.back_times(60, seed=7)
        self.assertTrue(all(0 <= delay <= 120 for delay in delays), delays)
        self.assertGreater(len(set(delays)), 10)

    def test_a_fixed_seed_gives_the_same_delays(self):
        self.assertEqual(self.back_times(10, seed=42, jitter="30"), self.back_times(10, seed=42, jitter="30"))
        self.assertTrue(all(0 <= delay <= 30 for delay in self.back_times(40, seed=3, jitter="30")))

    def test_a_zero_delay_keeps_the_exact_time(self):
        self.assertEqual(set(self.back_times(5, seed=1, jitter="0")), {0})

    def test_an_invalid_delay_falls_back_to_the_default(self):
        delays = self.back_times(40, seed=5, jitter="soon")
        self.assertTrue(all(0 <= delay <= 120 for delay in delays), delays)
        self.assertGreater(max(delays), 0)


if __name__ == "__main__":
    unittest.main()

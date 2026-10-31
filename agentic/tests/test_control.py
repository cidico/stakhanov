#!/usr/bin/env python3
"""Controlling a running campaign: stop (drained or at once), restart, the desired state, and the supervisor that
relaunches a campaign that should be running. Mock providers only."""

from __future__ import annotations

import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()

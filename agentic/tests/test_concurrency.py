#!/usr/bin/env python3
"""Races between runs on one machine: the main branch lock of finalize, and the names a campaign can never take."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
import unittest

from test_campaign import Repo, SPEC, ticket

RESERVED = ["queue", "moved", "finalized", "finalizing", "supervisor", "archive", "tasks", "slots", "fleet-seen", "main"]


def wait_for(condition, seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


class ReservedNameTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()

    def tearDown(self):
        self.repo.close()

    def test_init_refuses_every_reserved_name(self):
        for name in RESERVED:
            with self.subTest(name=name):
                result = self.repo.command("init", "SPEC.md", "--slug", name, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"campaign slug '{name}' is reserved", result.stderr)
                self.assertEqual(self.repo.git("branch", "--list", f"campaign/{name}").stdout, "")

    def test_a_name_that_only_contains_a_reserved_one_is_free(self):
        for name in ("queue-two", "main-fix", "tasks1"):
            with self.subTest(name=name):
                (self.repo.root / "SPEC.md").write_text(SPEC)
                self.repo.command("init", "SPEC.md", "--slug", name)

    def test_a_queue_definition_refuses_a_reserved_slug(self):
        definition = {"name": "night", "provider": "mock", "campaigns": [
            {"slug": "archive", "spec": "SPEC.md", "tickets": "tickets", "validation": "validation.json"}]}
        path = self.repo.root / "queue.json"
        path.write_text(json.dumps(definition))
        result = self.repo.command("queue", "start", str(path), "--foreground", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved", result.stderr)


class MainLockTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.repo.init_campaign()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.repo.configure([ticket(status="done")])
        self.cache = Path(self.repo.cache.name)
        self.out = self.cache / "out"
        self.out.mkdir()
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait()
        self.repo.close()

    def base(self):
        return next(self.cache.glob(f"*/{self.repo.slug}")).parent

    def set_final(self, worktree, slug, commands):
        manifest = worktree / "campaigns" / slug / "validation.json"
        plan = json.loads(manifest.read_text())
        plan["final"] = commands
        manifest.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=worktree)
        self.repo.git("commit", "-m", "final plan", cwd=worktree)

    def second_campaign(self):
        (self.repo.root / "SPEC.md").write_text(SPEC)
        result = self.repo.command("init", "SPEC.md", "--slug", "second-one")
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        worktree = Path(next(line for line in result.stdout.splitlines() if line.startswith("Worktree: ")).removeprefix("Worktree: "))
        first = self.repo.worktree, self.repo.slug
        self.repo.worktree, self.repo.slug = worktree, "second-one"
        self.repo.configure([ticket(status="done")])
        self.repo.worktree, self.repo.slug = first
        return worktree

    def start(self, worktree, name, env=None):
        merged = dict(self.repo.env, **(env or {}))
        stdout = open(self.out / f"{name}.out", "w")
        process = subprocess.Popen([str(self.repo.binary(worktree)), "finalize"], cwd=worktree, env=merged, text=True,
                                   stdout=stdout, stderr=subprocess.STDOUT)
        stdout.close()
        self.processes.append(process)
        return process

    def output(self, name):
        path = self.out / f"{name}.out"
        return path.read_text() if path.exists() else ""

    def test_two_finalizes_at_once_one_waits_for_the_other_and_both_finish(self):
        second = self.second_campaign()
        gate = self.out / "go"
        # The first one stays in its final validation, which holds the main branch, until the gate opens.
        self.set_final(self.repo.worktree, self.repo.slug, [["sh", "-c", f"touch {self.out}/started; while [ ! -f {gate} ]; do sleep 0.05; done"]])
        first = self.start(self.repo.worktree, "first")
        self.assertTrue(wait_for(lambda: (self.out / "started").exists()), self.output("first"))
        base = self.base()
        holder = (base / "main.lock.holder").read_text()
        self.assertTrue(holder.startswith(f"{first.pid}\t"), holder)
        self.assertIn("finalize", holder)

        waiting = self.start(second, "second")
        self.assertTrue(wait_for(lambda: "Waiting for the main branch lock" in self.output("second")), self.output("second"))
        self.assertIn(f"held by pid {first.pid} (", self.output("second"))
        self.assertIsNone(waiting.poll())
        gate.touch()
        self.assertEqual(first.wait(timeout=120), 0, self.output("first"))
        self.assertEqual(waiting.wait(timeout=120), 0, self.output("second"))
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout, "")
        self.assertFalse((base / "main.lock.holder").exists())
        for slug in (self.repo.slug, "second-one"):
            self.assertTrue((base / "finalized" / f"{slug}.json").exists())

    def test_a_finalize_that_waits_too_long_says_who_holds_the_lock(self):
        lock = self.base() / "main.lock"
        (self.base() / "main.lock.holder").write_text("4242\tcampaign finalize somewhere-else\n")
        with lock.open("a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            started = time.time()
            result = self.repo.command("finalize", cwd=self.repo.worktree, check=False, env={"AGENTIC_MAIN_LOCK_WAIT_SECONDS": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.time() - started, 30)
        self.assertIn("main.lock is still held by pid 4242 (campaign finalize somewhere-else) after 1s", result.stderr)
        # Nothing moved.
        self.assertIn(f"campaign/{self.repo.slug}", self.repo.git("branch", "--list", "campaign/*").stdout)

    def test_with_main_lock_runs_a_command_holding_the_lock_and_returns_its_status(self):
        lib = Path(self.repo.root) / ".agentic" / "lib"
        script = f"""
            set -Eeuo pipefail
            export AGENTIC_CACHE={self.cache}
            REPO_ROOT={self.repo.root}
            source {lib}/common.sh
            source {lib}/slots.sh
            source {lib}/finalize.sh
            held() {{ flock -n "$(main_lock_file)" true && echo FREE || echo HELD; return 7; }}
            status=0
            with_main_lock held || status=$?
            echo "status=$status"
            flock -n "$(main_lock_file)" true && echo RELEASED
        """
        result = subprocess.run(["bash", "-c", script], text=True, capture_output=True, env=dict(os.environ))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["HELD", "status=7", "RELEASED"])


if __name__ == "__main__":
    unittest.main()

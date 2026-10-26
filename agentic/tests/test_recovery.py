#!/usr/bin/env python3
"""Finalization recovery and namespace-boundary tests."""

from __future__ import annotations

import json
from pathlib import Path
import unittest

from test_campaign import Repo, ticket


class FinalizationRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.repo.init_campaign()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)

    def tearDown(self):
        self.repo.close()

    def test_failed_final_validation_preserves_recoverable_campaign(self):
        self.repo.configure([ticket()])
        manifest = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(manifest.read_text())
        plan["final"] = [["false"]]
        manifest.write_text(json.dumps(plan))
        self.repo.git("add", str(manifest), cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "failing final proof", cwd=self.repo.worktree)
        self.repo.mock_provider()
        run = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)

        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.repo.worktree.is_dir())
        self.assertTrue((self.repo.worktree / "campaigns" / self.repo.slug / "SPEC.md").is_file())
        self.assertIn(
            f"campaign/{self.repo.slug}",
            self.repo.git("branch", "--list", f"campaign/{self.repo.slug}").stdout,
        )
        self.assertTrue(any(path.name == self.repo.slug for path in Path(self.repo.cache.name).rglob(self.repo.slug)))

    def test_finalize_rebases_fast_forwards_and_removes_owned_state(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        run = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        (self.repo.root / "main-advanced.txt").write_text("main advanced\n")
        self.repo.git("add", "main-advanced.txt")
        self.repo.git("commit", "-m", "advance main")

        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.git("branch", "--show-current").stdout.strip(), "main")
        self.assertTrue((self.repo.root / "main-advanced.txt").is_file())
        self.assertFalse((self.repo.root / "campaigns" / self.repo.slug).exists())
        self.assertNotIn(
            f"campaign/{self.repo.slug}",
            self.repo.git("branch", "--list", f"campaign/{self.repo.slug}").stdout,
        )
        self.assertFalse(self.repo.worktree.exists())
        self.assertFalse(any(path.name == self.repo.slug for path in Path(self.repo.cache.name).rglob(self.repo.slug)))
        self.assertNotIn(
            f"agentic/{self.repo.slug}/",
            self.repo.git("branch", "--list", f"agentic/{self.repo.slug}/*").stdout,
        )

    def test_finalize_runs_campaign_expensive_validation(self):
        self.repo.configure([ticket()])
        marker = Path(self.repo.cache.name) / "campaign-l4-ran"
        manifest = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(manifest.read_text())
        plan["campaign_expensive"] = [["touch", str(marker)]]
        manifest.write_text(json.dumps(plan))
        self.repo.git("add", str(manifest), cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "declare campaign expensive", cwd=self.repo.worktree)
        self.repo.mock_provider()
        run = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.is_file())

    def test_finalize_preserves_branches_outside_owned_namespace(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        run = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        foreign_branches = ("foreign/keep", "campaign/other", "agentic/other/TST-999")
        for branch in foreign_branches:
            self.repo.git("branch", branch)

        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        for branch in foreign_branches:
            self.assertIn(branch, self.repo.git("branch", "--list", branch).stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)

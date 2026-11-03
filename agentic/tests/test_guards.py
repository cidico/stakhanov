#!/usr/bin/env python3
"""The guards of the kit: a validation that must fail on the base, the guard every reviewer finding names, and the files a
worker may not reach. No real provider process is used."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_campaign import Repo, TICKETS, ticket

CHEAP = ["git", "diff", "--check", "HEAD"]
PRODUCT = ["test", "-f", "product-TST-001.txt"]


class GuardCase(unittest.TestCase):
    def tearDown(self):
        for repo in getattr(self, "repos", []):
            repo.close()

    def repo(self, tickets=None, cheap=None, settings=None, **plan_edits):
        """A campaign with its mock provider; cheap (a list of argv) replaces the cheap phase of every ticket."""
        if not hasattr(self, "repos"):
            self.repos = []
        repo = Repo(settings=settings)
        self.repos.append(repo)
        repo.init_campaign()
        repo.configure(tickets or [ticket()])
        repo.mock_provider()
        edits = dict(plan_edits, **({} if cheap is None else {"cheap": cheap}))
        if edits:
            self.edit_plan(repo, lambda plan: [item.update(edits) for item in plan["tickets"].values()])
        return repo

    def tmp(self):
        """A folder of this test, for the files its validation commands write."""
        if not hasattr(self, "_tmp"):
            self._tmp = tempfile.TemporaryDirectory(prefix="guards-test-")
            self.addCleanup(self._tmp.cleanup)
        return self._tmp.name

    @staticmethod
    def edit_plan(repo, change):
        path = repo.worktree / "campaigns" / repo.slug / "validation.json"
        plan = json.loads(path.read_text())
        change(plan)
        path.write_text(json.dumps(plan))
        repo.git("add", ".", cwd=repo.worktree)
        repo.git("commit", "-m", "plan", cwd=repo.worktree, check=False)

    @staticmethod
    def runtime(repo):
        return next(Path(repo.cache.name).glob("*/*/campaign.json")).parent

    def events(self, repo):
        path = self.runtime(repo) / "events" / "campaign.ndjson"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def of_type(self, repo, name):
        return [event for event in self.events(repo) if event["type"] == name]

    @staticmethod
    def states(repo):
        return {item["id"]: item["status"] for item in json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)["tickets"]}

    def run_campaign(self, repo, **env):
        repo.env.update(env)
        return repo.command("run", "--provider", "mock", cwd=repo.worktree, check=False)

    def workers_started(self, repo, ticket_id="TST-001"):
        return [event for event in self.of_type(repo, "provider-started")
                if event.get("ticket") == ticket_id and "role=worker" in event["message"]]

    def state(self, repo, ticket_id="TST-001"):
        return json.loads((self.runtime(repo) / "state" / f"{ticket_id}.validate-base").read_text())


class BaseCheckTests(GuardCase):
    """Before the first worker of a ticket, its validation runs on the ticket's base and at least one command fails."""

    def test_a_validation_that_passes_on_the_base_is_refused_before_any_worker(self):
        repo = self.repo([ticket(base_check=True)], cheap=[CHEAP])
        result = self.run_campaign(repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual(self.workers_started(repo), [])
        self.assertEqual(list(Path(repo.cache.name).rglob("TST-001-worker.md")), [])
        message = "validate already passes on the base: it does not prove the change"
        [passes] = self.of_type(repo, "validate-base-passes")
        self.assertIn(message, passes["message"])
        self.assertIn("passed: git diff --check HEAD", passes["message"])
        [blocked] = self.of_type(repo, "ticket-blocked")
        self.assertTrue(blocked["message"].startswith(message), blocked["message"])
        # A defect of the plan is for a person: no automatic recovery, no diagnosis, no second block.
        self.assertEqual(self.of_type(repo, "recovery-scheduled"), [])
        self.assertEqual(self.state(repo)["outcome"], "refused")
        # The base was checked in a throwaway worktree that is gone, and the receipt is kept apart from the ticket's own.
        self.assertFalse((self.runtime(repo) / "validate-base").exists() and any((self.runtime(repo) / "validate-base").iterdir()))
        self.assertNotIn("validate-base", repo.git("worktree", "list", "--porcelain").stdout)
        receipts = self.runtime(repo) / "validation"
        self.assertEqual(json.loads((receipts / "base" / "TST-001.base.json").read_text())["status"], "PASS")
        self.assertFalse((receipts / "TST-001.cheap.json").exists())
        self.assertFalse((receipts / "TST-001.base.json").exists())

    def test_a_validation_that_fails_on_the_base_lets_the_worker_run(self):
        repo = self.repo([ticket(base_check=True)], cheap=[CHEAP, PRODUCT])
        result = self.run_campaign(repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual(len(self.workers_started(repo)), 1)
        [proves] = self.of_type(repo, "validate-base-proves")
        self.assertIn("failed test -f product-TST-001.txt", proves["message"])
        self.assertIn("passed git diff --check HEAD", proves["message"])
        self.assertEqual(self.of_type(repo, "validate-base-passes"), [])

    def test_the_first_failing_command_proves_it_and_stops_the_rest(self):
        counter = Path(self.tmp(), "after")
        repo = self.repo([ticket(base_check=True)], cheap=[PRODUCT, ["sh", "-c", f"echo ran >> {counter}"]])
        self.run_campaign(repo)
        [proves] = self.of_type(repo, "validate-base-proves")
        self.assertIn("passed none", proves["message"])
        self.assertEqual(self.of_type(repo, "validate-base-passes"), [])
        # The command after it ran once, for the ticket's own validation after the worker.
        self.assertEqual(counter.read_text().splitlines(), ["ran"])

    def test_a_component_command_proves_it_too_and_an_expensive_one_is_never_run(self):
        marker = Path(self.tmp(), "expensive")
        repo = self.repo([ticket(base_check=True)], cheap=[CHEAP], component=[PRODUCT],
                         expensive=[["sh", "-c", f"echo ran >> {marker}"]])
        self.run_campaign(repo)
        self.assertEqual(len(self.of_type(repo, "validate-base-proves")), 1)
        # The expensive phase runs for the ticket once, after the worker; never on the base.
        self.assertEqual(marker.read_text().splitlines(), ["ran"])
        repo = self.repo([ticket(base_check=True)], cheap=[CHEAP], expensive=[PRODUCT])
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual(len(self.of_type(repo, "validate-base-passes")), 1)

    def test_a_ticket_with_no_cheap_or_component_command_is_refused(self):
        repo = self.repo([ticket(base_check=True)], cheap=[])
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        [passes] = self.of_type(repo, "validate-base-passes")
        self.assertIn("it has no cheap or component command to run", passes["message"])
        self.assertEqual(self.workers_started(repo), [])

    def test_skip_with_a_reason_skips_the_check_and_records_why(self):
        marker = Path(self.tmp(), "base-runs")
        repo = self.repo([ticket()], cheap=[CHEAP, ["sh", "-c", f"test -f product-TST-001.txt || echo base >> {marker}"]])
        result = self.run_campaign(repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        reason = "the sample validation is a diff check, which passes on any base"
        [skipped] = self.of_type(repo, "validate-base-skipped")
        self.assertIn(reason, skipped["message"])
        self.assertEqual(self.of_type(repo, "validate-base-started"), [])
        self.assertFalse(marker.exists())
        # The state is gone with the integrated ticket; the event is the record. While it runs, the state says why too.
        self.assertFalse((self.runtime(repo) / "state" / "TST-001.validate-base").exists())

    def test_the_state_of_a_skipped_ticket_says_why(self):
        repo = self.repo([ticket()], cheap=[CHEAP])
        self.run_campaign(repo, MOCK_BLOCK_ONCE=str(Path(self.tmp(), "once")), AGENTIC_AUTO_RECOVERIES="0")
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        state = self.state(repo)
        self.assertEqual(state["outcome"], "skipped")
        self.assertIn("passes on any base", state["reason"])

    def verify_with(self, repo, text):
        (repo.worktree / "campaigns" / repo.slug / "tickets" / "TST-001.md").write_text(text)
        return repo.command("verify", cwd=repo.worktree, check=False)

    def test_skip_without_a_reason_is_refused_at_plan_time(self):
        repo = self.repo()
        base = ticket(base_check=True)
        for label, text, message in (
            ("no reason", base.replace("\n\n\n---", "\nvalidate_base: skip\n---", 1), "needs a non-empty validate_base_reason"),
            ("empty reason", base.replace("\n\n\n---", "\nvalidate_base: skip\nvalidate_base_reason:\n---", 1),
             "needs a non-empty validate_base_reason"),
            ("blank reason", base.replace("\n\n\n---", '\nvalidate_base: skip\nvalidate_base_reason: "  "\n---', 1),
             "needs a non-empty validate_base_reason"),
            ("a reason alone", base.replace("\n\n\n---", "\nvalidate_base_reason: a reason\n---", 1),
             "validate_base_reason without validate_base: skip"),
            ("another value", base.replace("\n\n\n---", "\nvalidate_base: run\nvalidate_base_reason: a reason\n---", 1),
             "validate_base must be 'skip'"),
        ):
            with self.subTest(label):
                self.assertIn("validate_base", text)
                result = self.verify_with(repo, text)
                self.assertNotEqual(result.returncode, 0, label)
                self.assertIn(message, result.stderr)
        accepted = self.verify_with(repo, ticket())
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_a_resumed_run_does_not_run_the_check_again(self):
        counter = Path(self.tmp(), "base-runs")
        probe = ["sh", "-c", f"test -f product-TST-001.txt || {{ echo base >> {counter}; exit 1; }}"]
        repo = self.repo([ticket(base_check=True)], cheap=[probe])
        # The first worker blocks (no automatic recovery); recover and run again: the same ticket on the same base.
        self.run_campaign(repo, MOCK_BLOCK_ONCE=str(Path(self.tmp(), "once")), AGENTIC_AUTO_RECOVERIES="0")
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual(counter.read_text().splitlines(), ["base"])
        repo.command("recover", "TST-001", cwd=repo.worktree)
        self.assertEqual(self.state(repo)["outcome"], "proves")
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual(counter.read_text().splitlines(), ["base"])
        self.assertEqual(len(self.of_type(repo, "validate-base-proves")), 1)

    def test_another_base_runs_the_check_again(self):
        counter = Path(self.tmp(), "base-runs")
        probe = ["sh", "-c", f"test -f product-TST-001.txt || {{ echo base >> {counter}; exit 1; }}"]
        repo = self.repo([ticket(base_check=True)], cheap=[probe])
        self.run_campaign(repo, MOCK_BLOCK_ONCE=str(Path(self.tmp(), "once")), AGENTIC_AUTO_RECOVERIES="0")
        # Another ticket of the campaign lands a change in the meantime: the files of the base are not the same.
        (repo.worktree / "elsewhere.txt").write_text("a change of another ticket\n")
        repo.git("add", ".", cwd=repo.worktree)
        repo.git("commit", "-m", "another ticket", cwd=repo.worktree)
        repo.command("recover", "TST-001", cwd=repo.worktree)
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual(counter.read_text().splitlines(), ["base", "base"])

    def test_recover_checks_a_refused_ticket_again(self):
        repo = self.repo([ticket(base_check=True)], cheap=[CHEAP])
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        # The coordinator fixes the validation on the campaign branch, then recovers the ticket.
        self.edit_plan(repo, lambda plan: plan["tickets"]["TST-001"].update(cheap=[CHEAP, PRODUCT]))
        repo.command("recover", "TST-001", cwd=repo.worktree)
        self.assertFalse((self.runtime(repo) / "state" / "TST-001.validate-base").exists())
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual(len(self.of_type(repo, "validate-base-proves")), 1)

    def test_a_refused_ticket_stays_refused_on_the_same_base_without_running_the_check(self):
        counter = Path(self.tmp(), "base-runs")
        repo = self.repo([ticket(base_check=True)], cheap=[["sh", "-c", f"echo base >> {counter}"]])
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        # Made todo again, the ticket meets the same base (only the status of a ticket changed): the first answer stands.
        path = repo.worktree / "campaigns" / repo.slug / "tickets" / "TST-001.md"
        subprocess.run(["python3", str(TICKETS), "set-status", str(path), "TST-001", "todo"], check=True)
        repo.git("commit", "-am", "todo again", cwd=repo.worktree)
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual(counter.read_text().splitlines(), ["base"])
        self.assertEqual(len(self.of_type(repo, "validate-base-passes")), 1)
        self.assertEqual(len(self.of_type(repo, "ticket-blocked")), 2)
        self.assertEqual(self.workers_started(repo), [])

    def test_an_environment_failure_on_the_base_blocks_without_a_worker_or_a_recovery(self):
        repo = self.repo([ticket(base_check=True)], cheap=[["not-a-command-of-this-machine", "--version"]])
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual(self.workers_started(repo), [])
        [blocked] = self.of_type(repo, "ticket-blocked")
        self.assertTrue(blocked["message"].startswith("environment: not-a-command-of-this-machine --version (command not found"),
                        blocked["message"])
        self.assertTrue(blocked["message"].endswith("on the base"), blocked["message"])
        self.assertEqual(len(self.of_type(repo, "environment-failure")), 1)
        self.assertEqual(self.of_type(repo, "recovery-scheduled"), [])

    def test_a_command_past_its_deadline_on_the_base_is_the_environments(self):
        repo = self.repo([ticket(base_check=True)], cheap=[["sleep", "30"]])
        self.run_campaign(repo, AGENTIC_VALIDATION_TIMEOUT_SECONDS="1")
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual(self.workers_started(repo), [])
        [failure] = self.of_type(repo, "environment-failure")
        self.assertIn("timed out after", failure["message"])
        receipt = json.loads((self.runtime(repo) / "validation" / "base" / "TST-001.base.json").read_text())
        self.assertTrue(receipt["evidence"][-1]["timedOut"])

    def test_the_commands_run_on_the_base_commit_with_the_project_environment(self):
        out = Path(self.tmp(), "seen")
        probe = ["sh", "-c", f'{{ git rev-parse HEAD; pwd; printf "%s\\n" "$AGENTIC_TEST_FLAG"; test -f product-TST-001.txt; }} >> {out}']
        repo = self.repo([ticket(base_check=True)], cheap=[probe], settings={"env": {"AGENTIC_TEST_FLAG": "from-project"}})
        tip = repo.git("rev-parse", "campaign/harness-sample").stdout.strip()
        self.run_campaign(repo)
        head, where, flag = out.read_text().splitlines()[:3]  # the run on the base is the first
        self.assertEqual(head, tip)
        self.assertEqual(Path(where).parent.name, "validate-base")
        self.assertNotEqual(Path(where), self.runtime(repo) / "worktrees" / "TST-001")
        self.assertEqual(flag, "from-project")
        self.assertEqual(self.states(repo), {"TST-001": "done"})


    def test_the_overview_shows_the_ticket_checking_its_base(self):
        gate, started = Path(self.tmp(), "go"), Path(self.tmp(), "started")
        slow = ["sh", "-c", f"touch {started}; while [ ! -f {gate} ]; do sleep 0.1; done; test -f product-TST-001.txt"]
        repo = self.repo([ticket(base_check=True)], cheap=[slow])
        runner = subprocess.Popen([str(repo.binary(repo.worktree)), "run", "--provider", "mock"], cwd=repo.worktree, env=repo.env,
                                  text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(300):
                if started.exists():
                    break
                time.sleep(0.1)
            self.assertTrue(started.exists())
            [campaign] = json.loads(repo.command("overview", "--json").stdout)["campaigns"]
            [item] = campaign["tickets"]
            self.assertEqual((item["status"], item["phase"]), ("in-progress", "checking-base"))
        finally:
            gate.touch()
            runner.wait(timeout=120)
        self.assertEqual(self.states(repo), {"TST-001": "done"})


class ReviewerGuardTests(GuardCase):
    """Every finding of a reviewer names the guard that would have caught it."""

    def review_repo(self, finding, **kwargs):
        repo = self.repo(**kwargs)
        repo.env.update(MOCK_FINDING=finding, MOCK_FINDING_DIR=str(Path(repo.cache.name) / "reviews"))
        return repo

    def ledger(self, repo):
        path = self.runtime(repo) / "guards.ndjson"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_a_rejection_without_a_guard_is_refused_and_the_reviewer_is_invoked_again(self):
        repo = self.review_repo("no-guard-once")
        result = self.run_campaign(repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        [failed] = self.of_type(repo, "provider-failed")
        self.assertIn("finding is missing its guard", failed["message"])
        [finding] = self.ledger(repo)
        self.assertEqual(finding["guard"]["kind"], "test")
        self.assertEqual(finding["round"], 1)

    def test_a_reviewer_that_never_names_the_guard_is_a_provider_failure(self):
        repo = self.review_repo("no-guard")
        self.run_campaign(repo)
        # As an incomplete rejection: neither a product failure nor a decision; the delta waits for the next run.
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        self.assertEqual(len(self.of_type(repo, "provider-failed")), 2)
        # The second invocation was told the exact error, and what a finding must carry.
        prompt = next(Path(repo.cache.name).rglob("TST-001-review.md")).read_text()
        self.assertIn("failed the provider contract (invalid provider result: finding is missing its guard", prompt)
        self.assertIn("names the automatic check that would have caught it as guard {kind, how}", prompt)
        self.assertIn("provider unavailable after fresh re-invocation",
                      " ".join(event["message"] for event in self.of_type(repo, "harness-error")))
        self.assertEqual(self.ledger(repo), [])

    def test_a_guarded_finding_is_accepted_and_kept(self):
        repo = self.review_repo("guard")
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        [finding] = self.ledger(repo)
        self.assertEqual((finding["ticket"], finding["round"], finding["verdict"], finding["severity"]),
                         ("TST-001", 1, "FIX", "major"))
        self.assertEqual(finding["guard"], {"kind": "test", "how": "a unit test that refunds an order with tax and asserts the whole total comes back"})
        self.assertEqual((finding["path"], finding["line"]), ("src/rule.txt", 3))
        self.assertIn("refund total", finding["message"])
        self.assertEqual(self.of_type(repo, "provider-failed"), [])

    def test_the_findings_of_every_review_are_kept_after_the_next_review_overwrites_the_result(self):
        repo = self.review_repo("guard")
        self.run_campaign(repo)
        results = self.runtime(repo) / "results"
        self.assertEqual(json.loads((results / "TST-001-review.json").read_text())["findings"], [])
        self.assertEqual(len(self.ledger(repo)), 1)

    def guards(self, repo, *args):
        return repo.command("guards", *args, cwd=repo.worktree)

    def test_campaign_guards_lists_only_the_findings_an_automatic_check_could_have_caught(self):
        repo = self.review_repo("mixed")
        self.run_campaign(repo)
        self.assertEqual(len(self.ledger(repo)), 2)
        listing = json.loads(self.guards(repo, "--json").stdout)
        self.assertEqual(listing["count"], 1)
        [finding] = listing["findings"]
        self.assertEqual((finding["campaign"], finding["kind"], finding["ticket"], finding["round"], finding["severity"]),
                         ("harness-sample", "campaign", "TST-001", 1, "major"))
        self.assertEqual(finding["guard"]["kind"], "test")
        self.assertIn("refund total", finding["message"])
        text = self.guards(repo).stdout
        self.assertIn("1 finding(s) an automatic check could have caught:", text)
        self.assertIn("harness-sample (campaign) TST-001 round 1 [major] test: a unit test that refunds an order", text)
        self.assertIn("By guard: test 1", text)
        self.assertNotIn("curt", text)

    def test_a_note_on_a_pass_counts_and_a_reviewer_only_finding_does_not(self):
        repo = self.review_repo("note")
        self.run_campaign(repo)
        self.assertEqual(json.loads(self.guards(repo, "--json").stdout)["count"], 1)
        other = self.review_repo("reviewer-only")
        self.run_campaign(other)
        self.assertEqual(len(self.ledger(other)), 1)
        self.assertEqual(json.loads(self.guards(other, "--json").stdout), {"count": 0, "findings": []})
        self.assertIn("No finding asks for a guard.", self.guards(other).stdout)

    def test_guards_covers_every_campaign_and_task_of_the_machine(self):
        repo = self.review_repo("guard")
        self.run_campaign(repo)
        cache = next(Path(repo.cache.name).glob("*/harness-sample")).parent
        # A task of the same project on this machine, with a ledger of its own.
        task = cache / "tsk-901"
        task.mkdir()
        (task / "campaign.json").write_text(json.dumps({"slug": "tsk-901", "kind": "task", "worktree": str(task / "tree")}))
        (task / "guards.ndjson").write_text("\n".join(json.dumps(line) for line in (
            {"ticket": "T-001", "round": 2, "task_round": 3, "verdict": "FIX", "severity": "minor", "path": None, "line": None,
             "message": "The header is missing.", "reason": "r", "fix": "f", "guard": {"kind": "lint", "how": "a lint rule on headers"}},
            {"ticket": "T-001", "round": 2, "verdict": "FIX", "severity": "minor", "path": None, "line": None,
             "message": "Taste.", "reason": "r", "fix": "f", "guard": {"kind": "reviewer-only", "how": "taste"}},
            {"ticket": "T-001", "round": 1, "verdict": "FIX", "severity": "major", "path": None, "line": None,
             "message": "From before guards.", "reason": "r", "fix": "f"})) + "\n")
        listing = json.loads(repo.command("guards", "--json").stdout)  # from the main worktree, not the campaign's
        self.assertEqual(sorted((item["campaign"], item["kind"]) for item in listing["findings"]),
                         [("harness-sample", "campaign"), ("tsk-901", "task")])
        self.assertEqual(listing["count"], 2)
        [item] = [item for item in listing["findings"] if item["kind"] == "task"]
        self.assertEqual((item["ticket"], item["round"], item["task_round"], item["guard"]["kind"]), ("T-001", 2, 3, "lint"))
        self.assertEqual(repo.command("guards", "--json", "--bogus", check=False).returncode, 2)

    def test_the_overview_counts_the_findings_per_campaign(self):
        repo = self.review_repo("mixed")
        self.run_campaign(repo)
        [campaign] = json.loads(repo.command("overview", "--json").stdout)["campaigns"]
        self.assertEqual(campaign["guards"], 1)
        self.assertIn("· guards=1", repo.command("overview").stdout)
        quiet = self.repo()
        self.run_campaign(quiet)
        [campaign] = json.loads(quiet.command("overview", "--json").stdout)["campaigns"]
        self.assertEqual(campaign["guards"], 0)
        self.assertNotIn("guards=", quiet.command("overview").stdout)


class InstructionFileTests(GuardCase):
    """A worker's change to an instruction file, the .agentic folder or a skill or agent folder is refused."""

    def test_the_owned_paths(self):
        repo = Repo(settings={"instruction_files": ["AGENTS.md", "CLAUDE.md", "RULES.md"]})
        self.addCleanup(repo.close)
        script = ('source "$1/lib/common.sh"; source "$1/lib/engine.sh"; shift; '
                  'for path; do if is_coordinator_owned "$path"; then echo "$path yes"; else echo "$path no"; fi; done')
        paths = {
            "AGENTS.md": "yes", "CLAUDE.md": "yes", "RULES.md": "yes", "docs/CLAUDE.md": "yes", "apps/web/AGENTS.md": "yes",
            ".agentic/WORKFLOW.md": "yes", ".agentic/project.json": "yes", ".agentic/bin/campaign": "yes",
            ".claude/skills/x/SKILL.md": "yes", ".claude/agents/campaign-worker.md": "yes", ".claude/settings.json": "yes",
            ".codex/skills/x/SKILL.md": "yes", ".grok/skills/x/SKILL.md": "yes", ".agents/skills/x/SKILL.md": "yes",
            "campaigns/c/SPEC.md": "yes", "campaigns/c/tickets/T-001.md": "yes", "campaigns/c/validation.json": "yes",
            "README.md": "no", "docs/AGENT.md": "no", "src/agentic/lib.py": "no", ".agents/notes.md": "no",
            "agentic/WORKFLOW.md": "no", "claude/skills/x.md": "no",
        }
        result = subprocess.run(["bash", "-c", script, "owned", str(repo.root / ".agentic"), *paths], cwd=repo.root,
                                env=repo.env, text=True, capture_output=True, check=True)
        self.assertEqual(dict(line.rsplit(" ", 1) for line in result.stdout.splitlines()), paths)

    def refused(self, path, text="a change\\n", **env):
        repo = self.repo()
        repo.env.update(MOCK_APPEND_FILE=path, MOCK_APPEND_TEXT=text, **env)
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "todo"}, path)
        [error] = [event for event in self.of_type(repo, "harness-error") if "coordinator-owned" in event["message"]]
        self.assertIn("delta preserved", error["message"])
        return repo

    def test_a_worker_editing_the_agentic_folder_is_refused(self):
        self.refused(".agentic/WORKFLOW.md")

    def test_a_worker_editing_a_skill_or_an_agent_is_refused(self):
        self.refused(".claude/skills/run-campaign/SKILL.md")
        self.refused(".claude/agents/campaign-worker.md")
        self.refused(".codex/skills/run-campaign/SKILL.md")

    def test_a_worker_editing_an_instruction_file_is_refused(self):
        self.refused("AGENTS.md")
        self.refused("docs/CLAUDE.md")

    def test_a_worker_that_commits_the_change_itself_is_refused_too(self):
        for path in ("AGENTS.md", ".agentic/WORKFLOW.md", ".claude/agents/campaign-worker.md"):
            with self.subTest(path):
                repo = self.refused(path, MOCK_COMMIT="1")
                tree = self.runtime(repo) / "worktrees" / "TST-001"
                # The worker's commit stays in its worktree, out of the campaign.
                self.assertNotEqual(repo.git("rev-parse", "HEAD", cwd=tree).stdout, repo.git("rev-parse", "campaign/harness-sample").stdout)
                self.assertNotIn(path, repo.git("diff", "--name-only", "main", "campaign/harness-sample").stdout)

    def test_a_worker_that_commits_an_ordinary_file_is_not_refused(self):
        repo = self.repo()
        repo.env.update(MOCK_APPEND_FILE="notes.md", MOCK_APPEND_TEXT="notes\\n", MOCK_COMMIT="1")
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})


if __name__ == "__main__":
    unittest.main()

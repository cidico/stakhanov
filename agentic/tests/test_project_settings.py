#!/usr/bin/env python3
"""Main-branch detection, project.json, the SPEC sections and the stale-worktree, decide and CRLF defects."""

from __future__ import annotations

import datetime
import json
from pathlib import Path
import shutil
import subprocess
import time
import unittest

from test_campaign import KIT, SPEC, Repo, ticket

CHEAP = ["git", "diff", "--check", "HEAD"]


class RepoCase(unittest.TestCase):
    def tearDown(self):
        for repo in getattr(self, "repos", []):
            repo.close()

    def repo(self, **kwargs):
        if not hasattr(self, "repos"):
            self.repos = []
        repo = Repo(**kwargs)
        self.repos.append(repo)
        return repo

    @staticmethod
    def states(repo):
        return {item["id"]: item["status"] for item in json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)["tickets"]}

    @staticmethod
    def events(repo, name="campaign.ndjson"):
        path = next(Path(repo.cache.name).rglob(name), None)
        return [json.loads(line) for line in path.read_text().splitlines()] if path else []

    @staticmethod
    def edit_plan(repo, change):
        path = repo.worktree / "campaigns" / repo.slug / "validation.json"
        plan = json.loads(path.read_text())
        change(plan)
        path.write_text(json.dumps(plan))
        repo.git("add", ".", cwd=repo.worktree)
        repo.git("commit", "-m", "plan", cwd=repo.worktree)

    @staticmethod
    def runtime(repo):
        return next(Path(repo.cache.name).glob("*/*/campaign.json")).parent


class MainBranchTests(RepoCase):
    def test_main_is_found(self):
        repo = self.repo()
        repo.init_campaign()
        self.assertEqual(repo.git("rev-parse", "main").stdout, repo.git("merge-base", "main", "campaign/harness-sample").stdout)

    def test_master_is_found_when_there_is_no_main(self):
        repo = self.repo(branch="master")
        repo.init_campaign(); repo.configure([ticket(status="done")])
        (repo.root / "SPEC.md").unlink(missing_ok=True)
        result = repo.command("finalize", cwd=repo.worktree)
        self.assertIn("finalized into master", result.stdout)
        self.assertEqual(repo.git("branch", "--show-current").stdout.strip(), "master")

    def test_main_wins_when_both_exist(self):
        repo = self.repo(branch="master")
        repo.git("branch", "main")
        repo.git("checkout", "-q", "main")
        repo.init_campaign()
        self.assertEqual(repo.git("rev-parse", "main").stdout, repo.git("merge-base", "main", "campaign/harness-sample").stdout)

    def test_config_names_the_main_branch(self):
        repo = self.repo(branch="trunk", settings={"main_branch": "trunk"})
        repo.init_campaign(); repo.configure([ticket(status="done")])
        (repo.root / "SPEC.md").unlink(missing_ok=True)
        self.assertIn("finalized into trunk", repo.command("finalize", cwd=repo.worktree).stdout)

    def test_config_wins_over_detection(self):
        repo = self.repo(branch="main", settings={"main_branch": "release"})
        repo.git("branch", "release")
        repo.git("checkout", "-q", "release")
        repo.init_campaign()
        self.assertEqual(repo.git("rev-parse", "release").stdout, repo.git("merge-base", "release", "campaign/harness-sample").stdout)

    def test_unknown_branch_is_a_clear_error(self):
        repo = self.repo(branch="trunk")
        result = repo.command("init", "SPEC.md", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("neither 'main' nor 'master' exists", result.stderr)
        self.assertIn('set "main_branch" in .agentic/project.json', result.stderr)

    def test_init_requires_the_main_branch(self):
        repo = self.repo()
        repo.git("checkout", "-q", "-b", "feature")
        result = repo.command("init", "SPEC.md", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("init requires main", result.stderr)


class SettingsTests(RepoCase):
    def test_invalid_json_names_the_file(self):
        repo = self.repo(settings="{not json")
        result = repo.command("current", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("project.json", result.stderr)
        self.assertIn("invalid JSON", result.stderr)

    def test_non_string_env_is_rejected(self):
        repo = self.repo(settings={"env": {"AGENTIC_TEST_VALUE": 1}})
        result = repo.command("current", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid settings", result.stderr)

    def test_env_is_exported_to_validation_without_overriding_the_environment(self):
        repo = self.repo(settings={"env": {"AGENTIC_TEST_FLAG": "from-config", "AGENTIC_TEST_KEPT": "from-config"}})
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        out = Path(repo.cache.name) / "env-seen"
        probe = ["sh", "-c", f'printf "%s %s" "$AGENTIC_TEST_FLAG" "$AGENTIC_TEST_KEPT" > {out}']
        self.edit_plan(repo, lambda plan: plan["tickets"]["TST-001"].update(cheap=[CHEAP, probe]))
        repo.command("run", "--provider", "mock", cwd=repo.worktree, env={"AGENTIC_TEST_KEPT": "from-environment"})
        self.assertEqual(out.read_text(), "from-config from-environment")
        self.assertEqual(self.states(repo), {"TST-001": "done"})

    def test_dangerous_environment_keys_are_refused(self):
        for key in ("PATH", "HOME", "IFS", "ENV", "BASH_ENV", "BASHOPTS", "SHELLOPTS", "PS4", "GIT_DIR", "GIT_CONFIG_COUNT",
                    "LD_PRELOAD", "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONSTARTUP"):
            with self.subTest(key=key):
                repo = self.repo(settings={"env": {key: "x"}})
                result = repo.command("current", check=False)
                self.assertEqual(result.returncode, 2)
                self.assertIn(key, result.stderr)
                self.assertIn("not allowed", result.stderr)

    def test_other_environment_keys_are_allowed(self):
        repo = self.repo(settings={"env": {"AGENTIC_TEST_FLAG": "1", "AGENTIC_WORKER_TIMEOUT_SECONDS": "90", "MY_TOKEN_PATH": "x", "GITHUB": "y"}})
        result = repo.command("current", check=False)
        self.assertNotIn("not allowed", result.stderr)
        self.assertIn("outside campaign", result.stderr)

    def test_the_main_branch_config_applies_to_a_campaign_created_before_it_changed(self):
        repo = self.repo(settings={"env": {"AGENTIC_TEST_FLAG": "old"}})
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        # Config committed on the main branch after init: the campaign worktree still holds the old copy.
        (repo.root / ".agentic" / "project.json").write_text(json.dumps({"env": {"AGENTIC_TEST_FLAG": "new"}, "required_checks": [CHEAP]}))
        repo.git("add", ".agentic"); repo.git("commit", "-m", "new settings")
        self.assertIn("old", (repo.worktree / ".agentic" / "project.json").read_text())
        out = Path(repo.cache.name) / "env-seen"
        probe = ["sh", "-c", f'printf "%s" "$AGENTIC_TEST_FLAG" > {out}']
        self.edit_plan(repo, lambda plan: (plan["tickets"]["TST-001"].update(cheap=[CHEAP, probe]), plan.update(final=[CHEAP])))
        # required_checks from the new config apply too: the plan must keep the cheap check in the final list.
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(out.read_text(), "new")
        self.assertEqual(self.states(repo), {"TST-001": "done"})

    def test_uncommitted_edits_of_project_json_do_not_apply(self):
        repo = self.repo(settings={"name": "Acme"})
        repo.init_campaign(); repo.configure([ticket()])
        (repo.worktree / ".agentic" / "project.json").write_text("{not json")
        result = repo.command("status", cwd=repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_local_file_is_the_fallback_without_a_committed_copy(self):
        repo = self.repo(commit_kit=False)
        kit = Path(repo.cache.name) / "kit"
        shutil.copytree(KIT, kit)
        (kit / "project.json").write_text("{not json")
        result = subprocess.run([str(kit / "bin" / "campaign"), "current"], cwd=repo.root, env=repo.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid JSON", result.stderr)

    def test_finalize_checks_the_plan_again_after_refreshing_it(self):
        required = ["sh", "-c", "true"]
        repo = self.repo(settings={"required_checks": [CHEAP, required]})
        repo.init_campaign(); repo.configure([ticket(status="done")])
        (repo.root / "SPEC.md").unlink(missing_ok=True)
        full = lambda plan: (plan["tickets"]["TST-001"].update(cheap=[CHEAP, required]), plan.update(final=[CHEAP, required, ["false"]]))
        self.edit_plan(repo, full)
        first = repo.command("finalize", cwd=repo.worktree, check=False)
        self.assertIn("final validation failed", first.stderr)
        # The fix drops a required check from the final list: finalize stops with the verify message.
        self.edit_plan(repo, lambda plan: plan.update(final=[CHEAP]))
        second = repo.command("finalize", cwd=repo.worktree, check=False)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("lacks the required checks", second.stderr)
        self.assertIn("final list", second.stderr)
        self.edit_plan(repo, lambda plan: plan.update(final=[CHEAP, required]))
        third = repo.command("finalize", cwd=repo.worktree, check=False)
        self.assertEqual(third.returncode, 0, third.stderr)

    def test_instruction_file_edit_in_a_subfolder_is_rejected(self):
        repo = self.repo(settings={"instruction_files": ["CLAUDE.md"]})
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_APPEND_FILE="docs/CLAUDE.md", MOCK_APPEND_TEXT="new rule\\n")
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        self.assertIn("coordinator-owned", " ".join(event["message"] for event in self.events(repo)))

    def test_only_the_configured_instruction_files_are_guarded(self):
        repo = self.repo(settings={"instruction_files": ["CLAUDE.md"]})
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_APPEND_FILE="docs/AGENTS.md", MOCK_APPEND_TEXT="notes\\n")
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(self.states(repo), {"TST-001": "done"})

    def test_default_instruction_files_guard_the_root_too(self):
        repo = self.repo(settings={})
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_APPEND_FILE="CLAUDE.md", MOCK_APPEND_TEXT="new rule\\n")
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(self.states(repo), {"TST-001": "todo"})

    def test_role_prompt_names_the_project_and_its_instruction_files(self):
        repo = self.repo(settings={"name": "Acme Shop", "instruction_files": ["RULES.md", "CLAUDE.md"]})
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        prompt = next(Path(repo.cache.name).rglob("TST-001-worker.md")).read_text()
        self.assertIn("exactly one ticket of Acme Shop.", prompt)
        self.assertIn("RULES.md, CLAUDE.md", prompt)
        self.assertNotIn("AGENTS.md", prompt)

    def test_role_prompt_without_a_name(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        prompt = next(Path(repo.cache.name).rglob("TST-001-worker.md")).read_text()
        self.assertIn("exactly one ticket. Start", prompt)

    def test_required_checks_must_be_in_every_cheap_phase_and_in_final(self):
        required = ["sh", "-c", "true"]
        repo = self.repo(settings={"required_checks": [CHEAP, required]})
        repo.init_campaign(); repo.configure([ticket(), ticket("TST-002")]); repo.mock_provider()
        result = repo.command("verify", cwd=repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        for text in ("TST-001", "TST-002", "cheap phase", "final list", '["sh","-c","true"]'):
            self.assertIn(text, result.stderr)
        run = repo.command("run", "--provider", "mock", cwd=repo.worktree, check=False)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("required checks", run.stderr)
        # One ticket fixed, the other still missing the check: only the latter is named.
        self.edit_plan(repo, lambda plan: (plan["tickets"]["TST-001"].update(cheap=[CHEAP, required]), plan.update(final=[CHEAP, required])))
        partial = repo.command("verify", cwd=repo.worktree, check=False)
        self.assertIn("TST-002", partial.stderr)
        self.assertNotIn("TST-001", partial.stderr)
        self.edit_plan(repo, lambda plan: plan["tickets"]["TST-002"].update(cheap=[required, CHEAP]))
        self.assertIn("verified", repo.command("verify", cwd=repo.worktree).stdout)

    def local_time(self, repo, env=None):
        repo.init_campaign()
        events = self.runtime(repo) / "events" / "campaign.ndjson"
        events.write_text(json.dumps({"time": "2031-03-04T10:00:00Z", "type": "probe", "message": ""}) + "\n")
        overview = json.loads(repo.command("overview", "--json", env=env).stdout)
        return overview["campaigns"][0]["recent_events"][-1]["local_time"]

    def test_timezone_comes_from_the_settings(self):
        repo = self.repo(settings={"timezone": "Europe/Paris"})
        self.assertEqual(self.local_time(repo, env={"TZ": "Asia/Tokyo"}), "11:00 (04/03)")

    def test_timezone_environment_wins_over_the_settings(self):
        repo = self.repo(settings={"timezone": "Europe/Paris"})
        self.assertEqual(self.local_time(repo, env={"AGENTIC_DISPLAY_TZ": "America/Argentina/Buenos_Aires"}), "07:00 (04/03)")

    def test_timezone_defaults_to_the_system_zone(self):
        repo = self.repo(settings={})
        self.assertEqual(self.local_time(repo, env={"TZ": "Asia/Tokyo"}), "19:00 (04/03)")

    def archive_repo(self, settings):
        repo = self.repo(settings=settings)
        (repo.root / ".gitignore").write_text("out/\n")
        repo.git("add", ".gitignore"); repo.git("commit", "-m", "ignore out")
        repo.init_campaign(); repo.configure([ticket(status="done")])
        (repo.root / "SPEC.md").unlink(missing_ok=True)
        return repo

    def test_archive_dir_inside_the_main_worktree_when_ignored(self):
        repo = self.archive_repo({"archive_dir": "out/{date}/campaign-{slug}"})
        result = repo.command("finalize", cwd=repo.worktree)
        target = repo.root / "out" / datetime.date.today().isoformat() / "campaign-harness-sample"
        self.assertTrue((target / "events").is_dir(), result.stdout)
        self.assertIn(str(target), result.stdout)
        self.assertFalse(list(Path(repo.cache.name).rglob("archive/*")))

    def test_archive_dir_that_git_does_not_ignore_goes_to_the_cache(self):
        repo = self.archive_repo({"archive_dir": "kept/{slug}"})
        repo.command("finalize", cwd=repo.worktree)
        self.assertFalse((repo.root / "kept").exists())
        self.assertTrue(list(Path(repo.cache.name).rglob("archive/*/events")))

    def test_archive_defaults_to_the_cache(self):
        repo = self.archive_repo({})
        repo.command("finalize", cwd=repo.worktree)
        self.assertFalse((repo.root / "out").exists())
        self.assertTrue(list(Path(repo.cache.name).rglob("archive/*/events")))


class InitTests(RepoCase):
    NO_HEADING = SPEC.replace("# Harness Sample\n", "")

    def test_a_spec_without_a_heading_needs_a_slug(self):
        repo = self.repo()
        temp_spec = Path(repo.cache.name) / "tmp.ln5bet9o"
        temp_spec.write_text(self.NO_HEADING)
        result = repo.command("init", str(temp_spec), check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--slug <short-kebab-name>", result.stderr)
        self.assertIn("# <Title>", result.stderr)
        self.assertEqual(repo.git("branch", "--list", "campaign/*").stdout.strip(), "")

    def test_the_slug_option_names_a_spec_without_a_heading(self):
        repo = self.repo()
        (repo.root / "SPEC.md").write_text(self.NO_HEADING)
        repo.command("init", "SPEC.md", "--slug", "named-by-hand")
        self.assertIn("campaign/named-by-hand", repo.git("branch", "--list").stdout)

    def test_the_slug_comes_from_the_first_heading(self):
        repo = self.repo()
        repo.command("init", "SPEC.md")
        self.assertIn("campaign/harness-sample", repo.git("branch", "--list").stdout)

    def test_init_refuses_a_kit_that_is_not_committed(self):
        repo = self.repo(commit_kit=False)
        result = repo.command("init", "SPEC.md", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("commit the installed .agentic", result.stderr)
        self.assertEqual(repo.git("branch", "--list", "campaign/*").stdout.strip(), "")
        self.assertEqual(repo.git("worktree", "list").stdout.count("\n"), 1)


class SpecSectionTests(RepoCase):
    def init(self, text):
        repo = self.repo()
        (repo.root / "SPEC.md").write_text(text)
        return repo.command("init", "SPEC.md", check=False)

    def test_complete_spec_is_accepted_without_further_notes(self):
        self.assertEqual(self.init(SPEC).returncode, 0)

    def test_further_notes_are_optional_and_accepted(self):
        self.assertEqual(self.init(SPEC + "## Further Notes\nAnything.\n").returncode, 0)

    def test_every_template_section_is_required(self):
        for section in ("Problem Statement", "Solution", "User Stories", "Implementation Decisions", "Testing Decisions",
                        "Out of Scope", "Open questions"):
            with self.subTest(section=section):
                text = SPEC.replace(f"## {section}\n", "")
                result = self.init(text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(section, result.stderr)

    def test_the_old_section_set_is_not_enough(self):
        old = "# Old\n" + "".join(f"## {name}\nx\n" for name in ("Problem", "Goals", "Non-goals", "Decisions", "Requirements", "Constraints", "Acceptance")) + "## Open questions\nNone.\n"
        result = self.init(old)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Problem Statement", result.stderr)

    def test_open_questions_accept_none_or_non_blocking_only(self):
        self.assertEqual(self.init(SPEC.replace("None.", "- non-blocking: naming of the flag")).returncode, 0)
        for blocked in ("No questions yet.", "- Which database?"):
            with self.subTest(text=blocked):
                result = self.init(SPEC.replace("None.", blocked))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Open questions", result.stderr)


class DefectTests(RepoCase):
    def test_a_worker_sees_the_campaign_commits_made_after_its_worktree_existed(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        runtime = self.runtime(repo)
        worktree = runtime / "worktrees/TST-001"
        repo.git("worktree", "add", "-b", f"agentic/{repo.slug}/TST-001", str(worktree), f"campaign/{repo.slug}")
        (repo.worktree / "campaign-news.txt").write_text("news\n")
        repo.git("add", "campaign-news.txt", cwd=repo.worktree)
        repo.git("commit", "-m", "campaign advances", cwd=repo.worktree)
        seen = Path(repo.cache.name) / "seen"
        repo.env["MOCK_SEEN_DIR"] = str(seen)
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        # The campaign's own commit is not the ticket's delta: a worker still implements it, on the new code.
        self.assertTrue((runtime / "results/TST-001-worker.json").is_file())
        self.assertIn("campaign-news.txt", (seen / "TST-001-worker.json").read_text().split())
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        prompt = (runtime / "prompts/TST-001-worker.md").read_text()
        self.assertIn(f"git merge-base campaign/{repo.slug} HEAD", prompt)

    def test_a_ticket_commit_still_counts_as_a_delta_when_the_campaign_advanced(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        runtime = self.runtime(repo)
        worktree = runtime / "worktrees/TST-001"
        repo.git("worktree", "add", "-b", f"agentic/{repo.slug}/TST-001", str(worktree), f"campaign/{repo.slug}")
        (worktree / "product-TST-001.txt").write_text("mine\n")
        repo.git("add", "product-TST-001.txt", cwd=worktree)
        repo.git("commit", "-m", "feat(agentic): complete TST-001", cwd=worktree)
        (repo.worktree / "campaign-news.txt").write_text("news\n")
        repo.git("add", "campaign-news.txt", cwd=repo.worktree)
        repo.git("commit", "-m", "campaign advances", cwd=repo.worktree)
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertFalse((runtime / "results/TST-001-worker.json").exists())
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertTrue((repo.worktree / "product-TST-001.txt").is_file())
        self.assertTrue((repo.worktree / "campaign-news.txt").is_file())

    def decision_repo(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        runtime = self.runtime(repo)
        (runtime / "decisions").mkdir(exist_ok=True)
        decision = runtime / "decisions/TST-001.json"
        decision.write_text(json.dumps({"ticket": "TST-001", "reason": "test", "options": ["retry", "block", "cancel"]}))
        (runtime / "run-config.json").write_text(json.dumps({"provider": "mock", "workers": 1, "mode": "unattended"}))
        return repo, decision

    def test_decide_retry_on_a_todo_ticket_is_idempotent(self):
        repo, decision = self.decision_repo()
        result = repo.command("decide", "TST-001", "retry", cwd=repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already todo", result.stdout)
        self.assertIn("Decision 'retry' applied", result.stdout)
        self.assertFalse(decision.exists())
        for _ in range(100):
            if not json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)["runner"]["active"]:
                break
            time.sleep(0.2)
        self.assertEqual(self.states(repo), {"TST-001": "done"})

    def test_decide_block_on_a_blocked_ticket_is_idempotent(self):
        repo, decision = self.decision_repo()
        repo.command("decide", "TST-001", "block", cwd=repo.worktree)
        decision.write_text(json.dumps({"ticket": "TST-001", "reason": "again", "options": ["block"]}))
        again = repo.command("decide", "TST-001", "block", cwd=repo.worktree, check=False)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already blocked", again.stdout)
        self.assertFalse(decision.exists())

    def test_renaming_a_guarded_file_is_still_a_guarded_edit(self):
        repo = self.repo(settings={})
        (repo.root / "AGENTS.md").write_text("rules\n")
        repo.git("add", "AGENTS.md"); repo.git("commit", "-m", "rules")
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_RENAME_FROM="AGENTS.md", MOCK_RENAME_TO="notes.md")
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        self.assertIn("coordinator-owned", " ".join(event["message"] for event in self.events(repo)))
        worktree = self.runtime(repo) / "worktrees" / "TST-001"
        self.assertTrue((worktree / "notes.md").is_file())

    def test_a_provider_failure_without_a_result_is_reinvoked_once_then_a_harness_error(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env["MOCK_EXIT_FAIL"] = "1"
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        events = self.events(repo)
        self.assertEqual([event["type"] for event in events].count("provider-failed"), 2)
        self.assertEqual([event["type"] for event in events].count("provider-started"), 2)
        self.assertIn("provider unavailable after fresh re-invocation",
                      " ".join(event["message"] for event in events if event["type"] == "harness-error"))
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        worktree = self.runtime(repo) / "worktrees" / "TST-001"
        self.assertTrue((worktree / "product-TST-001.txt").is_file())
        self.assertEqual(repo.git("log", "--oneline", cwd=worktree).stdout.count("complete TST-001"), 0)

    def test_a_crlf_file_does_not_block_the_worker_commit(self):
        repo = self.repo()
        repo.git("config", "core.autocrlf", "false")
        (repo.root / "crlf.txt").write_bytes(b"one\r\n")
        repo.git("add", "crlf.txt"); repo.git("commit", "-m", "crlf file")
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_APPEND_FILE="crlf.txt", MOCK_APPEND_TEXT="two\\r\\n")
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual((repo.worktree / "crlf.txt").read_bytes(), b"one\r\ntwo\r\n")
        self.assertNotIn("harness-error", [event["type"] for event in self.events(repo)])

    def test_real_trailing_whitespace_still_blocks_the_worker_commit(self):
        repo = self.repo()
        repo.git("config", "core.whitespace", "trailing-space")
        (repo.root / "text.txt").write_text("one\n")
        repo.git("add", "text.txt"); repo.git("commit", "-m", "text file")
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_APPEND_FILE="text.txt", MOCK_APPEND_TEXT="two \\n")
        repo.command("run", "--provider", "mock", cwd=repo.worktree)
        self.assertEqual(self.states(repo), {"TST-001": "todo"})

    def test_a_fixed_validation_plan_applies_when_finalize_resumes(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket(status="done")])
        (repo.root / "SPEC.md").unlink(missing_ok=True)
        self.edit_plan(repo, lambda plan: plan.update(final=[["false"]]))
        first = repo.command("finalize", cwd=repo.worktree, check=False)
        self.assertNotEqual(first.returncode, 0)
        self.assertIn("final validation failed", first.stderr)
        # The coordinator fixes the plan on the campaign branch; the frozen copy must not keep the old command.
        self.edit_plan(repo, lambda plan: plan.update(final=[["true"]]))
        second = repo.command("finalize", cwd=repo.worktree, check=False)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn("campaign/harness-sample", repo.git("branch", "--list").stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)

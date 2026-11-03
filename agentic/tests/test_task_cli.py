#!/usr/bin/env python3
"""campaign task: the local commands of a task (new, list, status, log, diff, stop, restart, fix, drop), its accept into
the main branch, the regen_paths and coordinator_paths of project.json, and main.lock held without inheritance. The
mock provider stands in for claude (AGENTIC_PROVIDER_DIR); every repository is temporary."""

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
from test_task import brief


def wait_for(condition, seconds=90):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return False


class TaskCliCase(unittest.TestCase):
    def setUp(self):
        self.repo = None
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-task-cli-")
        self.scratch = Path(self.temp.name)
        self.leftovers = []

    def tearDown(self):
        for pid in self.leftovers:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        if self.repo is not None:
            for item in self.tasks():
                if item["runner_active"]:
                    self.task("stop", item["name"], "--now", check=False)
            self.repo.close()
        self.temp.cleanup()

    def make_repo(self, settings=None, **env):
        self.repo = Repo(settings=settings)
        self.repo.mock_provider()
        # The task runs with the claude provider: the mock stands in for it.
        providers = Path(self.repo.env["AGENTIC_PROVIDER_DIR"])
        (providers / "claude").symlink_to(providers / "mock")
        for name in list(self.repo.env):
            if name.startswith("AGENTIC_CLAUDE"):
                del self.repo.env[name]
        self.repo.env.update(env)
        return self.repo

    def commit_on_main(self, path, text, message=None):
        target = self.repo.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        self.repo.git("add", path)
        self.repo.git("commit", "-m", message or f"main: {path}")
        return self.repo.git("rev-parse", "HEAD").stdout.strip()

    def write_brief(self, text, name="brief.md"):
        path = self.scratch / "briefs" / name
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)
        return path

    def task(self, *args, check=True, env=None, cwd=None):
        return self.repo.command("task", *args, check=check, env=env, cwd=cwd)

    def tasks(self):
        result = self.task("list", "--json", check=False)
        return json.loads(result.stdout)["tasks"] if result.returncode == 0 else []

    def info(self, name="tsk-901"):
        return next(item for item in self.tasks() if item["name"] == name)

    def wait_idle(self, name="tsk-901", seconds=90):
        self.assertTrue(wait_for(lambda: not self.info(name)["runner_active"], seconds), f"{name} is still running")
        return self.info(name)

    def new(self, text=None, *args, env=None, name="tsk-901", wait=True):
        result = self.task("new", str(self.write_brief(text or brief(), f"{name}.md")), *args, env=env, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        if wait:
            self.wait_idle(name)
        return result

    def runtime(self, name="tsk-901"):
        return next(Path(self.repo.cache.name).glob(f"*/{name}/campaign.json")).parent

    def events(self, runtime):
        path = runtime / "events" / "campaign.ndjson"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def archived(self, name="tsk-901"):
        return next(Path(self.repo.cache.name).glob(f"*/archive/{name}-*"))

    def main_log(self, since):
        return [line for line in self.repo.git("log", "--format=%s", f"{since}..main").stdout.splitlines() if line]

    def assert_forgotten(self, name="tsk-901"):
        self.assertEqual(self.repo.git("branch", "--list", f"campaign/{name}", f"agentic/{name}/*").stdout.strip(), "")
        self.assertNotIn(f"/{name}/worktrees/", self.repo.git("worktree", "list").stdout)
        self.assertEqual(list(Path(self.repo.cache.name).glob(f"*/{name}/campaign.json")), [])
        self.assertEqual([item["name"] for item in self.tasks()], [])


class TaskNewTests(TaskCliCase):
    def links_settings(self):
        reference = self.scratch / "home" / "reference"
        reference.mkdir(parents=True)
        (reference / "OLD.md").write_text("the old system\n")
        settings = {"task_preamble": "docs/preamble.md", "task_links": {"webapp-ref": "~/reference"}}
        return settings, {"HOME": str(self.scratch / "home")}, reference

    def test_new_mounts_the_context_and_links_and_records_the_task(self):
        settings, env, reference = self.links_settings()
        self.make_repo(settings, **env)
        self.commit_on_main("docs/preamble.md", "You are the worker of a task.\n- Read AGENTS.md.")
        notes = self.scratch / "notes.md"
        notes.write_text("context notes\n")
        main = self.repo.git("rev-parse", "main").stdout.strip()
        result = self.new(brief(), "--context", str(notes), "--no-start", wait=False)
        self.assertIn("Task tsk-901 created: Write the product file", result.stdout)
        self.assertIn("Not started (--no-start)", result.stdout)
        runtime = self.runtime()
        data = json.loads((runtime / "campaign.json").read_text())
        self.assertEqual({key: data[key] for key in ("slug", "kind", "branch", "id", "title", "base", "base_ref", "home",
                                                      "epoch", "round", "desired")},
                         {"slug": "tsk-901", "kind": "task", "branch": "campaign/tsk-901", "id": "TSK-901",
                          "title": "Write the product file", "base": main, "base_ref": "main", "home": data["home"],
                          "epoch": 1, "round": 1, "desired": "stopped"})
        self.assertTrue(data["home"])
        self.assertEqual(data["brief_path"], str(self.scratch / "briefs" / "tsk-901.md"))
        self.assertEqual(Path(data["brief"]).read_text(), brief())
        self.assertEqual(self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip(), main)
        tree = runtime / "worktrees" / "T-001"
        self.assertEqual(self.repo.git("symbolic-ref", "--short", "HEAD", cwd=tree).stdout.strip(), "agentic/tsk-901/T-001")
        task_md = (tree / ".task" / "TASK.md").read_text()
        self.assertEqual(task_md, "You are the worker of a task.\n- Read AGENTS.md.\n\n---\n\n" + brief())
        self.assertEqual((tree / ".task" / "notes.md").read_text(), "context notes\n")
        self.assertEqual(os.readlink(tree / "webapp-ref"), str(reference))
        # Neither the context nor the link is ever seen by Git.
        self.assertEqual(self.repo.git("status", "--porcelain", "--untracked-files=all", cwd=tree).stdout, "")
        exclude = (self.repo.root / ".git" / "info" / "exclude").read_text().splitlines()
        self.assertIn("/.task", exclude)
        self.assertIn("/webapp-ref", exclude)
        self.assertEqual(self.info()["state"], "new")

    def test_restart_runs_a_task_that_was_not_started_with_the_briefs_settings(self):
        self.make_repo()
        self.new(brief(), "--no-start", wait=False)
        self.task("restart", "tsk-901")
        info = self.wait_idle()
        self.assertEqual((info["state"], info["ticket"]), ("delivered", "done"))
        config = json.loads((self.runtime() / "run-config.json").read_text())
        self.assertEqual((config["provider"], config["workers"], config["mode"]), ("claude", 1, "unattended"))
        self.assertEqual({key: config["env"].get(key) for key in ("AGENTIC_CLAUDE_WORKER_MODEL", "AGENTIC_CLAUDE_WORKER_EFFORT",
                                                                   "AGENTIC_WORKER_TIMEOUT_SECONDS")},
                         {"AGENTIC_CLAUDE_WORKER_MODEL": "opus", "AGENTIC_CLAUDE_WORKER_EFFORT": "high",
                          "AGENTIC_WORKER_TIMEOUT_SECONDS": "1800"})
        result = self.task("restart", "tsk-901", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("is delivered", result.stderr)

    def test_new_refuses_a_name_that_exists_on_this_machine(self):
        self.make_repo()
        self.new(brief(), "--no-start", wait=False)
        result = self.task("new", str(self.write_brief(brief(title="Another"), "again.md")), "--no-start", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("a task or campaign named tsk-901 already exists", result.stderr)
        self.assertEqual(json.loads((self.runtime() / "campaign.json").read_text())["title"], "Write the product file")
        # A campaign of that name too.
        self.repo.command("init", "SPEC.md", "--slug", "tsk-902")
        result = self.task("new", str(self.write_brief(brief(task_id="TSK-902"), "campaign.md")), "--no-start", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("a task or campaign named tsk-902 already exists", result.stderr)

    def test_new_refuses_a_link_whose_path_does_not_exist_and_keeps_nothing(self):
        self.make_repo({"task_links": {"webapp-ref": str(self.scratch / "missing")}})
        result = self.task("new", str(self.write_brief(brief())), check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"webapp-ref points to {self.scratch / 'missing'}, which does not exist on", result.stderr)
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout, "")
        self.assertEqual(list(Path(self.repo.cache.name).glob("*/tsk-901")), [])

    def test_a_failure_half_way_keeps_nothing(self):
        self.make_repo({"required_checks": [["git", "diff", "--check", "HEAD"]]})
        result = self.task("new", str(self.write_brief(brief())), check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lacks the required check", result.stderr)
        self.assertIn("nothing of it was kept", result.stderr)
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout, "")
        self.assertEqual(list(Path(self.repo.cache.name).glob("*/tsk-901")), [])

    def test_list_status_log_and_diff_of_a_delivered_task(self):
        self.make_repo()
        self.new()
        [item] = self.tasks()
        self.assertEqual((item["name"], item["id"], item["state"], item["round"], item["phase"]),
                         ("tsk-901", "TSK-901", "delivered", 1, None))
        self.assertEqual(item["base"], self.repo.git("rev-parse", "main").stdout.strip())
        self.assertGreaterEqual(item["age_seconds"], 0)
        line = self.task("list").stdout.strip()
        self.assertTrue(line.startswith("tsk-901\tdelivered\tbase "), line)
        self.assertTrue(line.endswith("\tWrite the product file"), line)
        status = json.loads(self.task("status", "TSK-901", "--json").stdout)
        self.assertEqual((status["task"]["state"], status["campaign"], [ticket["status"] for ticket in status["tickets"]]),
                         ("delivered", "tsk-901", ["done"]))
        text = self.task("status", "tsk-901").stdout
        self.assertIn("Task tsk-901 (TSK-901): Write the product file\nState: delivered\n", text)
        self.assertIn("T-001\tdone", text)
        log = self.task("log", "tsk-901").stdout
        self.assertIn("task-round  round 1: the brief", log)
        self.assertIn("ticket-done T-001", log)
        diff = self.task("diff", "tsk-901").stdout
        self.assertIn("+++ b/product-T-001.txt", diff)
        self.assertIn("+T-001", diff)
        self.assertEqual(self.task("diff", "tsk-901", "--name-only").stdout.split(), ["product-T-001.txt"])
        missing = self.task("status", "nope", check=False)
        self.assertEqual(missing.returncode, 2)
        self.assertIn("no task named nope", missing.stderr)


class TaskAcceptTests(TaskCliCase):
    UNMARKED = ("where both sides changed files that git merges without conflict markers (binary, or a merge attribute such "
                "as -merge), which only a person can merge: ")

    def test_accept_with_the_main_branch_still_lands_one_commit_without_context_or_links(self):
        reference = self.scratch / "reference"
        reference.mkdir()
        self.make_repo({"task_links": {"webapp-ref": str(reference)}, "accept_checks": [["test", "-f", "product-T-001.txt"]]})
        main = self.repo.git("rev-parse", "main").stdout.strip()
        self.new(brief(), env={"MOCK_SEEN_DIR": str(self.scratch / "seen")})
        # The worker saw the link at the root of its worktree.
        self.assertIn("webapp-ref", (self.scratch / "seen" / "T-001-worker.json").read_text().split())
        result = self.task("accept", "tsk-901")
        self.assertIn("Task tsk-901 accepted into main", result.stdout)
        self.assertEqual(self.main_log(main), ["feat(task): Write the product file"])
        self.assertEqual(self.repo.git("show", "--name-only", "--format=", "main").stdout.split(), ["product-T-001.txt"])
        files = self.repo.git("ls-tree", "-r", "--name-only", "main").stdout.split()
        self.assertFalse([path for path in files if path.startswith(".task") or path.startswith("webapp-ref")], files)
        self.assertEqual((self.repo.root / "product-T-001.txt").read_text(), "T-001\n")
        self.assert_forgotten()
        archive = self.archived()
        types = [json.loads(line)["type"] for line in (archive / "events" / "campaign.ndjson").read_text().splitlines()]
        self.assertIn("task-accepted", types)
        # The main branch did not move since the base: only accept_checks ran.
        receipt = json.loads((archive / "validation" / "accept" / "campaign.final.json").read_text())
        self.assertEqual([record["command"] for record in receipt["evidence"]], [["test", "-f", "product-T-001.txt"]])
        self.assertTrue(next(Path(self.repo.cache.name).glob("*/finalized/tsk-901.json")).is_file())
        self.assertTrue(reference.is_dir())

    def test_accept_after_the_main_branch_moved_validates_again_and_lands(self):
        self.make_repo({"accept_checks": [["true"]]})
        self.new()
        main = self.commit_on_main("other.txt", "other\n", "main moves")
        self.task("accept", "tsk-901")
        self.assertEqual(self.main_log(main), ["feat(task): Write the product file"])
        self.assertEqual(self.repo.git("rev-parse", "main~1").stdout.strip(), main)
        receipt = json.loads((self.archived() / "validation" / "accept" / "campaign.final.json").read_text())
        self.assertEqual(receipt["status"], "PASS")
        # The task's validate commands (with the brief's deadline), then the project's checks.
        self.assertEqual([record["command"] for record in receipt["evidence"]], [["test", "-f", "product-T-001.txt"], ["true"]])
        self.assertEqual(receipt["evidence"][0]["timeoutSeconds"], 1800)

    def test_a_conflict_marks_the_task_and_fix_rebase_resolves_it(self):
        self.make_repo()
        self.commit_on_main("shared.txt", "seed\n")
        env = {"MOCK_SHARED_FILE": "shared.txt"}
        self.new(env=env)
        tip = self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip()
        main = self.commit_on_main("shared.txt", "seed\nmain\n", "main changes the same line")
        result = self.task("accept", "tsk-901", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("was not accepted (conflict): the rebase onto main conflicted in: shared.txt", result.stderr)
        self.assertIn("campaign task fix tsk-901 --rebase", result.stderr)
        info = self.info()
        self.assertEqual((info["state"], info["accept"]["state"]), ("conflict", "conflict"))
        self.assertEqual(self.repo.git("rev-parse", "main").stdout.strip(), main)
        self.assertEqual(self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip(), tip)
        self.assertFalse((self.runtime() / "worktrees" / "accept").exists())

        self.task("fix", "tsk-901", "--rebase", "--note", "Keep the line of main and the task's.", env=env)
        info = self.wait_idle()
        self.assertEqual((info["state"], info["round"], info["base"]), ("delivered", 2, main))
        runtime = self.runtime()
        prompt = (runtime / "prompts" / "T-001-integration-repair.md").read_text()
        self.assertIn("task fix --rebase", prompt)
        self.assertIn("conflicted in: shared.txt", prompt)
        self.assertIn("Keep the line of main and the task's.", prompt)
        types = [event["type"] for event in self.events(runtime)]
        self.assertIn("task-rebased", types)
        self.assertEqual(self.repo.git("merge-base", "main", "campaign/tsk-901").stdout.strip(), main)
        self.task("accept", "tsk-901")
        self.assertEqual(self.main_log(main), ["feat(task): Write the product file"])
        self.assertEqual((self.repo.root / "shared.txt").read_text(), "seed\nmain\nT-001\n")

    def assert_fix_rebase_keeps_the_delta(self, move_on_main, expected, shared="shared.txt", seed=b"seed\n"):
        """No worker could resolve the delta re-applied on the main branch from markers: fix --rebase stops with nothing
        moved, saying why, instead of a round on a task without its delta."""
        self.make_repo()
        (self.repo.root / shared).write_bytes(seed)
        self.repo.git("add", shared)
        self.repo.git("commit", "-m", f"main: {shared}")
        env = {"MOCK_SHARED_FILE": shared}
        self.new(env=env)
        runtime = self.runtime()
        base, tip = json.loads((runtime / "campaign.json").read_text())["base"], self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip()
        move_on_main()
        result = self.task("fix", "tsk-901", "--rebase", "--note", "Follow main.", env=env, check=False)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn(f"the delta of task tsk-901 does not apply on main, {expected}. Nothing moved", result.stderr)
        self.assertNotIn("applied cleanly", result.stdout + result.stderr)
        # The branch, the base and the round are as they were, and so is the delta, with its copy kept.
        self.assertEqual(self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip(), tip)
        data = json.loads((runtime / "campaign.json").read_text())
        self.assertEqual((data["base"], data["round"]), (base, 1))
        self.assertEqual(sorted(self.task("diff", "tsk-901", "--name-only").stdout.split()), sorted(["product-T-001.txt", shared]))
        patch = runtime / "state" / "T-001.conflict.patch"
        self.assertIn(f"a copy of the delta is in {patch}", result.stderr)
        self.assertTrue(patch.stat().st_size > 0)
        tree = runtime / "worktrees" / "T-001"
        if tree.exists():
            self.assertEqual(self.repo.git("rev-parse", "HEAD", cwd=tree).stdout.strip(), tip)
            self.assertEqual(self.repo.git("status", "--porcelain", cwd=tree).stdout, "")
        self.assertFalse((runtime / "state" / "T-001.reapplied").exists())
        self.assertFalse((runtime / "state" / "T-001.retry").exists())
        self.assertEqual(self.info()["state"], "delivered")
        types = [event["type"] for event in self.events(runtime)]
        self.assertIn("task-rebase-refused", types)
        self.assertNotIn("task-rebased", types)
        self.assertEqual(types.count("task-round"), 1)
        return tip

    def test_fix_rebase_keeps_the_delta_when_the_main_branch_deleted_a_file_it_changes(self):
        def delete():
            self.repo.git("rm", "-q", "shared.txt")
            self.repo.git("commit", "-m", "main deletes shared.txt")
        self.assert_fix_rebase_keeps_the_delta(delete, "which no longer has files it changes: shared.txt (deleted since the base)")

    def test_fix_rebase_keeps_the_delta_when_the_main_branch_renamed_a_file_it_changes(self):
        def rename():
            self.repo.git("mv", "shared.txt", "renamed.txt")
            self.repo.git("commit", "-m", "main renames shared.txt")
        self.assert_fix_rebase_keeps_the_delta(
            rename, "which no longer has files it changes: shared.txt (renamed to renamed.txt since the base)")

    def test_fix_rebase_keeps_the_delta_when_both_sides_changed_a_binary_file(self):
        """git apply --3way leaves a binary conflict as the main branch's version, with no marker: a round on it would
        commit the task without its change."""
        def change():
            (self.repo.root / "image.bin").write_bytes(b"PNG\0main\n")
            self.repo.git("commit", "-qam", "main changes image.bin")
        tip = self.assert_fix_rebase_keeps_the_delta(change, f"{self.UNMARKED}image.bin", shared="image.bin", seed=b"PNG\0base\n")
        shown = subprocess.run(["git", "-C", str(self.repo.root), "show", f"{tip}:image.bin"], capture_output=True, check=True)
        self.assertEqual(shown.stdout, b"PNG\0base\nT-001\n")

    def test_fix_rebase_keeps_the_delta_when_both_sides_changed_a_text_file_with_a_merge_attribute(self):
        """A -merge attribute (a lockfile, a generated file) makes git merge a text file as it merges a binary one: the main
        branch's version, with no marker, which a round would commit without the task's line."""
        def change():
            (self.repo.root / ".gitattributes").write_text("shared.txt -merge\n")
            (self.repo.root / "shared.txt").write_text("seed\nmain\n")
            self.repo.git("add", ".gitattributes", "shared.txt")
            self.repo.git("commit", "-m", "main changes shared.txt, which never merges")
        tip = self.assert_fix_rebase_keeps_the_delta(change, f"{self.UNMARKED}shared.txt")
        self.assertEqual(self.repo.git("show", f"{tip}:shared.txt").stdout, "seed\nT-001\n")

    def test_fix_rebase_leaves_out_a_file_the_task_and_the_main_branch_both_deleted(self):
        self.make_repo()
        self.commit_on_main("doomed.txt", "one\n")
        self.new(env={"MOCK_DELETE_FILE": "doomed.txt"})
        self.repo.git("rm", "-q", "doomed.txt")
        self.repo.git("commit", "-m", "main deletes doomed.txt too")
        main = self.repo.git("rev-parse", "main").stdout.strip()
        result = self.task("fix", "tsk-901", "--rebase", "--note", "Follow main.", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = self.wait_idle()
        self.assertEqual((info["state"], info["round"], info["base"]), ("delivered", 2, main))
        self.assertEqual(self.task("diff", "tsk-901", "--name-only").stdout.split(), ["product-T-001.txt"])
        self.assertNotIn("task-rebase-refused", [event["type"] for event in self.events(self.runtime())])

    def test_fix_rebase_says_git_apply_rejected_the_patch_when_main_still_has_the_files(self):
        """The task deletes a file the main branch changed: the main branch still has it, and the message says so."""
        self.make_repo()
        self.commit_on_main("doomed.txt", "one\n")
        self.new(env={"MOCK_DELETE_FILE": "doomed.txt"})
        self.commit_on_main("doomed.txt", "one\ntwo\n", "main changes doomed.txt")
        result = self.task("fix", "tsk-901", "--rebase", "--note", "Follow main.", check=False)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("the delta of task tsk-901 does not apply on main, as git apply rejected the whole patch: error: ", result.stderr)
        self.assertIn("doomed.txt", result.stderr)
        self.assertNotIn("no longer has", result.stderr)

    def test_fix_rebase_of_a_task_without_a_delta_moves_its_base(self):
        self.make_repo()
        self.new(brief(), "--no-start", wait=False)
        main = self.commit_on_main("other.txt", "other\n", "main moves")
        result = self.task("fix", "tsk-901", "--rebase", "--note", "Start from the current main.", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = self.wait_idle()
        self.assertEqual((info["state"], info["round"], info["base"]), ("delivered", 2, main))
        runtime = self.runtime()
        self.assertEqual(self.repo.git("merge-base", "main", "campaign/tsk-901").stdout.strip(), main)
        self.assertEqual(self.task("diff", "tsk-901", "--name-only").stdout.split(), ["product-T-001.txt"])
        # No delta, no integration repair: the round starts with the worker and the findings.
        self.assertFalse((runtime / "prompts" / "T-001-integration-repair.md").exists())
        prompt = (runtime / "prompts" / "T-001-worker.md").read_text()
        self.assertIn("Start from the current main.", prompt)
        self.assertIn(f"Round 2 of task TSK-901 (campaign task fix): the task has no delta on its base {main} yet.", prompt)
        self.assertNotIn("re-applied", prompt)
        self.assertNotIn("earlier rounds delivered", prompt)
        [rebased] = [event["message"] for event in self.events(runtime) if event["type"] == "task-rebased"]
        self.assertIn("the task had no delta to re-apply", rebased)
        self.assertFalse((runtime / "state" / "T-001.conflict.patch").exists())

    def test_reapply_delta_fails_apart_and_restores_the_worktree_when_the_patch_does_not_apply(self):
        """The function the integration conflict of every campaign uses too."""
        self.make_repo()
        self.commit_on_main("shared.txt", "seed\n")
        self.commit_on_main("kept.txt", "one\n")
        base = self.repo.git("rev-parse", "main").stdout.strip()
        tree = self.scratch / "ticket"
        self.repo.git("worktree", "add", "-q", "-b", "ticket", str(tree), base)
        (tree / "shared.txt").write_text("seed\nticket\n")
        (tree / "kept.txt").write_text("one\nticket\n")
        self.repo.git("commit", "-qam", "ticket", cwd=tree)
        head = self.repo.git("rev-parse", "HEAD", cwd=tree).stdout.strip()
        self.repo.git("rm", "-q", "shared.txt")
        self.repo.git("commit", "-m", "main deletes shared.txt")
        script = 'source "$1/lib/common.sh"; source "$1/lib/engine.sh"; shift; reapply_delta "$@"'
        result = subprocess.run(["bash", "-c", script, "reapply", str(self.repo.root / ".agentic"), str(tree), base, "main",
                                 str(self.scratch / "delta.patch")], cwd=self.repo.root, env=self.repo.env, text=True,
                                capture_output=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "which no longer has files it changes: shared.txt (deleted since the base)\n")
        self.assertEqual(self.repo.git("rev-parse", "HEAD", cwd=tree).stdout.strip(), head)
        self.assertEqual(self.repo.git("status", "--porcelain", cwd=tree).stdout, "")
        self.assertEqual((tree / "kept.txt").read_text(), "one\nticket\n")

    def test_accept_regen_lands_a_commit_of_its_own_and_the_workers_regen_change_stays_out(self):
        self.make_repo({"regen_paths": ["generated.txt"],
                        "accept_regen": [["bash", "-c", "printf 'generated\\n' > generated.txt"]]})
        main = self.repo.git("rev-parse", "main").stdout.strip()
        self.new(env={"MOCK_APPEND_FILE": "generated.txt", "MOCK_APPEND_TEXT": "the worker's\\n"})
        self.assertEqual(self.repo.git("diff", "--name-only", main, "campaign/tsk-901").stdout.split(), ["product-T-001.txt"])
        dropped = [event for event in self.events(self.runtime()) if event["type"] == "regen-paths-dropped"]
        self.assertEqual(len(dropped), 1)
        self.assertIn("generated.txt", dropped[0]["message"])
        self.task("accept", "tsk-901")
        self.assertEqual(self.main_log(main), ["chore(regen): tsk-901", "feat(task): Write the product file"])
        self.assertEqual(self.repo.git("show", "--name-only", "--format=", "main~1").stdout.split(), ["product-T-001.txt"])
        self.assertEqual(self.repo.git("show", "main:generated.txt").stdout, "generated\n")

    def test_red_accept_checks_land_nothing(self):
        self.make_repo({"accept_checks": [["bash", "-c", "echo the solution does not build >&2; exit 1"]]})
        main = self.repo.git("rev-parse", "main").stdout.strip()
        self.new()
        tip = self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip()
        result = self.task("accept", "tsk-901", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("was not accepted (accept-failed)", result.stderr)
        info = self.info()
        self.assertEqual(info["state"], "accept-failed")
        self.assertIn("exit 1", info["reason"])
        receipt = json.loads(Path(info["accept"]["evidence"]).read_text())
        self.assertEqual(receipt["status"], "FAIL")
        self.assertEqual(self.repo.git("rev-parse", "main").stdout.strip(), main)
        self.assertEqual(self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip(), tip)
        self.assertFalse((self.runtime() / "worktrees" / "accept").exists())
        self.assertIn("task-accept-failed", [event["type"] for event in self.events(self.runtime())])

    def test_accept_refuses_a_task_that_is_not_delivered(self):
        self.make_repo()
        self.new(brief(), "--no-start", wait=False)
        result = self.task("accept", "tsk-901", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("task tsk-901 is not delivered: its ticket is todo", result.stderr)

    def test_two_accepts_at_once_one_waits_for_the_main_lock(self):
        gate, out = self.scratch / "go", self.scratch / "out"
        out.mkdir()
        self.make_repo({"accept_checks": [["sh", "-c", f'touch {out}/started-"$AGENTIC_TASK"; while [ ! -f {gate} ]; do sleep 0.05; done']]})
        main = self.repo.git("rev-parse", "main").stdout.strip()
        self.new(brief(), env={"MOCK_APPEND_FILE": "a.txt", "MOCK_APPEND_TEXT": "a\\n"})
        self.new(brief(task_id="TSK-902", title="Write another file"), env={"MOCK_APPEND_FILE": "b.txt", "MOCK_APPEND_TEXT": "b\\n"},
                 name="tsk-902")
        processes, logs = [], []
        for name in ("tsk-901", "tsk-902"):
            log = open(self.scratch / f"{name}.log", "w")
            processes.append(subprocess.Popen([str(self.repo.binary()), "task", "accept", name], cwd=self.repo.root,
                                              env=self.repo.env, text=True, stdout=log, stderr=subprocess.STDOUT))
            log.close()
            if name == "tsk-901":
                self.assertTrue(wait_for(lambda: (out / "started-tsk-901").exists()), (self.scratch / "tsk-901.log").read_text())
        second = self.scratch / "tsk-902.log"
        self.assertTrue(wait_for(lambda: "Waiting for the main branch lock" in second.read_text()), second.read_text())
        self.assertIn(f"held by pid {processes[0].pid} (", second.read_text())
        self.assertIsNone(processes[1].poll())
        self.assertFalse((out / "started-tsk-902").exists())
        gate.touch()
        for process, name in zip(processes, ("tsk-901", "tsk-902")):
            self.assertEqual(process.wait(timeout=120), 0, (self.scratch / f"{name}.log").read_text())
        self.assertEqual(self.main_log(main), ["feat(task): Write another file", "feat(task): Write the product file"])
        self.assertEqual(self.tasks(), [])


class TaskFixAndDropTests(TaskCliCase):
    def test_fix_note_reaches_the_prompt_of_the_new_round(self):
        self.make_repo()
        self.new()
        self.task("fix", "tsk-901", "--note", "Name the product after the ticket.")
        info = self.wait_idle()
        self.assertEqual((info["state"], info["round"]), ("delivered", 2))
        runtime = self.runtime()
        prompt = (runtime / "prompts" / "T-001-worker.md").read_text()
        self.assertIn("Coordinator diagnosis for this recovery", prompt)
        self.assertIn("Round 2 of task TSK-901 (campaign task fix)", prompt)
        self.assertIn("Name the product after the ticket.", prompt)
        rounds = [event["message"] for event in self.events(runtime) if event["type"] == "task-round"]
        self.assertEqual(rounds, ["round 1: the brief", "round 2: campaign task fix with the coordinator's findings"])
        # The first round proved that the validation fails on the base; the second starts on the branch that has its delta.
        base_events = [(event["type"], event["message"]) for event in self.events(runtime) if event["type"].startswith("validate-base-")]
        self.assertEqual([kind for kind, _ in base_events], ["validate-base-started", "validate-base-proves", "validate-base-skipped"])
        self.assertIn("round 2 of the task", base_events[-1][1])
        log = self.task("log", "tsk-901").stdout
        self.assertNotIn("round 1: the brief", log)
        self.assertIn("round 2: campaign task fix", log)
        # The findings go once their round is integrated.
        self.assertFalse((runtime / "diagnosis" / "T-001.md").exists())

    def test_fix_findings_outlive_an_automatic_recovery_of_their_round(self):
        """The first worker of the round blocks: the recovery's diagnosis carries the evidence and still the findings, and
        so do the prompts of the recovery's worker and of the reviewer."""
        self.make_repo()
        self.new(brief(review=True), "--no-start", wait=False)
        self.task("fix", "tsk-901", "--note", "THE-COORDINATOR-NOTE", env={"MOCK_BLOCK_ONCE": str(self.scratch / "block-once")})
        info = self.wait_idle()
        self.assertEqual((info["state"], info["round"]), ("delivered", 2))
        runtime = self.runtime()
        self.assertIn("recovery-scheduled", [event["type"] for event in self.events(runtime)])
        worker = (runtime / "prompts" / "T-001-worker.md").read_text()
        self.assertIn("Automatic recovery 1/2 for T-001", worker)
        self.assertIn("The coordinator's findings for this round, which the round must still apply:", worker)
        self.assertIn("THE-COORDINATOR-NOTE", worker)
        self.assertLess(worker.index("THE-COORDINATOR-NOTE"), worker.index("Automatic recovery 1/2"))
        self.assertIn("THE-COORDINATOR-NOTE", (runtime / "prompts" / "T-001-review.md").read_text())
        # They go with the round, once it is integrated.
        self.assertFalse((runtime / "state" / "T-001.findings.md").exists())
        self.assertFalse((runtime / "diagnosis" / "T-001.md").exists())

    def test_diff_shows_the_delta_fix_rebase_re_applied_before_it_is_committed(self):
        """fix --rebase moves the task's branch to the main branch's tip before the round commits the re-applied delta."""
        self.make_repo()
        self.commit_on_main("shared.txt", "seed\n")
        self.new(env={"MOCK_SHARED_FILE": "shared.txt"})
        self.commit_on_main("shared.txt", "seed\nmain\n", "main changes the same line")
        track = self.scratch / "track"
        # The integration repair resolves the markers, then sleeps before the round commits.
        self.task("fix", "tsk-901", "--rebase", "--note", "Keep both lines.",
                  env={"MOCK_SHARED_FILE": "shared.txt", "MOCK_TRACK_DIR": str(track), "MOCK_SLEEP": "60"})
        self.assertTrue(wait_for(lambda: (track / "active").exists() and (track / "active").read_text() == "1"))
        self.assertEqual(self.repo.git("rev-parse", "campaign/tsk-901").stdout.strip(), self.repo.git("rev-parse", "main").stdout.strip())
        result = self.task("diff", "tsk-901")
        self.assertIn("holds work that campaign/tsk-901 has not got yet", result.stderr)
        self.assertIn("+++ b/product-T-001.txt", result.stdout)
        self.assertIn("+++ b/shared.txt", result.stdout)
        # Against the new base: the main branch's line is no change of the task.
        changed = [line for line in result.stdout.splitlines() if line[:1] in "+-" and line[:3] not in ("+++", "---")]
        self.assertEqual(changed, ["+T-001", "+T-001"])
        self.assertEqual(sorted(self.task("diff", "tsk-901", "--name-only").stdout.split()), ["product-T-001.txt", "shared.txt"])
        # The round's own index is untouched: the new file is still untracked there.
        tree = self.runtime() / "worktrees" / "T-001"
        self.assertIn("?? product-T-001.txt", self.repo.git("status", "--porcelain", cwd=tree).stdout)

    def test_diff_shows_the_commits_of_a_round_before_they_are_integrated(self):
        """The round commits its worker's change, then validates it: campaign/<name> only gets it at the integration."""
        hold, started = self.scratch / "hold", self.scratch / "started"
        self.make_repo()
        gate = f"sh -c 'touch {started}; while [ -e {hold} ]; do sleep 0.1; done'"
        self.new(brief(validate=("test -f product-T-001.txt", gate)))
        hold.touch()
        started.unlink()
        self.task("fix", "tsk-901", "--note", "Add round-2.txt.", env={"MOCK_APPEND_FILE": "round-2.txt", "MOCK_APPEND_TEXT": "two\\n"})
        try:
            self.assertTrue(wait_for(lambda: started.exists()), self.task("log", "tsk-901").stdout)
            tree = self.runtime() / "worktrees" / "T-001"
            self.assertEqual(self.repo.git("status", "--porcelain", cwd=tree).stdout, "")
            result = self.task("diff", "tsk-901", "--name-only")
            self.assertIn("holds work that campaign/tsk-901 has not got yet", result.stderr)
            self.assertEqual(sorted(result.stdout.split()), ["product-T-001.txt", "round-2.txt"])
        finally:
            hold.unlink()
        self.assertEqual(self.wait_idle()["state"], "delivered")
        # Integrated: the branch has it, and the note is gone.
        result = self.task("diff", "tsk-901", "--name-only")
        self.assertEqual((sorted(result.stdout.split()), result.stderr), (["product-T-001.txt", "round-2.txt"], ""))

    def test_fix_brief_takes_the_findings_from_a_file(self):
        self.make_repo()
        self.new()
        findings = self.scratch / "findings.md"
        findings.write_text("1. The product file needs a header.\n")
        self.task("fix", "tsk-901", "--brief", str(findings))
        self.wait_idle()
        self.assertIn("1. The product file needs a header.", (self.runtime() / "prompts" / "T-001-worker.md").read_text())
        result = self.task("fix", "tsk-901", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--note TEXT or --brief FILE", result.stderr)

    def test_stop_now_then_restart_finishes_the_round(self):
        self.make_repo()
        track = self.scratch / "track"
        self.new(env={"MOCK_TRACK_DIR": str(track), "MOCK_SLEEP": "60"}, wait=False)
        self.assertTrue(wait_for(lambda: (track / "active").exists() and (track / "active").read_text() == "1"))
        self.assertIn("Stopped tsk-901 at once", self.task("stop", "tsk-901", "--now").stdout)
        info = self.info()
        self.assertEqual((info["state"], info["desired"]), ("stopped", "stopped"))
        # The ticket worktree keeps its context for the next run.
        self.assertTrue((self.runtime() / "worktrees" / "T-001" / ".task" / "TASK.md").is_file())
        self.task("restart", "tsk-901")
        self.assertEqual(self.wait_idle()["state"], "delivered")

    def test_drop_stops_the_task_removes_everything_and_runs_task_cleanup(self):
        cleanup = self.scratch / "cleanup.log"
        self.make_repo({"task_cleanup": [["bash", "-c", f'printf "%s %s\\n" "$AGENTIC_TASK" "$PWD" >> {cleanup}']]})
        track = self.scratch / "track"
        self.new(env={"MOCK_TRACK_DIR": str(track), "MOCK_SLEEP": "60"}, wait=False)
        self.assertTrue(wait_for(lambda: (track / "active").exists() and (track / "active").read_text() == "1"))
        self.assertEqual(self.info()["state"], "running")
        result = self.task("drop", "tsk-901")
        self.assertIn("Task tsk-901 dropped.", result.stdout)
        self.assertEqual(cleanup.read_text(), f"tsk-901 {self.repo.root}\n")
        self.assert_forgotten()
        types = [json.loads(line)["type"] for line in (self.archived() / "events" / "campaign.ndjson").read_text().splitlines()]
        self.assertIn("task-dropped", types)

    def test_drop_stops_the_engine_when_the_campaign_worktree_is_gone(self):
        self.make_repo()
        track = self.scratch / "track"
        self.new(env={"MOCK_TRACK_DIR": str(track), "MOCK_SLEEP": "60"}, wait=False)
        self.assertTrue(wait_for(lambda: (track / "active").exists() and (track / "active").read_text() == "1"))
        runtime = self.runtime()
        engine = int((runtime / "runner.pid").read_text())
        # The folder is moved away by hand: its processes keep running, from wherever it went.
        (runtime / "worktrees" / "campaign").rename(self.scratch / "campaign-moved")
        os.kill(engine, 0)
        result = self.task("drop", "tsk-901", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(wait_for(lambda: not Path(f"/proc/{engine}").exists() or
                                 Path(f"/proc/{engine}/stat").read_text().rsplit(")", 1)[1].split()[0] == "Z", 2),
                        "the engine outlived the drop")
        self.assertFalse(runtime.exists())
        self.assertEqual(self.repo.git("branch", "--list", "campaign/tsk-901", "agentic/tsk-901/*").stdout.strip(), "")


class TaskPathSettingsTests(TaskCliCase):
    def test_the_workers_change_to_a_regen_path_never_enters_the_commit(self):
        self.make_repo({"regen_paths": ["bun.lock", "AnalyzerReleases.*"]})
        main = self.commit_on_main("bun.lock", "v1\n")
        self.new(env={"MOCK_SHARED_FILE": "bun.lock",
                      "MOCK_APPEND_FILE": "analyzers/rules/AnalyzerReleases.Unshipped.md", "MOCK_APPEND_TEXT": "rule\\n"})
        self.assertEqual(self.info()["state"], "delivered")
        self.assertEqual(self.repo.git("diff", "--name-only", main, "campaign/tsk-901").stdout.split(), ["product-T-001.txt"])
        tree = Path(json.loads((self.runtime() / "campaign.json").read_text())["worktree"])
        self.assertEqual((tree / "bun.lock").read_text(), "v1\n")
        [dropped] = [event["message"] for event in self.events(self.runtime()) if event["type"] == "regen-paths-dropped"]
        self.assertIn("bun.lock", dropped)
        self.assertIn("analyzers/rules/AnalyzerReleases.Unshipped.md", dropped)

    def test_a_worker_editing_a_coordinator_path_is_refused(self):
        self.make_repo({"coordinator_paths": [".agents/**", "Directory.Packages.props"]})
        self.new(env={"MOCK_APPEND_FILE": ".agents/database.md", "MOCK_APPEND_TEXT": "a new rule\\n"})
        info = self.info()
        self.assertEqual(info["ticket"], "todo")
        self.assertIn("worker edited coordinator-owned instructions; delta preserved",
                      [event["message"] for event in self.events(self.runtime()) if event["type"] == "harness-error"])
        self.assertEqual(self.repo.git("rev-parse", "campaign/tsk-901").stdout, self.repo.git("rev-parse", "main").stdout)

    def test_coordinator_paths_guard_a_campaigns_tickets_too(self):
        self.make_repo({"coordinator_paths": ["Directory.Packages.props"]})
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        self.repo.env.update(MOCK_APPEND_FILE="src/Directory.Packages.props", MOCK_APPEND_TEXT="<Project />\\n")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        status = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual([item["status"] for item in status["tickets"]], ["todo"])

    def test_is_coordinator_owned_reads_the_globs(self):
        self.make_repo({"coordinator_paths": [".agents/**", "Directory.*", "/package.json", "src/*.md"]})
        script = ('source "$1/lib/common.sh"; source "$1/lib/engine.sh"; shift; '
                  'for path; do if is_coordinator_owned "$path"; then echo "$path yes"; else echo "$path no"; fi; done')
        paths = {".agents/x.md": "yes", ".agents/a/b.md": "yes", "docs/.agents/x.md": "no", "Directory.Build.props": "yes",
                 "src/Directory.Packages.props": "yes", "package.json": "yes", "apps/web/package.json": "no",
                 "src/a.md": "yes", "src/x/a.md": "no", "AGENTS.md": "yes", "README.md": "no"}
        result = subprocess.run(["bash", "-c", script, "owned", str(self.repo.root / ".agentic"), *paths], cwd=self.repo.root,
                                env=self.repo.env, text=True, capture_output=True, check=True)
        self.assertEqual(dict(line.rsplit(" ", 1) for line in result.stdout.splitlines()), paths)

    def test_the_task_settings_are_checked_when_they_load(self):
        cases = {
            "task_preamble": ({"task_preamble": "/etc/preamble.md"}, "task_preamble must be the path of a file"),
            "task_preamble up": ({"task_preamble": "../preamble.md"}, "task_preamble must be the path of a file"),
            "task_links value": ({"task_links": {"ref": "relative/path"}}, "task_links must map file names"),
            "task_links name": ({"task_links": {"a/b": "/tmp"}}, "task_links must map file names"),
            "task_links list": ({"task_links": ["/tmp"]}, "task_links must map file names"),
            "task_cleanup": ({"task_cleanup": ["docker rm"]}, "task_cleanup must be a list of commands"),
            "accept_regen": ({"accept_regen": [[]]}, "accept_regen must be a list of commands"),
            "accept_checks": ({"accept_checks": [{"command": ["true"], "timeout_minutes": 0}]},
                              "accept_checks must be a list of commands"),
            "regen_paths": ({"regen_paths": "bun.lock"}, "regen_paths must be a list of globs"),
            "coordinator_paths": ({"coordinator_paths": ["../x"]}, "coordinator_paths must be a list of globs"),
        }
        for name, (settings, message) in cases.items():
            with self.subTest(name):
                repo = Repo(settings=settings)
                try:
                    result = repo.command("task", "list", check=False)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn(f"invalid settings in main:.agentic/project.json: {message}", result.stderr)
                finally:
                    repo.close()
        example = json.loads((Path(__file__).resolve().parents[1] / "project.json.example").read_text())
        repo = Repo(settings=dict(example, accept_checks=[{"command": ["true"], "timeout_minutes": 5}],
                                  task_links={"webapp-ref": "~/ref"}, regen_paths=["/bun.lock", "**/AnalyzerReleases.*"]))
        try:
            self.assertIn("No tasks on", repo.command("task", "list").stdout)
        finally:
            repo.close()


class MainLockInheritanceTests(TaskCliCase):
    """main.lock is held as a machine slot is: no command started under it inherits it, and it comes back with its holder."""

    @staticmethod
    def lock_free(lock):
        with open(lock, "a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.flock(handle, fcntl.LOCK_UN)
            return True

    @staticmethod
    def holds(pid, path):
        try:
            entries = os.listdir(f"/proc/{pid}/fd")
        except FileNotFoundError:
            return False
        for entry in entries:
            try:
                if os.readlink(f"/proc/{pid}/fd/{entry}") == os.path.realpath(path):
                    return True
            except OSError:
                pass
        return False

    def test_the_final_validation_of_finalize_runs_without_the_main_lock_and_its_leftover_never_holds_it(self):
        """lib/validation.py starts each command with close_fds, so the server the final validation leaves behind never got
        the lock even when finalize held it in its own descriptor; validation.py itself did, as every child of finalize
        did. The command looks at the descriptors of its parent, validation.py, while it runs."""
        pid_file, fds = self.scratch / "server.pid", self.scratch / "validation.fds"
        self.make_repo()
        self.repo.init_campaign()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.repo.configure([ticket(status="done")])
        manifest = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(manifest.read_text())
        # A build server the final validation leaves behind: it outlives the finalize.
        plan["final"] = [["sh", "-c", f"for fd in /proc/$PPID/fd/*; do readlink \"$fd\"; done > {fds}; "
                                      f"sleep 600 </dev/null >/dev/null 2>&1 & echo $! > {pid_file}"]]
        manifest.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "final plan", cwd=self.repo.worktree)
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        server = int(pid_file.read_text())
        self.leftovers.append(server)
        self.assertEqual(result.returncode, 0, result.stderr)
        lock = next(Path(self.repo.cache.name).glob("*/main.lock"))
        self.assertTrue(fds.read_text().strip())
        self.assertNotIn(os.path.realpath(lock), fds.read_text().splitlines())
        os.kill(server, 0)
        self.assertFalse(self.holds(server, lock))
        self.assertTrue(self.lock_free(lock))

    def test_a_grandchild_left_running_by_a_git_hook_of_the_accept_never_holds_the_main_branch(self):
        """git runs the project's hooks with every descriptor of its caller: a process a hook leaves running under the
        accept (the post-commit of its squash) held main.lock when the accept kept the lock in its own descriptor."""
        pids = self.scratch / "hook.pids"
        self.make_repo({"accept_checks": [["true"]]})
        self.new()
        hooks = Path(self.repo.git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()) / "hooks"
        hooks.mkdir(exist_ok=True)
        hook = hooks / "post-commit"
        hook.write_text(f"#!/bin/sh\nsleep 600 </dev/null >/dev/null 2>&1 &\necho $! >> {pids}\n")
        hook.chmod(0o755)
        self.task("accept", "tsk-901")
        servers = [int(line) for line in pids.read_text().split()]
        self.leftovers += servers
        self.assertTrue(servers)
        lock = next(Path(self.repo.cache.name).glob("*/main.lock"))
        for server in servers:
            os.kill(server, 0)
            self.assertFalse(self.holds(server, lock))
        self.assertTrue(self.lock_free(lock))

    def test_a_process_a_git_hook_leaves_running_never_holds_the_locks_of_the_task(self):
        """The post-commit of an accept that lands nothing (and of the engine's commits in the next round) leaves a process
        running: it holds neither launcher.lock nor runner.lock, so the task fix after it never waits for them."""
        pids = self.scratch / "hook.pids"
        self.make_repo({"accept_checks": [["false"]]})
        self.new()
        runtime = self.runtime()
        hooks = Path(self.repo.git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()) / "hooks"
        hooks.mkdir(exist_ok=True)
        hook = hooks / "post-commit"
        hook.write_text(f"#!/bin/sh\nsleep 600 </dev/null >/dev/null 2>&1 &\necho $! >> {pids}\n")
        hook.chmod(0o755)
        try:
            result = self.task("accept", "tsk-901", check=False)
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn("was not accepted (accept-failed)", result.stderr)
            servers = [int(line) for line in pids.read_text().split()]
            self.leftovers += servers
            self.assertTrue(servers)
            for server in servers:
                os.kill(server, 0)
                for lock in ("launcher.lock", "runner.lock"):
                    self.assertFalse(self.holds(server, runtime / lock), lock)
            self.assertTrue(self.lock_free(runtime / "launcher.lock"))
            # The round's worker changes a file, so the engine commits it and runs the hook too.
            env = dict(self.repo.env, MOCK_APPEND_FILE="round-2.txt", MOCK_APPEND_TEXT="two\\n")
            try:
                fixed = subprocess.run([str(self.repo.binary()), "task", "fix", "tsk-901", "--note", "Pass the checks."],
                                       cwd=self.repo.root, env=env, text=True, capture_output=True, timeout=30)
            except subprocess.TimeoutExpired:
                self.fail("task fix waited for a lock that a process left by a git hook holds")
            self.assertEqual(fixed.returncode, 0, fixed.stderr)
            # The engine's runner.lock comes back when it ends.
            self.assertEqual(self.wait_idle(seconds=60)["state"], "delivered")
            self.assertGreater(len(pids.read_text().split()), len(servers))
        finally:
            self.leftovers += [int(line) for line in pids.read_text().split()] if pids.exists() else []
        for server in self.leftovers:
            for lock in ("launcher.lock", "runner.lock"):
                self.assertFalse(self.holds(server, runtime / lock), lock)
        self.assertTrue(self.lock_free(runtime / "runner.lock"))

    def test_a_process_the_post_checkout_hook_leaves_when_a_regen_path_goes_back_never_holds_the_runner_lock(self):
        """The engine takes the worker's change to a regen path back with a checkout of that path, which runs post-checkout
        (its third argument 0) while the engine's runner.lock is open."""
        pids = self.scratch / "hook.pids"
        self.make_repo({"regen_paths": ["generated.txt"]})
        self.commit_on_main("generated.txt", "generated\n")
        hooks = Path(self.repo.git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()) / "hooks"
        hooks.mkdir(exist_ok=True)
        hook = hooks / "post-checkout"
        hook.write_text(f'#!/bin/sh\n[ "$3" = 0 ] || exit 0\nsleep 600 </dev/null >/dev/null 2>&1 &\necho $! >> {pids}\n')
        hook.chmod(0o755)
        try:
            self.new(env={"MOCK_APPEND_FILE": "generated.txt", "MOCK_APPEND_TEXT": "the worker's\\n"}, wait=False)
            self.assertEqual(self.wait_idle(seconds=60)["state"], "delivered")
        finally:
            self.leftovers += [int(line) for line in pids.read_text().split()] if pids.exists() else []
        self.assertTrue(self.leftovers, "the post-checkout of the regen path never ran")
        runtime = self.runtime()
        for server in self.leftovers:
            os.kill(server, 0)
            self.assertFalse(self.holds(server, runtime / "runner.lock"))
        self.assertTrue(self.lock_free(runtime / "runner.lock"))
        self.assertEqual(self.repo.git("show", "campaign/tsk-901:generated.txt").stdout, "generated\n")

    def test_the_main_lock_comes_back_when_an_accept_is_killed_during_its_validation(self):
        out = self.scratch / "out"
        out.mkdir()
        self.make_repo({"accept_checks": [["sh", "-c", f"echo $$ > {out}/check.pid; while :; do sleep 0.05; done"]]})
        self.new()
        log = open(self.scratch / "accept.log", "w")
        accept = subprocess.Popen([str(self.repo.binary()), "task", "accept", "tsk-901"], cwd=self.repo.root,
                                  env=self.repo.env, stdout=log, stderr=subprocess.STDOUT)
        log.close()
        self.assertTrue(wait_for(lambda: (out / "check.pid").exists()), (self.scratch / "accept.log").read_text())
        check = int((out / "check.pid").read_text())
        validation = int(Path(f"/proc/{check}/stat").read_text().rsplit(")", 1)[1].split()[1])
        self.leftovers += [check, validation]
        lock = next(Path(self.repo.cache.name).glob("*/main.lock"))
        self.assertFalse(self.lock_free(lock))
        self.assertFalse(self.holds(validation, lock))
        self.assertFalse(self.holds(check, lock))
        accept.send_signal(signal.SIGKILL)
        accept.wait(timeout=10)
        # The validation still runs; the lock went with its holder.
        self.assertTrue(wait_for(lambda: self.lock_free(lock), 5), "main.lock outlived the accept")
        os.kill(validation, 0)
        os.kill(check, 0)


if __name__ == "__main__":
    unittest.main()

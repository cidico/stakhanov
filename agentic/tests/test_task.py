#!/usr/bin/env python3
"""A task: a campaign of one ticket whose plan, generated from its brief, lives in the runtime. The plan generator, the
engine on kind: task (no plan or status commits, optional review, never a red base), the bounded validation repair and
the environment failures of tickets and tasks, and the object form of the validation commands. No real provider runs."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_campaign import KIT, Repo, ticket

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "tasks"
CHEAP = ["git", "diff", "--check", "HEAD"]
# For the tests about what a validation does after the worker: they do not need the proof that it fails on the base.
SKIP_BASE = "validate_base: skip\nvalidate_base_reason: the test is about the validation after the worker"


def brief(task_id="TSK-901", title="Write the product file", validate=("test -f product-T-001.txt",), review=False,
          commit=None, fields=""):
    """A brief in the format of the rewrite's tasks; validate holds the command strings, fields extra front matter."""
    lines = ["---", f"id: {task_id}", f"title: {json.dumps(title)}", "after: [TSK-900]", "domains: [product]",
             "requires: []", "prefer: any", "model: opus", "effort: high", f"review: {str(review).lower()}",
             "timeout_minutes: 30", "validate:"]
    lines += [f"  - {json.dumps(command)}" for command in validate]
    if commit:
        lines.append(f"commit: {json.dumps(commit)}")
    if fields:
        lines.append(fields)
    lines += ["---", "", "# Objetivo", "", "Write the product file.", "", "# Aceite", "", "- `product-T-001.txt` exists.",
              "", "# Fora do escopo", "", "- anything else", "", "# Contexto", "", "- the mock worker writes it.", ""]
    return "\n".join(lines)


class TaskCase(unittest.TestCase):
    def setUp(self):
        self.repo = None

    def tearDown(self):
        if self.repo is not None:
            self.repo.close()

    def make_repo(self, **kwargs):
        self.repo = Repo(**kwargs)
        self.repo.mock_provider()
        return self.repo

    def runtime_of(self, slug):
        result = subprocess.run(["bash", "-c", 'source "$1/lib/common.sh" && runtime_dir "$2"', "runtime",
                                 str(self.repo.root / ".agentic"), slug],
                                cwd=self.repo.root, env=self.repo.env, text=True, capture_output=True, check=True)
        return Path(result.stdout.strip())

    def write_brief(self, text, name="brief.md"):
        path = Path(self.repo.cache.name) / "briefs" / name
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)
        return path

    def start_task(self, text, slug="tsk-901"):
        """What `campaign task new` does: the plan in the runtime, the campaign/<slug> branch and its worktree from the
        main branch, and a campaign.json of kind task."""
        runtime = self.runtime_of(slug)
        result = self.repo.command("_task-plan", str(self.write_brief(text)), str(runtime / "plan"))
        self.assertEqual(result.stdout.strip(), slug)
        worktree = runtime / "worktrees" / "campaign"
        self.repo.git("worktree", "add", "-b", f"campaign/{slug}", str(worktree), "main")
        (runtime / "campaign.json").write_text(json.dumps({
            "slug": slug, "kind": "task", "branch": f"campaign/{slug}", "worktree": str(worktree),
            "spec": str(runtime / "plan" / "SPEC.md")}))
        self.runtime, self.worktree, self.slug = runtime, worktree, slug
        return worktree

    def run_task(self, env=None):
        result = self.repo.command("run", "--provider", "mock", cwd=self.worktree, check=False, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def status(self, worktree=None):
        return json.loads(self.repo.command("status", "--json", cwd=worktree or self.worktree).stdout)

    def events(self, runtime=None):
        path = (runtime or self.runtime) / "events" / "campaign.ndjson"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def invocations(self, role, ticket="T-001", runtime=None):
        return [event for event in self.events(runtime) if event["type"] == "provider-started"
                and event.get("ticket") == ticket and event["message"].startswith(f"role={role} ")]

    def commits(self, branch):
        log = self.repo.git("log", "--format=%s", f"main..{branch}").stdout
        return [line for line in log.splitlines() if line]


class TaskPlanTests(TaskCase):
    """campaign _task-plan BRIEF DIR."""

    def plan(self, path, directory):
        return self.repo.command("_task-plan", str(path), str(directory), check=False)

    def test_the_plan_of_a_real_brief(self):
        self.make_repo()
        directory = Path(self.repo.cache.name) / "plan"
        result = self.plan(FIXTURES / "GRD-002.md", directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "grd-002")
        self.assertEqual(sorted(str(path.relative_to(directory)) for path in directory.rglob("*") if path.is_file()),
                         ["SPEC.md", "task.json", "tickets/T-001.md", "validation.json"])
        spec = (directory / "SPEC.md").read_text()
        self.assertTrue(spec.startswith("# Regra: no máximo 6 parâmetros de construtor\n"))
        for section in ("Problem Statement", "Solution", "User Stories", "Implementation Decisions", "Testing Decisions",
                        "Out of Scope", "Open questions"):
            self.assertIn(f"\n## {section}\n", spec)
        problem = spec.split("## Problem Statement\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn("Criar a regra de analisador", problem)
        # The whole body of the brief, under the generated sections.
        for line in ("### Objetivo", "### Aceite", "### Fora do escopo", "### Contexto", "- outras regras",
                     "- A regra tem o id `SHOTLY003`, o descriptor no próprio arquivo e uma mensagem que diz o que fazer no lugar."):
            self.assertIn(f"\n{line}\n", spec)
        tickets = json.loads(subprocess.run(["python3", str(KIT / "lib" / "tickets.py"), "list", str(directory / "tickets")],
                                            check=True, capture_output=True, text=True).stdout)
        self.assertEqual([(item["id"], item["status"], item["depends_on"], item["collision_domains"]) for item in tickets],
                         [("T-001", "todo", [], ["analyzer-ctor"])])
        self.assertIn("Criar a regra de analisador", tickets[0]["goal"])
        ticket_text = (directory / "tickets" / "T-001.md").read_text()
        self.assertIn("- Severidade de erro; nenhuma supressão possível.", ticket_text.split("# Acceptance", 1)[1])
        self.assertIn("- outras regras", ticket_text.split("# Non-goals", 1)[1])
        self.assertIn("SHOTLY001/002/003 de hoje", ticket_text.split("# Context", 1)[1])
        command = ["dotnet", "test", "platform/analyzers/Shotly.Analyzers.slnx"]
        self.assertEqual(json.loads((directory / "validation.json").read_text()), {
            "version": 1, "timeout_minutes": 60,
            "tickets": {"T-001": {"cheap": [command], "component": [], "expensive": []}}, "final": [command]})
        task = json.loads((directory / "task.json").read_text())
        self.assertEqual({key: value for key, value in task.items() if key != "brief"}, {
            "id": "GRD-002", "slug": "grd-002", "title": "Regra: no máximo 6 parâmetros de construtor",
            "after": ["GRD-001"], "domains": ["analyzer-ctor"], "requires": ["dotnet"], "prefer": "any",
            "model": "opus", "effort": "high", "review": False, "timeout_minutes": 60,
            "validate": ["dotnet test platform/analyzers/Shotly.Analyzers.slnx"], "commit": None, "units": None,
            "validate_base": None, "validate_base_reason": None, "ticket": "T-001"})
        self.assertEqual(task["brief"], str((FIXTURES / "GRD-002.md").resolve()))

    def test_a_shell_command_of_the_brief_is_split_as_a_shell_splits_it(self):
        self.make_repo()
        directory = Path(self.repo.cache.name) / "plan"
        result = self.plan(FIXTURES / "CAT-002.md", directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "cat-002")
        plan = json.loads((directory / "validation.json").read_text())
        commands = [["bash", "-c", "test -s tools/parity/catalog/identity/README.md && ls tools/parity/catalog/identity/*.md | wc -l"],
                    ["git", "diff", "--check"]]
        self.assertEqual(plan["tickets"]["T-001"]["cheap"], commands)
        self.assertEqual(plan["final"], commands)
        self.assertEqual(plan["timeout_minutes"], 120)
        task = json.loads((directory / "task.json").read_text())
        self.assertEqual((task["review"], task["prefer"], task["model"], task["requires"]), (True, "kepler", "sonnet", ["webapp-ref"]))

    def test_the_optional_commit_and_units_are_kept(self):
        self.make_repo()
        directory = Path(self.repo.cache.name) / "plan"
        result = self.plan(self.write_brief(brief(commit="feat(analyzers)", fields="units: 2")), directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        task = json.loads((directory / "task.json").read_text())
        self.assertEqual((task["commit"], task["units"]), ("feat(analyzers)", 2))

    def test_validate_base_and_its_reason_are_kept_and_reach_the_ticket(self):
        self.make_repo()
        directory = Path(self.repo.cache.name) / "plan"
        reason = "a refactor: the tests that prove it already pass: yes"
        result = self.plan(self.write_brief(brief(fields=f'validate_base: skip\nvalidate_base_reason: "{reason}"')), directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        task = json.loads((directory / "task.json").read_text())
        self.assertEqual((task["validate_base"], task["validate_base_reason"]), ("skip", reason))
        listing = json.loads(subprocess.run(["python3", str(KIT / "lib" / "tickets.py"), "get", str(directory / "tickets"), "T-001"],
                                            text=True, capture_output=True, check=True).stdout)
        self.assertEqual((listing["validate_base"], listing["validate_base_reason"]), ("skip", reason))
        # Without them the check runs: the ticket carries nothing and the brief's fields are null.
        plain = Path(self.repo.cache.name) / "plain"
        self.assertEqual(self.plan(self.write_brief(brief(), "plain.md"), plain).returncode, 0)
        task = json.loads((plain / "task.json").read_text())
        self.assertEqual((task["validate_base"], task["validate_base_reason"]), (None, None))
        self.assertNotIn("validate_base", (plain / "tickets" / "T-001.md").read_text())

    def test_a_brief_is_refused_with_its_reason_and_nothing_is_written(self):
        self.make_repo()
        good = brief()
        cases = {
            "no front matter": (good.split("---\n", 2)[2], "no front matter"),
            "no id": (good.replace("id: TSK-901\n", ""), "id is required"),
            "no title": (good.replace('title: "Write the product file"\n', ""), "title is required"),
            "empty validate": (good.replace('validate:\n  - "test -f product-T-001.txt"\n', "validate: []\n"),
                               "validate must be a non-empty list"),
            "no validate": (good.replace('validate:\n  - "test -f product-T-001.txt"\n', ""), "validate must be a non-empty list"),
            "no review": (good.replace("review: false\n", ""), "review is required"),
            "review as text": (good.replace("review: false", "review: yes"), "review must be true or false"),
            "timeout as text": (good.replace("timeout_minutes: 30", 'timeout_minutes: "30"'), "timeout_minutes must be an integer"),
            "timeout out of range": (good.replace("timeout_minutes: 30", "timeout_minutes: 0"), "timeout_minutes must be an integer"),
            "domains as text": (good.replace("domains: [product]", "domains: product"), "domains must be a list"),
            "after of numbers": (good.replace("after: [TSK-900]", "after: [1]"), "after must be a list of non-empty strings"),
            "a validate number": (good.replace('  - "test -f product-T-001.txt"', "  - 42"), "command 1 must be a non-empty string"),
            "unbalanced quotes": (good.replace('  - "test -f product-T-001.txt"', "  - \"bash -c 'true\""), "cannot be split"),
            "unknown field": (good.replace("prefer: any", "prefer: any\nreveiw: true"), "unknown field(s): reveiw"),
            "commit message": (brief(commit="Add the product file"), "commit must be the type(area)"),
            "duplicate field": (good.replace("prefer: any", "prefer: any\nprefer: kepler"), "prefer appears twice"),
            "bad name": (good.replace("id: TSK-901", "id: TSK_901"), "invalid campaign slug: tsk_901"),
            "skip without a reason": (brief(fields="validate_base: skip"), "validate_base: skip needs a validate_base_reason"),
            "skip with a blank reason": (brief(fields='validate_base: skip\nvalidate_base_reason: "  "'),
                                         "validate_base_reason must be a non-empty string"),
            "a reason without skip": (brief(fields="validate_base_reason: it is a refactor"),
                                      "validate_base_reason without validate_base: skip"),
            "another validate_base": (brief(fields="validate_base: run\nvalidate_base_reason: it is a refactor"),
                                      "validate_base must be skip"),
            "validate_base twice": (brief(fields=SKIP_BASE + "\nvalidate_base: skip"), "validate_base appears twice"),
        }
        # A command runs with no shell: shell syntax outside quotes is refused and the brief is told to use bash -c.
        for name, command in {"an and": "cd apps && bun test", "an or": "make || true", "a pipe": "ls | wc -l",
                              "a semicolon": "cd apps; bun test", "a redirection": "dotnet test > out.txt",
                              "an append": "dotnet test >> out.txt", "an input": "sort < in.txt",
                              "a merged stream": "dotnet test 2>&1", "a background": "sleep 1 &",
                              "a variable": "echo $HOME", "a glob": "ls tools/*.md", "a substitution": "echo `date`",
                              "a double quote that closes": 'bash -c "true" && true'}.items():
            cases[f"shell syntax: {name}"] = (good.replace('  - "test -f product-T-001.txt"', f"  - {json.dumps(command)}"),
                                              "write it as bash -c")
        for name, (text, message) in cases.items():
            with self.subTest(name):
                directory = Path(self.repo.cache.name) / "plans" / name.replace(" ", "-").replace(":", "")
                result = self.plan(self.write_brief(text), directory)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn(message, result.stderr)
                self.assertFalse(directory.exists())
                self.assertEqual(list(directory.parent.glob(".task-plan.*")), [])

    def test_a_plan_without_the_projects_required_checks_is_refused(self):
        self.make_repo(settings={"required_checks": [CHEAP]})
        directory = Path(self.repo.cache.name) / "plan"
        result = self.plan(self.write_brief(brief()), directory)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lacks the required check", result.stderr)
        self.assertFalse(directory.exists())
        result = self.plan(self.write_brief(brief(validate=("test -f product-T-001.txt", " ".join(CHEAP)))), directory)
        self.assertEqual(result.returncode, 0, result.stderr)


class TaskEngineTests(TaskCase):
    """A campaign.json of kind task: the engine reads the plan in the runtime and commits only the worker's delta."""

    def test_a_task_runs_to_done_with_no_commit_but_the_workers_delta(self):
        self.make_repo()
        worktree = self.start_task(brief())
        self.assertIn("Campaign tsk-901 verified (1 tickets)", self.repo.command("verify", cwd=worktree).stdout)
        self.assertEqual([item["id"] for item in json.loads(self.repo.command("ready", "--json", cwd=worktree).stdout)], ["T-001"])
        main = self.repo.git("rev-parse", "main").stdout
        self.run_task()
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["done"])
        self.assertIn("status: done\n", (self.runtime / "plan" / "tickets" / "T-001.md").read_text())
        self.assertEqual(self.commits(f"campaign/{self.slug}"), ["feat(task): Write the product file"])
        self.assertEqual(self.repo.git("rev-parse", "main").stdout, main)
        self.assertTrue((worktree / "product-T-001.txt").is_file())
        self.assertFalse((worktree / "campaigns").exists())
        self.assertEqual(self.repo.git("status", "--porcelain", cwd=worktree).stdout, "")
        self.assertEqual(self.repo.git("branch", "--list", f"agentic/{self.slug}/*").stdout.strip(), "")
        types = [event["type"] for event in self.events()]
        self.assertIn("review-skipped", types)
        self.assertIn("ticket-done", types)
        self.assertEqual(self.invocations("reviewer"), [])
        # The worker reads the plan where it lives.
        prompt = (self.runtime / "prompts" / "T-001-worker.md").read_text()
        self.assertIn(f"Campaign SPEC: {self.runtime}/plan/SPEC.md\n", prompt)
        self.assertIn(f"Ticket: {self.runtime}/plan/tickets/T-001.md\n", prompt)
        overview = json.loads(self.repo.command("overview", "--json").stdout)
        [item] = overview["campaigns"]
        self.assertEqual((item["slug"], item["kind"], item["counts"]), ("tsk-901", "task", {"done": 1}))
        self.assertEqual(item["tickets"][0]["goal"], "Write the product file.")

    def test_a_task_with_review_runs_its_reviewer_and_commits_with_the_briefs_message(self):
        self.make_repo()
        self.start_task(brief(review=True, commit="docs(catalog)"))
        self.run_task()
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["done"])
        self.assertEqual(len(self.invocations("reviewer")), 1)
        self.assertNotIn("review-skipped", [event["type"] for event in self.events()])
        self.assertEqual(self.commits(f"campaign/{self.slug}"), ["docs(catalog): Write the product file"])

    def test_the_repair_of_a_red_validation_stops_at_one(self):
        self.make_repo()
        self.start_task(brief(validate=("test -f never-created",)))
        self.run_task(env={"AGENTIC_AUTO_RECOVERIES": "0"})
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["blocked"])
        self.assertEqual(len(self.invocations("worker")), 2)  # the worker and one repair
        blocked = [event for event in self.events() if event["type"] == "ticket-blocked"]
        self.assertEqual([event["message"] for event in blocked], ["validation still red after 1 repair(s)"])
        # The block is written in the runtime; nothing reaches the task's branch.
        self.assertIn("status: blocked\n", (self.runtime / "plan" / "tickets" / "T-001.md").read_text())
        self.assertEqual(self.commits(f"campaign/{self.slug}"), [])

    def test_a_task_never_has_a_red_base(self):
        self.make_repo()
        worktree = self.start_task(brief())
        plan_path = self.runtime / "plan" / "validation.json"
        plan = json.loads(plan_path.read_text())
        plan["baseline"] = [["false"]]
        plan_path.write_text(json.dumps(plan))
        script = ('source "$1/lib/common.sh"; source "$1/lib/validation.sh"; source "$1/lib/engine.sh"; '
                  'if base_is_red; then echo red; else echo green; fi')

        def base():
            return subprocess.run(["bash", "-c", script, "base", str(worktree / ".agentic")], cwd=worktree,
                                  env=self.repo.env, text=True, capture_output=True, check=True).stdout.strip()

        self.assertEqual(base(), "green")
        self.assertEqual(list((self.runtime / "validation").glob("campaign.baseline.json")), [])
        # The same plan in a campaign: its base is red.
        (worktree / "campaigns" / self.slug).mkdir(parents=True)
        (worktree / "campaigns" / self.slug / "validation.json").write_text(json.dumps(plan))
        data = json.loads((self.runtime / "campaign.json").read_text())
        del data["kind"]
        (self.runtime / "campaign.json").write_text(json.dumps(data))
        self.assertEqual(base(), "red")

    def test_decide_and_recover_change_a_tasks_status_without_a_commit(self):
        self.make_repo()
        worktree = self.start_task(brief(validate=("test -f never-created",)))
        self.run_task(env={"AGENTIC_AUTO_RECOVERIES": "0"})
        self.repo.command("recover", "T-001", cwd=worktree)
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["todo"])
        self.assertEqual(self.commits(f"campaign/{self.slug}"), [])
        # decide moves the status from todo to blocked: in the runtime, and nothing is committed.
        (self.runtime / "decisions").mkdir(exist_ok=True)
        decision = self.runtime / "decisions" / "T-001.json"
        decision.write_text(json.dumps({"ticket": "T-001", "reason": "test", "options": ["retry", "block", "cancel"]}))
        result = self.repo.command("decide", "T-001", "block", cwd=worktree)
        self.assertIn("T-001 marked blocked", result.stderr + result.stdout)
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["blocked"])
        self.assertIn("status: blocked\n", (self.runtime / "plan" / "tickets" / "T-001.md").read_text())
        self.assertIn("decision-applied", [event["type"] for event in self.events()])
        self.assertFalse(decision.exists())
        self.assertEqual(self.commits(f"campaign/{self.slug}"), [])
        self.assertEqual(self.repo.git("status", "--porcelain", cwd=worktree).stdout, "")

    def test_an_adopted_task_stays_a_task(self):
        # What `campaign move` leaves in the target's clone before `_adopt`: the branch and the runtime it sent.
        self.make_repo()
        slug = "tsk-901"
        staged = self.repo.root / ".git" / "agentic-move" / slug
        self.repo.command("_task-plan", str(self.write_brief(brief())), str(staged / "plan"))
        self.repo.git("branch", f"campaign/{slug}", "main")
        result = self.repo.command("_adopt", slug, "--from", "elsewhere", "--epoch", "2", "--desired", "stopped")
        runtime = self.runtime_of(slug)
        data = json.loads((runtime / "campaign.json").read_text())
        self.assertEqual((data["kind"], data["spec"], data["epoch"]), ("task", f"{runtime}/plan/SPEC.md", 2))
        worktree = Path(result.stdout.strip().splitlines()[-1])
        self.assertEqual([(item["id"], item["status"]) for item in self.status(worktree)["tickets"]], [("T-001", "todo")])


class TaskBaseCheckTests(TaskCase):
    """The validate commands of a task must fail on its base before its worker starts, unless the brief says why not."""

    def test_validate_commands_that_pass_on_the_base_refuse_the_task_before_its_worker(self):
        self.make_repo()
        self.start_task(brief(validate=("git diff --check HEAD",)))
        self.run_task()
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["blocked"])
        self.assertEqual(self.invocations("worker"), [])
        message = "validate already passes on the base: it does not prove the change"
        [blocked] = [event for event in self.events() if event["type"] == "ticket-blocked"]
        self.assertTrue(blocked["message"].startswith(message), blocked["message"])
        self.assertIn("passed: git diff --check HEAD", blocked["message"])
        self.assertEqual([event for event in self.events() if event["type"] == "recovery-scheduled"], [])
        # Nothing is committed for a task, and no throwaway worktree is left.
        self.assertEqual(self.commits(f"campaign/{self.slug}"), [])
        self.assertNotIn("validate-base", self.repo.git("worktree", "list", "--porcelain").stdout)

    def test_a_validate_command_that_fails_on_the_base_lets_the_worker_run(self):
        self.make_repo()
        self.start_task(brief())
        self.run_task()
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["done"])
        [proves] = [event for event in self.events() if event["type"] == "validate-base-proves"]
        self.assertIn("failed test -f product-T-001.txt", proves["message"])

    def test_skip_with_a_reason_runs_the_worker_and_records_why(self):
        self.make_repo()
        self.start_task(brief(validate=("git diff --check HEAD",), fields='validate_base: skip\nvalidate_base_reason: "docs only"'))
        self.run_task()
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["done"])
        [skipped] = [event for event in self.events() if event["type"] == "validate-base-skipped"]
        self.assertIn("docs only", skipped["message"])
        self.assertEqual(len(self.invocations("worker")), 1)

    def test_the_context_and_the_links_of_the_task_are_there_on_the_base(self):
        reference = Path(tempfile.mkdtemp(prefix="task-link-"))
        self.addCleanup(shutil.rmtree, reference, True)
        self.make_repo(settings={"task_links": {"ref-link": str(reference)}})
        seen = Path(self.repo.cache.name) / "seen"
        probe = (f"bash -c 'test -e ref-link && test -f .task/TASK.md && ! test -f product-T-001.txt && echo seen >> {seen}; "
                 f"test -f product-T-001.txt'")
        self.start_task(brief(validate=(probe,)))
        # What `campaign task new` mounts in the ticket worktree (git ignores it there), and the engine copies to the base.
        with open(self.repo.root / ".git" / "info" / "exclude", "a") as exclude:
            exclude.write("/.task\n/ref-link\n")
        tree = self.runtime / "worktrees" / "T-001"
        self.repo.git("worktree", "add", "-b", f"agentic/{self.slug}/T-001", str(tree), f"campaign/{self.slug}")
        (tree / ".task").mkdir()
        (tree / ".task" / "TASK.md").write_text("the brief\n")
        (tree / "ref-link").symlink_to(reference)
        self.run_task()
        self.assertEqual(seen.read_text().splitlines(), ["seen"])  # only the run on the base, before the product exists
        self.assertEqual([item["status"] for item in self.status()["tickets"]], ["done"])


class EnvironmentFailureTests(TaskCase):
    """A validation that fails because of its environment is neither repaired nor recovered, for a task and a ticket."""

    def assert_environment_block(self, command, cause, runtime, ticket="T-001", status=None):
        self.assertEqual([item["status"] for item in status["tickets"]], ["blocked"])
        self.assertEqual(len(self.invocations("worker", ticket, runtime)), 1)  # the worker, no repair
        events = self.events(runtime)
        [failure] = [event for event in events if event["type"] == "environment-failure"]
        self.assertIn(f"{command} ({cause}", failure["message"])
        [blocked] = [event for event in events if event["type"] == "ticket-blocked"]
        self.assertTrue(blocked["message"].startswith(f"environment: {command} ({cause}"), blocked["message"])
        self.assertNotIn("recovery-scheduled", [event["type"] for event in events])

    def task_blocked_by(self, command, cause, env=None, settings=None):
        self.make_repo(settings=settings)
        self.start_task(brief(validate=(command,), fields=SKIP_BASE))
        self.run_task(env=env)
        self.assert_environment_block(command, cause, self.runtime, status=self.status())

    def test_a_command_that_exits_127(self):
        self.task_blocked_by("bash -c 'not-a-command-of-this-machine --version'", "exit 127, command not found")

    def test_a_command_that_does_not_exist(self):
        self.task_blocked_by("not-a-command-of-this-machine --version", "command not found")

    def task_repaired_for(self, command):
        """A validation whose missing file is the code's: one repair, then the block of a red validation."""
        self.make_repo()
        self.start_task(brief(validate=(command,)))
        self.run_task(env={"AGENTIC_AUTO_RECOVERIES": "0"})
        self.assertNotIn("environment-failure", [event["type"] for event in self.events()])
        self.assertEqual(len(self.invocations("worker")), 2)  # the worker and one repair
        self.assertIn("validation still red after 1 repair(s)",
                      [event["message"] for event in self.events() if event["type"] == "ticket-blocked"])

    def test_a_script_of_the_worktree_that_is_missing_is_repaired(self):
        # A task creates what it validates: a script that is not there yet is the code's defect, not the machine's.
        self.task_repaired_for("bash not-created.sh")

    def test_a_relative_path_that_is_missing_is_repaired(self):
        self.task_repaired_for("./not-created.sh")

    def test_a_command_looked_up_in_the_path_is_the_environments(self):
        self.task_blocked_by("bash -c tool-of-no-machine", "exit 127, command not found")

    def test_a_command_past_its_deadline(self):
        self.task_blocked_by("sleep 30", "timed out after", env={"AGENTIC_VALIDATION_TIMEOUT_SECONDS": "1"})
        receipt = json.loads((self.runtime / "validation" / "T-001.cheap.json").read_text())
        self.assertTrue(receipt["evidence"][-1]["timedOut"])

    def test_an_output_that_matches_a_pattern_of_the_project(self):
        command = "bash -c 'echo Cannot connect to the Docker daemon at unix:///var/run/docker.sock >&2; exit 1'"
        self.task_blocked_by(command, "output matches Cannot connect to the Docker daemon",
                             settings={"environment_failure_patterns": ["Cannot connect to the Docker daemon"]})

    def test_an_output_that_matches_no_pattern_is_repaired(self):
        self.make_repo(settings={"environment_failure_patterns": ["Cannot connect to the Docker daemon"]})
        self.start_task(brief(validate=("bash -c 'echo assertion failed >&2; exit 1'",)))
        self.run_task(env={"AGENTIC_AUTO_RECOVERIES": "0"})
        self.assertEqual(len(self.invocations("worker")), 2)
        self.assertNotIn("environment-failure", [event["type"] for event in self.events()])

    def test_a_receipt_of_an_earlier_run_is_not_this_runs_failure(self):
        # validation.py writes no receipt when it stops before any command (here, a bad deadline setting): the timed-out
        # receipt left by an earlier run says nothing about this one, which is repaired as any red validation.
        self.make_repo()
        self.start_task(brief(fields=SKIP_BASE))
        (self.runtime / "validation").mkdir(parents=True, exist_ok=True)
        (self.runtime / "validation" / "T-001.cheap.json").write_text(json.dumps({
            "status": "FAIL", "timedOut": True, "failed_command": ["sleep", "30"],
            "evidence": [{"command": ["sleep", "30"], "exitCode": 124, "timedOut": True, "summary": "timed out after 1 min"}]}))
        self.run_task(env={"AGENTIC_AUTO_RECOVERIES": "0", "AGENTIC_VALIDATION_TIMEOUT_SECONDS": "never"})
        self.assertNotIn("environment-failure", [event["type"] for event in self.events()])
        self.assertEqual(len(self.invocations("worker")), 2)
        self.assertIn("validation still red after 1 repair(s)",
                      [event["message"] for event in self.events() if event["type"] == "ticket-blocked"])

    def test_an_invalid_pattern_stops_every_command(self):
        self.make_repo(settings={"environment_failure_patterns": ["(unclosed"]})
        result = self.repo.command("overview", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid environment_failure_patterns", result.stderr)
        self.assertIn("(unclosed", result.stderr)

    def test_a_campaign_ticket_is_blocked_the_same_way(self):
        self.make_repo()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text())
        plan["tickets"]["TST-001"]["cheap"] = [["bash", "-c", "not-a-command-of-this-machine"]]
        plan_path.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "environment", cwd=self.repo.worktree)
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        self.assert_environment_block("bash -c not-a-command-of-this-machine", "exit 127, command not found", runtime,
                                      "TST-001", json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout))


class CampaignUnchangedTests(TaskCase):
    """A campaign keeps its plan on its branch, its commits and its reviewer; only its validation repair is bounded."""

    def test_a_campaign_commits_its_plan_and_status_and_is_reviewed(self):
        self.make_repo()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        self.assertEqual(self.commits(f"campaign/{self.repo.slug}"),
                         ["chore(agentic): mark TST-001 done", "feat(agentic): complete TST-001", "tickets",
                          "docs(agentic): initialize harness-sample campaign"])
        self.assertEqual(len(self.invocations("reviewer", "TST-001", runtime)), 1)
        self.assertNotIn("review-skipped", [event["type"] for event in self.events(runtime)])
        [item] = json.loads(self.repo.command("overview", "--json").stdout)["campaigns"]
        self.assertEqual((item["kind"], item["counts"]), ("campaign", {"done": 1}))

    def test_a_campaign_ignores_a_task_json_of_its_plan(self):
        # review is a task's setting: a campaign's ticket is reviewed whatever its plan folder holds.
        self.make_repo()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        (self.repo.worktree / "campaigns" / self.repo.slug / "task.json").write_text(json.dumps({"review": False, "title": "x"}))
        self.repo.git("add", ".", cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "stray task.json", cwd=self.repo.worktree)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        self.assertEqual(len(self.invocations("reviewer", "TST-001", runtime)), 1)
        self.assertIn("feat(agentic): complete TST-001", self.commits(f"campaign/{self.repo.slug}"))

    def test_a_campaign_tickets_repair_stops_at_one_and_takes_the_recovery_path(self):
        self.make_repo()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text())
        plan["tickets"]["TST-001"]["cheap"] = [["test", "-f", "never-created"]]
        plan_path.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree)
        self.repo.git("commit", "-m", "red", cwd=self.repo.worktree)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual([item["status"] for item in state["tickets"]], ["blocked"])
        events = self.events(runtime)
        self.assertEqual([event["type"] for event in events].count("recovery-scheduled"), 2)
        blocked = [event["message"] for event in events if event["type"] == "ticket-blocked"]
        self.assertEqual(blocked, ["validation still red after 1 repair(s)"] * 3)
        # Three runs of the ticket (the first and two recoveries), each a worker and one repair.
        self.assertEqual(len(self.invocations("worker", "TST-001", runtime)), 6)

    def test_more_repairs_when_the_setting_allows_them(self):
        self.make_repo()
        self.start_task(brief(validate=("test -f never-created",)))
        self.run_task(env={"AGENTIC_AUTO_RECOVERIES": "0", "AGENTIC_VALIDATION_REPAIRS": "2"})
        self.assertEqual(len(self.invocations("worker")), 3)
        self.assertIn("validation still red after 2 repair(s)",
                      [event["message"] for event in self.events() if event["type"] == "ticket-blocked"])

    def test_an_invalid_repair_setting_stops_the_run(self):
        self.make_repo()
        self.start_task(brief())
        result = self.repo.command("run", "--provider", "mock", cwd=self.worktree, check=False,
                                   env={"AGENTIC_VALIDATION_REPAIRS": "many"})
        self.assertEqual(result.returncode, 2)
        self.assertIn("AGENTIC_VALIDATION_REPAIRS must be a single digit", result.stderr)


class CommandFormTests(TaskCase):
    """{"command": [...], "timeout_minutes": N} is a command everywhere the kit reads a plan."""

    def campaign_with(self, change, settings=None):
        self.make_repo(settings=settings)
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text())
        change(plan)
        plan_path.write_text(json.dumps(plan))
        return self.repo.command("verify", cwd=self.repo.worktree, check=False)

    def test_verify_accepts_the_object_form(self):
        def change(plan):
            plan["timeout_minutes"] = 30
            plan["tickets"]["TST-001"]["cheap"] = [{"command": CHEAP, "timeout_minutes": 5}]
            plan["final"] = [{"command": CHEAP}]
            plan["baseline"] = [{"command": ["true"], "timeout_minutes": 1}]
        result = self.campaign_with(change)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_verify_refuses_a_malformed_object(self):
        cases = {
            "empty command": {"command": []},
            "no command": {"timeout_minutes": 5},
            "text command": {"command": "git diff --check"},
            "unknown field": {"command": CHEAP, "cwd": "/"},
            "zero minutes": {"command": CHEAP, "timeout_minutes": 0},
            "too many minutes": {"command": CHEAP, "timeout_minutes": 1441},
            "text minutes": {"command": CHEAP, "timeout_minutes": "5"},
        }
        for name, entry in cases.items():
            with self.subTest(name):
                def change(plan, entry=entry):
                    plan["tickets"]["TST-001"]["cheap"] = [entry]
                result = self.campaign_with(change)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("trusted validation plan is malformed", result.stderr)
                self.repo.close()
                self.repo = None
        with self.subTest("plan minutes"):
            result = self.campaign_with(lambda plan: plan.update(timeout_minutes=0))
            self.assertIn("trusted validation plan is malformed", result.stderr)

    def test_a_required_check_in_the_object_form_counts(self):
        def change(plan):
            plan["tickets"]["TST-001"]["cheap"] = [{"command": CHEAP, "timeout_minutes": 5}]
            plan["final"] = [{"command": CHEAP}]
        result = self.campaign_with(change, settings={"required_checks": [CHEAP]})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_baseline_command_in_the_object_form_is_recognized(self):
        self.make_repo()
        receipt = Path(self.repo.cache.name) / "receipt.json"
        manifest = Path(self.repo.cache.name) / "validation.json"
        receipt.write_text(json.dumps({"status": "FAIL", "failed_command": ["make", "lint"]}))
        script = 'source "$1/lib/common.sh"; source "$1/lib/validation.sh"; failed_command_is_baseline "$2" "$3"'
        for baseline, expected in (([{"command": ["make", "lint"], "timeout_minutes": 5}], 0), ([["make", "lint"]], 0),
                                   ([{"command": ["make", "test"]}], 1)):
            with self.subTest(baseline=baseline):
                manifest.write_text(json.dumps({"version": 1, "tickets": {}, "final": [["true"]], "baseline": baseline}))
                result = subprocess.run(["bash", "-c", script, "baseline", str(self.repo.root / ".agentic"), str(receipt),
                                         str(manifest)], cwd=self.repo.root, env=self.repo.env, capture_output=True)
                self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()

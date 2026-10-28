#!/usr/bin/env python3
"""Deterministic supervisor tests. No real provider process is used."""

from __future__ import annotations

import atexit
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest

HARNESS = Path(__file__).resolve().parents[1]
TICKETS = HARNESS / "lib" / "tickets.py"

# The tests never run the kit they live in: an installed kit carries the project's real project.json (name, main branch,
# environment). They run from one clean copy without it, made once for the whole run.
_KIT_ROOT = tempfile.mkdtemp(prefix="agentic-kit-")
atexit.register(shutil.rmtree, _KIT_ROOT, ignore_errors=True)
KIT = Path(_KIT_ROOT) / "agentic"
shutil.copytree(HARNESS, KIT, ignore=shutil.ignore_patterns("tests", "__pycache__", "project.json*"))
CAMPAIGN = KIT / "bin" / "campaign"

SPEC = """\
# Harness Sample

## Problem Statement
Prove the supervisor.
## Solution
Complete deterministic tickets.
## User Stories
1. As a maintainer, I want deterministic tickets, so that the supervisor is proven.
## Implementation Decisions
Use a mock provider.
## Testing Decisions
All tickets complete.
## Out of Scope
Real provider calls.
## Open questions
None.
"""


def ticket(ticket_id="TST-001", status="todo", risk="low", dependencies=(), collision=()):
    deps = "[" + ", ".join(dependencies) + "]"
    domains = "[" + ", ".join(collision) + "]"
    return textwrap.dedent(f"""\
        ---
        id: {ticket_id}
        status: {status}
        risk: {risk}
        depends_on: {deps}
        collision_domains: {domains}
        ---
        # Goal
        Produce {ticket_id}.
        # Acceptance
        A product file exists.
        # Non-goals
        External state.
        # Context
        Risk is local and the mock owns one file.
        # Validation
        ## Cheap
        Run the trusted static command.
        ## Component
        None.
        ## Expensive
        None.
        """)


class ModeSelectorContractTests(unittest.TestCase):
    """Guard the host instructions; the shell supervisor does not render the native UI. Asserts structure and stable
    tokens, not whole sentences."""

    PROVIDERS = ("codex", "claude", "grok")

    def setUp(self):
        self.procedure = (HARNESS / "RUN-CAMPAIGN.md").read_text()
        self.selection = self.procedure.split("3. If no runner", 1)[1].split("4. Run", 1)[0]

    def test_grok_native_single_select(self):
        self.assertIn("Grok", self.selection)
        self.assertIn("`ask_user_question`", self.selection)
        self.assertIn("single-select", self.selection)
        self.assertIn("`Interactive` and `Unattended`", self.selection)

    def test_codex_native_selector_payload(self):
        self.assertIn("Codex", self.selection)
        self.assertIn("`request_user_input`", self.selection)
        payload = json.loads(self.selection.split("```json\n", 1)[1].split("```", 1)[0])
        self.assertEqual(len(payload["questions"]), 1)
        question = payload["questions"][0]
        self.assertEqual(question["id"], "mode")
        self.assertTrue(question["question"].strip())
        self.assertEqual([option["label"] for option in question["options"]], ["Interactive", "Unattended"])
        for label, mode in (("Interactive", "interactive"), ("Unattended", "unattended")):
            self.assertIn(f"`{label}` → `{mode}`", self.selection)
        self.assertIn("`--mode`", self.selection)

    def test_unavailable_selector_defaults_to_interactive_without_a_question(self):
        self.assertIn("no native selector", self.selection)
        self.assertIn("automatically use `interactive`", self.selection)
        self.assertIn("No native mode selector available", self.selection)

    def test_explicit_modes_skip_the_question(self):
        for mode in ("interactive", "unattended"):
            with self.subTest(mode=mode):
                self.assertIn(f"Explicit `run-campaign {mode}` → use `{mode}` without asking", self.selection)

    def test_no_textual_selector_path(self):
        self.assertIn("Never render a textual mode-selection question", self.selection)
        for legacy in ("present exactly these two choices", "Fallback: textual choice", "1. Interactive", "- Interactive"):
            self.assertNotIn(legacy, self.procedure)

    def test_wrappers_route_explicit_and_missing_modes(self):
        found = 0
        for provider in self.PROVIDERS:
            candidates = (HARNESS.parent / "skills" / provider / "run-campaign" / "SKILL.md",
                          HARNESS.parent / f".{provider}" / "skills" / "run-campaign" / "SKILL.md")
            wrapper = next((path for path in candidates if path.is_file()), None)
            if wrapper is None:
                continue
            found += 1
            with self.subTest(provider=provider):
                text = wrapper.read_text()
                self.assertIn("`interactive` or `unattended`", text)
                self.assertIn("step 3", text)
                self.assertIn("`.agentic/RUN-CAMPAIGN.md`", text)
                self.assertIn("Interactive", text)
                self.assertIn("textual", text)
                if provider == "codex":
                    self.assertIn("`request_user_input`", text)
                elif provider == "grok":
                    self.assertIn("`ask_user_question`", text)
                else:
                    self.assertIn("native structured", text)
        if not found:
            self.skipTest("no run-campaign skill wrapper next to this kit")


class Repo:
    def __init__(self, branch="main", settings=None, commit_kit=True):
        """Commits the clean kit as .agentic (with the settings as project.json, when given); commit_kit=False leaves
        the repository without one and commands run from the kit copy outside it."""
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-test-")
        self.cache = tempfile.TemporaryDirectory(prefix="agentic-cache-")
        self.root = Path(self.temp.name)
        self.branch = branch
        self.installed = commit_kit
        self.env = dict(os.environ, AGENTIC_CACHE=self.cache.name)
        self.env.pop("AGENTIC_DISPLAY_TZ", None)
        self.git("init", "-b", self.branch)
        self.git("config", "user.email", "agentic@example.test")
        self.git("config", "user.name", "Agentic Test")
        (self.root / "README.md").write_text("seed\n")
        self.git("add", "README.md")
        self.git("commit", "-m", "seed")
        if commit_kit:
            self.install_kit(settings)
        (self.root / "SPEC.md").write_text(SPEC)

    def install_kit(self, settings):
        target = self.root / ".agentic"
        shutil.copytree(KIT, target)
        if settings:
            (target / "project.json").write_text(settings if isinstance(settings, str) else json.dumps(settings))
        self.git("add", ".agentic")
        self.git("commit", "-m", "install agentic")

    def close(self):
        # Remove linked worktrees through Git before TemporaryDirectory cleanup.
        subprocess.run(["git", "-C", str(self.root), "worktree", "prune"], stdout=subprocess.DEVNULL)
        self.temp.cleanup()
        self.cache.cleanup()

    def git(self, *args, cwd=None, check=True):
        return subprocess.run(["git", "-C", str(cwd or self.root), *args], text=True,
                              capture_output=True, check=check)

    def command(self, *args, cwd=None, check=True, env=None):
        merged = dict(self.env)
        if env:
            merged.update(env)
        where = Path(cwd or self.root)
        return subprocess.run([str(self.binary(where)), *args], cwd=where, env=merged,
                              text=True, capture_output=True, check=check)

    def binary(self, where=None):
        return Path(where or self.root) / ".agentic" / "bin" / "campaign" if self.installed else CAMPAIGN

    def init_campaign(self):
        result = self.command("init", "SPEC.md")
        line = next(line for line in result.stdout.splitlines() if line.startswith("Worktree: "))
        self.worktree = Path(line.removeprefix("Worktree: "))
        self.slug = "harness-sample"
        return result

    def configure(self, tickets):
        base = self.worktree / "campaigns" / self.slug
        directory = base / "tickets"
        directory.mkdir(parents=True, exist_ok=True)
        for value in tickets:
            ticket_id = value.split("id: ", 1)[1].splitlines()[0]
            (directory / f"{ticket_id}.md").write_text(value)
        plan = {
            "version": 1,
            "tickets": {
                value.split("id: ", 1)[1].splitlines()[0]: {
                    "cheap": [["git", "diff", "--check", "HEAD"]],
                    "component": [], "expensive": []
                } for value in tickets
            },
            "final": [["git", "diff", "--check", "HEAD"]],
        }
        (base / "validation.json").write_text(json.dumps(plan))
        self.git("add", ".", cwd=self.worktree)
        self.git("commit", "-m", "tickets", cwd=self.worktree)

    def mock_provider(self, reviewer="PASS", worker="PASS", diagnosis="PASS"):
        root = Path(self.cache.name) / "mock-providers" / "mock"
        root.mkdir(parents=True)
        script = root / "run.sh"
        script.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            set -eu
            if [ "${1:-}" = --preflight ]; then
              [ "$#" -eq 2 ] && { [ "$2" = interactive ] || [ "$2" = unattended ]; }
              exit
            fi
            role=$1 worktree=$2 prompt=$3 result=$4 events=$5
            ticket=$(basename "$result" | cut -d- -f1-2)
            status=PASS
            if [ "$role" = reviewer ]; then status=${MOCK_REVIEWER:-PASS}; fi
            if [ "$role" = worker ] && echo "$result" | grep -q -- '-worker.json$'; then status=${MOCK_WORKER:-PASS}; fi
            if [ "$role" = worker ] && [ "${MOCK_FAIL_TICKET:-}" = "$ticket" ] && echo "$result" | grep -q -- '-worker.json$'; then status=FAILED; fi
            if [ "$role" = diagnostician ]; then status=${MOCK_DIAGNOSIS:-PASS}; fi
            if [ "$role" = worker ] && [ -n "${MOCK_BLOCK_ONCE:-}" ] && echo "$result" | grep -q -- '-worker.json$'; then
              mkdir -p "$MOCK_BLOCK_ONCE"
              if [ ! -f "$MOCK_BLOCK_ONCE/$ticket" ]; then touch "$MOCK_BLOCK_ONCE/$ticket"; status=BLOCKED; fi
            fi
            if [ "$role" = worker ] && [ "$status" = PASS ] && [ -n "${MOCK_SHARED_FILE:-}" ] && echo "$result" | grep -q -- '-worker.json$'; then
              printf '%s\n' "$ticket" >> "$worktree/$MOCK_SHARED_FILE"
            fi
            if [ "$role" = worker ] && [ "$status" = PASS ] && [ -n "${MOCK_APPEND_FILE:-}" ] && echo "$result" | grep -q -- '-worker.json$'; then
              mkdir -p "$(dirname "$worktree/$MOCK_APPEND_FILE")"; printf "$MOCK_APPEND_TEXT" >> "$worktree/$MOCK_APPEND_FILE"
            fi
            if [ "$role" = worker ] && [ "$status" = PASS ] && [ -n "${MOCK_DELETE_FILE:-}" ] && echo "$result" | grep -q -- '-worker.json$'; then
              rm -f "$worktree/$MOCK_DELETE_FILE"
            fi
            if [ "$role" = worker ] && [ -n "${MOCK_SEEN_DIR:-}" ]; then
              mkdir -p "$MOCK_SEEN_DIR"; ls -1 "$worktree" > "$MOCK_SEEN_DIR/$(basename "$result")"
            fi
            if [ "$role" = worker ] && [ "$status" = PASS ] && [ "${MOCK_POISON_TICKET:-}" = "$ticket" ]; then
              touch "$worktree/poison"
            fi
            if [ "$role" = worker ] && echo "$result" | grep -q -- '-integration-repair.json$' && [ -n "${MOCK_SHARED_FILE:-}" ]; then
              sed -i -E '/^(<<<<<<<|=======|>>>>>>>)/d' "$worktree/$MOCK_SHARED_FILE"
            fi
            if [ "$role" = worker ] && [ "$status" = PASS ]; then
              if [ -n "${MOCK_TRACK_DIR:-}" ]; then
                mkdir -p "$MOCK_TRACK_DIR"; exec 9>"$MOCK_TRACK_DIR/lock"; flock -x 9
                active=$(cat "$MOCK_TRACK_DIR/active" 2>/dev/null || printf 0); active=$((active+1)); printf '%s' "$active" > "$MOCK_TRACK_DIR/active"
                maximum=$(cat "$MOCK_TRACK_DIR/max" 2>/dev/null || printf 0); [ "$active" -le "$maximum" ] || printf '%s' "$active" > "$MOCK_TRACK_DIR/max"
                flock -u 9; sleep "${MOCK_SLEEP:-0}"; flock -x 9
                active=$(cat "$MOCK_TRACK_DIR/active"); printf '%s' "$((active-1))" > "$MOCK_TRACK_DIR/active"; flock -u 9
              fi
              printf '%s\n' "$ticket" > "$worktree/product-$ticket.txt"
            fi
            if [ "$role" = worker ] && [ -n "${MOCK_REPAIR_FILE:-}" ] && echo "$result" | grep -q -- '-repair.json$'; then
              touch "$worktree/$MOCK_REPAIR_FILE"
            fi
            if [ "$role" = worker ] && [ -n "${MOCK_RENAME_FROM:-}" ] && echo "$result" | grep -q -- '-worker.json$'; then
              git -C "$worktree" mv "$MOCK_RENAME_FROM" "$MOCK_RENAME_TO"
            fi
            if [ "$role" = worker ] && [ "${MOCK_EXIT_FAIL:-}" = 1 ]; then exit 1; fi
            findings='[]'; [ "$status" = FIX ] && findings='[{"severity":"major","path":null,"line":null,"message":"fix"}]'
            if [ "$role" = reviewer ] && [ "${MOCK_CONCRETE_FIX:-}" = 1 ] && [ ! -f "$worktree/review-fixed" ]; then
              status=FIX; findings='[{"severity":"major","path":"review-fixed","line":1,"message":"Required output review-fixed is missing.","reason":"Acceptance requires the ticket output file.","fix":"Create review-fixed next to the product file and check that it exists."}]'
            fi
            blocker=null; human_decision=null
            if [ "$role" = worker ] && [ "$status" = BLOCKED ]; then
              blocker='"mock blocker"'
              if [ -n "${MOCK_HUMAN_CATEGORY:-}" ]; then
                human_decision=$(jq -cn --arg category "$MOCK_HUMAN_CATEGORY" '{category:$category,question:"human input required"}')
              fi
            fi
            root_cause=null; evidence='[]'; reproduction=null; fix=null
            if [ "$role" = diagnostician ] && [ "$status" = PASS ]; then
              root_cause='"mock cause"'; evidence='["mock evidence"]'; reproduction='{"command":"git diff --check HEAD","outcome":"failed before repair"}'; fix='"mock fix"'
            fi
            jq -n --arg role "$role" --arg status "$status" --argjson blocker "$blocker" --argjson human "$human_decision" --argjson findings "$findings" --argjson root "$root_cause" --argjson evidence "$evidence" --argjson repro "$reproduction" --argjson fix "$fix" '{schema_version:"1.0",role:$role,status:$status,summary:"mock",changed_files:[],validation_evidence:[],needs_diagnosis:false,blocker:$blocker,human_decision:$human,findings:$findings,root_cause:$root,evidence:$evidence,cheap_reproduction:$repro,affected_phases:(if $role=="diagnostician" then ["cheap"] else [] end),recommended_fix:$fix}' > "$result"
            jq -n --arg role "$role" '{provider:"mock",role:$role,state:"complete"}' >> "$events"
        """))
        script.chmod(0o755)
        self.env["AGENTIC_PROVIDER_DIR"] = str(Path(self.cache.name) / "mock-providers")
        self.env["MOCK_REVIEWER"] = reviewer
        self.env["MOCK_WORKER"] = worker
        self.env["MOCK_DIAGNOSIS"] = diagnosis


class CampaignTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()

    def tearDown(self):
        self.repo.close()

    def test_01_campaign_init(self):
        result = self.repo.init_campaign()
        self.assertIn("Campaign initialized", result.stdout)
        self.assertTrue((self.repo.worktree / "campaigns/harness-sample/SPEC.md").is_file())

    def test_02_current_campaign_detection(self):
        self.repo.init_campaign()
        self.assertEqual(self.repo.command("current", cwd=self.repo.worktree).stdout.strip(), "harness-sample")

    def test_03_current_refuses_main(self):
        result = self.repo.command("current", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_04_dependency_ready_calculation(self):
        self.repo.init_campaign(); self.repo.configure([ticket(), ticket("TST-002", dependencies=("TST-001",))])
        ready = json.loads(self.repo.command("ready", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual([item["id"] for item in ready], ["TST-001"])

    def test_04b_ready_starts_critical_path_first(self):
        self.repo.init_campaign(); self.repo.configure([
            ticket(), ticket("TST-002"), ticket("TST-003", dependencies=("TST-002",)),
            ticket("TST-004", dependencies=("TST-003",))])
        ready = json.loads(self.repo.command("ready", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual([item["id"] for item in ready], ["TST-002", "TST-001"])

    def test_05_done_dependency_unlocks_ticket(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done"), ticket("TST-002", dependencies=("TST-001",))])
        ready = json.loads(self.repo.command("ready", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual([item["id"] for item in ready], ["TST-002"])

    def test_06_invalid_dependency(self):
        self.repo.init_campaign(); self.repo.configure([ticket(dependencies=("TST-999",))])
        self.assertNotEqual(self.repo.command("verify", cwd=self.repo.worktree, check=False).returncode, 0)

    def test_07_dependency_cycle(self):
        self.repo.init_campaign(); self.repo.configure([ticket(dependencies=("TST-002",)), ticket("TST-002", dependencies=("TST-001",))])
        self.assertNotEqual(self.repo.command("verify", cwd=self.repo.worktree, check=False).returncode, 0)

    def test_08_duplicate_frontmatter_key(self):
        path = self.repo.root / "ticket.md"; path.write_text(ticket().replace("status: todo", "status: todo\nstatus: done"))
        result = subprocess.run(["python3", str(TICKETS), "get", str(self.repo.root), "TST-001"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_09_invalid_status(self):
        path = self.repo.root / "ticket.md"; path.write_text(ticket(status="READY"))
        result = subprocess.run(["python3", str(TICKETS), "list", str(self.repo.root)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_10_invalid_risk(self):
        path = self.repo.root / "ticket.md"; path.write_text(ticket(risk="extreme"))
        result = subprocess.run(["python3", str(TICKETS), "list", str(self.repo.root)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_11_parallel_limit_rejects_four(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        result = self.repo.command("run", "--provider", "mock", "--workers", "4", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_12_provider_contract_missing_adapter(self):
        self.repo.init_campaign(); self.repo.configure([ticket()])
        result = self.repo.command("run", "--provider", "missing", cwd=self.repo.worktree, check=False)
        self.assertIn("provider unavailable", result.stderr)

    def test_13_reviewer_pass_integrates_and_cleans(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "done")
        self.assertFalse(any("agentic/harness-sample" in item.stdout for item in [self.repo.git("branch", "--list")]))

    def test_14_incomplete_reviewer_is_provider_failure(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider(reviewer="FIX")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "todo")
        self.assertEqual(state["decisions"], [])
        prompt = next(Path(self.repo.cache.name).rglob('TST-001-review.md')).read_text()
        self.assertIn('failed the provider contract (invalid provider result: finding has invalid fields)', prompt)


    def test_15_worker_failure_does_not_require_diagnostician(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider(worker="FAILED")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        events = next(Path(self.repo.cache.name).rglob("TST-001.ndjson")).read_text()
        self.assertNotIn('"role": "diagnostician"', events)


    def test_16_blocked_ticket_does_not_hide_independent_ready(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="blocked"), ticket("TST-002")])
        ready = json.loads(self.repo.command("ready", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual([item["id"] for item in ready], ["TST-002"])

    def test_17_decision_request_and_block(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="needs-human")])
        runtime = next(Path(self.repo.cache.name).glob("*/*")); (runtime / "decisions").mkdir(exist_ok=True)
        (runtime / "decisions/TST-001.json").write_text(json.dumps({"ticket":"TST-001","reason":"test","options":["retry","block","cancel"]}))
        self.repo.command("decide", "TST-001", "block", cwd=self.repo.worktree)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "blocked")

    def test_18_finalization_gate_rejects_todo(self):
        self.repo.init_campaign(); self.repo.configure([ticket()])
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_19_cleanup_refuses_noncompleted_ticket(self):
        self.repo.init_campaign(); self.repo.configure([ticket()])
        result = self.repo.command("cleanup", "--ticket", "TST-001", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_20_namespace_cleanup_preserves_foreign_branch(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        self.repo.git("branch", "foreign/keep", cwd=self.repo.worktree)
        self.repo.command("cleanup", cwd=self.repo.worktree)
        self.assertIn("foreign/keep", self.repo.git("branch", "--list", "foreign/keep", cwd=self.repo.worktree).stdout)

    def test_21_finalize_rebases_ff_and_removes_campaign_state(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        run = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.repo.root / "campaigns/harness-sample").exists())
        self.assertEqual(self.repo.git("branch", "--show-current").stdout.strip(), "main")
        self.assertNotIn("campaign/harness-sample", self.repo.git("branch", "--list").stdout)
        self.assertTrue((self.repo.root / "product-TST-001.txt").is_file())

    def test_finalize_drains_large_worktree_inventory(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        wrappers = Path(self.repo.cache.name) / "wrappers"
        wrappers.mkdir()
        wrapper = wrappers / "git"
        wrapper.write_text("#!/usr/bin/env python3\nimport os,subprocess,sys\n"
            + "real=" + repr(shutil.which("git")) + "\n"
            + "args=sys.argv[1:]\n"
            + "if args[-3:]==['worktree','list','--porcelain']:\n"
            + " data=subprocess.check_output([real,*args])\n"
            + " sys.stdout.buffer.write(data)\n"
            + " sys.stdout.buffer.write(b'\\n' * 1048576)\n"
            + " sys.stdout.buffer.flush()\n"
            + "else: os.execv(real,[real,*args])\n")
        wrapper.chmod(0o755)
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False,
            env={"PATH": str(wrappers) + os.pathsep + os.environ["PATH"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.repo.worktree.exists())
        self.assertNotIn("campaign/harness-sample", self.repo.git("branch", "--list").stdout)

    def test_finalize_runs_the_final_validation_once(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        counter = Path(self.repo.cache.name) / "final-runs"
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text()); plan["final"] = [["sh", "-c", f"echo run >> {counter}"]]
        plan_path.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "count final", cwd=self.repo.worktree)
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counter.read_text().splitlines(), ["run"])

    def test_finalize_rebases_again_when_main_moves_during_final_validation(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        marker = Path(self.repo.cache.name) / "main-moved"
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text())
        plan["final"] = [["sh", "-c", f"[ -f {marker} ] || {{ touch {marker}; git -C {self.repo.root} commit -q --allow-empty -m moved; }}"]]
        plan_path.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "move main", cwd=self.repo.worktree)
        first = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(first.returncode, 0)
        self.assertIn("main moved during finalize", first.stderr)
        second = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("moved", self.repo.git("log", "--format=%s", "main").stdout.splitlines())
        self.assertNotIn("campaign/harness-sample", self.repo.git("branch", "--list").stdout)

    def final_validation_that_moves_main_once(self, conflict=False):
        """The final validation counts its runs and, on the first, lands a commit on main (one that conflicts with
        the campaign's product.txt when asked). Returns the file that holds one line per run."""
        root, cache = self.repo.root, Path(self.repo.cache.name)
        counter, marker = cache / "final-runs", cache / "main-moved"
        land = (f"printf 'main\\n' > {root}/product.txt && git -C {root} add product.txt && git -C {root} commit -q -m moved"
                if conflict else f"git -C {root} commit -q --allow-empty -m moved")
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text())
        plan["final"] = [["sh", "-c", f"echo run >> {counter}; [ -f {marker} ] || {{ touch {marker}; {land}; }}"]]
        plan_path.write_text(json.dumps(plan))
        if conflict:
            (self.repo.worktree / "product.txt").write_text("campaign\n")
        self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "move main", cwd=self.repo.worktree)
        return counter

    def test_finalize_validates_again_after_a_manual_rebase_of_a_conflicting_finalize(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        counter = self.final_validation_that_moves_main_once(conflict=True)
        first = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertIn("main moved during finalize", first.stderr)
        second = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertIn("conflicted", second.stderr)
        # The coordinator rebases by hand, as the error says: main is an ancestor again, but the tree is new.
        self.assertNotEqual(self.repo.git("rebase", "main", cwd=self.repo.worktree, check=False).returncode, 0)
        (self.repo.worktree / "product.txt").write_text("resolved\n")
        self.repo.git("add", "product.txt", cwd=self.repo.worktree)
        self.repo.git("-c", "core.editor=true", "rebase", "--continue", cwd=self.repo.worktree)
        third = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertEqual(counter.read_text().splitlines(), ["run", "run"])
        self.assertEqual((self.repo.root / "product.txt").read_text(), "resolved\n")

    def test_finalize_cleans_a_campaign_main_already_integrated(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.repo.git("merge", "--ff-only", "campaign/harness-sample")
        self.repo.git("rm", "-r", "-q", "campaigns/harness-sample"); self.repo.git("commit", "-m", "integrated by hand")
        main_tip = self.repo.git("rev-parse", "main").stdout.strip()
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.git("rev-parse", "main").stdout.strip(), main_tip)
        self.assertFalse(self.repo.worktree.exists())
        self.assertNotIn("campaign/harness-sample", self.repo.git("branch", "--list").stdout)

    def test_22_finalize_refuses_dirty_main_before_cleanup(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.worktree / "product.txt").write_text("campaign\n")
        self.repo.git("add", "product.txt", cwd=self.repo.worktree); self.repo.git("commit", "-m", "product", cwd=self.repo.worktree)
        (self.repo.root / "product.txt").write_text("preserve\n")
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("product.txt", result.stderr)
        self.assertTrue((self.repo.worktree / "campaigns/harness-sample/SPEC.md").exists())
        self.assertEqual((self.repo.root / "product.txt").read_text(), "preserve\n")

    def test_finalize_leaves_unrelated_dirty_main_changes_untouched(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        (self.repo.root / "other-session").mkdir()
        (self.repo.root / "other-session" / "notes.txt").write_text("keep\n")
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.repo.worktree.exists())
        self.assertEqual((self.repo.root / "other-session" / "notes.txt").read_text(), "keep\n")

    def test_23_init_keeps_dirty_main_changes(self):
        (self.repo.root / "unrelated.txt").write_text("keep\n")
        self.repo.init_campaign()
        self.assertTrue((self.repo.root / "unrelated.txt").exists())
        self.assertEqual(self.repo.git("branch", "--show-current").stdout.strip(), "main")

    def test_24_unattended_runner_is_detached_and_observable(self):
        self.repo.init_campaign(); self.repo.configure([ticket(collision=("one",))]); self.repo.mock_provider()
        self.repo.env["MOCK_SLEEP"] = "1"
        result = self.repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=self.repo.worktree)
        self.assertIn("started detached", result.stdout)
        active_seen = False
        for _ in range(30):
            state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
            active_seen = active_seen or state["runner"]["active"]
            if not state["runner"]["active"]:
                break
            time.sleep(0.1)
        self.assertTrue(active_seen)
        config = next(Path(self.repo.cache.name).rglob("run-config.json"))
        self.assertEqual(json.loads(config.read_text())["mode"], "unattended")

    def test_25_default_parallelism_reaches_two_and_never_three(self):
        values = [ticket(f"TST-00{i}", collision=(f"domain-{i}",)) for i in range(1, 4)]
        self.repo.init_campaign(); self.repo.configure(values); self.repo.mock_provider()
        track = Path(self.repo.cache.name) / "track-parallel"; self.repo.env.update(MOCK_TRACK_DIR=str(track), MOCK_SLEEP="0.2")
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((track / "max").read_text(), "2")

    def test_26_collision_domain_serializes_workers(self):
        values = [ticket(f"TST-00{i}", collision=("shared",)) for i in range(1, 3)]
        self.repo.init_campaign(); self.repo.configure(values); self.repo.mock_provider()
        track = Path(self.repo.cache.name) / "track-collision"; self.repo.env.update(MOCK_TRACK_DIR=str(track), MOCK_SLEEP="0.1")
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((track / "max").read_text(), "1")

    def test_27_blocked_ticket_does_not_stop_independent_worker(self):
        values = [ticket("TST-001", collision=("a",)), ticket("TST-002", collision=("b",))]
        self.repo.init_campaign(); self.repo.configure(values); self.repo.mock_provider(diagnosis="FAILED")
        self.repo.env["MOCK_FAIL_TICKET"] = "TST-001"
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        states = {item["id"]: item["status"] for item in json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)["tickets"]}
        self.assertEqual(states, {"TST-001": "done", "TST-002": "done"})


    def test_28_rerun_completed_campaign_does_not_run_final_proof(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        for _ in range(2):
            result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
        final = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(final.returncode, 0, final.stderr)

    def test_29_interactive_uses_detached_supervisor_without_operational_decisions(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        result = self.repo.command("run", "--provider", "mock", "--mode", "interactive", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = next(Path(self.repo.cache.name).rglob("run-config.json"))
        runtime = config.parent
        self.assertEqual(json.loads(config.read_text())["mode"], "interactive")
        self.assertEqual(list((runtime / "decisions").glob("*.json")), [])

    def test_30_provider_preflight_fails_before_ticket_worktree_is_created(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        adapter = Path(self.repo.env["AGENTIC_PROVIDER_DIR"]) / "mock" / "run.sh"
        adapter.write_text("#!/usr/bin/env bash\n[ \"${1:-}\" != --preflight ]\n")
        adapter.chmod(0o755)
        result = self.repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preflight failed", result.stderr)
        self.assertNotIn("agentic/harness-sample/TST-001", self.repo.git("branch", "--list").stdout)

    def test_31_real_human_gate_is_categorized(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider(worker="BLOCKED")
        self.repo.env["MOCK_HUMAN_CATEGORY"] = "product-ambiguity"
        result = self.repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        for _ in range(50):
            state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
            if not state["runner"]["active"]:
                break
            time.sleep(0.1)
        self.assertEqual(state["tickets"][0]["status"], "needs-human")
        self.assertEqual(state["decisions"][0]["category"], "product-ambiguity")

    def test_32_technical_block_does_not_manufacture_human_decision(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider(worker="BLOCKED")
        result = self.repo.command("run", "--provider", "mock", "--mode", "interactive", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "blocked")
        self.assertEqual(state["decisions"], [])

    def test_34_recovery_preserves_dirty_delta_without_checkpoint(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="blocked")]); self.repo.mock_provider()
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        worktree = runtime / "worktrees/TST-001"
        self.repo.git("worktree", "add", "-b", f"agentic/{self.repo.slug}/TST-001", str(worktree), f"campaign/{self.repo.slug}")
        (runtime / "state/TST-001.base").write_text("invalid historical hash")
        (runtime / "state/TST-001.diagnosis-required").write_text("stale")
        (worktree / "product.txt").write_text("preserved repair\n")
        self.repo.command("recover", "TST-001", cwd=self.repo.worktree)
        self.assertEqual((worktree / "product.txt").read_text(), "preserved repair\n")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertEqual((self.repo.worktree / "product.txt").read_text(), "preserved repair\n")
        events = (runtime / "events/TST-001.ndjson").read_text()
        self.assertIn('"role": "reviewer"', events)
        self.assertNotIn('"role": "worker"', events)
        self.assertNotIn('"role": "diagnostician"', events)


    def test_33_no_campaign_wide_proof_by_default(self):
        self.repo.init_campaign(); self.repo.configure([ticket(risk="high")]); self.repo.mock_provider()
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text()); plan["final"] = [["false"]]
        plan_path.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "explicit final", cwd=self.repo.worktree)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "done")
        self.assertFalse(list(Path(self.repo.cache.name).rglob("campaign.final.json")))
    def test_33_existing_product_delta_skips_worker_reimplementation(self):
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        self.repo.mock_provider(worker="FAILED")
        runtime = next(Path(self.repo.cache.name).rglob("campaign.json")).parent
        worktree = runtime / "worktrees" / "TST-001"
        branch = "agentic/harness-sample/TST-001"
        self.repo.git("worktree", "add", "-b", branch, str(worktree), "campaign/harness-sample", cwd=self.repo.worktree)
        (worktree / "product-TST-001.txt").write_text("recovered\n")
        self.repo.git("add", "product-TST-001.txt", cwd=worktree)
        self.repo.git("commit", "-m", "feat(agentic): complete TST-001", cwd=worktree)
        (runtime / "state").mkdir(exist_ok=True)
        campaign_head = self.repo.git("rev-parse", "campaign/harness-sample", cwd=self.repo.worktree).stdout.strip()
        (runtime / "state" / "TST-001.base").write_text(campaign_head + "\n")
        (runtime / "state" / "TST-001.retry").write_text("now\n")
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo.worktree / "product-TST-001.txt").is_file())
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)


    def test_35_known_expensive_failure_gets_focused_repair(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text())
        plan["tickets"]["TST-001"]["expensive"] = [["test", "-f", "repaired-input"]]
        plan_path.write_text(json.dumps(plan))
        self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "specific proof", cwd=self.repo.worktree)
        self.repo.env["MOCK_REPAIR_FILE"] = "repaired-input"
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertTrue((self.repo.worktree / "repaired-input").exists())
        events = next(Path(self.repo.cache.name).rglob("TST-001.ndjson")).read_text()
        self.assertNotIn('"role": "diagnostician"', events)
        self.assertFalse(list(Path(self.repo.cache.name).rglob("*.expensive-attempts.json")))

    def test_36_new_worker_and_reviewer_per_ticket(self):
        self.repo.init_campaign(); self.repo.configure([ticket(), ticket("TST-002", dependencies=("TST-001",))]); self.repo.mock_provider()
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        for identifier in ('TST-001', 'TST-002'):
            events = next(Path(self.repo.cache.name).rglob(identifier + '.ndjson')).read_text()
            self.assertEqual(events.count('"role": "worker"'), 1)
            self.assertEqual(events.count('"role": "reviewer"'), 1)

    def test_37_concrete_review_finding_gets_repair_and_fresh_recheck(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        self.repo.env.update(MOCK_CONCRETE_FIX="1", MOCK_REPAIR_FILE="review-fixed")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertTrue((self.repo.worktree / 'review-fixed').exists())
        events = next(Path(self.repo.cache.name).rglob('TST-001.ndjson')).read_text()
        self.assertEqual(events.count('"role": "reviewer"'), 2)
        self.assertNotIn('"role": "diagnostician"', events)
        prompts = next(Path(self.repo.cache.name).rglob('TST-001-review-repair.md')).parent
        repair = (prompts / 'TST-001-review-repair.md').read_text()
        self.assertIn('Why: Acceptance requires the ticket output file.', repair)
        self.assertIn('How to fix: Create review-fixed next to the product file', repair)
        self.assertIn('Your previous findings:', (prompts / 'TST-001-review.md').read_text())

    def test_38_empty_recovery_worktree_still_gets_worker(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        worktree = runtime / "worktrees/TST-001"
        self.repo.git("worktree", "add", "-b", f"agentic/{self.repo.slug}/TST-001", str(worktree), f"campaign/{self.repo.slug}")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertTrue((self.repo.worktree / 'product-TST-001.txt').exists())


    def events(self, name="campaign.ndjson"):
        path = next(Path(self.repo.cache.name).rglob(name), None)
        return [json.loads(line) for line in path.read_text().splitlines()] if path else []

    def test_39_integration_conflict_is_resolved_automatically(self):
        (self.repo.root / "shared.txt").write_text("base\n")
        self.repo.git("add", "shared.txt"); self.repo.git("commit", "-m", "shared")
        values = [ticket("TST-001", collision=("a",)), ticket("TST-002", collision=("b",))]
        self.repo.init_campaign(); self.repo.configure(values); self.repo.mock_provider()
        self.repo.env.update(MOCK_SHARED_FILE="shared.txt", MOCK_SLEEP="0.5", MOCK_TRACK_DIR=str(Path(self.repo.cache.name) / "track-conflict"))
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        states = {item["id"]: item["status"] for item in json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)["tickets"]}
        self.assertEqual(states, {"TST-001": "done", "TST-002": "done"})
        shared = (self.repo.worktree / "shared.txt").read_text()
        self.assertIn("TST-001", shared); self.assertIn("TST-002", shared)
        self.assertNotRegex(shared, r"(?m)^(<<<<<<<|=======|>>>>>>>)")
        self.assertIn("integration-conflict", [event["type"] for event in self.events()])

    def test_40_blocked_worker_recovers_automatically_with_diagnosis(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        self.repo.env["MOCK_BLOCK_ONCE"] = str(Path(self.repo.cache.name) / "block-once")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "done")
        types = [event["type"] for event in self.events()]
        self.assertIn("ticket-blocked", types); self.assertIn("recovery-scheduled", types)
        self.assertFalse(list(Path(self.repo.cache.name).rglob("diagnosis/TST-001.md")))

    def test_41_auto_recovery_is_bounded_and_keeps_the_reason(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider(worker="BLOCKED")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "blocked")
        events = self.events()
        self.assertEqual([event["type"] for event in events].count("recovery-scheduled"), 2)
        self.assertIn("mock blocker", [event for event in events if event["type"] == "ticket-blocked"][-1]["message"])

    def test_42_human_decision_is_never_recovered_automatically(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider(worker="BLOCKED")
        self.repo.env["MOCK_HUMAN_CATEGORY"] = "product-ambiguity"
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        types = [event["type"] for event in self.events()]
        self.assertIn("ticket-needs-human", types); self.assertNotIn("recovery-scheduled", types)

    def test_43_recovery_with_diagnosis_starts_with_a_worker(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        worktree = runtime / "worktrees/TST-001"
        self.repo.git("worktree", "add", "-b", f"agentic/{self.repo.slug}/TST-001", str(worktree), f"campaign/{self.repo.slug}")
        (worktree / "partial.txt").write_text("partial\n")
        (runtime / "diagnosis").mkdir(exist_ok=True)
        (runtime / "diagnosis/TST-001.md").write_text("Finish the partial output.\n")
        (runtime / "state/TST-001.retry").write_text("coordinator\n")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertTrue(list(runtime.rglob("results/TST-001-recovery.json")))
        self.assertTrue((self.repo.worktree / "partial.txt").exists())

    def _ticket_worktree(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        worktree = runtime / "worktrees/TST-001"
        self.repo.git("worktree", "add", "-b", f"agentic/{self.repo.slug}/TST-001", str(worktree), f"campaign/{self.repo.slug}")
        return runtime, worktree

    def test_43b_uncommitted_delta_means_the_worker_never_finished(self):
        runtime, worktree = self._ticket_worktree()
        (worktree / "partial.txt").write_text("cut off by a usage limit\n")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        types = [event["type"] for event in self.events()]
        self.assertIn("worker-interrupted", types)
        self.assertTrue(list(runtime.rglob("results/TST-001-recovery.json")))
        prompt = next(runtime.rglob("prompts/TST-001-recovery.md")).read_text()
        self.assertIn("stopped before it finished", prompt)
        self.assertIn("compare it with the ticket's Acceptance", prompt)
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "done")
        self.assertTrue((self.repo.worktree / "partial.txt").exists())

    def test_43c_committed_delta_goes_straight_to_validation(self):
        runtime, worktree = self._ticket_worktree()
        (worktree / "product-TST-001.txt").write_text("finished\n")
        self.repo.git("add", "product-TST-001.txt", cwd=worktree)
        self.repo.git("commit", "-m", "feat(agentic): complete TST-001", cwd=worktree)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertNotIn("worker-interrupted", [event["type"] for event in self.events()])
        self.assertFalse(list(runtime.rglob("results/TST-001-recovery.json")))
        self.assertFalse(list(runtime.rglob("results/TST-001-worker.json")))
        state = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(state["tickets"][0]["status"], "done")

    def test_44_review_repair_is_validated_again(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        counter = Path(self.repo.cache.name) / "cheap-runs"
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text()); plan["tickets"]["TST-001"]["cheap"] = [["bash", "-c", f"echo run >> {counter}"]]
        plan_path.write_text(json.dumps(plan)); self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "count", cwd=self.repo.worktree)
        self.repo.env.update(MOCK_CONCRETE_FIX="1", MOCK_REPAIR_FILE="review-fixed")
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        self.assertGreaterEqual(len(counter.read_text().splitlines()), 2)

    def test_45_red_base_is_reported_not_repaired(self):
        self.repo.init_campaign()
        self.repo.configure([ticket("TST-001", collision=("a",)), ticket("TST-002", dependencies=("TST-001",), collision=("b",))])
        self.repo.mock_provider(); self.repo.env["MOCK_POISON_TICKET"] = "TST-001"
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        guard = ["test", "!", "-e", "poison"]
        plan = json.loads(plan_path.read_text()); plan["baseline"] = [guard]; plan["tickets"]["TST-002"]["cheap"] = [guard]
        plan_path.write_text(json.dumps(plan)); self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "baseline", cwd=self.repo.worktree)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        states = {item["id"]: item["status"] for item in json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)["tickets"]}
        self.assertEqual(states, {"TST-001": "done", "TST-002": "blocked"})
        events = self.events()
        self.assertIn("base-red", [event["type"] for event in events])
        self.assertNotIn("recovery-scheduled", [event["type"] for event in events if event.get("ticket") == "TST-002"])

    def test_46_rebase_invariant_detects_a_dropped_change(self):
        root = self.repo.root
        (root / "f.txt").write_text("a\n"); self.repo.git("add", "f.txt"); self.repo.git("commit", "-m", "base")
        base = self.repo.git("rev-parse", "HEAD").stdout.strip()
        self.repo.git("checkout", "-b", "ticket"); (root / "f.txt").write_text("ticket\n"); self.repo.git("commit", "-am", "ticket")
        tip = self.repo.git("rev-parse", "HEAD").stdout.strip()
        self.repo.git("checkout", "main"); (root / "f.txt").write_text("upstream\n"); self.repo.git("commit", "-am", "upstream")
        upstream = self.repo.git("rev-parse", "HEAD").stdout.strip()
        lost = self.repo.command("_verify-rebase", str(root), tip, base, upstream, check=False)
        self.assertNotEqual(lost.returncode, 0); self.assertIn("f.txt", lost.stdout)
        self.repo.git("checkout", "ticket")
        kept = self.repo.command("_verify-rebase", str(root), tip, base, upstream, check=False)
        self.assertEqual(kept.returncode, 0, kept.stdout)

    def test_47_runner_git_never_replays_recorded_resolutions(self):
        result = subprocess.run(["bash", "-c", f"source {KIT / 'lib/common.sh'} && git config --get rerere.enabled"],
                                cwd=self.repo.root, text=True, capture_output=True, env=self.repo.env)
        self.assertEqual(result.stdout.strip(), "false")


    def test_48_red_baseline_refuses_to_start(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        plan_path = self.repo.worktree / "campaigns" / self.repo.slug / "validation.json"
        plan = json.loads(plan_path.read_text()); plan["baseline"] = [["false"]]
        plan_path.write_text(json.dumps(plan)); self.repo.git("add", ".", cwd=self.repo.worktree); self.repo.git("commit", "-m", "red", cwd=self.repo.worktree)
        result = self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("campaign base is red", result.stderr)
        self.assertNotIn("agentic/harness-sample/TST-001", self.repo.git("branch", "--list").stdout)

    def test_49_engine_runs_from_an_agentic_snapshot(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        runtime = next(Path(self.repo.cache.name).glob("*/*/campaign.json")).parent
        self.assertTrue((runtime / "agentic/bin/campaign").is_file())
        self.assertTrue((runtime / "agentic/roles/worker.md").is_file())

    def test_50_finalize_archives_the_campaign_history(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("history archived", result.stdout)
        self.assertTrue(list(Path(self.repo.cache.name).rglob("archive/*/events/campaign.ndjson")))

    def test_51_finalize_conflict_aborts_and_keeps_the_campaign(self):
        self.repo.init_campaign(); self.repo.configure([ticket()]); self.repo.mock_provider()
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        (self.repo.root / "product-TST-001.txt").write_text("main owns this\n")
        self.repo.git("add", "product-TST-001.txt"); self.repo.git("commit", "-m", "competing change")
        result = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicted", result.stderr)
        self.assertNotIn("rebase in progress", self.repo.git("status", cwd=self.repo.worktree).stdout)
        self.assertIn("campaign/harness-sample", self.repo.git("branch", "--list").stdout)

    def write_queue(self, *slugs):
        definitions = Path(self.repo.cache.name) / "queue-input"
        campaigns = []
        for number, slug in enumerate(slugs, 1):
            ticket_id = f"TST-{number:03d}"
            folder = definitions / slug
            (folder / "tickets").mkdir(parents=True)
            (folder / "SPEC.md").write_text(SPEC)
            (folder / "tickets" / f"{ticket_id}.md").write_text(ticket(ticket_id))
            (folder / "validation.json").write_text(json.dumps({
                "version": 1, "final": [["git", "diff", "--check", "HEAD"]],
                "tickets": {ticket_id: {"cheap": [["git", "diff", "--check", "HEAD"]], "component": [], "expensive": []}}}))
            campaigns.append({"slug": slug, "spec": f"{slug}/SPEC.md", "tickets": f"{slug}/tickets",
                              "validation": f"{slug}/validation.json"})
        queue = definitions / "queue.json"
        queue.write_text(json.dumps({"name": "nightly", "provider": "mock", "workers": 1, "campaigns": campaigns}))
        return queue

    def run_queue(self, queue):
        env = dict(self.repo.env, AGENTIC_QUEUE_POLL_SECONDS="0.2", AGENTIC_QUEUE_RELAUNCH_SECONDS="0.2")
        return subprocess.run([str(self.repo.binary()), "queue", "start", str(queue), "--foreground"], cwd=self.repo.root,
                              env=env, text=True, capture_output=True, timeout=180)

    def test_52_queue_runs_campaigns_in_sequence_and_finalizes_them(self):
        self.repo.mock_provider()
        (self.repo.root / "SPEC.md").unlink()
        result = self.run_queue(self.write_queue("queue-first", "queue-second"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo.root / "product-TST-001.txt").exists())
        self.assertTrue((self.repo.root / "product-TST-002.txt").exists())
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout.strip(), "")
        status = json.loads(self.repo.command("queue", "status", "nightly", "--json").stdout)
        self.assertEqual(status["state"], "done")
        self.assertEqual(status["finalized"], ["queue-first", "queue-second"])

    def test_queue_finalizes_a_campaign_that_is_ready_instead_of_running_it(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        self.final_validation_that_moves_main_once()
        stopped = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertIn("main moved during finalize", stopped.stderr)
        # The cleanup commit already removed the planning files: status and run would refuse this campaign forever.
        self.assertFalse((self.repo.worktree / "campaigns" / self.repo.slug).exists())
        result = self.run_queue(self.write_queue(self.repo.slug))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout.strip(), "")
        status = json.loads(self.repo.command("queue", "status", "nightly", "--json").stdout)
        self.assertEqual((status["state"], status["finalized"]), ("done", [self.repo.slug]))

    def test_queue_finalize_tries_again_when_main_moves_during_it(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        counter = self.final_validation_that_moves_main_once()
        result = self.run_queue(self.write_queue(self.repo.slug))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counter.read_text().splitlines(), ["run", "run"])
        self.assertIn("moved", self.repo.git("log", "--format=%s", "main").stdout.splitlines())
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout.strip(), "")

    def test_queue_does_not_initialize_a_campaign_finalized_by_hand(self):
        self.repo.init_campaign(); self.repo.configure([ticket(status="done")])
        (self.repo.root / "SPEC.md").unlink(missing_ok=True)
        by_hand = self.repo.command("finalize", cwd=self.repo.worktree, check=False)
        self.assertEqual(by_hand.returncode, 0, by_hand.stderr)
        marker = next(Path(self.repo.cache.name).glob(f"*/finalized/{self.repo.slug}.json"))
        self.assertEqual(json.loads(marker.read_text())["main_branch_head"], self.repo.git("rev-parse", "main").stdout.strip())
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        result = self.run_queue(self.write_queue(self.repo.slug))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.git("branch", "--list", "campaign/*").stdout.strip(), "")
        status = json.loads(self.repo.command("queue", "status", "nightly", "--json").stdout)
        self.assertEqual((status["state"], status["finalized"]), ("done", [self.repo.slug]))

    def test_53_overview_lists_every_campaign_with_ticket_counts(self):
        self.repo.init_campaign(); self.repo.configure([ticket(), ticket("TST-002")]); self.repo.mock_provider()
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        overview = json.loads(self.repo.command("overview", "--json").stdout)
        campaign = next(item for item in overview["campaigns"] if item["slug"] == "harness-sample")
        self.assertFalse(campaign["runner_active"])
        self.assertEqual(campaign["counts"], {"done": 2})
        self.assertEqual(campaign["tickets"][0]["goal"], "Produce TST-001.")
        self.assertTrue(campaign["recent_events"])

if __name__ == "__main__":
    unittest.main(verbosity=1)

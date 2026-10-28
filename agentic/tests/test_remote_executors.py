#!/usr/bin/env python3
"""Remote executors without a real host or model: a fake ssh drops the destination and runs the remote command on this
machine, and a fake run prefix maps every absolute argument under the executor root, like a container that bind-mounts
<root>/x at /x. The mock provider therefore works in <root><worktree>, never in the local ticket worktree."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_campaign import Repo, ticket

FAKE_SSH = """\
#!/usr/bin/env bash
# Drops the ssh options and the destination, then runs the remote command here (rsync -e and git use it too).
while (($#)); do
  case $1 in
    -[BbcDEeFIiJLlmOopQRSWw]) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
exec bash -c "$*"
"""

UNREACHABLE_SSH = """\
#!/usr/bin/env bash
printf 'ssh: connect to host box port 22: Connection refused\\n' >&2
exit 255
"""

# The run prefix: its first argument is the executor root; it logs the mapped command line under that root.
FAKE_RUN = """\
#!/usr/bin/env bash
root=$1
shift
mapped=()
for argument in "$@"; do
  case $argument in
    /*) mapped+=("$root$argument") ;;
    *) mapped+=("$argument") ;;
  esac
done
printf '%s\\n' "${mapped[*]}" >> "$root/run.log"
exec "${mapped[@]}"
"""


class RemoteExecutorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-remote-")
        base = Path(self.temp.name)
        self.root = base / "remote"
        self.root.mkdir()
        tools = base / "bin"
        tools.mkdir()
        self.ssh = self.tool(tools / "ssh", FAKE_SSH)
        self.unreachable = self.tool(tools / "unreachable-ssh", UNREACHABLE_SSH)
        self.run_prefix = self.tool(tools / "run", FAKE_RUN)
        self.repos = []

    def tearDown(self):
        for repo in self.repos:
            repo.close()
        self.temp.cleanup()

    @staticmethod
    def tool(path, text):
        path.write_text(text)
        path.chmod(0o755)
        return path

    def repo(self, workers=1):
        executor = {"name": "box", "ssh": "box", "workers": workers, "root": str(self.root),
                    "run": [str(self.run_prefix), str(self.root)], "exclude": ["node_modules/"]}
        repo = Repo(settings={"executors": [executor]})
        self.repos.append(repo)
        (repo.root / ".gitignore").write_text("node_modules/\n")
        (repo.root / "doomed.txt").write_text("the worker deletes this\n")
        repo.git("add", "."); repo.git("commit", "-m", "project files")
        repo.env["AGENTIC_SSH"] = str(self.ssh)
        return repo

    @staticmethod
    def runtime(repo):
        return next(Path(repo.cache.name).glob("*/*/campaign.json")).parent

    @staticmethod
    def events(repo, name="campaign.ndjson"):
        path = next(Path(repo.cache.name).rglob(name), None)
        return [json.loads(line) for line in path.read_text().splitlines()] if path else []

    @staticmethod
    def states(repo):
        return {item["id"]: item["status"] for item in json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)["tickets"]}

    def remote(self, path):
        return Path(f"{self.root}{path}")

    def run_log(self):
        path = self.root / "run.log"
        return path.read_text() if path.exists() else ""

    def run_campaign(self, repo, *options, env=None):
        result = repo.command("run", "--provider", "mock", "--workers", "1", *options, cwd=repo.worktree, check=False, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_a_remote_worker_change_and_deletion_reach_integration_and_the_reviewer_stays_local(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        seen = Path(repo.cache.name) / "seen"
        repo.env.update(MOCK_DELETE_FILE="doomed.txt", MOCK_SEEN_DIR=str(seen))
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual((repo.worktree / "product-TST-001.txt").read_text(), "TST-001\n")
        self.assertFalse((repo.worktree / "doomed.txt").exists())
        # The worker ran in the remote copy of the ticket worktree, through the run prefix, and only the worker did.
        worktree = self.runtime(repo) / "worktrees" / "TST-001"
        self.assertTrue((self.remote(worktree) / "product-TST-001.txt").is_file())
        self.assertFalse((self.remote(worktree) / "doomed.txt").exists())
        lines = self.run_log().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn(f" worker {self.remote(worktree)} ", lines[0])
        events = self.events(repo)
        self.assertIn(("executor-assigned", "executor=box"), [(e["type"], e["message"]) for e in events if e.get("ticket") == "TST-001"])
        started = [e["message"] for e in events if e["type"] == "provider-started"]
        self.assertTrue(any("role=worker" in m and "executor=box" in m for m in started), started)
        self.assertTrue(any("role=reviewer" in m and "executor=" not in m for m in started), started)
        # The provider events the remote adapter wrote came back with the result.
        ticket_events = next(Path(repo.cache.name).rglob("TST-001.ndjson")).read_text()
        self.assertEqual(ticket_events.count('"role": "worker"'), 1)
        self.assertEqual(ticket_events.count('"role": "reviewer"'), 1)
        self.assertLess(ticket_events.index('"role": "worker"'), ticket_events.index('"role": "reviewer"'))

    def test_the_uncommitted_delta_goes_to_the_remote_worker(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        worktree = self.runtime(repo) / "worktrees" / "TST-001"
        repo.git("worktree", "add", "-b", f"agentic/{repo.slug}/TST-001", str(worktree), f"campaign/{repo.slug}")
        (worktree / "partial.txt").write_text("cut off\n")
        (worktree / "doomed.txt").unlink()
        seen = Path(repo.cache.name) / "seen"
        repo.env["MOCK_SEEN_DIR"] = str(seen)
        self.run_campaign(repo)
        listing = (seen / "TST-001-recovery.json").read_text().split()
        self.assertIn("partial.txt", listing)
        self.assertNotIn("doomed.txt", listing)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertTrue((repo.worktree / "partial.txt").is_file())
        self.assertFalse((repo.worktree / "doomed.txt").exists())

    def test_excluded_folders_stay_local_and_survive_the_copy_back(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider(worker="BLOCKED")
        worktree = self.runtime(repo) / "worktrees" / "TST-001"
        repo.git("worktree", "add", "-b", f"agentic/{repo.slug}/TST-001", str(worktree), f"campaign/{repo.slug}")
        (worktree / "node_modules").mkdir()
        (worktree / "node_modules" / "keep.txt").write_text("local only\n")
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "blocked"})
        self.assertEqual((worktree / "node_modules" / "keep.txt").read_text(), "local only\n")
        self.assertTrue(self.remote(worktree).is_dir())
        self.assertFalse((self.remote(worktree) / "node_modules").exists())

    def test_an_unreachable_executor_falls_back_locally_without_spending_an_attempt(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env["AGENTIC_SSH"] = str(self.unreachable)
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        events = self.events(repo)
        unavailable = [e["message"] for e in events if e["type"] == "executor-unavailable"]
        self.assertEqual(len(unavailable), 1)
        self.assertIn("executor=box", unavailable[0])
        self.assertIn("ssh could not reach box", unavailable[0])
        workers = [e["message"] for e in events if e["type"] == "provider-started" and "role=worker" in e["message"]]
        self.assertEqual(len(workers), 2)
        self.assertTrue(all("attempt=1" in m for m in workers), workers)
        self.assertIn("executor=box", workers[0])
        self.assertNotIn("executor=", workers[1])
        self.assertNotIn("provider-failed", [e["type"] for e in events])
        self.assertEqual(self.run_log(), "")

    def test_agentic_executors_local_runs_everything_here(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        self.run_campaign(repo, env={"AGENTIC_EXECUTORS": "local"})
        self.assertEqual(self.states(repo), {"TST-001": "done"})
        self.assertEqual(self.run_log(), "")
        self.assertNotIn("executor-assigned", [e["type"] for e in self.events(repo)])

    def test_capacity_is_the_local_workers_plus_the_executor_workers(self):
        repo = self.repo(workers=2)
        values = [ticket(f"TST-00{i}", collision=(f"domain-{i}",)) for i in range(1, 5)]
        repo.init_campaign(); repo.configure(values); repo.mock_provider()
        track = Path(repo.cache.name) / "track"
        repo.env.update(MOCK_TRACK_DIR=str(track), MOCK_SLEEP="2")
        self.run_campaign(repo)
        self.assertEqual(self.states(repo), {f"TST-00{i}": "done" for i in range(1, 5)})
        self.assertEqual((track / "max").read_text(), "3")
        events = self.events(repo)
        assigned = [e["message"] for e in events if e["type"] == "executor-assigned"]
        # The first three start together: the executor's two slots first, then the local one.
        self.assertEqual(assigned[:3], ["executor=box", "executor=box", "executor=local"])
        self.assertIn("executors=box:2 capacity=3", next(e["message"] for e in events if e["type"] == "runner-started"))

    def test_status_and_overview_show_the_executor_of_an_in_progress_ticket(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        repo.env.update(MOCK_TRACK_DIR=str(Path(repo.cache.name) / "track"), MOCK_SLEEP="3")
        started = repo.command("run", "--provider", "mock", "--workers", "1", "--mode", "unattended", cwd=repo.worktree)
        self.assertIn("started detached", started.stdout)
        seen = text = overview = None
        for _ in range(100):
            item = json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)["tickets"][0]
            if item["status"] == "in-progress" and "executor" in item:
                seen = item["executor"]
                text = repo.command("status", cwd=repo.worktree).stdout
                overview = json.loads(repo.command("overview", "--json").stdout)
                break
            time.sleep(0.1)
        for _ in range(150):
            if not json.loads(repo.command("status", "--json", cwd=repo.worktree).stdout)["runner"]["active"]:
                break
            time.sleep(0.2)
        self.assertEqual(seen, "box")
        self.assertIn("TST-001\tin-progress\tlow\texecutor=box", text)
        self.assertEqual(overview["campaigns"][0]["tickets"][0].get("executor"), "box")

    def test_a_remote_timeout_kills_the_remote_process_group(self):
        repo = self.repo()
        repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
        adapter = Path(repo.env["AGENTIC_PROVIDER_DIR"]) / "mock/run.sh"
        hang = '''
            if [ "$role" = worker ]; then
              printf 'invoked\\n' >> "$DEADLINE_PROOF/invocations"
              bash -c 'trap "" TERM; echo "$BASHPID" > "$DEADLINE_PROOF/child.pid"; exec sleep 120' &
              wait
            fi
        '''
        adapter.write_text(adapter.read_text().replace("status=PASS\n", hang + "\nstatus=PASS\n", 1))
        proof = Path(repo.cache.name) / "deadline-proof"
        proof.mkdir()
        repo.env.update(DEADLINE_PROOF=str(proof), AGENTIC_WORKER_TIMEOUT_SECONDS="6")
        started = time.monotonic()
        result = subprocess.run([str(repo.binary(repo.worktree)), "run", "--provider", "mock", "--workers", "1"],
                                cwd=repo.worktree, env=repo.env, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 40)
        self.assertEqual((proof / "invocations").read_text().splitlines(), ["invoked"])
        pid = int((proof / "child.pid").read_text())
        stat = Path(f"/proc/{pid}/stat")
        if stat.exists():
            self.assertEqual(stat.read_text().split(") ", 1)[1].split()[0], "Z")
        self.assertIn("provider-timeout", [e["type"] for e in self.events(repo)])
        self.assertEqual(self.states(repo), {"TST-001": "todo"})
        self.assertEqual(list((self.root / ".agentic" / "run").glob("*.pgid")), [])


class ExecutorSettingsTests(unittest.TestCase):
    def tearDown(self):
        for repo in getattr(self, "repos", []):
            repo.close()

    def current(self, settings, env=None):
        repo = Repo(settings=settings)
        self.repos = getattr(self, "repos", []) + [repo]
        return repo.command("current", check=False, env=env)

    def test_invalid_executors_stop_every_command(self):
        good = {"name": "box", "ssh": "box", "workers": 1}
        cases = {
            "executors must be a list": {"executors": {"box": good}},
            "name must match": {"executors": [dict(good, name="Box")]},
            "reserved": {"executors": [dict(good, name="local")]},
            "ssh must be": {"executors": [dict(good, ssh="-oProxyCommand=x")]},
            "workers must be a positive integer": {"executors": [dict(good, workers=0)]},
            "root must be an absolute path": {"executors": [dict(good, root="relative", run=["wrap"])]},
            "root needs a run prefix": {"executors": [dict(good, root="/srv/work")]},
            "run must be a list": {"executors": [dict(good, run="wrap")]},
            "exclude must be a list": {"executors": [dict(good, exclude=[""])]},
            "rsync_options must be a list": {"executors": [dict(good, rsync_options="--chmod=g+w")]},
            "unknown field": {"executors": [dict(good, worker=2)]},
            "is not unique": {"executors": [good, dict(good, workers=2)]},
        }
        for message, settings in cases.items():
            with self.subTest(message=message):
                result = self.current(settings)
                self.assertEqual(result.returncode, 2)
                self.assertIn("invalid executors", result.stderr)
                self.assertIn(message, result.stderr)

    def test_a_valid_executor_list_is_accepted(self):
        executor = {"name": "edenred-arch", "ssh": "edenred-arch", "workers": 2, "root": "/srv/work/",
                    "run": ["/usr/local/bin/agentic-worker-run"], "exclude": ["node_modules/"], "rsync_options": ["--chmod=g+w"]}
        result = self.current({"executors": [executor]})
        self.assertNotIn("invalid", result.stderr)
        self.assertIn("outside campaign", result.stderr)

    def test_agentic_executors_accepts_only_local(self):
        result = self.current({}, env={"AGENTIC_EXECUTORS": "remote"})
        self.assertEqual(result.returncode, 2)
        self.assertIn("AGENTIC_EXECUTORS accepts only 'local'", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)

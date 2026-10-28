#!/usr/bin/env python3
"""bin/offload without a real host: the fake ssh and run prefix of test_remote_executors run the remote side on this
machine, with every local absolute path mapped under the executor root, so a remote run works in <root><worktree> and
never in the local worktree."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from test_campaign import Repo
from test_remote_executors import FAKE_RUN, FAKE_SSH, UNITS_RUN, UNREACHABLE_SSH


class OffloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-offload-")
        base = Path(self.temp.name)
        self.root = base / "remote"
        self.root.mkdir()
        self.tools = base / "bin"
        self.tools.mkdir()
        self.ssh = self.tool("ssh", FAKE_SSH)
        self.unreachable = self.tool("unreachable-ssh", UNREACHABLE_SSH)
        self.run_prefix = self.tool("run", FAKE_RUN)
        self.repos = []

    def tearDown(self):
        for repo in self.repos:
            repo.close()
        self.temp.cleanup()

    def tool(self, name, text):
        path = self.tools / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def executor(self, name="box", root=None, **fields):
        root = root or self.root
        return {"name": name, "ssh": name, "workers": 1, "root": str(root), "run": [str(self.run_prefix), str(root)],
                "exclude": ["node_modules/"], **fields}

    def repo(self, *executors, project=None):
        repo = Repo(settings={**(project or {}), "executors": list(executors) or [self.executor()]})
        self.repos.append(repo)
        repo.env["AGENTIC_SSH"] = str(self.ssh)
        return repo

    def offload(self, repo, *arguments, env=None, cwd=None):
        merged = dict(repo.env)
        merged.update(env or {})
        return subprocess.run([str(repo.root / ".agentic" / "bin" / "offload"), *arguments], cwd=cwd or repo.root,
                              env=merged, text=True, capture_output=True, timeout=120)

    def remote(self, path):
        return Path(f"{self.root}{path}")

    def run_log(self):
        path = self.root / "run.log"
        return path.read_text() if path.exists() else ""

    def test_a_remote_run_streams_its_output_and_copies_back_only_the_back_paths(self):
        admit = self.tool("admit", f"#!/usr/bin/env bash\nprintf '%s %s\\n' \"$AGENTIC_UNITS\" \"$AGENTIC_RUN_KIND\" >> {self.root}/admit.log\n")
        self.run_prefix = self.tool("units-run", UNITS_RUN)
        repo = self.repo(self.executor(admit=[str(admit)], env={"EXECUTOR_ONLY": "executor"}),
                         project={"env": {"PROJECT_ONLY": "project"}})
        (repo.root / "uncommitted.txt").write_text("not committed\n")
        script = ('echo "on stdout"; echo "on stderr" >&2; cat uncommitted.txt; '
                  'echo "units=$AGENTIC_UNITS offload=$AGENTIC_OFFLOAD $PROJECT_ONLY $EXECUTOR_ONLY"; '
                  'mkdir -p results/deep; echo result > results/deep/r.txt; echo junk > junk.txt; exit 3')
        result = self.offload(repo, "--units", "2", "--back", "results", "--", "bash", "-c", script)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["on stdout", "not committed", "units=2 offload=1 project executor"])
        self.assertIn("on stderr", result.stderr)
        self.assertIn("offload: running on box", result.stderr)
        self.assertNotIn("on stderr", result.stdout)
        # Only the --back path came back; the rest of the remote worktree stays there.
        self.assertEqual((repo.root / "results" / "deep" / "r.txt").read_text(), "result\n")
        self.assertFalse((repo.root / "junk.txt").exists())
        self.assertTrue((self.remote(repo.root) / "junk.txt").is_file())
        self.assertEqual((self.root / "admit.log").read_text(), "2 offload\n")
        self.assertEqual((self.root / "units.log").read_text(), "units=2\n")
        self.assertEqual(list((self.root / ".agentic" / "run").glob("*.pgid")), [])

    def test_the_command_runs_from_the_current_folder(self):
        repo = self.repo()
        (repo.root / "sub").mkdir()
        (repo.root / "sub" / "file.txt").write_text("in sub\n")
        result = self.offload(repo, "--back", "made.txt", "--", "bash", "-c", "cat file.txt; echo made > made.txt",
                              cwd=repo.root / "sub")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "in sub\n")
        self.assertEqual((repo.root / "sub" / "made.txt").read_text(), "made\n")

    def build(self, repo):
        """A build made here, in folders the executor's exclude keeps off the worktree sync."""
        (repo.root / "build" / "out").mkdir(parents=True)
        (repo.root / "build" / "out" / "app.bin").write_text("built here\n")
        (repo.root / "build" / "single.txt").write_text("one file\n")
        (repo.root / "build" / "unsent").mkdir()
        (repo.root / "build" / "unsent" / "other.bin").write_text("never sent\n")

    def test_send_paths_reach_the_executor_despite_its_exclude(self):
        repo = self.repo(self.executor(exclude=["build/"]))
        self.build(repo)
        script = "cat build/out/app.bin build/single.txt; [ ! -e build/unsent ] && echo 'unsent stays here'"
        result = self.offload(repo, "--send", "build/out", "--send", "build/single.txt", "--", "bash", "-c", script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "built here\none file\nunsent stays here\n")

    def test_a_sent_folder_is_mirrored_exactly(self):
        repo = self.repo(self.executor(exclude=["build/"]))
        self.build(repo)
        remote_out = self.remote(repo.root.resolve()) / "build" / "out"
        remote_out.mkdir(parents=True)
        (remote_out / "stale.bin").write_text("from an older build\n")
        result = self.offload(repo, "--send", "build/out", "--", "ls", "build/out")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "app.bin\n")
        self.assertFalse((remote_out / "stale.bin").exists())

    def test_a_missing_send_path_is_refused_before_anything_is_sent(self):
        repo = self.repo()
        result = self.offload(repo, "--send", "build/missing", "--", "true")
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("--send names a path that does not exist: build/missing", result.stderr)
        self.assertEqual(self.run_log(), "")
        self.assertFalse(self.remote(repo.root.resolve()).exists())

    def test_send_does_nothing_when_the_command_runs_here(self):
        repo = self.repo(self.executor(exclude=["build/"]))
        self.build(repo)
        self.here = repo.root.resolve()
        result = self.offload(repo, "--send", "build/out", "--", "bash", "-c",
                              'echo "units=$AGENTIC_UNITS offload=$AGENTIC_OFFLOAD"; pwd; exit 4',
                              env={"AGENTIC_SSH": str(self.unreachable)})
        self.assert_ran_here(result, "ssh could not reach box")
        self.assertEqual((repo.root / "build" / "out" / "app.bin").read_text(), "built here\n")

    def test_each_runs_every_value_at_once_on_the_same_remote_worktree(self):
        repo = self.repo()
        # Every run waits until all three started there, which only concurrent runs in one worktree can satisfy.
        script = ('touch "started-$N"; for _ in $(seq 100); do [ -e started-1 ] && [ -e started-2 ] && [ -e started-3 ] '
                  '&& break; sleep 0.1; done; [ -e started-1 ] && [ -e started-2 ] && [ -e started-3 ] || exit 9; '
                  'echo "value $N"; echo "error $N" >&2; [ "$N" != 2 ]')
        result = self.offload(repo, "--each", "N=1,2,3", "--", "bash", "-c", script)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(sorted(result.stdout.splitlines()), ["[box N=1] value 1", "[box N=2] value 2", "[box N=3] value 3"])
        for value in "123":
            self.assertIn(f"[box N={value}] error {value}", result.stderr)
        self.assertIn("offload: N=1 PASS on box", result.stderr)
        self.assertIn("offload: N=2 FAIL (exit 1) on box", result.stderr)
        self.assertIn("offload: N=3 PASS on box", result.stderr)
        self.assertEqual(len(self.run_log().splitlines()), 3)
        self.assertFalse((repo.root / "started-1").exists())

    def test_each_passes_only_when_every_value_passes(self):
        repo = self.repo()
        result = self.offload(repo, "--each", "N=a,b", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("offload: N=a PASS on box", result.stderr)
        self.assertIn("offload: N=b PASS on box", result.stderr)

    def test_the_first_executor_that_admits_the_run_takes_it(self):
        full = self.tool("full", "#!/usr/bin/env bash\necho 'free=0/4'\nexit 1\n")
        other = Path(self.temp.name) / "other"
        repo = self.repo(self.executor(admit=[str(full)]), self.executor("second", root=other))
        result = self.offload(repo, "--", "bash", "-c", "pwd")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("executor unavailable: box: no room (free=0/4, admit exited 1)", result.stderr)
        self.assertIn("offload: running on second", result.stderr)
        self.assertEqual(result.stdout.strip(), f"{other}{repo.root.resolve()}")

    def assert_ran_here(self, result, reason):
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "units=1 offload=1")
        self.assertEqual(Path(result.stdout.splitlines()[1]).resolve(), self.here)
        if reason:
            self.assertIn(reason, result.stderr)
            self.assertIn("offload: no executor can take the run; it runs here", result.stderr)
        else:
            self.assertEqual(result.stderr, "")
        self.assertNotIn("bash -c", self.run_log())

    def run_here_case(self, repo, reason, env=None):
        self.here = repo.root.resolve()
        result = self.offload(repo, "--", "bash", "-c", 'echo "units=$AGENTIC_UNITS offload=$AGENTIC_OFFLOAD"; pwd; exit 4',
                              env=env)
        self.assert_ran_here(result, reason)

    def test_an_unreachable_executor_runs_the_command_here(self):
        repo = self.repo()
        self.run_here_case(repo, "ssh could not reach box", env={"AGENTIC_SSH": str(self.unreachable)})

    def test_an_executor_whose_admit_refuses_runs_the_command_here(self):
        full = self.tool("full", "#!/usr/bin/env bash\necho busy\nexit 1\n")
        repo = self.repo(self.executor(admit=[str(full)]))
        self.run_here_case(repo, "box: no room (busy, admit exited 1)")

    def test_an_executor_without_a_required_command_runs_the_command_here(self):
        repo = self.repo(self.executor(requires=["bash", "agentic-missing-command"]))
        self.run_here_case(repo, "box: requires agentic-missing-command")

    def test_an_executor_run_never_offloads_again(self):
        for variable in ("AGENTIC_OFFLOAD", "AGENTIC_EXECUTOR_RUN"):
            with self.subTest(variable=variable):
                repo = self.repo()
                self.run_here_case(repo, None, env={variable: "1"})

    def test_agentic_executors_local_runs_the_command_here(self):
        repo = self.repo()
        self.run_here_case(repo, None, env={"AGENTIC_EXECUTORS": "local"})

    def test_each_here_runs_the_values_one_after_another(self):
        repo = self.repo()
        script = '[ ! -e running ] || exit 7; touch running; sleep 0.3; rm running; echo "value $N"; [ "$N" != b ]'
        result = self.offload(repo, "--each", "N=a,b", "--", "bash", "-c", script, env={"AGENTIC_SSH": str(self.unreachable)})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["[local N=a] value a", "[local N=b] value b"])
        self.assertIn("offload: N=a PASS on local", result.stderr)
        self.assertIn("offload: N=b FAIL (exit 1) on local", result.stderr)

    def test_usage_errors_exit_64(self):
        repo = self.repo()
        cases = [[], ["--", ], ["--units", "0", "--", "true"], ["--each", "N", "--", "true"], ["--each", "N=a,,b", "--", "true"],
                 ["--each", "N=a", "--each", "M=b", "--", "true"], ["--back", "/etc", "--", "true"], ["--back", "..", "--", "true"],
                 ["--back", ".", "--", "true"], ["--send", "/etc", "--", "true"], ["--send", "..", "--", "true"],
                 ["--bogus", "--", "true"]]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.offload(repo, *arguments)
                self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(self.run_log(), "")

    def test_term_stops_every_remote_run(self):
        repo = self.repo()
        worktree = self.remote(repo.root.resolve())
        process = subprocess.Popen([str(repo.root / ".agentic" / "bin" / "offload"), "--each", "N=1,2", "--",
                                    "bash", "-c", 'echo "$$" > "pid-$N"; exec sleep 60'],
                                   cwd=repo.root, env=repo.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(200):
            if (worktree / "pid-1").exists() and (worktree / "pid-2").exists():
                break
            time.sleep(0.1)
        time.sleep(0.3)
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=30), 143)
        for name in ("pid-1", "pid-2"):
            pid = int((worktree / name).read_text())
            stat = Path(f"/proc/{pid}/stat")
            if stat.exists():
                self.assertEqual(stat.read_text().split(") ", 1)[1].split()[0], "Z")
        self.assertEqual(list((self.root / ".agentic" / "run").glob("*.pgid")), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)

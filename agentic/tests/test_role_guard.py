#!/usr/bin/env python3
"""bin/role-guard: the PreToolUse hook that keeps the campaign roles from editing files through the shell and from writing
to git. Table-driven: every form it blocks and every form it must let through. No claude process is started."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

GUARD = Path(__file__).resolve().parents[1] / "bin" / "role-guard"

EDIT = "use the Edit tool"
WRITE = "create files with Write and change them with Edit"
GIT = "the runner commits and integrates; only read git is allowed"

loader = importlib.machinery.SourceFileLoader("role_guard", str(GUARD))
guard = importlib.util.module_from_spec(importlib.util.spec_from_loader("role_guard", loader))
loader.exec_module(guard)

QUEUE = "/srv/agentic-queue"

BLOCKED = {
    EDIT: [
        "sed -i s/a/b/ f", "sed -i'' s/a/b/ f", "sed -i '' s/a/b/ f", "sed -i.bak s/a/b/ f", "sed -ni 's/a/b/p' f",
        "sed -Ei 's/a/b/' f", "sed -E -i 's/a/b/' f", "sed --in-place s/a/b/ f", "sed --in-place=.bak s/a/b/ f",
        "sed -n -e 's/a/b/' -i f", "sed 's/a/b/' -i f", "sed -i -e 's/a/b/' f", "sed -s -i 's/a/b/' a b",
        "FOO=1 sed -i s/a/b/ f", "command sed -i s/a/b/ f", "env FOO=1 sed -i s/a/b/ f", "sudo sed -i s/a/b/ f",
        "nice -n 5 sed -i s/a/b/ f", "timeout 10 sed -i s/a/b/ f", "/usr/bin/sed -i s/a/b/ f", "gsed -i s/a/b/ f",
        "cd x && sed -i s/a/b/ f", "make; sed -i s/a/b/ f", "false || sed -i s/a/b/ f", "ls | sed -i s/a/b/ f",
        "echo a\nsed -i s/a/b/ f", "( sed -i s/a/b/ f )", "{ sed -i s/a/b/ f; }", "echo $(sed -i s/a/b/ f)",
        "echo `sed -i s/a/b/ f`", 'echo "$(sed -i s/a/b/ f)"', "for f in *.md; do sed -i s/a/b/ \"$f\"; done",
        "if true; then sed -i s/a/b/ f; fi", "echo a | xargs sed -i s/a/b/", "ls | xargs -n 1 sed -i s/a/b/",
        "find . -name '*.md' -exec sed -i s/a/b/ {} +", "find . -type f -execdir sed -i s/a/b/ {} \\;",
        "bash -c 'sed -i s/a/b/ f'", 'sh -c "sed -i s/a/b/ f"', "bash -lc 'cd x && sed -i s/a/b/ f'", "eval 'sed -i s/a/b/ f'",
        "env -S 'sed -i s/a/b/ f'", "diff <(sed -i s/a/b/ f) x",
        "perl -i -pe 's/a/b/' f", "perl -pi -e 's/a/b/' f", "perl -0pi -e 's/a/b/' f", "perl -i.bak -pe 's/a/b/' f",
        "perl -pie 's/a/b/' f", "perl -Mstrict -i -pe 's/a/b/' f", "perl -pe 's/a/b/' -i f", "perl -00 -pi -e 's/a/b/' f",
        "perl -0777pi -e 's/a/b/' f", "perl -wpi -e 's/a/b/' f", "sudo perl -pi -e 's/a/b/' f",
    ],
    WRITE: [
        "echo hi > f", "echo hi >f", "echo hi >> f", "echo hi >| f", "echo hi 2> err.txt", "echo hi 1> f", "echo hi 2>>f",
        "echo hi &> f", "echo hi &>> f", "echo hi >& f", "echo hi <> f", "echo hi {fd}> f", ": > f", "> f", "exec 3> f",
        "cat <<EOF > f\nx\nEOF", "cat > f <<'EOF'\nx\nEOF", "cat >> f <<-EOF\n\tx\n\tEOF", "cat <<EOF >f\nx\nEOF\necho after",
        "tee f", "echo x | tee -a f", "echo x | tee --append f", "echo x | tee /tmp/ok f", "echo x | tee -- f",
        "echo x | sudo tee f", "echo x | tee f > /dev/null", "echo x | tee /tmp/ok - f",
        "printf x > \"$f\"", "echo x > $HOME/f", "echo x > ~/f", "echo x > ../f", "echo x > /tmp/../etc/f", "echo x > /tmpfile",
        "echo x > /etc/f", "echo x > /tmp", "echo x > ./tmp/f", "echo x > /tmp/$(whoami)/../f",
        "diff a b > out.diff", "cat a b > c", "sort a > a.sorted", "ls | wc -l > count.txt",
        "bash -c 'echo hi > f'", 'sh -c "echo hi > f"', "echo $(echo hi > f)", "echo `echo hi > f`", "(echo hi > f)", "{ echo a; } > f",
        "if true; then echo a > f; fi", "for i in 1 2; do echo $i; done > f", "while read l; do echo $l; done < in > out",
        "echo a && echo b > f", "echo a ||\n echo b > f", "diff <(echo a) <(echo b) > f", "echo a > >(tee f)", "echo a | tee >(cat > f)",
        "eval 'echo hi > f'", "env FOO=1 tee f", "xargs tee f", "cat <<EOF\n$(echo hi > f)\nEOF",
        "echo x > /var/lib/x/queue/hosts/f",
    ],
    GIT: [
        "git add .", "git add -A", "git add -p", "git rm f", "git rm --cached f", "git mv a b", "git reset", "git reset --hard",
        "git reset --soft HEAD~1", "git stash", "git stash push -m x", "git stash pop", "git stash drop", "git stash -u",
        "git rebase main", "git rebase -i HEAD~2", "git merge x", "git merge --ff-only x", "git commit -m x", "git commit --amend",
        "git commit -am 'x > y'", "git checkout -- f", "git checkout -b x", "git checkout main", "git switch x", "git switch -c x",
        "git restore f", "git restore --staged f", "git clean -fd", "git clean -n", "git push", "git push origin main", "git pull",
        "git fetch", "git fetch --all", "git cherry-pick x", "git revert x", "git am p.patch", "git apply p.patch",
        "git apply --index p.patch", "git update-index --assume-unchanged f", "git update-ref -d refs/x", "git update-ref refs/x HEAD",
        "git tag v1", "git tag -a v1 -m x", "git tag -d v1", "git tag -f v1", "git tag -s v1", "git tag v1 HEAD~1",
        "git branch x", "git branch x HEAD~1", "git branch -D x", "git branch -d x", "git branch -m a b", "git branch -M a",
        "git branch -c a b", "git branch -f x HEAD", "git branch --delete x", "git branch --set-upstream-to=origin/x",
        "git branch -u origin/x", "git worktree add p", "git worktree remove p", "git worktree move a b", "git worktree prune",
        "git worktree lock p", "git notes add -m x", "git notes append -m x", "git notes remove", "git gc", "git prune",
        "git config user.name x", "git config --global user.name x", "git config --unset a", "git config --add a b",
        "git config set a b", "git config --edit", "git config -e", "git init", "git clone x", "git remote add o x",
        "git remote remove o", "git submodule update", "git bisect start", "git commit-tree HEAD^{tree}", "git hash-object -w f",
        "git -C path add .", "git -c core.x=y commit -m x", "git --no-pager commit -m x", "git --git-dir=.git add .",
        "git --work-tree . add .", "FOO=1 git add .", "command git add .", "env GIT_DIR=x git add .", "/usr/bin/git add .",
        "sudo git add .", "git add . && git commit -m x", "cd x; git reset", "make && git add -A", "echo x | xargs git add",
        "bash -c 'git commit -m x'", "(git add .)", "if true; then git add .; fi", "echo $(git add .)", "timeout 5 git add .",
    ],
}

ALLOWED = [
    # read git
    "git status", "git status --porcelain=v1", "git diff", "git diff --no-renames HEAD", "git diff --stat main..HEAD",
    "git log --oneline -5", "git log --format=%s main..HEAD", "git show HEAD", "git show HEAD:README.md", "git blame f",
    "git grep -n x", "git ls-files", "git ls-files --others --exclude-standard", "git ls-tree HEAD", "git ls-tree -r HEAD --name-only",
    "git rev-parse HEAD", "git rev-parse --show-toplevel", "git cat-file -p HEAD", "git describe --tags", "git shortlog -sn",
    "git reflog", "git reflog show", "git reflog -5", "git branch", "git branch --show-current", "git branch -a", "git branch -v",
    "git branch -vv", "git branch -r", "git branch --list 'agentic/*'", "git branch -l", "git branch --contains HEAD",
    "git branch --merged main", "git worktree list", "git worktree list --porcelain", "git config --get user.name",
    "git config --list", "git config -l", "git config user.name", "git config --get-regexp 'remote.*'", "git config get user.name",
    "git config list", "git tag", "git tag -l", "git tag --list 'v*'", "git tag -n", "git tag --contains HEAD",
    "git -C path status", "git -C path log -1", "git --no-pager log -1", "git -c core.pager=cat log -1", "git stash list",
    "git stash show -p", "git notes list", "git notes show HEAD", "git remote", "git remote -v", "git remote show origin",
    "git remote get-url origin", "git merge-base main HEAD", "git apply --check p.patch", "git apply --stat p.patch",
    "git diff HEAD | cat", "git log | head -3", "git diff --output=/tmp/x.diff", "git status && git diff", "FOO=1 git status",
    "command git status", "git submodule status", "git symbolic-ref HEAD", "git symbolic-ref --short HEAD", "/usr/bin/git log -1",
    "git $subcommand", "git",
    # sed and perl that change nothing
    "sed -n 1,5p f", "sed 's/a/b/' f", "sed -e 's/i/x/' f", "sed -ne 's/a/b/p' f", "sed --expression=s/a/b/ f",
    "sed -n '/-i/p' f", "sed -E 's/(a|b)/c/' f", "echo x | sed 's/x/y/'", "sed -s -n p a b", "sed -n -e '1p' -e '2p' f",
    "sed --quiet --regexp-extended 's/a/b/' f", "sed -l 5 p f", "sed --version", "sed -f script.sed f", "sed -e 's/i/x/' -- f",
    "perl -ne 'print if /x/' f", "perl -e 'print 1'", "perl -pe 's/a/b/' f", "perl -Mstrict -e 1", "perl -le 'print q(i)'",
    "perl -we 'print 1'", "perl script.pl -i f", "perl -e 'print 1' -- -i", "perl -MList::Util=sum -e 'print sum(1,2)'", "perl -v",
    "sed", "perl", "$editor -i f",
    # redirections that write nothing a role must not
    "echo hi > /dev/null", "echo hi >/dev/null 2>&1", "echo hi &>/dev/null", "echo hi 2>&1", "cmd >&2", "cmd 2>&1 | tee", "cmd 1>&2",
    "cmd >&-", "cmd 2>/dev/null || true", "echo hi > /dev/stderr", "echo hi 1>&2", "exec 2>&1", "cmd 3>&1 1>&2 2>&3",
    "echo hi > /tmp/x", "echo hi >> /tmp/dir/x", "echo hi > /tmp/a/b/c.json", "cat <<EOF > /tmp/f\nx\nEOF", "echo hi 2>/tmp/err",
    "echo x | tee /tmp/x", "echo x | tee -a /tmp/x /dev/null", "echo x | tee", "cmd | tee >/dev/null",
    "echo hi > /tmp/$$.out", "echo hi > /tmp/$(date +%s).out", "echo hi > \"/tmp/$name\"",
    f"echo '{{}}' > {QUEUE}/requests/abc123/result.json", f"touch {QUEUE}/requests/abc123/done", f"echo done > {QUEUE}/requests/abc123/done",
    f"cat <<'EOF' > {QUEUE}/requests/abc123/result.json\n{{}}\nEOF", f"jq . x > {QUEUE}/requests/abc123/result.json",
    # here-strings, input redirections and heredocs that write nothing
    "cat <<< 'text'", "grep x <<< \"$var\"", "cat <<<\"a > b\"", "cat <<< x | wc -c", "cat < f", "wc -l < f", "sort < a | uniq",
    "while read l; do echo $l; done < in", "python3 - <<'PY'\nopen('f', 'w').write('x')\nPY", "cat <<'EOF'\nsed -i x\n> f\ngit commit\nEOF",
    "cat <<EOF\njust > text, no substitution\nEOF", "bash <<'EOF'\necho hi\nEOF", "cat <<EOF | wc -l\nhello\nEOF",
    # quoted or escaped text that only looks like a write
    "echo \"write > file\"", "echo 'a >> b'", "echo \"tee f\"", "echo 'sed -i x f'", "echo \"git commit -m x\"", "printf 'git add .\\n'",
    "grep -n \">\" f", "grep '>' f", "echo \"x\" | jq '.a > 1'", "echo \\> file", "echo a\\>b", "awk '$1 > 2' f", "echo \"a\\\"> f\"",
    "[[ a > b ]] && echo yes", "[[ -f f && a < b ]]", "(( x > 3 ))", "[ 3 -gt 2 ] && echo ok", "echo $((3 > 2))", "echo $(( 1 > 0 ))",
    "test \"$a\" \\> \"$b\"", "echo ${x:-a>b}", "echo \"${x:-a>b}\"", "echo $'a > b'", "git log --grep='>' ", "echo hi # > f",
    "gh pr create --body \"fix > bug\"", "curl -d 'a>b' http://x", "echo ok; # sed -i x",
    # commands the guard has no opinion about
    "ls -la", "mkdir -p /tmp/a", "cp a b", "mv a b", "touch f", "rm f", "bun test", "dotnet test", "cat f | wc -l", "sleep 1 &",
    "make && make test", "git-lfs status", "echo $(date)", "echo `date`", "cd x && ls", "true", "", "   ", "\n", "# only a comment",
    # a command line the guard cannot read: it lets it through and never crashes
    "echo \"unterminated", "echo 'unterminated", "echo $(", "echo `", "echo ${", "if then (", ")))", "((", "cat <<", "echo >", "echo <",
    "$(", "<(", ">(", "\\", "echo $'", "'", '"', "a=", "{", "}", "&", "| |", "; ;", "echo \"$(\"", "echo $((",
]

NOT_BASH = [
    {"tool_name": "Edit", "tool_input": {"file_path": "a", "old_string": "sed -i x > y", "new_string": "git commit"}},
    {"tool_name": "Write", "tool_input": {"file_path": "a", "content": "sed -i x > y\ngit add ."}},
    {"tool_name": "Read", "tool_input": {"file_path": "a"}},
    {"tool_name": "Grep", "tool_input": {"pattern": "git commit", "command": "sed -i x f"}},
    {"tool_name": "NotebookEdit", "tool_input": {"command": "git add ."}},
    {"tool_name": "Agent", "tool_input": {"prompt": "run git commit"}},
    {"tool_name": "bash", "tool_input": {"command": "git add ."}},
    {"tool_name": "Bash"},
    {"tool_name": "Bash", "tool_input": None},
    {"tool_name": "Bash", "tool_input": {}},
    {"tool_name": "Bash", "tool_input": {"command": None}},
    {"tool_name": "Bash", "tool_input": {"command": ["git", "add", "."]}},
    {"tool_name": "Bash", "tool_input": "git add ."},
    {},
    [],
]


def hook(command, tool="Bash", **extra):
    """The JSON a PreToolUse hook gets on stdin."""
    return json.dumps(dict({"session_id": "s", "agent_id": "a1", "agent_type": "campaign-worker", "permission_mode": "bypassPermissions",
                            "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {"command": command}, "cwd": "/work"},
                           **extra))


def run(payload, role="worker", env=None):
    environment = dict(os.environ, AGENTIC_SESSION_DIR=QUEUE)
    environment.update(env or {})
    return subprocess.run([sys.executable, str(GUARD), role], input=payload, text=True, capture_output=True, env=environment, timeout=30)


class RoleGuardTableTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"AGENTIC_SESSION_DIR": QUEUE})
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def verdict(command):
        """The advice of the violation guard.scan raises, or None."""
        try:
            guard.scan(command)
        except guard.Violation as violation:
            return violation.advice
        return None

    def test_every_blocked_form_is_blocked_with_the_advice_of_its_kind(self):
        for advice, commands in BLOCKED.items():
            for command in commands:
                with self.subTest(command=command):
                    self.assertEqual(self.verdict(command), advice)

    def test_every_allowed_form_is_allowed(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                self.assertIsNone(self.verdict(command))

    def test_the_blocked_table_covers_every_form_the_order_names(self):
        blocked = {command for commands in BLOCKED.values() for command in commands}
        names = ["add", "rm", "mv", "reset", "stash", "rebase", "merge", "commit", "checkout", "switch", "restore", "clean",
                 "push", "pull", "fetch", "cherry-pick", "revert", "am", "apply", "update-index", "update-ref", "gc", "prune"]
        for name in names:
            self.assertTrue(any(command.startswith(f"git {name}") for command in blocked), name)
        for fragment in ("git tag v1", "git tag -d", "git branch -D", "git branch -d", "git branch -m", "git branch -M", "git branch -c",
                         "git branch -f", "git branch x", "git worktree add", "git worktree remove", "git worktree move",
                         "git worktree prune", "git notes add", "git config user.name x", "tee f", "tee -a f", "<<EOF > f", ">> f",
                         "sed -ni", "sed -i.bak", "sed -Ei", "perl -pi", "perl -0pi", "FOO=1 git add", "git -C path add", "command ",
                         "env ", "$(", "`", "( "):
            self.assertTrue(any(fragment in command for command in blocked), fragment)

    def test_the_default_session_queue_and_the_xdg_state_are_honoured(self):
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": "/home/u/.state"}):
            os.environ.pop("AGENTIC_SESSION_DIR")
            self.assertIsNone(self.verdict("echo '{}' > /home/u/.state/agentic-session/requests/id/result.json"))
            self.assertEqual(self.verdict("echo '{}' > /home/u/.state/agentic-session/hosts/1.json"), WRITE)
            self.assertEqual(self.verdict(f"echo '{{}}' > {QUEUE}/requests/id/result.json"), WRITE)
        with mock.patch.dict(os.environ, {"HOME": "/home/v"}):
            os.environ.pop("AGENTIC_SESSION_DIR")
            os.environ.pop("XDG_STATE_HOME", None)
            self.assertIsNone(self.verdict("echo '{}' > /home/v/.local/state/agentic-session/requests/id/done"))

    def test_the_queue_folder_is_requests_only_and_never_leaves_it(self):
        self.assertIsNone(self.verdict(f"echo x > {QUEUE}/requests/id/result.json"))
        self.assertEqual(self.verdict(f"echo x > {QUEUE}/hosts/1.json"), WRITE)
        self.assertEqual(self.verdict(f"echo x > {QUEUE}/requests/../hosts/1.json"), WRITE)
        self.assertEqual(self.verdict(f"echo x > {QUEUE}/requests"), WRITE)
        self.assertEqual(self.verdict(f"echo x > {QUEUE}-other/requests/id"), WRITE)


class RoleGuardHookTests(unittest.TestCase):
    """The hook as Claude Code runs it: JSON on stdin, exit 2 and a message on stderr to block, exit 0 and silence otherwise."""

    def test_a_blocked_command_exits_2_with_a_short_message_for_the_model(self):
        for command, shown, advice in (("sed -i s/a/b/ f", "sed -i s/a/b/ f", EDIT), ("echo hi > f", "`> f`", WRITE),
                                       ("echo x | tee out.txt", "tee out.txt", WRITE), ("git commit -m x", "git commit -m x", GIT)):
            with self.subTest(command=command):
                result = run(hook(command), role="worker")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr.startswith("role-guard (worker): "), result.stderr)
                self.assertIn(advice, result.stderr)
                self.assertIn(shown, result.stderr)
                self.assertEqual(result.stderr.count("\n"), 1)

    def test_the_message_names_the_role(self):
        for role in ("worker", "reviewer", "diagnostician"):
            self.assertIn(f"role-guard ({role}): ", run(hook("git add ."), role=role).stderr)

    def test_an_allowed_command_exits_0_silently(self):
        for command in ("git status", "sed -n 1p f", "echo hi > /dev/null 2>&1", "echo hi > /tmp/x", "ls", f"echo {{}} > {QUEUE}/requests/a/result.json"):
            with self.subTest(command=command):
                result = run(hook(command))
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_other_tools_and_odd_inputs_exit_0_silently(self):
        for payload in NOT_BASH:
            with self.subTest(payload=payload):
                result = run(json.dumps(payload))
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        for text in ("", "not json", "{", "[1, 2]", "null", '"git add ."', "\x00", "{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"git add .\""):
            with self.subTest(stdin=text):
                result = run(text)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_the_hook_runs_without_a_role_and_ignores_the_fields_it_does_not_use(self):
        result = subprocess.run([sys.executable, str(GUARD)], input=hook("git add .", agent_type="x", extra={"a": 1}), text=True,
                                capture_output=True, env=dict(os.environ, AGENTIC_SESSION_DIR=QUEUE))
        self.assertEqual(result.returncode, 2)
        self.assertIn("role-guard (role): ", result.stderr)

    def test_a_very_long_and_deeply_nested_command_line_never_crashes_the_guard(self):
        commands = ["echo " + "x" * 200000, "echo " + "$(" * 200 + "date" + ")" * 200, "(" * 500 + "ls" + ")" * 500,
                    "bash -c '" * 30 + "git add ." + "'" * 30, "; ".join(["echo a > /tmp/x"] * 5000), "echo \"" + "$(date) " * 5000 + "\""]
        for command in commands:
            with self.subTest(command=command[:40]):
                result = run(hook(command))
                self.assertIn(result.returncode, (0, 2), result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_the_file_is_executable(self):
        self.assertTrue(os.access(GUARD, os.X_OK))
        self.assertTrue(GUARD.read_text().startswith("#!/usr/bin/env python3\n"))


if __name__ == "__main__":
    unittest.main()

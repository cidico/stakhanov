#!/usr/bin/env python3
"""The fleet without other machines: a fake ssh runs the remote command on this machine, under the identity of the
fake machine its destination names (a folder with its own home, machine id, runtime cache and fleet file). This machine
is the fake machine "here" to the others."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

import time

from test_campaign import Repo, SPEC, ticket

FLEET_SSH = """\
#!/usr/bin/env bash
# The destination (its user dropped) names a folder of $FLEET_HOSTS: the remote command runs from its home, with the
# variables of its env file. An unknown destination is unreachable. rsync -e and git use it too.
while (($#)); do
  case $1 in
    -[BbcDEeFIiJLlmOopQRSWw]) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$FLEET_HOSTS/${1#*@}
if [[ ! -f $host/env ]]; then
  printf 'ssh: connect to host %s port 22: Connection refused\\n' "$1" >&2
  exit 255
fi
shift
set -a
. "$host/env"
set +a
cd "$HOME"
exec bash -c "$*"
"""


class FleetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-fleet-")
        base = Path(self.temp.name)
        self.hosts = base / "hosts"
        tools = base / "bin"
        tools.mkdir()
        self.ssh = tools / "ssh"
        self.ssh.write_text(FLEET_SSH)
        self.ssh.chmod(0o755)
        self.repo = Repo(settings={"name": "proof"})
        self.root = Path(os.path.realpath(self.repo.root))
        self.envs = {}
        here = self.host("here", cache=self.repo.cache.name)
        # This machine keeps its own home: only its identity, cache and fleet file are the fake machine's.
        self.repo.env.update({key: value for key, value in here.items() if key in ("AGENTIC_MACHINE_ID", "AGENTIC_FLEET")})
        self.repo.env.update(AGENTIC_SSH=str(self.ssh), FLEET_HOSTS=str(self.hosts))
        self.host("box")

    def tearDown(self):
        self.repo.close()
        self.temp.cleanup()

    def host(self, name, cache=None, **extra):
        home = self.hosts / name / "home"
        home.mkdir(parents=True)
        # No git identity of this machine's user leaks into the fake one.
        env = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"), "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
               "AGENTIC_MACHINE_ID": f"{name}-machine-id", "AGENTIC_CACHE": cache or str(self.hosts / name / "cache"),
               "AGENTIC_FLEET": str(home / ".config" / "agentic" / "fleet.json"), **extra}
        (self.hosts / name / "env").write_text("".join(f"{key}={shlex.quote(value)}\n" for key, value in env.items()))
        self.envs[name] = env
        return env

    def clone(self, name):
        return self.hosts / name / "home" / "proof"

    def join(self, name="box", *extra, check=True, env=None):
        arguments = ["fleet", "join", name, "--ssh", name, "--as", "here", "--as-ssh", "me@here"]
        if "--path" not in extra:
            arguments += ["--path", str(self.clone(name))]
        return self.repo.command(*arguments, *extra, check=check, env=env)

    def on(self, name, *arguments, check=True):
        """A campaign command in the clone of the fake machine NAME, as that machine."""
        env = dict(self.repo.env, **self.envs[name])
        clone = self.clone(name)
        return subprocess.run([str(clone / ".agentic" / "bin" / "campaign"), *arguments], cwd=clone, env=env,
                              text=True, capture_output=True, check=check)

    def git(self, path, *arguments):
        return subprocess.run(["git", "-C", str(path), *arguments], text=True, capture_output=True, check=True).stdout.strip()

    def fleet_file(self, name):
        path = Path(self.envs[name]["AGENTIC_FLEET"])
        return json.loads(path.read_text()) if path.exists() else None

    def init_on(self, name, slug):
        clone = self.clone(name)
        (clone / "SPEC.md").write_text(SPEC)
        return self.on(name, "init", "SPEC.md", "--slug", slug)

    def test_join_clones_the_project_and_writes_one_fleet_file_everywhere(self):
        result = self.join()
        self.assertIn("box joined the fleet of proof", result.stdout)
        clone = self.clone("box")
        self.assertEqual(self.git(clone, "rev-parse", "HEAD"), self.git(self.root, "rev-parse", "main"))
        self.assertEqual(self.git(clone, "symbolic-ref", "--short", "HEAD"), "main")
        self.assertTrue((clone / ".agentic" / "bin" / "campaign").exists())
        self.assertEqual(self.git(clone, "config", "--local", "user.email"), "agentic@example.test")
        fleet = self.fleet_file("here")
        self.assertEqual(fleet, self.fleet_file("box"))
        self.assertEqual(fleet["machines"], {"here": {"ssh": "me@here", "id": "here-machine-id"},
                                             "box": {"ssh": "box", "id": "box-machine-id"}})
        self.assertEqual(fleet["projects"], {"proof": {"paths": {"here": str(self.root), "box": str(clone)}}})
        self.assertEqual(self.git(self.root, "remote", "get-url", "box"), f"box:{clone}")
        self.assertEqual(self.git(clone, "remote", "get-url", "here"), f"me@here:{self.root}")
        self.assertEqual(self.git(clone, "config", "remote.here.agentic-fleet"), "true")

    def test_join_twice_changes_nothing(self):
        self.join()
        fleet, remotes = self.fleet_file("box"), self.git(self.clone("box"), "remote", "-v")
        self.join()
        self.assertEqual(self.fleet_file("box"), fleet)
        self.assertEqual(self.git(self.clone("box"), "remote", "-v"), remotes)

    def test_listing_reports_a_main_branch_ahead_and_never_pulls_it(self):
        self.join()
        before = self.git(self.root, "rev-parse", "main")
        clone = self.clone("box")
        (clone / "ahead.txt").write_text("only on box\n")
        self.git(clone, "add", "ahead.txt")
        self.git(clone, "commit", "-m", "ahead on box")
        report = json.loads(self.repo.command("fleet", "--json").stdout)
        self.assertEqual(report["this_machine"], "here")
        box = next(machine for machine in report["machines"] if machine["name"] == "box")
        self.assertTrue(box["reachable"])
        self.assertEqual(box["main_branch"], {"only_there": 1, "only_here": 0})
        self.assertIn("git pull --ff-only box main", report["warnings"][0])
        self.assertEqual(self.git(self.root, "rev-parse", "main"), before)
        listing = self.repo.command("fleet").stdout
        self.assertIn("its main is 1 commit(s) ahead", listing)
        self.assertIn("Warning: box's main is 1 commit(s) ahead", listing)
        # Seen from box, this machine is behind, and nothing warns there.
        report = json.loads(self.on("box", "fleet", "--json").stdout)
        here = next(machine for machine in report["machines"] if machine["name"] == "here")
        self.assertEqual(here["main_branch"], {"only_there": 0, "only_here": 1})
        self.assertEqual(report["warnings"], [])

    def test_overview_lists_the_campaigns_of_every_machine_both_ways(self):
        self.join()
        self.repo.init_campaign()
        self.init_on("box", "remote-one")
        report = json.loads(self.repo.command("overview", "--fleet", "--json").stdout)
        campaigns = {machine["name"]: [c["slug"] for c in machine["campaigns"]] for machine in report["machines"]}
        self.assertEqual(campaigns, {"here": ["harness-sample"], "box": ["remote-one"]})
        self.assertTrue(report["machines"][0]["self"])
        report = json.loads(self.on("box", "overview", "--fleet", "--json").stdout)
        campaigns = {machine["name"]: [c["slug"] for c in machine["campaigns"]] for machine in report["machines"]}
        self.assertEqual(campaigns, {"box": ["remote-one"], "here": ["harness-sample"]})
        text = self.repo.command("overview", "--fleet").stdout
        self.assertIn("== here (this machine)", text)
        self.assertIn("== box\nCampaign remote-one", text)

    def test_an_unreachable_machine_shows_the_campaigns_last_seen(self):
        self.join()
        self.init_on("box", "remote-one")
        self.repo.command("overview", "--fleet", "--json")
        (self.hosts / "box" / "env").rename(self.hosts / "box" / "env.off")
        report = json.loads(self.repo.command("overview", "--fleet", "--json").stdout)
        box = next(machine for machine in report["machines"] if machine["name"] == "box")
        self.assertFalse(box["reachable"])
        self.assertIn("Connection refused", box["error"])
        self.assertTrue(box["seen_at"])
        self.assertEqual([c["slug"] for c in box["campaigns"]], ["remote-one"])
        text = self.repo.command("overview", "--fleet").stdout
        self.assertIn("== box — unreachable", text)
        self.assertIn("last seen", text)
        self.assertIn("Campaign remote-one", text)

    def test_init_refuses_a_slug_that_exists_on_another_machine(self):
        self.join()
        self.init_on("box", "harness-sample")
        result = self.repo.command("init", "SPEC.md", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("campaign harness-sample already exists on box", result.stderr)
        self.assertNotIn("campaign/harness-sample", self.git(self.root, "branch", "--list", "campaign/*"))

    def test_init_warns_about_a_main_branch_behind_and_an_unreachable_machine(self):
        self.join()
        self.host("cave")
        self.join("cave")
        clone = self.clone("box")
        (clone / "ahead.txt").write_text("only on box\n")
        self.git(clone, "add", "ahead.txt")
        self.git(clone, "commit", "-m", "ahead on box")
        (self.hosts / "cave" / "env").rename(self.hosts / "cave" / "env.off")
        result = self.repo.init_campaign()
        self.assertIn("Warning: box's main is 1 commit(s) ahead", result.stdout)
        self.assertIn("Warning: cave did not answer", result.stdout)

    def test_join_into_an_existing_clone_leaves_its_main_branch_alone(self):
        clone = self.clone("box")
        subprocess.run(["git", "clone", "-q", str(self.root), str(clone)], check=True)
        self.git(clone, "config", "user.email", "box@example.test")
        self.git(clone, "config", "user.name", "Box")
        (clone / "local.txt").write_text("only on box\n")
        self.git(clone, "add", "local.txt")
        self.git(clone, "commit", "-m", "box's own work")
        head = self.git(clone, "rev-parse", "HEAD")
        result = self.join()
        self.assertIn("box already has a clone", result.stdout)
        self.assertEqual(self.git(clone, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(clone, "remote", "get-url", "here"), f"me@here:{self.root}")

    def test_join_refuses_another_repository(self):
        clone = self.clone("box")
        clone.mkdir(parents=True)
        self.git(clone, "init", "-q")
        self.git(clone, "-c", "user.email=x@example.test", "-c", "user.name=X", "commit", "-q", "--allow-empty", "-m", "other")
        result = self.join(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("holds another repository", result.stderr)
        self.assertIsNone(self.fleet_file("here"))

    def test_a_third_machine_joins_everyone(self):
        self.join()
        self.host("cave")
        self.join("cave")
        for name in ("here", "box", "cave"):
            self.assertEqual(sorted(self.fleet_file(name)["machines"]), ["box", "cave", "here"])
        self.assertEqual(self.git(self.clone("box"), "remote", "get-url", "cave"), f"cave:{self.clone('cave')}")
        self.assertEqual(self.git(self.clone("cave"), "remote", "get-url", "box"), f"box:{self.clone('box')}")
        self.assertEqual(self.git(self.clone("cave"), "remote", "get-url", "here"), f"me@here:{self.root}")
        # Any machine runs the fleet commands: box lists cave's campaigns.
        self.init_on("cave", "in-the-cave")
        report = json.loads(self.on("box", "overview", "--fleet", "--json").stdout)
        self.assertEqual([c["slug"] for m in report["machines"] if m["name"] == "cave" for c in m["campaigns"]],
                         ["in-the-cave"])

    def test_leave_forgets_the_machine_everywhere(self):
        self.join()
        self.host("cave")
        self.join("cave")
        result = self.repo.command("fleet", "leave", "box")
        self.assertIn("box left the fleet", result.stdout)
        self.assertIsNone(self.fleet_file("box"))
        for name in ("here", "cave"):
            self.assertEqual(sorted(self.fleet_file(name)["machines"]), ["cave", "here"])
            self.assertEqual(sorted(self.fleet_file(name)["projects"]["proof"]["paths"]), ["cave", "here"])
        self.assertNotIn("box", self.git(self.root, "remote").split())
        self.assertNotIn("box", self.git(self.clone("cave"), "remote").split())
        self.assertEqual(self.git(self.clone("box"), "remote"), "")

    def test_join_reports_a_machine_that_cannot_reach_back(self):
        result = self.repo.command("fleet", "join", "box", "--ssh", "box", "--as", "here", "--as-ssh", "me@nowhere",
                                   "--path", str(self.clone("box")), check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("box cannot reach here's clone at me@nowhere", result.stdout)
        # box got a key of its own, to authorize here.
        key = (self.hosts / "box" / "home" / ".ssh" / "id_ed25519.pub").read_text().strip()
        self.assertIn(f"authorize this key of box there: {key}", result.stdout)
        self.assertEqual(self.fleet_file("box")["machines"]["here"]["ssh"], "me@nowhere")

    def test_a_remote_the_fleet_did_not_add_is_left_alone(self):
        self.git(self.root, "remote", "add", "box", "https://example.test/elsewhere.git")
        result = self.join(check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("left as it is", result.stdout)
        self.assertEqual(self.git(self.root, "remote", "get-url", "box"), "https://example.test/elsewhere.git")

    def test_the_clone_and_the_address_have_defaults(self):
        (self.hosts / "box" / "env").write_text(
            (self.hosts / "box" / "env").read_text() + "SSH_CONNECTION='10.0.0.9 50000 10.0.0.22 22'\n")
        # This home holds the repository: the clone goes at the same place under box's home.
        home = self.root.parent
        result = self.repo.command("fleet", "join", "box", "--ssh", "box", "--as", "here", check=False,
                                   env={"HOME": str(home)})
        expected = self.hosts / "box" / "home" / self.root.name
        fleet = self.fleet_file("box")
        self.assertEqual(fleet["projects"]["proof"]["paths"]["box"], str(expected))
        self.assertTrue((expected / ".agentic").is_dir())
        user = subprocess.run(["id", "-un"], text=True, capture_output=True, check=True).stdout.strip()
        self.assertEqual(fleet["machines"]["here"]["ssh"], f"{user}@10.0.0.9")
        # here's address is unknown to the fake ssh: box cannot reach back, and says so.
        self.assertEqual(result.returncode, 3)

    def test_a_loopback_address_needs_as_ssh(self):
        (self.hosts / "box" / "env").write_text(
            (self.hosts / "box" / "env").read_text() + "SSH_CONNECTION='127.0.0.1 50000 127.0.0.1 22'\n")
        result = self.repo.command("fleet", "join", "box", "--ssh", "box", "--as", "here",
                                   "--path", str(self.clone("box")), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pass --as-ssh", result.stderr)
        self.assertFalse(self.clone("box").exists())

    def test_commands_reach_a_campaign_wherever_it_is(self):
        self.join()
        self.repo.init_campaign()
        self.init_on("box", "remote-one")
        # From the main worktree, on this machine's campaign and on box's.
        here = json.loads(self.repo.command("status", "--campaign", "harness-sample", "--json").stdout)
        self.assertEqual(here["campaign"], "harness-sample")
        result = self.repo.command("status", "--campaign", "remote-one", "--json")
        self.assertEqual(json.loads(result.stdout)["campaign"], "remote-one")
        self.assertIn("campaign status on box (remote-one)", result.stderr)
        self.repo.command("stop", "--campaign", "remote-one", "--on", "box")
        campaign = next(Path(self.envs["box"]["AGENTIC_CACHE"]).rglob("remote-one/campaign.json"))
        self.assertEqual(json.loads(campaign.read_text())["desired"], "stopped")
        # And from box, on this machine's campaign.
        status = json.loads(self.on("box", "status", "--campaign", "harness-sample", "--json").stdout)
        self.assertEqual(status["campaign"], "harness-sample")

    def test_a_routed_command_says_where_the_campaign_is_not(self):
        self.join()
        result = self.repo.command("status", "--campaign", "nowhere", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no machine of the fleet holds campaign nowhere", result.stderr)
        result = self.repo.command("status", "--campaign", "nowhere", "--on", "ghost", check=False)
        self.assertIn("no machine ghost in the fleet", result.stderr)
        result = self.repo.command("status", "--on", "box", check=False)
        self.assertIn("--on needs --campaign SLUG", result.stderr)

    # Moving a campaign, and finalizing it from any machine.

    def wait(self, condition, seconds=40, message="condition"):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if condition():
                return
            time.sleep(0.2)
        self.fail(f"timed out waiting for {message}")

    def box_runtime(self, slug):
        return next(Path(self.envs["box"]["AGENTIC_CACHE"]).rglob(f"{slug}/campaign.json")).parent

    def test_a_campaign_moves_with_its_uncommitted_work_and_back(self):
        self.join()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.repo.env.update(MOCK_TRACK_DIR=str(Path(self.repo.cache.name) / "track"), MOCK_SLEEP="60")
        self.repo.command("run", "--provider", "mock", "--mode", "unattended", cwd=self.repo.worktree)
        self.wait(lambda: (Path(self.repo.cache.name) / "track" / "active").exists(), message="the worker to start")
        self.repo.command("stop", "--now", cwd=self.repo.worktree)
        # What an interrupted worker leaves: a new file, a deleted one.
        ticket_tree = next(Path(self.repo.cache.name).rglob("worktrees/TST-001"))
        (ticket_tree / "partial.txt").write_text("half done\n")
        (ticket_tree / "README.md").unlink()
        result = self.repo.command("move", "--to", "box", "--no-start", cwd=self.repo.worktree)
        self.assertIn("Carrying the uncommitted work of TST-001", result.stdout)
        self.assertIn("Campaign harness-sample moved to box", result.stdout)
        # Here: a tombstone, nothing else.
        self.assertEqual(self.git(self.root, "branch", "--list", "campaign/*", "agentic/*"), "")
        self.assertEqual(self.git(self.root, "for-each-ref", "refs/agentic/"), "")
        overview = json.loads(self.repo.command("overview", "--json").stdout)
        self.assertEqual(overview["campaigns"], [])
        self.assertEqual(overview["moved"][0]["moved_to"], "box")
        # There: the campaign, its worktrees and the uncommitted work, still uncommitted.
        runtime = self.box_runtime("harness-sample")
        campaign = json.loads((runtime / "campaign.json").read_text())
        self.assertEqual((campaign["epoch"], campaign["moved_from"], campaign["desired"]), (1, "here", "stopped"))
        moved_tree = runtime / "worktrees" / "TST-001"
        self.assertEqual((moved_tree / "partial.txt").read_text(), "half done\n")
        self.assertFalse((moved_tree / "README.md").exists())
        self.assertIn("partial.txt", self.git(moved_tree, "ls-files", "--others", "--exclude-standard"))
        self.assertEqual(self.git(moved_tree, "diff", "--name-status"), "D\tREADME.md")
        self.assertEqual(self.git(moved_tree, "diff", "--cached", "--name-only"), "")
        self.assertIn("campaign-moved", (runtime / "events" / "campaign.ndjson").read_text())
        # It runs there, driven from here, and ends.
        with (self.hosts / "box" / "env").open("a") as file:
            file.write(f"AGENTIC_PROVIDER_DIR={shlex.quote(self.repo.env['AGENTIC_PROVIDER_DIR'])}\nMOCK_SLEEP=0\n")
        self.repo.command("run", "--campaign", "harness-sample", "--provider", "mock", "--mode", "unattended",
                          env={"AGENTIC_CLAUDE_MODEL": "sonnet"})
        # The settings of the caller travel; its paths do not.
        moved_env = json.loads((runtime / "run-config.json").read_text())["env"]
        self.assertEqual(moved_env["AGENTIC_CLAUDE_MODEL"], "sonnet")
        self.assertEqual(moved_env["AGENTIC_CACHE"], self.envs["box"]["AGENTIC_CACHE"])
        self.wait(lambda: not json.loads(self.repo.command("status", "--campaign", "harness-sample", "--json").stdout)
                  ["runner"]["active"], message="the run on box to end")
        states = json.loads(self.repo.command("status", "--campaign", "harness-sample", "--json").stdout)["tickets"]
        self.assertEqual([item["status"] for item in states], ["done"])
        # And it comes back, asked from here.
        result = self.repo.command("move", "--campaign", "harness-sample", "--to", "here", "--no-start")
        self.assertIn("campaign move on box (harness-sample)", result.stderr)
        local = json.loads(next(Path(self.repo.cache.name).rglob("harness-sample/campaign.json")).read_text())
        self.assertEqual((local["epoch"], local["moved_from"]), (2, "box"))
        self.assertEqual(json.loads(self.repo.command("status", "--campaign", "harness-sample", "--json").stdout)
                         ["tickets"][0]["status"], "done")

    def test_finalize_brings_the_campaign_here_and_lands_in_this_main_branch(self):
        self.join()
        self.init_on("box", "remote-one")
        tree = self.box_runtime("remote-one") / "worktrees" / "campaign"
        (tree / "campaigns" / "remote-one" / "tickets").mkdir(parents=True, exist_ok=True)
        (tree / "campaigns" / "remote-one" / "tickets" / "TST-001.md").write_text(ticket(status="done"))
        (tree / "campaigns" / "remote-one" / "validation.json").write_text(json.dumps({"version": 1, "tickets": {
            "TST-001": {"cheap": [["git", "diff", "--check", "HEAD"]], "component": [], "expensive": []}},
            "final": [["git", "diff", "--check", "HEAD"]]}))
        (tree / "made-on-box.txt").write_text("from box\n")
        self.git(tree, "add", "-A")
        self.git(tree, "commit", "-m", "work done on box")
        result = self.repo.command("finalize", "--campaign", "remote-one")
        self.assertIn("Bringing remote-one here from box", result.stdout)
        self.assertIn("finalized into main", result.stdout)
        self.assertEqual((self.root / "made-on-box.txt").read_text(), "from box\n")
        self.assertNotIn("remote-one", self.git(self.root, "branch", "--list"))
        self.assertNotIn("remote-one", self.git(self.clone("box"), "branch", "--list"))

    def test_a_target_that_cannot_take_the_campaign_leaves_it_here(self):
        self.join()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        result = self.repo.command("move", "--to", "cave", cwd=self.repo.worktree, check=False)
        self.assertIn("cave holds no clone of proof", result.stderr)
        # box already has a branch of that campaign.
        self.git(self.clone("box"), "branch", "campaign/harness-sample")
        result = self.repo.command("move", "--to", "box", cwd=self.repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("box cannot take campaign harness-sample: campaign: campaign harness-sample already exists here",
                      result.stderr)
        status = json.loads(self.repo.command("status", "--json", cwd=self.repo.worktree).stdout)
        self.assertEqual(status["runner"]["desired"], "running")
        self.assertNotIn("moving", json.loads(next(Path(self.repo.cache.name).rglob("harness-sample/campaign.json")).read_text()))

    def test_a_machine_that_is_also_an_executor_never_sends_work_to_itself(self):
        settings = json.loads((self.root / ".agentic" / "project.json").read_text())
        settings["executors"] = [{"name": "here", "ssh": "here", "workers": 1}]
        (self.root / ".agentic" / "project.json").write_text(json.dumps(settings))
        self.repo.git("commit", "-qam", "here is an executor too")
        self.join()
        self.repo.init_campaign()
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.repo.command("run", "--provider", "mock", cwd=self.repo.worktree)
        events = next(Path(self.repo.cache.name).rglob("campaign.ndjson")).read_text()
        started = [json.loads(line) for line in events.splitlines() if '"runner-started"' in line][0]
        self.assertNotIn("executors=", started["message"])

    # Phase 2: the join leaves the machine ready, or says exactly what is left.

    MOCK_ADAPTER = """\
#!/usr/bin/env bash
state=${MOCK_PROVIDER_STATE:?}
case $1 in
  --ready) [ -f "$state/installed" ] || exit 69; [ -f "$state/signed-in" ] || { echo 'not signed in' >&2; exit 77; }; exit 0 ;;
  --install) touch "$state/installed"; [ "${MOCK_SIGNED_IN_AFTER_INSTALL:-}" = 1 ] && touch "$state/signed-in"; exit 0 ;;
  --login) touch "$state/signed-in" ;;
  --preflight) [ ! -f "$state/preflight-fails" ] || { echo 'missing option --json-schema' >&2; exit 69; }; exit 0 ;;
esac
"""

    def with_claude_skill(self):
        skill = self.root / ".claude" / "skills" / "run-campaign"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text("run\n")
        self.repo.git("add", ".claude")
        self.repo.git("commit", "-m", "claude skills")

    def mock_provider_on(self, name, *states, **env):
        adapters = self.hosts / name / "adapters"
        (adapters / "claude").mkdir(parents=True)
        adapter = adapters / "claude" / "run.sh"
        adapter.write_text(self.MOCK_ADAPTER)
        adapter.chmod(0o755)
        state = self.hosts / name / "provider-state"
        state.mkdir()
        for item in states:
            (state / item).touch()
        with (self.hosts / name / "env").open("a") as file:
            file.write(f"AGENTIC_PROVIDER_DIR={shlex.quote(str(adapters))}\nMOCK_PROVIDER_STATE={shlex.quote(str(state))}\n")
            for key, value in env.items():
                file.write(f"{key}={shlex.quote(value)}\n")
        return state

    def test_a_provider_that_is_not_signed_in_is_left_to_sign_in(self):
        self.with_claude_skill()
        self.mock_provider_on("box", "installed")
        result = self.join(check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn(f"sign in to claude on box: ssh -t box 'cd {self.clone('box')} && .agentic/providers/claude/run.sh --login'",
                      result.stdout)

    def test_a_missing_provider_is_installed(self):
        self.with_claude_skill()
        state = self.mock_provider_on("box", MOCK_SIGNED_IN_AFTER_INSTALL="1")
        result = self.join()
        self.assertTrue((state / "installed").exists())
        self.assertIn("claude is ready on box", result.stdout)
        self.assertIn("every command works there", result.stdout)

    def test_a_failing_preflight_is_pending(self):
        self.with_claude_skill()
        self.mock_provider_on("box", "installed", "signed-in", "preflight-fails")
        result = self.join(check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("the preflight of claude fails on box: missing option --json-schema", result.stdout)

    def restricted_path(self, name, without, extra=None):
        """A PATH for the fake machine NAME with every system command but WITHOUT, plus the EXTRA scripts."""
        folder = self.hosts / name / "bin"
        folder.mkdir()
        hidden = set(without) | {"sudo", "pacman", "apt-get", "dnf", "zypper"} | set(extra or {})
        for program in Path("/usr/bin").iterdir():
            if program.name not in hidden and not (folder / program.name).exists():
                (folder / program.name).symlink_to(program)
        for script, text in (extra or {}).items():
            (folder / script).write_text(text)
            (folder / script).chmod(0o755)
        with (self.hosts / name / "env").open("a") as file:
            file.write(f"PATH={shlex.quote(str(folder))}\n")
        return folder

    def test_missing_commands_without_sudo_are_left_with_the_command(self):
        self.restricted_path("box", {"jq", "rsync"}, {"pacman": "#!/bin/sh\nexit 0\n"})
        result = self.join(check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("install the commands jq rsync on box, as root: sudo env sh -c 'pacman -S --needed --noconfirm jq rsync'",
                      result.stdout)
        # Without jq the kit cannot run there, and the join says so.
        self.assertIn("the campaign commands fail on box", result.stdout)

    def test_missing_commands_are_installed_with_sudo(self):
        folder = self.hosts / "box" / "bin"
        pacman = f"""#!/bin/sh
# Installs by linking the real programs into this machine's PATH.
for package do case $package in -*) ;; *) ln -sf /usr/bin/$package {folder}/$package ;; esac; done
"""
        sudo = """#!/bin/sh
[ "$1" = -n ] && shift
[ "$1" = true ] && exit 0
exec "$@"
"""
        self.restricted_path("box", {"jq", "rsync"}, {"pacman": pacman, "sudo": sudo})
        result = self.join()
        self.assertIn("Installing on box: jq rsync", result.stdout)
        self.assertTrue((folder / "jq").exists())
        self.assertIn("every command works there", result.stdout)

    def test_a_user_that_does_not_linger_is_pending(self):
        loginctl = """#!/bin/sh
case $1 in show-user) echo no ;; enable-linger) echo 'Access denied' >&2; exit 1 ;; esac
"""
        self.restricted_path("box", set(), {"loginctl": loginctl})
        result = self.join(check=False)
        self.assertEqual(result.returncode, 3)
        user = subprocess.run(["id", "-un"], text=True, capture_output=True, check=True).stdout.strip()
        self.assertIn(f"campaigns on box would stop with the session that started them: run there, as root, "
                      f"loginctl enable-linger {user}", result.stdout)

    def test_the_project_files_and_setup_reach_the_new_clone(self):
        (self.root / "config").mkdir()
        (self.root / "config" / "local.env").write_text("SECRET=1\n")
        Path(self.envs["here"]["AGENTIC_FLEET"]).parent.mkdir(parents=True, exist_ok=True)
        Path(self.envs["here"]["AGENTIC_FLEET"]).write_text(json.dumps({"machines": {}, "projects": {"proof": {
            "paths": {}, "files": ["config/local.env"], "setup": ["bash", "-c", "cat config/local.env > setup.out"]}}}))
        result = self.join()
        clone = self.clone("box")
        self.assertEqual((clone / "config" / "local.env").read_text(), "SECRET=1\n")
        self.assertEqual((clone / "setup.out").read_text(), "SECRET=1\n")
        self.assertIn("Running the setup of proof on box", result.stdout)
        self.assertEqual(self.fleet_file("box")["projects"]["proof"]["setup"], ["bash", "-c", "cat config/local.env > setup.out"])

    def test_a_failing_setup_is_pending(self):
        Path(self.envs["here"]["AGENTIC_FLEET"]).parent.mkdir(parents=True, exist_ok=True)
        Path(self.envs["here"]["AGENTIC_FLEET"]).write_text(json.dumps({"machines": {}, "projects": {"proof": {
            "paths": {}, "files": ["missing.env"], "setup": ["false"]}}}))
        result = self.join(check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("missing.env (files of proof in the fleet file) does not exist in this clone", result.stdout)
        self.assertIn("the setup of proof failed on box (exit 1): false", result.stdout)

    def test_without_a_fleet(self):
        self.assertIn("No fleet holds proof", self.repo.command("fleet").stdout)
        report = json.loads(self.repo.command("overview", "--fleet", "--json").stdout)
        self.assertEqual(len(report["machines"]), 1)
        self.assertTrue(report["machines"][0]["self"])
        self.assertIsNone(report["this_machine"])


if __name__ == "__main__":
    unittest.main()

# Stakhanov

A campaign runner for coding agents. You write a spec and a set of tickets; a deterministic supervisor
(no model of its own) schedules them across parallel workers, validates each ticket, has a fresh reviewer
check it, and integrates the result into your main branch with a fast-forward. Workers, reviewers and
diagnosticians are `claude`, `codex` or `grok` processes; any one of them is enough.

The name: Alexei Stakhanov was the Soviet miner who cut fourteen times his quota of coal in a single shift.
Here the agents work the shifts.

## Flow

```
/grilling            stress-test the plan with the user (no files written)
   |
/to-spec             write the spec, then: campaign init <spec> --slug <name>   (from the main branch)
   |                 -> branch campaign/<slug> and its worktree
/to-tickets          tickets + validation.json, committed on the campaign branch; campaign verify
   |
/run-campaign        runner: workers -> validation -> review -> integration, in parallel
   |                 campaign-watch wakes the coordinator only when it is needed
/finalize-campaign   final validation, cleanup, git merge --ff-only into the main branch
```

`/grilling`, `/to-spec` and `/to-tickets` are Matt Pocock's skills (https://github.com/mattpocock/skills),
used unmodified. They are not stored in this kit: `install.sh` downloads them from his repository when it
installs, and only when a skill is missing. `/run-campaign`, `/finalize-campaign` and `/campaign-status` are
shipped here, for each provider.

Matt's skills publish wherever `docs/agents/issue-tracker.md` tells them to. The installer writes that file so that
`/to-spec` and `/to-tickets` publish into a campaign instead of into issues. It is exactly the "Other" tracker
configuration his `/setup-matt-pocock-skills` would write.

Documents installed with the engine, in `.agentic/`: `README.md` (what the runner enforces, the settings and
the environment variables), `WORKFLOW.md`, `SPEC.md`, `TICKET.md`, `VALIDATION.md`, `RUN-CAMPAIGN.md`,
`FINALIZE-CAMPAIGN.md` and `roles/`.

## Requirements

- Linux. macOS is not supported.
- `bash`, `git`, `jq`, `python3`, `flock`, `setsid`, `curl`, `tar` and the usual coreutils. No ripgrep. The
  installer installs the missing ones (see below); with `--no-machine-setup` you provide them.
- At least one provider CLI: `claude`, `codex` or `grok`. The installer installs it when it is missing.
- Optional: a working user systemd, so the engine runs in the user's `background.slice`.
- Optional: `ssh` and `rsync`, here and on the hosts, to run workers on remote executors (`executors` in
  `.agentic/project.json`).

## Install

```
./install.sh [--providers claude,codex,grok] [--update [--force]] [--replace-tracker]
             [--yes] [--no-machine-setup] [--matt-ref REF] <project-dir>
```

One command prepares the machine, then installs the kit in the project. `<project-dir>` must be the top level
of a Git work tree.

### Machine setup (runs first)

1. **System commands.** Any of `git`, `jq`, `python3`, `flock`, `setsid`, `curl` and `tar` that is missing (and
   `npm`, only when a `codex` or `grok` CLI has to be installed) is installed through the package manager found
   (`pacman`, `apt-get`, `dnf` or `zypper`), with `sudo` unless you are root. The installer prints the exact
   command and asks `Install? [y/N]` (default no). With no supported package manager, or when you decline, it
   stops and lists what to install by hand.
2. **Provider CLIs.** The providers are `--providers`; else those whose CLI is on `PATH`; else `claude`. A
   missing CLI is installed after the same question: `claude` with its official installer
   (`curl -fsSL https://claude.ai/install.sh | bash`), `codex` with `npm install -g @openai/codex`, `grok` with
   `npm install -g @xai-official/grok`. If the command is not on `PATH` afterwards, the installer says which
   directory to add. It never logs in: at the end it lists the CLIs it installed, which you must open once to
   sign in.
3. **Matt Pocock's skills** (`grilling`, `to-spec`, `to-tickets`). For each selected provider, each one that is
   not found (see the last item below) is installed unmodified from
   https://github.com/mattpocock/skills at the machine level: `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/` for claude,
   `~/.codex/skills/` for codex, `~/.grok/skills/` for grok. The archive is downloaded once per run
   (`https://codeload.github.com/mattpocock/skills/tar.gz/main`; `--matt-ref REF` picks another ref), each skill is
   located by name and copied whole, and a skill that already exists is never overwritten. No question is asked
   (user-level files, no `sudo`), and nothing goes into the project. If the download fails, the installer warns
   and installs the project anyway. His skills are fetched at install time; the kit does not store them.

`--yes` skips the questions of steps 1 and 2. `--no-machine-setup` skips steps 1 to 3 (for CI): the commands
must already be there, and a missing Matt skill only produces a warning.

### Project install

`<project-dir>` gets this (the project install is the same with or without the machine setup). The installer:

- copies `agentic/` to `<project>/.agentic/` (refuses if it exists, or if it is a symlink; `--update` replaces
  everything except `project.json`, and refuses while `.agentic` holds files the kit does not ship, unless
  `--force` deletes them);
- creates `.agentic/project.json` when missing, with the project name and the detected main branch (`main`, else
  `master`, else the current branch);
- copies the skills of each provider to `.claude/skills/`, `.codex/skills/` and `.grok/skills/`. Default: every
  provider whose CLI is on `PATH`, else `claude`; with `--update`, the providers whose skills are already
  installed;
- creates `docs/agents/issue-tracker.md` when missing. An existing file that differs from the template is kept,
  with a warning: `/to-spec` and `/to-tickets` would publish wherever it says, not into campaigns. Only
  `--replace-tracker` overwrites it, `--update` included;
- inserts the workflow rules between `<!-- stakhanov:start -->` and `<!-- stakhanov:end -->` in `AGENTS.md`,
  creating it when missing. Text outside the markers is never touched. `CLAUDE.md` is never touched: Codex and
  Grok read only `AGENTS.md`, and Claude Code reads it too (if yours does not, add the line `@AGENTS.md` to
  `CLAUDE.md` yourself). A `## Agent skills` section outside the markers, in `AGENTS.md` or `CLAUDE.md`, conflicts with
  the block and is reported;
- looks for `grilling`, `to-spec` and `to-tickets` where Matt's README installs them (`~/.<provider>/skills`,
  `<project>/.<provider>/skills`, a plugin under `~/.<provider>/plugins`, and `.agents/skills` in the project and
  in the home directory, where `npx skills add` puts them). That detection decides what the machine setup
  installs, and afterwards the installer warns "could not confirm skill X" only for a skill that is still missing
  (the download failed, or `--no-machine-setup`).

The installer never commits. A Claude Code plugin install of Matt's skills names the commands
`/mattpocock-skills:grilling`, `/mattpocock-skills:to-spec`, and so on, instead of `/grilling` and `/to-spec`.

### Then

1. Edit `.agentic/project.json` if needed (required checks, time zone, archive folder, remote executors).
2. Commit `.agentic`, the provider skills, `AGENTS.md` and `docs/agents/issue-tracker.md` on the main branch.
   Do this before `/to-spec`: `campaign init` refuses a main branch without the committed kit, because the
   campaign worktree and the engine come from the committed branch. The same goes for later edits of
   `project.json`: they apply once committed.
3. `/grilling` -> `/to-spec` -> `/to-tickets` -> `/run-campaign` -> `/finalize-campaign`.

If you later run `/setup-matt-pocock-skills` in the project, choose the "Other" tracker and keep
`docs/agents/issue-tracker.md` as it is; do not let it point to a hosted tracker or to `.scratch/`.

## Configuration

The settings (`.agentic/project.json`) and every `AGENTIC_*` environment variable are documented in
`agentic/README.md`, installed as `.agentic/README.md`. The effective `project.json` is the main branch's
committed copy.

Remote executors: `executors` in `project.json` lists machines (reached over ssh) that run workers next to the local
ones. The engine still does everything else here (worktrees, commits, validation, review, integration); each worker
invocation syncs the ticket worktree there and back, and falls back to this machine when the host is unreachable.

Claude accounts: `AGENTIC_CLAUDE_ACCOUNTS=udarnik` (or any command with the same `account` subcommands) lets the Claude
adapter run in the hook's current account and retry once in another one after a usage limit.

## Layout

```
agentic/        engine, installed as <project>/.agentic/
  bin/          campaign (the supervisor), campaign-watch
  lib/          shared shell and Python helpers, remote-run.sh (worker invocations on an executor)
  providers/    claude, codex and grok adapters, RESULT parsing
  roles/        worker, reviewer and diagnostician prompts
  tests/        engine tests, run by `campaign self-test`
  *.md          the documents listed under Flow
skills/         /run-campaign, /finalize-campaign and /campaign-status per provider
templates/      the block inserted into AGENTS.md and the tracker configuration
tests/          installer tests
install.sh
```

## Developing the kit

```
python3 -m unittest discover -s agentic/tests -p 'test_*.py'   # engine (mock providers, temporary repos)
bash agentic/tests/provider-adapters.sh                        # adapter arguments and RESULT parsing
agentic/bin/campaign self-test                                 # both, as installed in a project
bash tests/install.sh                                          # the installer (temporary repos and homes, stubbed network, sudo and package managers)
```

The tests never call a real model: providers are mocks and every repository is temporary.

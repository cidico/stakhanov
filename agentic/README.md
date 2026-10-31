# Campaign runner

`.agentic/bin/campaign` is the deterministic supervisor for campaigns. It has no model; it launches
provider processes through `.agentic/providers/<provider>/run.sh` and owns all routine filesystem, Git,
validation, and subprocess mutations. Agent-facing rules live in `WORKFLOW.md` and `roles/`; this file
documents what the runner enforces so those rules do not have to repeat it.

## Configuration

`.agentic/project.json` holds the per-project settings. A missing file means defaults; an invalid one stops
every command. `project.json.example` is a starting point, and the installer creates the file from it with the
project name and the detected main branch.

The effective settings are the main branch's committed copy (`git show <main>:.agentic/project.json`), for
every command, whether it runs in the main worktree or in a campaign worktree. The local file is read only to
find `main_branch`, and is the fallback while the main branch has no committed copy. An uncommitted edit to
`project.json` therefore changes nothing: commit it on the main branch.

| Field | Meaning |
| --- | --- |
| `name` | Project name used in role prompts. |
| `main_branch` | Branch campaigns start from and integrate into. Default: `main` if it exists, else `master`, else an error. A configured branch that does not exist is an error. |
| `instruction_files` | Names (no slash) of the instruction files roles read at the root and in every touched area. Default `["AGENTS.md", "CLAUDE.md"]`. The runner rejects a worker delta that edits any of them (root or scoped, a rename with `git mv` included), like `.agentic/*`, `.claude/*`, `.codex/*`, `.grok/*` and the campaign planning files. |
| `env` | String map exported to the runner, the workers and the validation commands (only variables not already set). `project.json` is committed, so never put a secret in it. The runner refuses `PATH`, `HOME`, `IFS`, `ENV`, `BASH_ENV`, `BASHOPTS`, `SHELLOPTS`, `PS4`, `GIT_*`, `LD_*` and `PYTHON*`, which would redirect the runner itself; everything else, `AGENTIC_*` included, is allowed. |
| `required_checks` | Argv arrays that every ticket's `cheap` phase and the plan's `final` list must contain; `campaign verify` refuses a plan without them, and finalize checks again before the final validation. |
| `timezone` | Display zone for local times. Precedence: `AGENTIC_DISPLAY_TZ`, then this field, then the system zone. |
| `archive_dir` | Where finalize archives the campaign history, relative to the main worktree, with `{date}` and `{slug}` placeholders; used only when Git ignores it. Default: the `archive/` folder of the cache. |
| `executors` | Remote machines that run workers and offloaded commands; see [Remote executors](#remote-executors). Default: none, every role runs on this machine. |

`name` is also how the machines of a [fleet](#fleet) know the project.

### Environment variables

| Variable | Effect |
| --- | --- |
| `AGENTIC_CACHE` | Runtime state, prompts, results and logs. Default `${XDG_CACHE_HOME:-~/.cache}/agentic`. |
| `AGENTIC_DISPLAY_TZ` | Display zone for local times. |
| `AGENTIC_AUTO_RECOVERIES` | Automatic recoveries of a technically blocked ticket (default 2, one digit). |
| `AGENTIC_WORKER_TIMEOUT_SECONDS` | Worker deadline (default 3600). |
| `AGENTIC_REVIEWER_TIMEOUT_SECONDS` | Reviewer deadline (default 1200). |
| `AGENTIC_DIAGNOSTICIAN_TIMEOUT_SECONDS` | Diagnostician deadline (default 1200). |
| `AGENTIC_RESCAN_SECONDS` | Ticket queue rescan while a worker slot is free (default 60). |
| `AGENTIC_QUEUE_POLL_SECONDS` | Campaign queue poll interval (default 60). |
| `AGENTIC_QUEUE_RELAUNCH_SECONDS` | Campaign queue relaunch delay (default 300). |
| `AGENTIC_PROVIDER_DIR` | Alternate adapter directory: `<dir>/<provider>/run.sh` replaces `.agentic/providers/<provider>/run.sh`. For tests and custom adapters. |
| `AGENTIC_CLAUDE_MODEL`, `AGENTIC_CLAUDE_{WORKER,REVIEWER,DIAGNOSTICIAN}_MODEL` | Claude model (default `opus`); the role variable wins over the provider-wide one. |
| `AGENTIC_CLAUDE_EFFORT`, `AGENTIC_CLAUDE_{WORKER,REVIEWER,DIAGNOSTICIAN}_EFFORT` | Claude effort (default `high`). |
| `AGENTIC_CODEX_MODEL` | Codex model; unset means the CLI default. |
| `AGENTIC_CODEX_EFFORT`, `AGENTIC_CODEX_{WORKER,REVIEWER,DIAGNOSTICIAN}_EFFORT` | Codex effort (default `medium` for workers, `high` for the others). |
| `AGENTIC_GROK_MODEL` | Grok model; unset means the CLI default. |
| `AGENTIC_GROK_EFFORT`, `AGENTIC_GROK_{WORKER,REVIEWER,DIAGNOSTICIAN}_EFFORT` | Grok effort (default `medium` for workers, `high` for the others). |
| `AGENTIC_CLAUDE_ACCOUNTS` | Account hook command of the Claude adapter (for example `udarnik`); see `providers/claude/README.md`. Unset: claude runs in the caller's account. |
| `AGENTIC_EXECUTORS` | `local` runs every worker on this machine whatever `executors` declares. Any other non-empty value is an error. |
| `AGENTIC_SSH` | The ssh command for the executors (default `ssh`), also rsync's `-e` and git's transport. It is split on spaces, so it may carry options. |
| `AGENTIC_SUPERVISOR` | `off` never installs the supervisor (tests, CI). |
| `AGENTIC_SUPERVISOR_POLL_SECONDS`, `AGENTIC_SUPERVISOR_DELAY_SECONDS` | The supervisor's poll (default 60) and relaunch delay (default 300). |
| `AGENTIC_FLEET` | The fleet file. Default `${XDG_CONFIG_HOME:-~/.config}/agentic/fleet.json`. |
| `AGENTIC_MACHINE_ID` | This machine's id in the fleet, instead of `/etc/machine-id`. For tests. |
| `AGENTIC_OFFLOAD`, `AGENTIC_EXECUTOR_RUN` | Set to `1`, `bin/offload` runs its command on this machine: it already is an offloaded command (`AGENTIC_OFFLOAD`, which `offload` sets) or an executor run (`AGENTIC_EXECUTOR_RUN`, which the executor package's run prefix sets). |

The runner sets `AGENTIC_CAMPAIGN_ROOT` for the adapters, `AGENTIC_UNITS` for an executor's `admit` and `run`, and
`AGENTIC_RUN_KIND` (`worker` or `offload`) for its `admit` (see
[Remote executors](#remote-executors)); they are not settings.

## Starting a campaign

`campaign init <spec> [--slug <kebab-name>]`, run from the main branch, creates `campaign/<slug>` and its
worktree and commits the spec as `campaigns/<slug>/SPEC.md`. The slug is `--slug`, or else derived from the
spec's first `# ` heading; there is no fallback to the file name, and `init` stops when neither gives a slug.
`init` also refuses when the main branch has no committed `.agentic/bin/campaign` (commit the installed kit
first), and `campaign queue start` refuses the same way. `.agentic/SPEC.md` has the spec contract and
`.agentic/TICKET.md` the tickets; `campaign verify` checks both and the validation plan.

Required commands: `bash`, `git`, `jq`, `python3`, `flock`, `setsid`, `cmp` (diffutils) and the usual coreutils (plus `ssh` and
`rsync` for remote executors). Linux only.

## Scheduling

- `campaign run --workers 1..3` (default 2) starts write workers for tickets whose dependencies are
  `done` and whose collision domains are disjoint from running tickets. Ready tickets start in order of
  how many unfinished tickets they unblock transitively (the critical path first), then by ticket id.
  With [remote executors](#remote-executors) the capacity is `--workers` plus every executor's `workers`.
- Blocked or `needs-human` tickets do not stop independent tickets; the runner pauses only when
  nothing else can run.
- Runtime state, prompts, results, receipts, and logs live in the campaign cache
  (`$AGENTIC_CACHE`, default `${XDG_CACHE_HOME:-~/.cache}/agentic`), never in Git.

## Ticket lifecycle

1. A fresh worker process runs in the ticket worktree. An existing committed ticket delta, or one that
   `campaign recover` names, is reused instead of restarting the worker; the delta is measured from the merge
   base. A reused worktree is fast-forwarded to the campaign branch only when it is clean and has no commits of
   its own. A recovery with a diagnosis always starts with a worker applying it.
2. A `FAILED` worker may trigger an optional diagnostician (when it sets `needs_diagnosis`) followed
   by one repair worker.
3. The runner rejects a worker delta that edits `.agentic/*`, `.claude/*`, `.codex/*`, `.grok/*`, the campaign
   planning files or any instruction file (`instruction_files` of `project.json`, at the root or scoped), a
   rename (`git mv`) of one of them included: those belong to the coordinator. Otherwise it commits the worker
   delta (files with CRLF line endings included) and runs the ticket's declared validation. When a failing command
   is one of the plan's `baseline` commands and it also fails on the campaign base, the ticket is blocked as
   `base-red` (the ticket did not cause it) instead of asking a worker to repair unrelated code.
4. A fresh reviewer runs. If the reviewer changes its worktree, the invocation fails
   (`reviewer-mutated`).
5. `FIX` and `REPLAN` must justify every finding with `message` (the defect), `reason` (the acceptance
   item, rule or concrete failure behind it) and `fix` (what to do and how to prove it); `FIX` needs a
   critical or major finding. A rejection without them fails the provider contract and the reviewer is
   invoked again with the exact error. `FIX` allows one repair worker, which receives the findings as
   Problem / Why / How to fix; the repaired code passes the declared validation again before one fresh
   review, which receives the previous findings and the repair summary and judges those first. A second
   `FIX` blocks the ticket with the remaining findings as its reason; `REPLAN` records a human decision
   and moves the ticket to `needs-human` with the reviewer's justification.
6. Integration rebases the ticket onto `campaign/<slug>` and checks that every file the ticket changed
   still carries its change. A conflict (or a dropped change) aborts the rebase, emits
   `integration-conflict`, re-applies the ticket delta on the current campaign with conflict markers, and a
   fresh worker resolves them; the result is validated and reviewed again (up to three attempts). If the
   base changed, cheap and component validation run again; a failure there is repaired the same way. Then
   `git merge --ff-only`, the ticket is marked `done`, and its worktree and branch are removed.
7. Every block emits `ticket-blocked` (or `ticket-needs-human`) with its reason. A technical block gets up to
   `AGENTIC_AUTO_RECOVERIES` (default 2) automatic recoveries: the evidence of the last attempt
   becomes `diagnosis/<ticket>.md` and a fresh worker applies it. Human decisions and `base-red` are never
   retried automatically.
8. The runner commits the worker delta right after a `PASS`, so a ticket worktree with uncommitted changes means
   the worker never finished, unless the recovery is explicit (`campaign recover` or a diagnosis) or the changes
   are a plan or instruction edit awaiting coordinator review. The runner emits `worker-interrupted` and starts
   a recovery worker with the same note instead of validating partial code.
9. Every git command of the runner (and of the commands it starts) runs with `rerere.enabled=false`, so
   conflict resolutions recorded elsewhere are never replayed.

## Provider invocations

- An invalid or missing RESULT is re-invoked once in a fresh process with a contract reminder. A
  second failure emits `harness-error` and preserves the delta; it is never a product failure.
- Wall-clock deadlines: 60 minutes for a worker, 20 minutes for a reviewer or diagnostician.
  `AGENTIC_WORKER_TIMEOUT_SECONDS`, `AGENTIC_REVIEWER_TIMEOUT_SECONDS`, and
  `AGENTIC_DIAGNOSTICIAN_TIMEOUT_SECONDS` accept positive integer seconds; zero or unlimited
  values are rejected.
- On timeout the runner terminates only that invocation's process group (10 seconds before a forced
  kill), emits `provider-timeout`, preserves the delta and evidence, and does not retry automatically.
  Diagnose the evidence and recover explicitly after a concrete correction. A live PID or network
  activity is not proof of progress and never extends the deadline.
- A usage-limit failure is an ordinary provider failure: the invocation is repeated once, then `harness-error`
  pauses the ticket with its delta preserved. The runner does not wait for the limit to reset; recover the
  ticket (`campaign recover`) once it has. With `AGENTIC_CLAUDE_ACCOUNTS` the Claude adapter first retries once
  in another account (`providers/claude/README.md`).
- Validation commands have no deadline. A stuck test holds its phase until someone kills it; find the process in
  the runner's process tree. The deadlines above limit only provider invocations.

## Engine, baseline and environment

- `campaign run` launches the engine from a snapshot of the main branch's committed `.agentic`
  (`<runtime>/agentic`). Fixes to the runner reach a campaign on its next run, and editing `.agentic` on
  the main branch never changes a script a running engine is reading. Adapters receive the campaign root through
  `AGENTIC_CAMPAIGN_ROOT`.
- When the plan declares `baseline` commands, `campaign run` runs them on the campaign base first and
  refuses to start while they fail (`baseline-red`).
- The `env` map of `project.json` is exported to the runner, the workers and the validation commands
  (only variables not already set).
- `campaign run`, `campaign finalize` and `campaign queue start` drop to the lowest CPU priority (nice 19), and the
  detached engine and queue run in the user's `background.slice` (`agentic-<kind>-<slug>-<pid>.scope`), so tests
  only take the CPU the rest of the machine leaves free. Without a working user systemd (CI) only the priority applies.

## Remote executors

A project can let other machines run workers. Everything else stays on this machine: worktrees, commits,
validation, reviewers, diagnosticians and integration. Declare them in `project.json`:

```json
"executors": [
  {"name": "build-box", "ssh": "root@build-box", "workers": 1, "root": "/srv/agentic/work",
   "run": ["/usr/local/bin/agentic-executor-run"], "admit": ["/usr/local/bin/agentic-executor-admit"],
   "worker_units": 2, "requires": ["dotnet", "docker"], "env": {"TESTS_PARALLEL": "4"},
   "exclude": ["node_modules/", "bin/", "obj/"], "rsync_options": ["--chmod=g+rwX"]}
]
```

The kit's `executor/` package (installed on the host, never into a project) provides that `run`, that `admit` and the rest
of a host: see its `README.md`.

| Field | Meaning |
| --- | --- |
| `name` | `[a-z0-9-]+`, unique; `local` is reserved for this machine. |
| `ssh` | ssh destination or alias. Batch mode: the host must accept a key without prompts. |
| `workers` | Positive integer: tickets this executor runs at once. |
| `root` | Absolute path on the host under which every local absolute path is mirrored (local `/x/y` lives at `<root>/x/y` there). Empty (the default) means the same paths. |
| `run` | Optional argv prefix on the host that runs the adapter and presents `<root>/x/y` at `/x/y` to it (for example a container with bind mounts). It receives `env NAME=VALUE... bash <adapter> <role> <worktree> <prompt> <result> <events>` with local paths (an offloaded command: `env NAME=VALUE... bash -c <cd and exec> offload <folder> <command>...`), and `AGENTIC_UNITS=<n>` in its own environment: the units the run takes. Without it, `root` must be empty. |
| `exclude` | rsync exclude patterns for the worktree sync, both ways (`/.git` is always excluded). Excluded folders are neither sent nor deleted on either side. |
| `admit` | Optional argv run on the host before each remote invocation, as `env AGENTIC_UNITS=<n> AGENTIC_RUN_KIND=worker\|offload <admit>...`. A non-zero exit means the host has no room now for `n` units (or, for a worker, no model account it can use): the ticket runs here for the rest of its run (`executor-unavailable`, no attempt spent) instead of waiting there. Useful when several runners share one host. |
| `worker_units` | Positive integer, default 1: the units (`AGENTIC_UNITS`) a worker invocation asks of `admit` and `run`. What a unit is belongs to the host (the executor package counts them against its capacity). |
| `requires` | Optional list of command names checked on the host before each remote invocation, through `run` (with `AGENTIC_UNITS=0`, so it takes no units): `[run...] sh -c 'command -v NAME'`. A missing one makes the executor unavailable (`requires NAME`) for that run, as an unreachable one. |
| `env` | Optional string map exported only into the runs on this executor, after the `AGENTIC_*` variables and the project's `env` keys, so it wins over them. The same names as in the project's `env` are refused. |
| `sync_paths` | Absolute local folders outside the worktree that the worker reads and may add to (for example recordings kept out of Git). Each one is sent to `<root><path>` before the run and brought back after it, never deleting on either side; a file newer here is kept. |
| `rsync_options` | Extra rsync options for every transfer. When `run` executes the adapter as another user than the ssh one, give the group access both ways (`--chmod=g+rwX`, with the executor root group-owned or under a default ACL): the engine and its results are owner-only here, and rsync carries the modes. That user must also leave the files it writes readable by the group: the result is written owner-only. |

- Capacity is the local `--workers` plus every executor's `workers`. A starting ticket takes the first executor (in
  settings order) with a free slot, else a local one; the order of the ready tickets (critical path first) does not
  change. The engine emits `executor-assigned` (`executor=<name>`) and keeps the choice in
  `<runtime>/state/<ticket>.executor` for the ticket's run. `campaign status` and `campaign overview` show the
  executor of every in-progress ticket (`local` included).
- Every worker-role invocation of that ticket (worker, repair, recovery, review repair, integration repair) runs on
  its executor through `lib/remote-run.sh`, under the same deadline. Reviewers and diagnosticians always run here.
- One remote invocation: reach the host; push the ticket's commit, `campaign/<slug>` and the main branch with
  `git push --force` to a bare mirror at `<root>/.agentic/mirror/<repo>-<hash>.git` (the remote home when `root` is
  empty), never anywhere else; check that commit out in `<root><worktree>` with the campaign and main branches next to
  it; rsync the working files (`--delete`, uncommitted changes and deletions included), the engine, the prompt and the
  ticket's events; run the adapter in its own process group; copy the result, the events and the working files back.
  The adapter receives every `AGENTIC_*` variable (except `AGENTIC_SSH` and `AGENTIC_EXECUTORS`), the `env` keys of
  `project.json`, the executor's `env` and the runner's git settings, with its worktree marked `safe.directory`. Before
  the push, the host's `requires` are checked and its `admit` asked for `worker_units`.
- When the executor fails before the adapter starts (ssh, a missing required command, `admit`, mirror push, checkout or
  sync), the engine emits `executor-unavailable` with the reason, runs that ticket here for the rest of the run, and
  repeats the invocation at once without spending one of its two attempts. The ticket keeps its executor slot, so this machine may run up
  to the whole capacity while an executor is down. A later ticket tries the executor again. Once the adapter started,
  every status is the adapter's (an adapter exit 75 is reported as 1), and a failed copy back is a failure (1).
- On a deadline the runner stops the remote process group (TERM, then KILL after 3 seconds) and copies the working
  files back within 5 seconds, so the partial work survives as a local worker's would. When that copy does not finish,
  the work stays in `<root><worktree>` until the next remote invocation of the ticket replaces it.
- The host needs `bash`, `git`, `rsync` and `setsid`; the adapter's own commands (`claude`, `jq`, `python3`...)
  must exist where `run` runs it. Each invocation opens about ten ssh connections: an `ssh_config` with
  `ControlMaster auto` and `ControlPersist` for the host makes them cheap. The adapter's run always gets a connection
  of its own (`ControlMaster=no`): when the runner here dies, that session ends on the executor, and a `run` prefix can
  watch for it to stop what it started.
- `AGENTIC_EXECUTORS=local` runs everything here. The mirror and the remote worktrees are never pruned.
- `lib/remote.sh` holds these steps; `lib/remote-run.sh` (worker invocations) and `bin/offload` (commands) use it.
- `campaign-watch` measures the CPU of local processes only: a remote worker that writes no event for longer than
  `--stall-minutes` wakes the coordinator as a silent provider.

## Offloading commands

`.agentic/bin/offload` sends one command (a heavy test suite, a build) from any worktree of the project to an executor,
and is the way a validation command, a worker or a person uses the executors' capacity:

```
.agentic/bin/offload [--units N] [--each NAME=V1,V2,...] [--send PATH]... [--back PATH]... -- COMMAND...
```

- It reads the settings as the runner does (the main branch's committed `project.json`, its `env` exported,
  `AGENTIC_EXECUTORS=local` honored) and takes the first executor, in settings order, that is reachable, has its
  `requires` and whose `admit` accepts `AGENTIC_UNITS=N` (`--units`, default 1). The executors' `workers` slots are not
  involved.
- The executor gets the worktree as it is here, through the same mirror and steps as a remote worker: its commit (the
  current branch, with the main branch and, in a campaign, the campaign branch next to it) checked out in
  `<root><worktree>`, the working files synced over it (uncommitted changes and deletions included, `exclude` kept on
  both sides) and the `sync_paths`; never the prompt, the result or the events.
- Then each `--send PATH` (relative to the current folder, inside the worktree) goes there even when `exclude` leaves it
  out, for example a build made here (`--send backend/tests/App.Tests/bin/Debug`) so the executor runs the tests without
  building: a folder is mirrored exactly (`--delete`, `--mkpath`), a file copied. A `--send` path that does not exist is
  a usage error, found before anything is sent.
- COMMAND runs there from the current folder, on an ssh connection of its own, as
  `[run...] env <AGENTIC_* but the transport ones> <project env keys> <executor env> AGENTIC_UNITS=N AGENTIC_OFFLOAD=1 bash -c 'cd "$1" && shift && exec "$@"' offload <folder> COMMAND...`
  (the run prefix also receives `AGENTIC_UNITS=N` in its own environment). Its stdout and stderr stream here, apart.
- Afterwards each `--back PATH` (relative to the current folder, inside the worktree) comes back with rsync, without
  deleting anything here, and so do the `sync_paths`. Nothing else of the remote worktree comes back: a validation
  command must not mean to change the worktree. The exit status is COMMAND's, or 1 when it passed and the copy back
  failed.
- `--each NAME=V1,V2,...` runs COMMAND once per value with `NAME=value` in its environment, all at once on the same
  remote worktree (each run takes N units through the run prefix, which may make some wait there). Every output line
  carries `[<executor> NAME=value] `, a final line per value says `PASS` or `FAIL (exit S)` and where it ran, and the
  status is 0 only when every run exited 0 (else 1).
- COMMAND runs here (from the current folder, with `AGENTIC_UNITS=N AGENTIC_OFFLOAD=1`; with `--each` one value after
  another; `--send` and `--back` do nothing, the paths already are here) when no executor can take it (unreachable, a
  required command missing, `admit` refuses, a setup step failing; each reason is printed), when there is no executor
  or `AGENTIC_EXECUTORS=local`, and always when `AGENTIC_OFFLOAD=1` or `AGENTIC_EXECUTOR_RUN=1` is set: inside an
  offloaded command or an executor run it never offloads again.
- TERM or INT stops the remote process groups (TERM, then KILL after 3 seconds; the local ones the same way) and exits
  143 or 130. A usage error exits 64.
- The remote worktree is the one a remote worker of the same ticket uses, so the folders `exclude` keeps there (build
  output, dependencies) stay warm between runs. Run one offload per worktree at a time.

## Fleet

Machines that each hold a clone of the project and reach one another over ssh form a fleet: from any of them,
`campaign overview --fleet` shows the campaigns of the project on all of them. Executors stay what they are (machines
that run workers and commands for a runner elsewhere); a fleet machine runs its own campaigns.

One file describes the fleet, the same on every machine: `${XDG_CONFIG_HOME:-~/.config}/agentic/fleet.json`
(`AGENTIC_FLEET`). `fleet join` and `fleet leave` write it on every machine; there is nothing else to configure.

```json
{
  "machines": {
    "kepler":       {"ssh": "cidico@10.0.0.10", "id": "<machine id>"},
    "edenred-arch": {"ssh": "edenred-arch",     "id": "<machine id>"}
  },
  "projects": {
    "ShotlyPro": {"paths": {"kepler": "/home/cidico/Projects/shotly/webapp",
                            "edenred-arch": "/home/shotlyrun/Projects/shotly/webapp"}}
  }
}
```

A machine finds its own entry by its machine id (`/etc/machine-id`). `ssh` is a destination every other machine
reaches with a key and no prompt (`BatchMode`); an alias works where each machine's ssh configuration defines it. A
project is the `name` of its committed `project.json`, and `paths` holds its clone on each machine. Every machine runs
commands on the others as their user: the machines of a fleet trust one another. A project may also carry `files`
(paths inside the clone that Git does not hold, such as local settings, copied from the joining machine's clone) and
`setup` (an argv run in the new clone, for the project's own toolchain); `fleet join` writes neither, so add them to
the file by hand.

`campaign fleet join NAME --ssh DESTINATION [--path PATH] [--as NAME] [--as-ssh DESTINATION]`, from a clone of the
project, adds the machine NAME:

- it reaches DESTINATION and reads the machine's id and its fleet file (the two fleets become one; this machine's
  entries win). The first join also enters this machine, as `--as` (default: its host name) reachable at `--as-ssh`
  (default: `<user>@<the address NAME sees this machine at>`; a loopback address needs `--as-ssh`);
- the clone goes at `--path`, by default the same place under NAME's home (the same path when this clone is outside
  this home). A missing or empty folder gets a new clone: this machine's main branch pushed there and checked out, with
  this clone's git identity when NAME has none. A clone of the project already there is left as it is; another
  repository or another folder stops the join, before anything changes;
- every machine gets the fleet file, and every clone of the project the other clones as git remotes named after their
  machines (`<ssh>:<path>`, marked `remote.<name>.agentic-fleet`). A remote of that name that the fleet did not add is
  left as it is;
- before the clone, the commands the kit needs (`git`, `jq`, `python3`, `flock`, `setsid`, `cmp`, `rsync`) that NAME lacks are
  installed with its package manager (`pacman`, `apt-get`, `dnf` or `zypper`), as root or through `sudo` without a
  password; in a terminal, sudo may ask for its password. Without `git` the join stops;
- the project's `files` are copied into the clone and its `setup` runs there;
- NAME and every other machine must reach each other's clone with git over ssh (a host seen for the first time is
  accepted, `StrictHostKeyChecking=accept-new`). When NAME cannot reach a machine, it gets an ssh key (when it has
  none) and the pending item carries its public key, to authorize on that machine;
- every provider the project runs campaigns with (the ones whose `run-campaign` skill it has) must be ready on NAME:
  the adapter's `--ready` mode says whether its CLI is installed and signed in; a missing one is installed for that
  user (`--install`: claude's official installer, or npm into `~/.local`); in a terminal, one that is not signed in
  signs in there (`--login`, interactively); then the adapter's preflight must pass;
- the user there must linger (`loginctl enable-linger`) when it has a systemd of its own, or a campaign's runner would
  stop with the session that started it; the join turns it on when the user may, else it asks for sudo's password in a
  terminal or leaves the command to run as root;
- last, the campaign commands must run there (`campaign overview`).

It runs again safely, and ends with "every command works there" or with the pending items (exit 3): a machine that does
not answer, a command that could not be installed (with the command to run as root), a provider to sign in (with the
command), a failed setup, a pair that cannot reach each other (with the key to authorize). Commands the fleet runs on a
machine have the user's `~/.local/bin` at the end of their PATH.

Code moves between the clones through git alone, and no command ever moves a main branch: a clone whose main branch is
behind another machine's is warned with the command that pulls it, which the owner runs by hand
(`git pull --ff-only <machine> <main branch>`). Campaign branches are fetched as `refs/remotes/<machine>/campaign/*`.

- `campaign fleet [--json]` fetches the main and campaign branches of every other machine of the project and lists the
  machines: this one, the reachable ones with how their main branch compares (`main_branch`: `only_there`,
  `only_here`), the unreachable ones with the reason; then the warnings.
- `campaign overview --fleet [--json]` adds every machine's `campaign overview` (its `campaigns` and `queues`). A
  machine that does not answer shows the ones seen last (`seen_at`, `seen_local_time`), kept in `fleet-seen.json` of
  the project's cache. Without a fleet it shows this machine alone.
- `campaign init` refuses a slug that a campaign branch of another machine already has, and warns about a main branch
  behind another machine's and about a machine that did not answer (the slug was not checked there).
- `status`, `stop`, `run`, `restart`, `decide`, `recover`, `watch` and `move` take `--campaign SLUG [--on MACHINE]`
  from any worktree of the project: on this machine when it holds the campaign, else on the machine of the fleet that
  does (MACHINE when given, and several holders need it), in that campaign's worktree there, over ssh. The output and
  the exit status are the command's there. The caller's `AGENTIC_*` settings travel with it (`AGENTIC_CLAUDE_MODEL=sonnet
  campaign run --campaign SLUG ...`), except the ones that name this machine's paths or identity (`AGENTIC_CACHE`,
  `AGENTIC_FLEET`, `AGENTIC_MACHINE_ID`, `AGENTIC_SSH`, `AGENTIC_PROVIDER_DIR`, `AGENTIC_SUPERVISOR`).
  `finalize --campaign SLUG` brings the campaign here first (see
  [Moving a campaign](#moving-a-campaign)).
- A machine of the fleet that is also one of the project's `executors` (the same name) never sends work to itself.
- `campaign fleet leave NAME` removes NAME: its fleet file and the fleet's remotes of its clones go, and every other
  machine forgets it (file and remote). A machine that does not answer is listed as pending.

## Legacy campaign layout (accepted, not produced)

Campaigns created before the kit keep running and finalizing; the kit never writes this layout.

- A SPEC may carry, instead of the current sections, every one of `Problem`, `Goals`, `Non-goals`, `Decisions`,
  `Requirements`, `Constraints`, `Acceptance` and `Open questions`. Sections of the two layouts never combine to
  complete one. With the legacy sections, `Open questions` may also read `Nenhuma`.
- A validation plan without `final` uses its plan-level `campaign_expensive` list as the final list.

## Moving a campaign

The machine that holds a campaign owns it: its runner, its worktrees, its branches `campaign/<slug>` and
`agentic/<slug>/*` and its runtime. `campaign move --to MACHINE [--now] [--start | --no-start]`, in the campaign's
worktree (or `--campaign SLUG` from any machine of the fleet), hands it to another machine of the project's fleet:

1. MACHINE must hold a clone of the project whose kit can adopt a campaign (pull the main branch there first, by hand,
   when it is older) and no campaign of that slug.
2. Here the campaign stops: by default no new ticket starts and the move waits for the running ones to end; with `--now`
   they stop at once. While it moves, neither `campaign run` nor the supervisor relaunches it.
3. The uncommitted work of each of its worktrees (untracked files and deletions included, ignored files not) becomes a
   commit under `refs/agentic/move/<slug>/`, without touching the branch or the index. Its branches and those commits
   are pushed to MACHINE's clone, and its runtime (events, results, prompts, decisions, diagnoses, validation evidence,
   `run-config.json`, the finalize checkpoint) is copied there; this machine's runner state, engine snapshot and
   worktrees stay behind.
4. MACHINE adopts it (`campaign _adopt`): its worktrees are made again under MACHINE's cache, each one's carried work
   restored as uncommitted work, and its `campaign.json` records `epoch` (one more than here), `moved_from` and the
   desired state it had here (event `campaign-moved`). The next run there treats an interrupted ticket as it would here
   (`worker-interrupted`).
5. Only then does this machine forget it: worktrees, branches and runtime go, and a tombstone stays in
   `<cache>/moved/<slug>.json` (`campaign overview` lists it as moved). A failure before that leaves the campaign here,
   as it was, and removes what MACHINE had received.
6. It starts on MACHINE when it was running here and has run before, or with `--start`, with the last run's provider,
   workers and travelling `AGENTIC_*` settings; `--no-start` never starts it.

`campaign finalize --campaign SLUG [--on MACHINE]` finalizes a campaign into the main branch of the machine it is run
on: a campaign held by another machine is first moved here (`move --to <this machine> --no-start`), then finalized as
usual. The machine where finalize runs is the one whose main branch receives the campaign.

## Stopping, restarting and supervision

A campaign has a desired state, `desired` in its `campaign.json` (`running` or `stopped`): `campaign run` sets it to
running and `campaign stop` to stopped. `campaign status` (`runner.desired` in `--json`) and `campaign overview` show it
(`stopping` while a stopped campaign's runner still ends its running tickets).

- `campaign stop` starts no new ticket; the runner stops by itself once the running tickets end (`runner-stopped`).
  A `campaign run` before then cancels the stop (`stop-cancelled`) and the runner goes on.
- `campaign stop --now` stops at once: TERM to the engine and everything it started (its whole systemd scope when it
  runs in one, else its process tree), KILL after 10 seconds. The partial work stays in the ticket worktrees; the next
  run treats it as an interrupted worker (`worker-interrupted`) and recovers it.
- `campaign restart [--now] [--provider NAME] [--workers N]` stops (at once with `--now`, else after the running tickets
  end), then runs again unattended with the last run's provider, workers and `AGENTIC_*` settings unless given (the
  environment's own settings win).
- `campaign watch [options]` is `campaign-watch --slug <this campaign>`.

`campaign run` also installs and refreshes this repository's supervisor, a systemd user service
(`agentic-supervisor-<repository id>.service`, from a snapshot of the main branch's `.agentic`) when the user has a
systemd of its own; `AGENTIC_SUPERVISOR=off` skips it. Every `AGENTIC_SUPERVISOR_POLL_SECONDS` (60) it looks at the
campaigns of the repository in the cache: one that should be running, has run before, is not finalizing, not done, not
waiting on its coordinator (a blocked or needs-human ticket, a pending decision) and not part of a running queue, and
whose runner is down (a crash, a reboot, a technical pause), is relaunched unattended with the last run's provider,
workers and `AGENTIC_*` settings (kept in `run-config.json`), `AGENTIC_SUPERVISOR_DELAY_SECONDS` (300) after it was
first seen down, three times at most without a ticket ending (`supervisor-relaunch`, its output in
`logs/supervisor.log`). A user that does not linger loses the supervisor and the runners with its last session
(`fleet join` checks it).

## Campaign queue

`campaign queue start FILE` runs prepared campaigns in sequence, unattended, and resumes where it stopped
when started again. The definition (paths relative to the file):

```json
{
  "name": "nightly",
  "provider": "claude",
  "workers": 2,
  "campaigns": [
    {"slug": "auth-sessions", "spec": "auth-sessions/SPEC.md", "tickets": "auth-sessions/tickets",
     "validation": "auth-sessions/validation.json", "files": ["auth-sessions/EXECUTION-CONTEXT.md"]}
  ]
}
```

For each campaign the queue creates it from the main worktree when its branch does not exist (SPEC,
tickets, validation plan and extra `files`, committed and verified), runs it unattended, and finalizes it
into the main branch. It waits for the coordinator, and resumes by itself once resolved, only when:

- a ticket is `blocked` or `needs-human` after its automatic recoveries, or a decision is pending;
- the runner paused three times on technical errors without finishing a ticket;
- the runner refused to start (red baseline or provider preflight);
- finalize failed or the main worktree has uncommitted changes in files the campaign changes (retried when the main branch or the campaign changes).

A restart picks up where the queue stopped. A campaign with a finalize checkpoint (`<runtime>/finalize.json`) goes
straight to finalize: its planning files are already gone, so it can no longer run. A campaign finalized by hand
leaves `<cache>/finalized/<slug>.json` (`campaign init` of the same slug clears it); the queue counts a slug that has
this marker and no `campaign/<slug>` branch as done and never initializes it again.

`campaign queue status [NAME] [--json]` shows the state (`running`, `waiting`, `finalizing`, `done`,
`stopped`) and its reason; `campaign queue stop NAME` stops only the queue, never the campaign runners.
The queue never pushes. Its state and log live in `<cache>/queue/<name>/`.

`campaign overview [--json]` lists every campaign and queue in the cache (ticket counts, active runner,
pending decisions, recent events); with `--fleet`, on every machine of the project's [fleet](#fleet). The
`campaign-status` skill reports `overview --fleet`.

## Human decisions

Only `product-ambiguity`, `requirement-change`, and `destructive-risk` create decisions. Apply one with
`campaign decide <ticket> <retry|block|cancel>`. A decision is consumed when applied: a second `decide` for the
same ticket fails with "no pending decision".

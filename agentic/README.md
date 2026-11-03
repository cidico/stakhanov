# Campaign runner

`.agentic/bin/campaign` is the deterministic supervisor for campaigns. It has no model; it launches
provider processes through `.agentic/providers/<provider>/run.sh` and owns all routine filesystem, Git,
validation, and subprocess mutations. Agent-facing rules live in `WORKFLOW.md` and `roles/`; this file
documents what the runner enforces so those rules do not have to repeat it.

`bin/campaign` only dispatches commands; its functions live in modules of `lib/` that it sources at start:

- `lib/plan.sh`: init, current, verify, ready, status and the plan of a [task](#tasks) (with `lib/task_plan.py`).
- `lib/provider.sh`: provider adapter, preflight, deadline, prompt, ticket executor, wait for quota and invocation.
- `lib/engine.sh`: decisions, ticket status, validation, review, integration, `run_ticket` and the engine loop.
- `lib/control.sh`: run, stop, restart, watch, the supervisor, decide and recover.
- `lib/finalize.sh`: finalize, the finalizing marker, the finalized marker and cleanup.
- `lib/queue.sh`: the campaign queue.
- `lib/guards.sh`: the guard every reviewer finding names: the ledger of the findings and `campaign guards`.
- `lib/overview.sh`: the overview of campaigns, queues and worker rounds. A worker round is an unattended worker a
  coordinating session starts outside a campaign: a systemd user unit `task-<id>.service` whose command is
  `LAUNCHER WORKTREE RUNDIR MODEL EFFORT MINUTES [PROMPT_FILE]`, with `started`, `waiting` (`until=<time>`) and
  `accounts.log` in `RUNDIR`. `campaign overview` lists the active ones as `rounds`.
- `lib/slots.sh`: the machine slots (also loaded by `bin/offload`).
- `lib/machine.sh`: `campaign machine`, what a machine offers a task: free slots, load, accounts, proven capabilities.
- `lib/task.sh`: `campaign task`, the commands of a [task](#tasks) on this machine and its accept into the main branch.
- `lib/fleet.sh` and `lib/move.sh` (with `lib/remote.sh`) load only for the fleet commands.
- `bin/role-guard`: the PreToolUse hook that keeps a claude role from editing files through the shell and from writing to git
  ([Role guard](#role-guard)).

## Configuration

`.agentic/project.json` holds the per-project settings. A missing file means defaults; an invalid one stops
every command. `project.json.example` (in the kit, not copied to projects) is a starting point, and the installer creates the
file from it with the project name and the detected main branch.

The effective settings are the main branch's committed copy (`git show <main>:.agentic/project.json`), for
every command, whether it runs in the main worktree or in a campaign worktree. The local file is read only to
find `main_branch`, and is the fallback while the main branch has no committed copy. An uncommitted edit to
`project.json` therefore changes nothing: commit it on the main branch.

| Field | Meaning |
| --- | --- |
| `name` | Project name used in role prompts. |
| `main_branch` | Branch campaigns start from and integrate into. Default: `main` if it exists, else `master`, else an error. A configured branch that does not exist is an error. |
| `instruction_files` | Names (no slash) of the instruction files roles read at the root and in every touched area. Default `["AGENTS.md", "CLAUDE.md"]`. The runner rejects a worker delta that edits any of them (root or scoped, committed by the worker or not, a rename with `git mv` included), like `.agentic/*`, the skill and agent folders (`.claude/*`, `.codex/*`, `.grok/*`, `.agents/skills/*`) and the campaign planning files. |
| `env` | String map exported to the runner, the workers and the validation commands (only variables not already set). `project.json` is committed, so never put a secret in it. The runner refuses `PATH`, `HOME`, `IFS`, `ENV`, `BASH_ENV`, `BASHOPTS`, `SHELLOPTS`, `PS4`, `GIT_*`, `LD_*` and `PYTHON*`, which would redirect the runner itself; everything else, `AGENTIC_*` included, is allowed. |
| `required_checks` | Argv arrays that every ticket's `cheap` phase and the plan's `final` list must contain; `campaign verify` refuses a plan without them, and finalize checks again before the final validation. |
| `capabilities` | What a machine must prove it has, for `campaign machine`: a map of name to the argv of its proof (`"dotnet": ["dotnet", "--version"]`). Each proof runs on the machine, with no shell and a 10 s deadline (`AGENTIC_MACHINE_PROBE_SECONDS`); exit 0 proves it. Default: none. |
| `timezone` | Display zone for local times. Precedence: `AGENTIC_DISPLAY_TZ`, then this field, then the system zone. |
| `archive_dir` | Where finalize archives the campaign history, relative to the main worktree, with `{date}` and `{slug}` placeholders; used only when Git ignores it. Default: the `archive/` folder of the cache. |
| `executors` | Remote machines that run workers and offloaded commands; see [Remote executors](#remote-executors). Default: none, every role runs on this machine. |
| `environment_failure_patterns` | Python regular expressions searched in the output (stdout and stderr) of a failed validation command: a match makes it a failure of the environment, which is never repaired (see [Ticket lifecycle](#ticket-lifecycle)). Default `[]`. An invalid one stops every command. |
| `task_preamble`, `task_links`, `task_cleanup`, `accept_regen`, `accept_checks`, `regen_paths`, `coordinator_paths` | What the tasks ask of the project; see [Tasks](#tasks). `coordinator_paths` also guards the tickets of every campaign. |

`name` is also how the machines of a [fleet](#fleet) know the project.

### Environment variables

| Variable | Effect |
| --- | --- |
| `AGENTIC_CACHE` | Runtime state, prompts, results and logs. Default `${XDG_CACHE_HOME:-~/.cache}/agentic`. |
| `AGENTIC_DISPLAY_TZ` | Display zone for local times. |
| `AGENTIC_AUTO_RECOVERIES` | Automatic recoveries of a technically blocked ticket (default 2, one digit). |
| `AGENTIC_VALIDATION_REPAIRS` | Repair workers of a red validation in one pass (default 1, one digit); `campaign run` refuses another value. |
| `AGENTIC_WORKER_TIMEOUT_SECONDS` | Worker deadline (default 3600). |
| `AGENTIC_REVIEWER_TIMEOUT_SECONDS` | Reviewer deadline (default 1200). |
| `AGENTIC_DIAGNOSTICIAN_TIMEOUT_SECONDS` | Diagnostician deadline (default 1200). |
| `AGENTIC_RESCAN_SECONDS` | Ticket queue rescan while a worker slot is free (default 60). |
| `AGENTIC_QUEUE_POLL_SECONDS` | Campaign queue poll interval (default 60). |
| `AGENTIC_QUEUE_RELAUNCH_SECONDS` | Campaign queue relaunch delay (default 300). |
| `AGENTIC_PROVIDER_DIR` | Alternate adapter directory: `<dir>/<provider>/run.sh` replaces `.agentic/providers/<provider>/run.sh`. For tests and custom adapters. |
| `AGENTIC_CLAUDE_MODEL`, `AGENTIC_CLAUDE_{WORKER,REVIEWER,DIAGNOSTICIAN}_MODEL` | Claude model (default `opus`); the role variable wins over the provider-wide one. |
| `AGENTIC_CLAUDE_EFFORT`, `AGENTIC_CLAUDE_{WORKER,REVIEWER,DIAGNOSTICIAN}_EFFORT` | Claude effort (default `high`). |
| `AGENTIC_CLAUDE_MODE` | `print` (default): every claude role is a headless `claude --print` process. `session`: no claude process of its own; the roles run as background subagents of an interactive host session (`/campaign-host`). With `session` the deadline of every role is `AGENTIC_SESSION_MAX_SECONDS` and the preflight needs a live host; see `providers/claude/README.md`. |
| `AGENTIC_SESSION_DIR` | The machine's queue of session requests and hosts. Default `${XDG_STATE_HOME:-~/.local/state}/agentic-session`. |
| `AGENTIC_SESSION_IDLE_SECONDS` | Session mode: how long nothing may move (transcript, CPU and I/O of the pending Bash call) before the subagent is cancelled (default 600). |
| `AGENTIC_SESSION_SAMPLE_SECONDS` | Session mode: the confirming sample after the idle time (default 30). |
| `AGENTIC_SESSION_MAX_SECONDS` | Session mode: the deadline the runner gives every role (default 604800, 7 days). |
| `AGENTIC_SESSION_POLL_SECONDS`, `AGENTIC_SESSION_FINISH_GRACE_SECONDS`, `AGENTIC_SESSION_CANCEL_WAIT_SECONDS`, `AGENTIC_SESSION_HOST_POLL_SECONDS` | Session mode: the adapter's poll (5), the wait for a result after the subagent ended (60), the wait for the host to stop a cancelled subagent (60) and the poll of `session-host wait` (3). For tests. |
| `AGENTIC_CODEX_MODEL` | Codex model; unset means the CLI default. |
| `AGENTIC_CODEX_EFFORT`, `AGENTIC_CODEX_{WORKER,REVIEWER,DIAGNOSTICIAN}_EFFORT` | Codex effort (default `medium` for workers, `high` for the others). |
| `AGENTIC_GROK_MODEL` | Grok model; unset means the CLI default. |
| `AGENTIC_GROK_EFFORT`, `AGENTIC_GROK_{WORKER,REVIEWER,DIAGNOSTICIAN}_EFFORT` | Grok effort (default `medium` for workers, `high` for the others). |
| `AGENTIC_CLAUDE_ACCOUNTS` | Account hook command of the Claude adapter (for example `udarnik`); see `providers/claude/README.md`. Unset: claude runs in the caller's account. `campaign run` says when it is missing or off on this machine; `fleet join` lists it as pending when it is missing on the new machine. |
| `AGENTIC_QUOTA_MIN_WAIT_SECONDS` | Shortest wait for quota when every account is out (default 60). |
| `AGENTIC_QUOTA_JITTER_SECONDS` | Random delay of 0 to this many seconds added to the wait for quota, so rounds do not wake together (default 120). |
| `AGENTIC_PROVIDER_TRANSIENT_RETRIES` | Times the Claude adapter backs off (30 s, 60 s, 120 s plus up to 50 %) and reruns after a transient API error (429 that is not a usage limit, 5xx, overloaded) without spending an attempt (default 3). |
| `AGENTIC_EXECUTORS` | `local` runs every worker on this machine whatever `executors` declares. Any other non-empty value is an error. |
| `AGENTIC_SSH` | The ssh command for the executors (default `ssh`), also rsync's `-e` and git's transport. It is split on spaces, so it may carry options. |
| `AGENTIC_SUPERVISOR` | `off` never installs the supervisor (tests, CI). |
| `AGENTIC_SUPERVISOR_POLL_SECONDS`, `AGENTIC_SUPERVISOR_DELAY_SECONDS` | The supervisor's poll (default 60) and relaunch delay (default 300). |
| `AGENTIC_FLEET` | The fleet file. Default `${XDG_CONFIG_HOME:-~/.config}/agentic/fleet.json`. |
| `AGENTIC_MAIN_LOCK_WAIT_SECONDS` | How long a finalize waits for `<cache>/main.lock` held by another (default 1800). |
| `AGENTIC_FLEET_CACHE_SECONDS` | How long a survey of the fleet's peers is reused (default 30; `0` keeps nothing). |
| `AGENTIC_MACHINE_ID` | This machine's id in the fleet, instead of `/etc/machine-id`. For tests. |
| `AGENTIC_MACHINE_PROBE_SECONDS` | Deadline, in seconds, of each `capabilities` proof and of each call `campaign machine` makes to the account hook (default 10). |
| `AGENTIC_SLOTS` | This machine's [slots](#machine-slots), instead of `machines.<this machine>.slots` of the fleet file; `0` means no limit. |
| `AGENTIC_STATE` | Machine-wide state of this user (the slots). Default `${XDG_STATE_HOME:-~/.local/state}/agentic`. |
| `AGENTIC_SLOT_POLL_SECONDS` | How often the request at the head of the queue for a slot looks again (default 1). |
| `AGENTIC_SLOT_CHECK_SECONDS` | How often the other requests, the stop request and the engine are checked while waiting for a slot (default 5, whole seconds). |
| `AGENTIC_OFFLOAD`, `AGENTIC_EXECUTOR_RUN` | Set to `1`, `bin/offload` runs its command on this machine: it already is an offloaded command (`AGENTIC_OFFLOAD`, which `offload` sets) or an executor run (`AGENTIC_EXECUTOR_RUN`, which the executor package's run prefix sets). |

The runner sets `AGENTIC_CAMPAIGN_ROOT` for the adapters, `AGENTIC_UNITS` for an executor's `admit` and `run`,
`AGENTIC_RUN_KIND` (`worker` or `offload`) for its `admit` (see
[Remote executors](#remote-executors)), `AGENTIC_FINALIZE` (the campaign's slug) for the commands of a final
validation (see [Final validation](#final-validation)), `AGENTIC_SLOT` (the slot held) for everything a round or a
final validation starts (see [Machine slots](#machine-slots)), and `AGENTIC_TASK` (the task's name) for the commands of a
task's accept and cleanup (see [Tasks](#tasks)); they are not settings.

What a provider call cost (dollars, tokens, turns, duration; `null` for what the provider does not report) is written
beside the result as `<result>.usage.json` and, with the number of attempts, in the `usage` and `attempts` of the
adapter's `completed` and `failed` events; the result and `RESULT.schema.json` do not carry it.

## Starting a campaign

`campaign init <spec> [--slug <kebab-name>]`, run from the main branch, creates `campaign/<slug>` and its
worktree and commits the spec as `campaigns/<slug>/SPEC.md`. The slug is `--slug`, or else derived from the
spec's first `# ` heading; there is no fallback to the file name, and `init` stops when neither gives a slug. A slug
cannot be a name the machine's cache already uses for a folder (`queue`, `moved`, `finalized`, `finalizing`,
`supervisor`, `archive`, and `tasks`, `slots`, `fleet-seen`, `main`, kept for what comes): every command that takes a
slug, and a queue definition, refuses them (`RESERVED_SLUGS` in `lib/common.sh`).
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

## Machine slots

`--workers` limits one runner; the slots limit the machine. Every round of a ticket and every final validation, of any
campaign or repository of this user on this machine, holds one slot while it runs, and waits in a FIFO queue when they are
all taken.

- **Capacity:** `AGENTIC_SLOTS`, else `slots` of this machine's entry in the fleet file
  (`"kepler": {"ssh": ..., "id": ..., "slots": 4}`). Without either there is no limit, and nothing waits. A value that
  is not a positive integer (`AGENTIC_SLOTS=many`) is an error in the engine, `campaign finalize` and `bin/offload`: it
  never turns the limit off.
- **A round, not a command:** a round of a ticket takes its slot right after `ticket-started` and keeps it to its end:
  worker, validation, diagnosis, repairs, review and integration; a wait for quota keeps it too. `campaign finalize`
  takes one before its locks and gives it back once the final validation is over; it waits for the slot before it checks
  its gates, so on a full machine a finalize that is going to fail (tickets not ready, a dirty tree) or only to clean up
  (a resumed `proved` stage) waits first. `bin/offload` takes one when its command runs here, never when it goes to an
  executor.
- **Executor tickets too:** the round of a ticket assigned to a remote executor also takes a local slot, because its
  validation and integration run here; the executors' `workers` do not add capacity beyond the slots of this machine.
- **Inherited, never asked twice:** the holder exports `AGENTIC_SLOT=<n>`, and whatever sees it (an `offload` that a
  worker or a validation command runs, a finalize inside a round) runs in that slot without asking for another. Nobody
  waits for a slot holding one, and nobody asks for one holding another lock. A detached engine drops the
  `AGENTIC_SLOT` it inherited: its rounds take their own.
- **No leaks:** the lock is kept by a guard process of the holder that has no other descriptor and ends with it. No
  command the round starts inherits it, a build server left running afterwards (MSBuild node reuse, `VBCSCompiler`, an
  ssh `ControlPersist` master) never holds the slot, and the slot comes back when the round ends, even when the round
  is killed with SIGKILL. Killing only the engine leaves the rounds in progress running, each with its slot, until they
  end; a round still waiting for a slot ends when it sees its engine gone (a `waiting-slot` event), so it does not keep
  the `runner.lock` for as long as the machine is full.
- **Visible:** a round that waits writes `waiting-slot` (its position in the queue, again when it changes) and
  `slot-taken` once it has the slot; `campaign overview` shows the phase `waiting-for-slot`. A stop request ends the
  wait as it ends a wait for quota. A finalize says it waits on stderr, and so does an offload.
- **Cost of waiting:** only the head of the queue looks at the slots every `AGENTIC_SLOT_POLL_SECONDS`; the requests
  behind it look when the queue changes or every `AGENTIC_SLOT_CHECK_SECONDS` (5, whole seconds), the pace at which the
  stop request and the engine are checked. A look at the queue starts no process.
- **Where:** `${AGENTIC_STATE:-${XDG_STATE_HOME:-~/.local/state}/agentic}/slots/`: `slot.0` to `slot.<N-1>` (flock
  files) and `queue/` (one file per waiting request, in order of time and pid; a request of a process that is gone is
  dropped). A slot is occupied by whoever holds its `flock`; the file's content (`pid`, `kind`, `label`, `since`) is only
  information, true only while the lock is held. A take empties the free slot files it finds, so a holder that died
  without releasing is not named for long.

## Ticket lifecycle

1. A fresh worker process runs in the ticket worktree. An existing committed ticket delta, or one that
   `campaign recover` names, is reused instead of restarting the worker; the delta is measured from the merge
   base. A reused worktree is fast-forwarded to the campaign branch only when it is clean and has no commits of
   its own. A recovery with a diagnosis always starts with a worker applying it. Before the first worker of a ticket
   (never a recovery, a repair or a later round of a task), the runner runs the ticket's `cheap` and `component`
   commands on the ticket's base commit, in a throwaway worktree, and at least one must fail
   ([Validation that fails before the change](#validation-that-fails-before-the-change)).
2. A `FAILED` worker may trigger an optional diagnostician (when it sets `needs_diagnosis`) followed
   by one repair worker.
3. After every worker round the runner rejects a delta that edits `.agentic/*`, the skill and agent folders (`.claude/*`,
   `.codex/*`, `.grok/*`, `.agents/skills/*`), the campaign planning files, any instruction file (`instruction_files` of
   `project.json`, at the root or scoped) or a path of the `coordinator_paths` globs, a rename (`git mv`) of one of them
   included, whether the worker left it uncommitted or committed it itself: those belong to the coordinator
   (`harness-error`, delta preserved). Otherwise it commits the worker
   delta (files with CRLF line endings included) and runs the ticket's declared validation. When a failing command
   is one of the plan's `baseline` commands and it also fails on the campaign base, the ticket is blocked as
   `base-red` (the ticket did not cause it) instead of asking a worker to repair unrelated code. A failure of the
   environment is not the code's either: a command that exits 127 (`command not found`) or cannot be started because it is not in the PATH (a path of the
   worktree that is missing is the code's, and is repaired), that
   runs past its deadline (`timedOut` in its receipt) or whose output matches one of the `environment_failure_patterns`
   of `project.json` blocks the ticket as `environment: <command> (<cause>)` (event `environment-failure`), with
   neither a repair nor an automatic recovery. Any other red phase gets a repair worker, at most
   `AGENTIC_VALIDATION_REPAIRS` (1) times in one pass of the validation (after the worker, after a review repair or
   an integration repair); past that the ticket is blocked as `validation still red after N repair(s)` and takes the
   automatic recoveries of step 7.
4. A fresh reviewer runs. If the reviewer changes its worktree, the invocation fails
   (`reviewer-mutated`).
5. `FIX` and `REPLAN` must justify every finding with `message` (the defect), `reason` (the acceptance
   item, rule or concrete failure behind it) and `fix` (what to do and how to prove it); `FIX` needs a
   critical or major finding. Every finding, on a `PASS` too, also names its `guard` ([Guards](#guards)). A rejection
   without them fails the provider contract and the reviewer is
   invoked again with the exact error. `FIX` allows one repair worker, which receives the findings as
   Problem / Why / How to fix; the repaired code passes the declared validation again before one fresh
   review, which receives the previous findings and the repair summary and judges those first. A second
   `FIX` blocks the ticket with the remaining findings as its reason; `REPLAN` records a human decision
   and moves the ticket to `needs-human` with the reviewer's justification.
6. Integration rebases the ticket onto `campaign/<slug>` and checks that every file the ticket changed
   still carries its change. A conflict (or a dropped change) aborts the rebase, emits
   `integration-conflict`, re-applies the ticket delta on the current campaign with conflict markers, and a
   fresh worker resolves them; the result is validated and reviewed again (up to three attempts). A delta that no worker
   could resolve from markers keeps the ticket's commits (and the copy of the delta, `state/<ticket>.conflict.patch`) and
   moves the ticket to `needs-human`, with no automatic recovery, saying why: it does not apply at all (for example, the
   campaign deleted or renamed a file the ticket changes, or the ticket deletes a file the campaign changed), or both
   sides changed a file git merges without conflict markers (a binary file, or a `-merge` or `merge=binary` attribute).
   A file that the ticket and the campaign both deleted is no conflict. If the base changed, cheap and component validation run again; a failure there is repaired the same way. Then
   `git merge --ff-only`, the ticket is marked `done`, and its worktree and branch are removed.
7. Every block emits `ticket-blocked` (or `ticket-needs-human`) with its reason. A technical block gets up to
   `AGENTIC_AUTO_RECOVERIES` (default 2) automatic recoveries: the evidence of the last attempt
   becomes `diagnosis/<ticket>.md` and a fresh worker applies it. Human decisions, `base-red` and failures of the
   environment are never retried automatically.
8. The runner commits the worker delta right after a `PASS`, so a ticket worktree with uncommitted changes means
   the worker never finished, unless the recovery is explicit (`campaign recover` or a diagnosis) or the changes
   are a plan or instruction edit awaiting coordinator review. The runner emits `worker-interrupted` and starts
   a recovery worker with the same note instead of validating partial code.
9. Every git command of the runner (and of the commands it starts) runs with `rerere.enabled=false`, so
   conflict resolutions recorded elsewhere are never replayed.

## Validation that fails before the change

A validation that already passes on the base proves nothing about the change. In the fresh-worker path of a ticket (not in
a recovery, a repair or a later round of a task, whose branch already holds the delta) `run_ticket` first calls
`validate_base_check`:

1. It reads the answer kept in `state/<ticket>.validate-base` (`base`, `key`, `outcome`, `reason`, `time`). The `key`
   hashes the files of the base (the `campaigns/` folder aside, because the runner's own status commits move the branch
   without changing what a command sees) and the ticket's `cheap` and `component` commands. With the same key the check is
   not made again: a `proves` or `skipped` outcome goes on to the worker, a `refused` one refuses the ticket again.
2. `validate_base: skip` in the ticket (a task's brief carries it into the ticket it generates) records `skipped` and the
   reason (event `validate-base-skipped`). The round of a task after the first records `skipped` too, saying so.
3. Otherwise it checks out the ticket's base commit as a detached worktree in `<runtime>/validate-base/<ticket>` (a task's
   `.task/` and `task_links` are copied there), runs `lib/validation.py ... base` on it with the plan's commands, deadlines and
   environment, and removes the worktree. The `base` phase runs the ticket's `cheap` and then `component` commands, stops at
   the first one that fails and writes `validation/base/<ticket>.base.json` (never `expensive`).
4. A failing command is the proof: `proves`, event `validate-base-proves` with the command that failed and the ones that
   passed before it. If every command passed, or there is none, the answer is `refused`: event `validate-base-passes`, and the
   ticket is blocked with "validate already passes on the base: it does not prove the change (...)" before any worker runs,
   with no automatic recovery. A failure of the environment on the base (a command not in the PATH, a deadline, an
   `environment_failure_patterns` match) blocks it as `environment: ... on the base`. A check that could not run is a
   `harness-error` that leaves the ticket as it was.

`campaign recover <ticket>` forgets a `refused` answer, so the ticket is checked again once its validation or its base was
fixed. The state goes with the integrated ticket.

## Guards

Every finding of a reviewer names `guard: {kind, how}`: the automatic check that would have caught it, so that it never
needs a reviewer again. `kind` is `analyzer`, `lint`, `test`, `validate` (a command of the ticket's validation plan),
`executor` (a check the runner itself makes) or `reviewer-only` (none can), and `how` is one line saying which rule, test or
command and what it asserts. `RESULT.schema.json` requires it of every finding, and `providers/validate-result.py` refuses a
result whose finding lacks it, or has an unknown kind or a `how` that is not one concrete line, like a finding without `fix`:
the reviewer is invoked again with the exact error.

The runner keeps every accepted finding in `<runtime>/guards.ndjson` (the finding as written, its `ticket`, its `round`: the
ordinal of the ticket's review, its `verdict` and, for a task, its `task_round`), because the result of a review is
overwritten by the next one.

`campaign guards [--json]` lists, for every campaign and task of this machine (the scope of `campaign overview`, not only the
campaign of the current branch), the findings whose guard is not `reviewer-only`: campaign or task, ticket, round, severity,
guard kind and how, and the message; `--json` gives `{count, findings}`. `campaign overview` gives each campaign `guards`, the
count of those findings, and `/campaign-status` shows it. A ledger written before guards existed has no guard to count.

## Role guard

A role changes files with the Edit and Write tools and leaves git to the runner. `bin/role-guard ROLE` is the PreToolUse hook
of the Bash tool that holds it to that. It reads the hook's JSON on stdin and, for a Bash call, exits 2 with a one-line
message on stderr (which reaches the model) when any simple command of the command line (split at `&&`, `||`, `;`, `|`,
newlines, subshells, `$( )` and backticks, `env`, `command`, `sudo`, `xargs`, `find -exec`, `bash -c` and the like) is:

- `sed` with `-i` or `--in-place` (`-ni`, `-i.bak`, `-Ei`...) or `perl` with `-i` (`-pi`, `-0pi`...): "use the Edit tool";
- a write by redirection (`>`, `>>`, `>|`, `&>`, `N>`), heredoc output (`cat <<EOF > f`) or `tee`, to a path other than
  `/dev/null` (and the other standard streams), a file descriptor (`2>&1`, `>&2`), anything under `/tmp` and the `requests/`
  folder of the session queue (`AGENTIC_SESSION_DIR`, where a read-only role writes its RESULT): "create files with Write
  and change them with Edit". A target that is only known when the shell runs (`> "$f"`) is refused;
- a git command that writes (`add`, `rm`, `mv`, `reset`, `stash`, `rebase`, `merge`, `commit`, `checkout`, `switch`, `restore`,
  `clean`, `push`, `pull`, `fetch`, `cherry-pick`, `revert`, `am`, `apply`, `update-index`, `update-ref`, `gc`, `prune`, `tag`
  to create or delete, `branch` to create, delete, rename or copy, `worktree add|remove|move|prune`, `notes add`, a `config`
  that sets, and a few plumbing writers): "the runner commits and integrates; only read git is allowed". `status`, `diff`,
  `log`, `show`, `blame`, `grep`, `ls-files`, `ls-tree`, `rev-parse`, `cat-file`, `describe`, `shortlog`, `reflog`, `branch`
  and `tag` to list, `worktree list`, `stash list|show`, `apply --check` and `config --get|--list` stay free.

Anything else, every other tool (Edit, Write, Read...) and a command line it cannot read exit 0 silently: the guard fails open
and never crashes. It is a guard against a model's habit, not a sandbox: a program that writes a file by itself is not seen.

Where it is installed: in session mode, in the frontmatter `hooks:` of the three agents (`agents/claude/`, installed into
`.claude/agents/`), whose hook only fires for that subagent, as `"${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"/.agentic/bin/role-guard
ROLE`; in print mode, by the claude adapter's `--settings` (`providers/claude/README.md`). Codex and Grok have no such hook.

## Provider invocations

- An invalid or missing RESULT is re-invoked once in a fresh process with a contract reminder. A
  second failure emits `harness-error` and preserves the delta; it is never a product failure.
- Wall-clock deadlines: 60 minutes for a worker, 20 minutes for a reviewer or diagnostician.
  `AGENTIC_WORKER_TIMEOUT_SECONDS`, `AGENTIC_REVIEWER_TIMEOUT_SECONDS`, and
  `AGENTIC_DIAGNOSTICIAN_TIMEOUT_SECONDS` accept positive integer seconds; zero or unlimited
  values are rejected. The claude adapter in session mode (`AGENTIC_CLAUDE_MODE=session`) gets
  `AGENTIC_SESSION_MAX_SECONDS` (7 days) for every role instead: only its idle rule ends a working subagent, and it
  ends it with status 124, handled as the timeout below.
- On timeout the runner terminates only that invocation's process group (10 seconds before a forced
  kill), emits `provider-timeout`, preserves the delta and evidence, and does not retry automatically.
  Diagnose the evidence and recover explicitly after a concrete correction. A live PID or network
  activity is not proof of progress and never extends the deadline.
- Without an account hook, a usage-limit failure is an ordinary provider failure: the invocation is repeated once,
  then `harness-error` pauses the ticket with its delta preserved; recover it (`campaign recover`) once the limit has
  reset. With `AGENTIC_CLAUDE_ACCOUNTS` the Claude adapter first retries once in another account, and when no account
  is left it exits 75 with the time the first one is back (`providers/claude/README.md`). The runner then waits for
  that time (`provider-quota-wait`, at least `AGENTIC_QUOTA_MIN_WAIT_SECONDS`; 15 minutes when the time is unknown)
  and runs the same invocation again without spending an attempt (`provider-quota-back`). A stop request ends the
  wait; the ticket keeps its product status and delta for the next run.
- The deadlines above limit only provider invocations. Every validation command has its own (`.agentic/VALIDATION.md`);
  a command past it is stopped with its process group, and a ticket phase that ran out of time is a failure of the
  environment (see [Ticket lifecycle](#ticket-lifecycle)).

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

## Tasks

A task is a campaign of one ticket whose plan lives in its runtime instead of on its branch. It runs on the same engine
(worktree, worker, validation, recovery, quota, supervisor, `move`, routing, overview, watch), and nothing but its
worker's delta is ever committed: no plan, no status.

- `campaign _task-plan BRIEF DIR` writes the plan from a brief, Markdown with a front matter in the format of the
  rewrite's tasks (`id`, `title`, `after`, `domains`, `requires`, `prefer`, `model`, `effort`, `review`,
  `timeout_minutes`, `validate`, and the optional `commit`, a `type(area)` such as `feat(analyzers)`, `units`, and the
  pair `validate_base: skip` with its `validate_base_reason`, which skips the check that `validate` fails on the base):
  `SPEC.md` (the sections `campaign verify` checks, with the brief's goal and its whole body), `tickets/T-001.md` (the
  one ticket, whose `collision_domains` are the brief's `domains`), `validation.json` (every `validate` command, split
  as a shell splits it but run without one, as the ticket's `cheap` phase and as `final`, with the brief's
  `timeout_minutes` at the top) and `task.json` (the front matter, normalized). It checks the plan as `campaign verify`
  does and prints the task's name, its id in lower case (`GRD-002` → `grd-002`). It refuses, with the reason, a brief
  without `id`, `title` or `review`, with an empty `validate`, an unknown field or one of the wrong type, a `skip`
  without a reason, a reason without `skip`, or whose name is not a valid slug.
- `"kind": "task"` in a `campaign.json` makes the campaign a task. Its plan is `<runtime>/plan` (the `DIR` above) for
  `verify`, `status`, `ready`, `overview` and the engine, and its ticket's status is written there, with no commit. The
  worker's delta is committed as `<commit>: <title>` of the brief (`feat(task): <title>` without `commit`), and the
  integration commits nothing else. `review: false` skips the reviewer (event `review-skipped`), and `base-red` never
  applies: a task usually creates what it validates. Its branch is still `campaign/<slug>`, and nothing that derives
  from the branch changes; a task moved to another machine stays a task, its plan travelling with its runtime.
  `campaign overview --json` gives every item's `kind` (`campaign` or `task`); without `kind`, a campaign is a campaign.

### Task commands

`campaign task <command>`, from any worktree of the project, drives the tasks of this machine by their name, the brief's
`id` in lower case (`GRD-002` is `grd-002`):

- `new BRIEF [--base REV] [--context FILE]... [--no-start]` writes the task's plan (`_task-plan`) in `<runtime>/plan`, a
  copy of the brief in `<runtime>/brief.md` and its `campaign.json`: `kind: task`, `id`, `title`, `base` (the commit) and
  `base_ref`, `brief` and `brief_path` (the file given), `home` (this machine), `epoch: 1`, `round: 1` and `created`. It
  creates `campaign/<name>` from REV (default: the main branch), the campaign worktree and the ticket's
  (`agentic/<name>/T-001`) as the engine makes them, mounts `.task/` in the ticket worktree (`TASK.md`: the
  `task_preamble`, a `---` line and the brief; and each `--context FILE`, by its name) and the `task_links` at its root,
  and runs it: `campaign run --provider claude --workers 1 --mode unattended`, with the brief's `model`, `effort` and
  `timeout_minutes` as `AGENTIC_CLAUDE_WORKER_MODEL`, `AGENTIC_CLAUDE_WORKER_EFFORT` and `AGENTIC_WORKER_TIMEOUT_SECONDS`
  (they win over the environment, and `run-config.json` keeps them), unless `--no-start`. It refuses a name that a task, a
  campaign or their branches already use on this machine, a link whose path does not exist here and a base that holds
  `.task` or a link's name; a failure half way keeps nothing. `/.task` and the links' names go to the clone's
  `info/exclude`, so neither ever enters a commit.
- `list [--json]`: the tasks of this machine with their state, phase, base, round and age. The state is `new` (never ran),
  `running` (`stopping`), `stopped`, `delivered` (its ticket is done), `conflict` or `accept-failed` (an accept that did not
  land it), `failed` (blocked after its automatic recoveries), `blocked` (a failure of the environment) or `needs-human`.
- `status NAME [--json]`: the task's state, its base and round, its result (the worker's `.task/RESULT.md`, kept as
  `<runtime>/RESULT.md` when the ticket worktree goes), then its `campaign status` (`--json` adds `task` to it).
- `log NAME [--follow]`: the events of the current round (from its `task-round` event) in the display zone; `--follow`
  goes on until the runner stops.
- `diff NAME [GIT DIFF OPTIONS]`: `git diff <base> campaign/<name>`, the worker's delta. While the ticket worktree holds
  work that `campaign/<name>` has not got yet (a round in progress, or the delta `fix --rebase` re-applied), it shows that
  worktree against the base instead, new files included, and says so on stderr.
- `stop NAME [--now]` and `restart NAME [--now]`: `campaign stop` and `campaign restart` of the task; `restart` also starts a
  task created with `--no-start`, always with the brief's settings.
- `fix NAME (--note TEXT | --brief FILE) [--rebase]`, its runner stopped: a new round on the same branch. The findings
  become `diagnosis/T-001.md`, which the round's first worker receives in its prompt (they are kept in
  `state/T-001.findings.md`, and the diagnosis of each automatic recovery of the round opens with them); the ticket is
  `todo` again with a fresh budget of automatic recoveries, and the round runs as `new` runs it. With `--rebase` the base
  becomes the main branch's tip: `campaign/<name>` moves there, the task's delta is re-applied on it mechanically (`git apply --3way`, the
  path of an integration conflict, with conflict markers where both sides changed the same code; event `task-rebased`),
  and the round starts with an `integration-repair` worker that resolves them and applies the findings. The worker never
  rebases. A task without a delta (one that never committed) only has its base moved, and its round starts with a worker.
  The delta is re-applied before anything moves: when no worker could resolve it from markers, nothing moves (the branch,
  the base and the round stay as they were, and the copy of the delta stays in `state/T-001.conflict.patch`), and `fix`
  stops saying why (event `task-rebase-refused`). That is a delta that does not apply at all (for example, the main
  branch deleted or renamed a file the task changes, so `git apply` has no 3-way fallback and rejects the whole patch),
  or a file both sides changed that git merges without conflict markers (a binary file, or a `-merge` or `merge=binary`
  attribute), which only a person can merge. A file that the task and the main branch both deleted is no conflict.
- `accept NAME [--body TEXT]`: see below.
- `drop NAME`: stops the task at once (its engine by its pid when the campaign worktree is gone), runs the
  `task_cleanup` commands, removes its worktrees, branches and runtime, and archives its history as finalize archives a
  campaign's (event `task-dropped`). Its locks stay held until the runtime is gone, so no run starts in it meanwhile.

### Accept

`campaign task accept NAME` lands a delivered task in this machine's main branch with the safety of finalize. It takes a
machine slot for its validation, then the task's locks and `main.lock` (a second accept, or a finalize, waits for it),
and:

1. checks that the task is delivered (its ticket `done`) and that the main worktree has no uncommitted change in the files
   the task changes;
2. in a temporary worktree, squashes the task's commits into one on its base, with the brief's message (`<commit>:
   <title>`, `feat(task): <title>` without `commit`) and the `--body` (the kit adds nothing; the project's git hooks run),
   and rebases it onto the main branch, checking that every changed file kept its change; a conflict aborts it and marks
   the task `conflict` (`task fix NAME --rebase`);
3. runs `accept_regen`, and commits what it changed as `chore(regen): <name>`;
4. runs the task's `validate` commands when the main branch moved since the task's base (with the brief's deadline), and
   the `accept_checks` always (receipt in `<runtime>/validation/accept/`); a red one lands nothing and marks the task
   `accept-failed` with its reason and the receipt (event `task-accept-failed`);
5. fast-forwards the main branch (event `task-accepted`, and `<cache>/finalized/<name>.json`), then cleans up as `drop`
   does, without touching what landed.

An accept that lands nothing leaves the task's branch as it was. The commands of `accept_regen`, `accept_checks` and `task_cleanup` run
through `lib/validation.py`: each one with its deadline (the object form `{"command": [...], "timeout_minutes": N}` is
accepted), in its own process group, without the runner's locks, and with `AGENTIC_TASK=<name>` in its environment. The
git commands that run the project's hooks (the squash's commit, the rebase, the fast-forward, a worktree's checkout, the
checkout that takes a worker's change to a regen path back) run without the kit's locks too, here and in the engine and finalize: a process a hook leaves running never holds one.

### Task settings

These fields of `project.json` are checked when the settings load. A glob is read as `.gitignore` reads one: `*` and `?`
stay within a folder, `**` crosses folders, a glob without a `/` matches at any depth and one with a `/` (or starting with
one) from the root, and a match also covers everything under it.

| Field | Meaning |
| --- | --- |
| `task_preamble` | Path, relative to the repository root, of a file of the main branch whose text opens every task's `.task/TASK.md`, before the brief. Default: none. |
| `task_links` | Map of a name (a file name) to a path, absolute or under `~/` (expanded on each machine): a link of that name to that path at the root of every task's worktree, for what a task reads outside the repository (the rewrite's `webapp-ref`). `task new` refuses a path that does not exist on the machine. Default: none. |
| `task_cleanup` | Commands that remove what a task left outside its worktree (its containers, labelled by `AGENTIC_TASK`), run by `drop` and `accept` from the main worktree. A failure is a warning. Default: none. |
| `accept_regen` | Commands that regenerate the `regen_paths`, run by `accept` on the rebased squash; what they change lands as `chore(regen): <name>`. Default: none. |
| `accept_checks` | Commands every `accept` runs before the fast-forward (the build of the whole solution, the fast tests), besides the task's `validate`. Default: none. |
| `regen_paths` | Globs of files a task's worker may regenerate to validate (`bun.lock`, `AnalyzerReleases.*`) but whose change never enters its commit: the engine leaves it out (event `regen-paths-dropped`) and `accept_regen` regenerates them. A campaign's tickets keep them. Default: none. |
| `coordinator_paths` | Globs that the workers of every task and campaign may not change (`.agents/**`, `Directory.Packages.props`, `package.json`), refused as the `instruction_files` are. Default: none. |

## Final validation

`campaign finalize` runs the plan's `final` commands once, on the rebased tree that the main branch will fast-forward
to (`.agentic/FINALIZE-CAMPAIGN.md` has the whole sequence). Its receipt, `<runtime>/validation/campaign.final.json`,
records the commit it validated (`tip`).

- The receipt is saved after every command (status `RUNNING` until the last one, then `PASS` or `FAIL`), and the receipt it
  replaces is kept as `campaign.final.json.previous` by the first save of a run only.
- A command that passed is not run again when finalize resumes on the same commit: the run takes the passed records
  of the existing receipt (any status, a killed run included), marks them `"reused": true` with their original times,
  prints `campaign final: reusing the PASS of <command> from <time> (same commit <sha>)` and runs the others. The
  final line counts them: `campaign final: PASS (6 commands, 3 reused)`. Nothing is reused when the branch is at
  another commit, when a tracked file has changed (now, or when the evidence was recorded), or when the receipt has no
  `tip`. Ticket phases and the baseline never reuse anything.
- While the final validation runs, finalize keeps the machine-local marker `<cache>/finalizing/<slug>.json` (`slug`,
  `pid`, `startedAt`, `tree`; mode 600), removed when the validation ends and when finalize exits. A finalize that is
  killed outright (SIGKILL, SIGTERM) leaves it behind, and the next reader removes it as stale. The validation commands
  run with `AGENTIC_FINALIZE=<slug>`, so a project's own scripts know they are the finalize's commands and must never
  wait for it.
- `<cache>/main.lock` (`flock`) serializes what moves this machine's main branch: finalize holds it from before its
  rebase onto the main branch until the main branch's cleanup ends, and a task's accept from its gates to its
  fast-forward, so a second finalize or accept waits (up to `AGENTIC_MAIN_LOCK_WAIT_SECONDS`, default 1800, then fails
  naming the pid and command that hold it, kept in `main.lock.holder`) and rebases on what the first left.
  `with_main_lock COMMAND...` of `lib/finalize.sh` is the same lock for any other command that moves the main branch. It
  is held as a machine slot is: by a guard process of the holder with no other descriptor, so no command the holder
  starts inherits it (a build server or a container the validation leaves running never holds the main branch), and it
  comes back when the holder ends, even by SIGKILL.
- `campaign finalizing` (machine-local: no campaign branch, any worktree of the project, never routed to another
  machine) prints one line per finalize validating on this machine, `<slug> since <time> (pid <pid>)`, with the time
  in the display zone, and exits 0; with none it prints nothing and exits 1. It removes the markers of finalizes that
  are gone (a dead pid, or a pid that is no longer a `campaign` process). It takes no option but `--help`. Project
  tools use it to stay away from the machine while a final validation runs.

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
- with `AGENTIC_CLAUDE_ACCOUNTS` set and installed on NAME, the join runs `<hook> account list --json` there and adds a
  pending item for each account without a login (`logged_in: false`) or without its onboarding (`onboarded: false`),
  with the command that fixes it (`CLAUDE_CONFIG_DIR=<folder> claude`, once); a hook that does not know `list` (exit
  2) or prints no JSON adds nothing;
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
- `campaign overview --fleet [--json]` adds every machine's `campaign overview` (its `campaigns`, `queues` and `rounds`). A
  machine that does not answer shows the ones seen last (`seen_at`, `seen_local_time`), kept in `fleet-seen.json` of
  the project's cache. Without a fleet it shows this machine alone.
- `campaign machine [--json]` is what a machine offers a task, read now: `name`, `at`; `slots` (`capacity`, `null`
  without a limit; `used`; `free`; `holders`, each `{slot, kind, label, since}` of an occupied slot, occupied meaning its
  `flock` is held); `load1`, `cpus`, `mem_available_mb`; `accounts` (what `<hook> account list --json` prints when the
  hook of `AGENTIC_CLAUDE_ACCOUNTS` understands it, else `{enabled, current}`; `null` without a hook); `capabilities`
  (`{name, proven, reason}` for each `capabilities` entry of `project.json`: the proof's argv run here, with no shell,
  within 10 s; `proven` is exit 0 and `reason` the first line of its error); and `accepts` (`machines.<name>.accepts`
  of the fleet file, default `true`). What a task `requires` is thus proven by the machine, not declared.
  `campaign machine --fleet [--json]` reads every machine of the fleet the same way, over ssh, under `fleet.lock` and
  with the survey cache; a machine that does not answer has `reachable: false`, its error and its last report
  (`seen_at`, `seen_local_time`, kept in `fleet-seen.json`).
- A survey of the fleet runs under `<cache>/fleet.lock`, so two processes on a machine never fetch the same peers at once
  (git's "cannot lock ref" made a peer look down), and `fleet-seen.json` is read and written under it. Its result (the
  peers' answers, not this machine's own state) is kept for `AGENTIC_FLEET_CACHE_SECONDS` (default 30, `0` for none): a
  survey that arrives while another one runs waits, then uses what it learned. `move` and the commands routed to
  another machine drop the cache; a change in the fleet's machines makes it stale by itself.
- `campaign init` refuses a slug that a campaign branch of another machine already has, and warns about a main branch
  behind another machine's and about a machine that did not answer (the slug was not checked there).
- `status`, `stop`, `run`, `restart`, `decide`, `recover`, `watch` and `move` take `--campaign SLUG [--on MACHINE]`
  from any worktree of the project: on this machine when it holds the campaign, else on the machine of the fleet that
  does (MACHINE when given, and several holders need it), in that campaign's worktree there, over ssh. The output and
  the exit status are the command's there. It runs with the kit of that machine's main clone, so a campaign created by
  an older kit is driven by the one its machine's main branch holds now (pulled there by hand). The caller's
  `AGENTIC_*` settings travel with it (`AGENTIC_CLAUDE_MODEL=sonnet
  campaign run --campaign SLUG ...`), except the ones that name this machine's paths or identity (`AGENTIC_CACHE`,
  `AGENTIC_FLEET`, `AGENTIC_MACHINE_ID`, `AGENTIC_SSH`, `AGENTIC_PROVIDER_DIR`, `AGENTIC_SUPERVISOR`) and the machine's
  own (`AGENTIC_SLOT`, the round's slot among the machine's slots, and `AGENTIC_STATE`, the machine's state folder),
  which never travel: not to a routed command, not to an executor, not into `run-config.json`.
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

`campaign status` also says where the campaign is (`location` in `--json`): the machine, the project's main clone, the
campaign's worktree and the command that opens its provider's CLI there (`cd <worktree> && claude`). From another machine
of the fleet that command starts with the ssh to the campaign's machine (`ssh -t <machine> 'cd <worktree> && claude'`).
`campaign overview` gives the same for every campaign (`machine`, `project`, `worktree`, `provider`, `open`), and
`campaign run` and `campaign move` print it when they start or hand over a campaign.

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
pending decisions, the count of findings a [guard](#guards) could catch, recent events); with `--fleet`, on every machine of the project's [fleet](#fleet). The
`campaign-status` skill reports `overview --fleet`.

## Human decisions

Only `product-ambiguity`, `requirement-change`, and `destructive-risk` create decisions. Apply one with
`campaign decide <ticket> <retry|block|cancel>`. A decision is consumed when applied: a second `decide` for the
same ticket fails with "no pending decision".

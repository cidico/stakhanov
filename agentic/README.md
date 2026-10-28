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
| `executors` | Remote machines that run workers; see [Remote executors](#remote-executors). Default: none, every role runs on this machine. |

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

The runner sets `AGENTIC_CAMPAIGN_ROOT` for the adapters; it is not a setting.

## Starting a campaign

`campaign init <spec> [--slug <kebab-name>]`, run from the main branch, creates `campaign/<slug>` and its
worktree and commits the spec as `campaigns/<slug>/SPEC.md`. The slug is `--slug`, or else derived from the
spec's first `# ` heading; there is no fallback to the file name, and `init` stops when neither gives a slug.
`init` also refuses when the main branch has no committed `.agentic/bin/campaign` (commit the installed kit
first), and `campaign queue start` refuses the same way. `.agentic/SPEC.md` has the spec contract and
`.agentic/TICKET.md` the tickets; `campaign verify` checks both and the validation plan.

Required commands: `bash`, `git`, `jq`, `python3`, `flock`, `setsid` and the usual coreutils (plus `ssh` and
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
  {"name": "build-box", "ssh": "build-box", "workers": 1, "root": "/srv/agentic",
   "run": ["/usr/local/bin/agentic-worker-run"], "exclude": ["node_modules/", "bin/", "obj/"],
   "rsync_options": ["--chmod=g+rwX"]}
]
```

| Field | Meaning |
| --- | --- |
| `name` | `[a-z0-9-]+`, unique; `local` is reserved for this machine. |
| `ssh` | ssh destination or alias. Batch mode: the host must accept a key without prompts. |
| `workers` | Positive integer: tickets this executor runs at once. |
| `root` | Absolute path on the host under which every local absolute path is mirrored (local `/x/y` lives at `<root>/x/y` there). Empty (the default) means the same paths. |
| `run` | Optional argv prefix on the host that runs the adapter and presents `<root>/x/y` at `/x/y` to it (for example a container with bind mounts). It receives `env NAME=VALUE... bash <adapter> <role> <worktree> <prompt> <result> <events>` with local paths. Without it, `root` must be empty. |
| `exclude` | rsync exclude patterns for the worktree sync, both ways (`/.git` is always excluded). Excluded folders are neither sent nor deleted on either side. |
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
  `project.json` and the runner's git settings, with its worktree marked `safe.directory`.
- When the executor fails before the adapter starts (ssh, mirror push, checkout or sync), the engine emits
  `executor-unavailable` with the reason, runs that ticket here for the rest of the run, and repeats the invocation
  at once without spending one of its two attempts. The ticket keeps its executor slot, so this machine may run up
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
- `campaign-watch` measures the CPU of local processes only: a remote worker that writes no event for longer than
  `--stall-minutes` wakes the coordinator as a silent provider.

## Legacy campaign layout (accepted, not produced)

Campaigns created before the kit keep running and finalizing; the kit never writes this layout.

- A SPEC may carry, instead of the current sections, every one of `Problem`, `Goals`, `Non-goals`, `Decisions`,
  `Requirements`, `Constraints`, `Acceptance` and `Open questions`. Sections of the two layouts never combine to
  complete one. With the legacy sections, `Open questions` may also read `Nenhuma`.
- A validation plan without `final` uses its plan-level `campaign_expensive` list as the final list.

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
pending decisions, recent events); the `campaign-status` skill reports it.

## Human decisions

Only `product-ambiguity`, `requirement-change`, and `destructive-risk` create decisions. Apply one with
`campaign decide <ticket> <retry|block|cancel>`. A decision is consumed when applied: a second `decide` for the
same ticket fails with "no pending decision".

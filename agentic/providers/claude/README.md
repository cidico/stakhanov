# Claude provider adapter

`run.sh` starts a new headless `claude --print` process for every role invocation. It never uses
`--continue`, `--resume`, or a session ID, and disables session persistence. Workers use
`bypassPermissions` so they can run builds and tests; reviewers and diagnosticians run the same way but with
`--disallowedTools Edit,Write,NotebookEdit,MultiEdit`, keeping `Bash` for tests and `git diff`. They do not use `--permission-mode plan`
because the CLI's plan mode calls a second model next to the one asked for (a haiku reviewer also used sonnet, about 20x the
cost); the runner's `reviewer-mutated` check is what guarantees a reviewer changed nothing. Every role
runs with `--permission-prompts none`, so anything that would prompt (including the user's `ask`
rules) is denied instead of waiting. The settings of a role are the kit's and the project's, never the user's: the adapter
passes `--setting-sources project,local` (the user's settings, and with them the user's hooks and the plugins the user
enabled, are not loaded, because a blocking hook such as a PermissionRequest hook waiting for a desktop approval stalls a
headless worker) and, with `--settings`, one hook of its own: `bin/role-guard ROLE` as a PreToolUse hook of Bash, which blocks
`sed -i`, `perl -i`, shell redirections, heredocs and `tee` that write files and git commands that write (the role edits
with Edit and Write, and the runner commits; see "Role guard" in `.agentic/README.md`). The command is the absolute path of
this kit's `bin/role-guard`, so a role on a remote executor uses the one synced there. `disableAllHooks` is not used any more:
it would switch the guard off too. The trade-off: the hooks and `permissions` of the project's `.claude/settings.json` (and of
`settings.local.json`) now load in a role, as they never did, so a blocking hook of the project can stall one; and what the
user keeps only in the user-level `settings.json` (an `apiKeyHelper`, `env`, model aliases) is not seen by a role: give it to
the runner through `AGENTIC_*` variables or the `env` of `project.json`. The adapter passes
the common schema through native `--json-schema` and extracts only the validated
`structured_output` object from Claude's JSON result envelope. The envelope's cost (`total_cost_usd`), tokens,
`num_turns` and `duration_ms` go to `<result>.usage.json` and to `usage` in the `completed`/`failed` events, summed over
the attempts when the account hook repeats the call (`attempts` in the event); a missing field is `null`.

Defaults are `high` effort for workers, reviewers and diagnosticians. Override them
with `AGENTIC_CLAUDE_WORKER_EFFORT`, `AGENTIC_CLAUDE_REVIEWER_EFFORT`, or
`AGENTIC_CLAUDE_DIAGNOSTICIAN_EFFORT`; `AGENTIC_CLAUDE_EFFORT` is the provider-wide fallback.
Every invocation passes an explicit `--model`, so a role never inherits the account default (which
follows the last interactive `/model` choice). Defaults are `opus` for workers, reviewers and
diagnosticians. Override them with `AGENTIC_CLAUDE_WORKER_MODEL`,
`AGENTIC_CLAUDE_REVIEWER_MODEL`, or `AGENTIC_CLAUDE_DIAGNOSTICIAN_MODEL`; `AGENTIC_CLAUDE_MODEL` is the
provider-wide fallback.

`run.sh --preflight <interactive|unattended>` checks that the installed CLI advertises every flag the
adapter uses and parses the exact non-interrupting invocation through `--help`, without a model turn.
Claude Code 2.1.285 was validated with real worker and reviewer invocations: the worker ran shell
commands and edited files, and the reviewer read the diff without changing the worktree.

Account hook (compatible with udarnik's `account` commands): when `AGENTIC_CLAUDE_ACCOUNTS` names a command and
`<command> account enabled` exits 0, claude runs in the account that `<command> account current` prints, through the env
prefix of `<command> account env ACCOUNT`. When claude fails, its output goes to `<command> account limit ACCOUNT` on
stdin. If that was a usage limit and the hook prints another account, the same invocation (same arguments and model)
runs once more there, with the provider event `account` naming both accounts (and, for a worker, a note in the prompt
that the cut-off process left partial, unverified work); a second failure is reported to the hook but not retried. Exit 75 from the hook
means no account is left: the adapter then exits 75 and its stderr carries `accounts-back-at=EPOCH` (from `<command>
account next`), so the runner waits for that time and runs the same invocation again without spending an attempt.
Any other status means it was not a usage limit: the role fails as it does without the hook. A missing command, a
disabled hook or an unusable account leaves claude in the caller's account.

Transient API errors (status 429 that is not a usage limit, 500, 502, 503, 529, or the text `overloaded` / `rate limit`) do not fail the role: after a failed process the hook says it was not a usage limit (without a hook, the text must not say so), and the adapter waits 30 s, 60 s, 120 s plus a random delay of up to 50 % and runs the same process again, at most `AGENTIC_PROVIDER_TRANSIENT_RETRIES` times (3 by default; 0 turns it off). Each retry is a `transient` event with the status and the wait, the usage sums every process (`attempts`), a stop request (TERM) ends the wait at once, and a usage limit is never retried this way. The adapter tells the hook it is a worker (`account current --kind worker`, `account limit ACCOUNT --kind worker`); a hook that answers 2 to `--kind` is called again without it.

After a process that succeeded (exit 0, result extracted and validated) the adapter calls `<command> account clear --at EPOCH ACCOUNT --kind worker` for the account that produced it, so an account marked out comes back for the fleet; `EPOCH` is the time (seconds) the claude process that produced the result ended, which the hook uses to tell the "out" marks older than that proof. It does so even when the account was not marked, and never fails or holds the call: a status 2 (an older hook) repeats the call without `--kind` and, if still 2, without `--at` too; any status other than 0 after that, a hook still running after `AGENTIC_CLAUDE_ACCOUNT_CLEAR_SECONDS` (10 s) or a missing hook is one line on stderr. Codex and Grok have no account hook.

The runner prompt names the project's instruction files, so no Claude-specific project rule exists.

## Readiness

`run.sh --ready` exits 0 when `claude` is installed and signed in, 69 when it is missing, 77 when it is not signed in; `run.sh --install`
installs it for the current user and `run.sh --login` signs in interactively. `campaign fleet join` uses them on a new
machine.

## Session mode

> In plain words: normally every role of a campaign (worker, reviewer, diagnostician) is a separate headless `claude -p`
> process. In session mode you open one ordinary interactive Claude Code session and run `/campaign-host` in it; the
> runner leaves each role as a request in a queue and that session runs it as a background subagent. Nothing else in the
> campaign changes. The friendly explanation is in the
> [main README](../../../README.md#running-roles-inside-your-interactive-session); the details follow.

`AGENTIC_CLAUDE_MODE=session` (project.json `env`, or the environment; the default is `print`, everything above) runs no
`claude --print` process. The roles run as background subagents of an interactive claude session, the host, because
headless traffic can be metered heavier than the interactive client's.

- **Host.** `/campaign-host` (skill) runs `.agentic/bin/session-host register` and keeps `session-host wait` running in the
  background. `register` finds the calling `claude` process, its session id and account in
  `<CLAUDE_CONFIG_DIR or ~/.claude>/sessions/<pid>.json`, its cgroup, and writes `hosts/<pid>.json` in the queue; it removes
  the files of dead hosts, puts the requests of dead hosts back in the queue and runs `udarnik keep SESSION` when udarnik
  knows it. `wait` prints `new ID` (a pending request) and `cancel ID AGENT_ID` (stop that subagent) and exits; `brief ID`
  prints the fields of the Agent tool call (`subagent_type`, `model`, `effort`, `description`, `run_in_background`,
  `prompt`) and reserves the request for this host for two minutes (two hosts never run the same role); `claim ID AGENT_ID`
  records the subagent; `cancelled ID` records that it was stopped; `status` lists hosts and requests; `unregister` removes
  the host. The agents (`campaign-worker`, with every tool but Agent; `campaign-reviewer` and `campaign-diagnostician`, with
  Read, Grep, Glob and Bash) are installed into the project's `.claude/agents/`. Each of them carries, in its frontmatter,
  a `hooks:` block with `bin/role-guard ROLE` as a PreToolUse hook of Bash (the same guard as print mode, see "Role guard" in
  `.agentic/README.md`). A hook declared in an agent's frontmatter fires only for that subagent; exit 2 blocks the call and its
  stderr reaches the model. Its command is `"${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"/.agentic/bin/role-guard
  ROLE`: Claude Code sets `CLAUDE_PROJECT_DIR` for hook commands, and when it is not set the project is the git top level of
  the folder the hook runs in (any worktree of the project has the kit). If neither finds the file the shell answers 127,
  which does not block: the guard is then off, never the role.
- **Queue.** `${AGENTIC_SESSION_DIR:-${XDG_STATE_HOME:-~/.local/state}/agentic-session}`, shared by every project of the
  machine: `hosts/` and `requests/<id>/`. A request folder holds `request.json` (id, project, ticket, role, model, effort,
  read_only, worktree, prompt, result, done, schema, created, attempt, adapter_pid), the copy of the combined prompt
  (`prompt.md`), the role's RESULT schema (`schema.json`) and, written later, the markers `assigned` (host pid, host
  session, agent id, transcript, time), `done` (the subagent wrote `result.json` completely), `cancel` (reason),
  `cancelled` (the host stopped the agent), `limited` (accounts that hit their limit), `finished` (the adapter ended
  without taking a result; pruned after a day). Everything is written atomically.
- **Adapter.** It files the request, then every 5 s: `done` present gives the result its role validation and, if valid,
  copies it to the engine's result path (exit 0; an invalid one exits 1 with `invalid provider result: REASON`, and the
  engine re-invokes once with the error appended). No `assigned` yet, or a dead host, means it keeps waiting and never counts
  that as idle (event `waiting for a host session`). A stop request (TERM, INT) writes `cancel` ("stop requested") and ends
  it at once. The preflight (`--preflight`) checks a live host instead of the CLI flags and exits 69 when there is none
  (`no live campaign host session on this machine; open one with /campaign-host`), which the runner retries later, so a run
  waits until a host is open. `--ready` is unchanged.
- **Idle rule.** A subagent is stopped only when for `AGENTIC_SESSION_IDLE_SECONDS` (600) none of these moved: its
  transcript's mtime and, when its transcript ends with a pending Bash call, the CPU time and the I/O of the processes
  running that command (the `bash -c ... eval '<command>'` wrapper found by the command text, restricted to the host's
  cgroup when known) and their descendants. Then a confirming sample of `AGENTIC_SESSION_SAMPLE_SECONDS` (30) follows; still
  nothing writes `cancel` ("idle"), waits up to 60 s for `cancelled` and exits 124 (the runner's `provider-timeout`).
  A pending tool other than Bash has no process, so only the transcript counts. There is no wall-clock deadline:
  the runner gives every role `AGENTIC_SESSION_MAX_SECONDS` (7 days).
- **Subagent ended without a result.** Its last transcript entry is a final assistant message with no pending tool call
  and `done` is still absent after 60 s: exit 1 with `invalid provider result: the subagent ended without writing its result`.
- **Usage limit.** The transcript ends with an API error entry (`isApiErrorMessage` and `error: rate_limit`, or a text
  like `hit your ... limit` / `usage limit reached`). With `AGENTIC_CLAUDE_ACCOUNTS` on, the text goes to `<hook> account
  limit <host account>`: status 0 (another account exists) takes the request back to the queue, hosts of the limited
  account skip it, and a host in another account (the limited session moved there by the takeover, or another session) runs
  it; status 75, or no hook, exits 75 with `accounts-back-at=EPOCH` (from `<hook> account next`, else 0), so the runner
  waits for quota. A validated result calls `<hook> account clear` for the host's account, as the `--print` path does.
- **Usage.** The usage file is summed from the subagent's transcript (assistant messages, once per message id): tokens,
  turns and duration; `cost_usd` stays null because a transcript carries no cost.

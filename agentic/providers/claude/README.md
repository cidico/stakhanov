# Claude provider adapter

`run.sh` starts a new headless `claude --print` process for every role invocation. It never uses
`--continue`, `--resume`, or a session ID, and disables session persistence. Workers use
`bypassPermissions` so they can run builds and tests; reviewers and diagnosticians use read-only
`plan` permission mode, which still allows read-only shell commands such as `git diff`. Every role
runs with `--permission-prompts none`, so anything that would prompt (including the user's `ask`
rules) is denied instead of waiting. User and plugin hooks are disabled with `--settings
'{"disableAllHooks":true}'`, because a blocking hook (such as a PermissionRequest hook waiting for a
desktop approval) stalls a headless worker. The adapter passes
the common schema through native `--json-schema` and extracts only the validated
`structured_output` object from Claude's JSON result envelope.

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

The runner prompt names the project's instruction files, so no Claude-specific project rule exists.

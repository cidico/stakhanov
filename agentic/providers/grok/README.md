# Grok provider adapter

`run.sh` starts a new single-turn/headless Grok process for every role invocation. It never uses
`--resume` or `--continue`, disables subagents, supplies `--always-approve`, and uses native
`--json-schema` output. Workers use `bypassPermissions` for non-interrupting execution; reviewers and
diagnosticians use read-only `plan` mode and `--disallowed-tools` for the shell and subagents.
A denied shell or `spawn_subagent` permission in plan mode cancels the whole headless turn and
yields no RESULT, even when `--no-subagents` is set. These are Grok-native
controls, not Codex or Claude policy.

Grok 1.0.13 emits `{text, stopReason, sessionId, requestId}` in JSON mode, with the schema-constrained
canonical RESULT serialized in `text`. The adapter parses that native envelope, including
camelCase `structuredOutput` (and snake_case `structured_output`) only when Grok session
fields are present, and rejects a Claude-only `structured_output` wrapper. `run.sh --preflight <interactive|unattended>` verifies the installed
flags and invocation shape without making a model call.

Defaults are `medium` effort for workers and `high` for reviewers and diagnosticians. Override them
with `AGENTIC_GROK_WORKER_EFFORT`, `AGENTIC_GROK_REVIEWER_EFFORT`, or
`AGENTIC_GROK_DIAGNOSTICIAN_EFFORT`; `AGENTIC_GROK_EFFORT` is the provider-wide fallback.
`AGENTIC_GROK_MODEL` optionally selects a model.

Smoke validated locally against Grok 1.0.13: prompt file, cwd, JSON output, JSON Schema, subagent
control, always-approve, permission mode, effort, and model flags are accepted by the installed CLI.
No model invocation was made.

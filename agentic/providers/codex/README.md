# Codex provider adapter

`run.sh` starts a new `codex exec --ephemeral` process for every role invocation, including
repair workers. It explicitly passes `--dangerously-bypass-approvals-and-sandbox` before `exec`:
all roles have full operational access to Docker and runtime/cache paths outside the
worktree, without approval prompts or reliance on the parent session configuration. Reviewer and
diagnostician read-only responsibilities remain role instructions, not OS sandbox restrictions.
Working-directory, model and effort options also precede `exec`; structured output options follow it.
It never uses `resume` or `fork` and retains native `--output-schema` validation.

`run.sh --preflight <interactive|unattended>` checks the installed CLI help and exercises parsing of
the global-before-`exec` non-interrupting shape without making a model call. Both modes use the same
approval-free subprocess policy.

Defaults are `medium` effort for workers and `high` for reviewers and diagnosticians. Override them
with `AGENTIC_CODEX_WORKER_EFFORT`, `AGENTIC_CODEX_REVIEWER_EFFORT`, or
`AGENTIC_CODEX_DIAGNOSTICIAN_EFFORT`; `AGENTIC_CODEX_EFFORT` is the provider-wide fallback.
`AGENTIC_CODEX_MODEL` optionally selects a model without committing a personal model ID.

The installed CLI must advertise the bypass flag; preflight fails closed if it is unavailable.
Argument regression tests cover every role. Operational smoke tests must invoke this adapter with a
fresh worker and verify Docker daemon access and a write under the agentic cache.

Real adapter smoke passed with `codex-cli 0.153.4`: a fresh worker queried the Docker daemon and
wrote/read a marker under the agentic cache. It reported `danger-full-access` and `approval never`; no
interactive approval was supplied. Smoke artifacts remain outside Git.

An optional `campaigns/<slug>/codex-effort.json` policy in the canonical adapter worktree
has highest precedence over inherited role variables, provider fallback and CLI user defaults.
It declares `roles` (coordinator, worker, reviewer, diagnostician) and `allowed_efforts`;
missing or disallowed role values stop before a model call. No policy changes model selection.
The coordinator is the interactive session; its entry records the requested effort, while the
shell supervisor is deterministic and has no model. Per-ticket entries document classification;
execution uses the role override when all tickets require the same effort.

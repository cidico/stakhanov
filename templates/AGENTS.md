<!-- stakhanov:start -->
## Functional acceptance first

Acceptance criteria and observed product behavior are the source of truth. The workflow exists to deliver
them: workflow metadata, receipts, and coordination machinery never block implementation, and a conflict
between the two is fixed by simplifying the workflow. Commits and SHAs are history, not proof of
correctness; proof is the validated behavior of the current code. Use the smallest validation that
meaningfully increases confidence in the change.

## Work routing

Read [`.agentic/WORKFLOW.md`](.agentic/WORKFLOW.md) before substantial implementation. It selects one of
three modes: `direct`, `ticket`, or `campaign`.

- Read [`.agentic/SPEC.md`](.agentic/SPEC.md) when creating or changing a campaign specification.
- Read [`.agentic/TICKET.md`](.agentic/TICKET.md) when creating or changing campaign tickets.
- Read [`.agentic/VALIDATION.md`](.agentic/VALIDATION.md) when defining executable campaign proof.
- Run `/run-campaign` only from a canonical `campaign/<slug>` branch.
- Run `/finalize-campaign` to validate, clean, and fast-forward a completed campaign into this machine's main branch.
- Run `/campaign-status` for the board of every campaign and queue, on every machine of the project's fleet.
- A campaign held by another machine of the fleet is driven from here with `.agentic/bin/campaign <command> --campaign
  <slug>` (`.agentic/README.md`, "Fleet").

## Model delegation

Outside a campaign, a coordinating session on Claude Fable or Opus is the architect: it diagnoses, decides,
writes a closed brief, and reviews the result itself. Execution goes to subagents on a cheaper model.

- Fable delegates to Sonnet for a closed brief, and to Opus when the builder must make design or cross-file
  decisions on its own. Opus delegates to Sonnet the same way. Sonnet does not delegate.
- Delegate manual and repetitive work: applying decided changes, running captures and suites, mechanical
  fixes, broad searches.
- Do a task of one or two commands yourself: a fresh subagent costs about 30k tokens before it starts.
- Keep one builder per area and send it follow-up orders instead of spawning a new one. Start a fresh
  builder when the previous one has been idle for more than an hour, carries a very large context, or the
  task is unrelated to what it read.
- Never relay a builder's report as verification; inspect the result first.

Campaign roles are fresh processes by design and never reuse a session; their model and effort come from the
provider adapter.

## Git rules

- The campaign supervisor owns its lifecycle commits. Outside it, only the coordinating main process stages
  and commits.
- Integration into the main branch is `git merge --ff-only`; when another branch landed first, rebase onto
  the main branch and merge again.
- Never commit secrets, auth material, private configuration, runtime state, logs, PIDs, temporary
  prompts/results, or worktrees.
- Destructive resets, other force operations, and external state changes require the user's current order.

## Agent skills

### Issue tracker

Specs and tickets are campaigns of `.agentic`; see `docs/agents/issue-tracker.md`.

`grilling`, `to-spec` and `to-tickets` come from https://github.com/mattpocock/skills, unmodified, and are
installed by `install.sh`.
<!-- stakhanov:end -->

# Campaign ticket contract

Tickets live at `campaigns/<slug>/tickets/<id>.md`. `/to-tickets` (Matt Pocock's skill, installed by `install.sh`)
writes them into the campaign worktree through `docs/agents/issue-tracker.md`; `campaign verify` checks them.
A ticket id is a capitalized prefix, a hyphen and at least three digits (`^[A-Z][A-Z0-9]*-[0-9]{3,}$`, for
example `AUTH-001`). Start every ticket with:

```yaml
---
id: AUTH-002
status: todo
risk: high
depends_on:
  - AUTH-001
collision_domains:
  - api:sessions
required: true
---
```

Allowed status values are `todo`, `in-progress`, `blocked`, `needs-human`, and `done`. `READY` is not
persisted; the runner calculates it when `status == todo` and all dependencies are `done`.

Allowed risk values are `low`, `medium`, and `high`. Classify remote environments, multi-service
Docker, large storage or corpora, real auth, external providers, schema migration/cutover, expensive
E2E, and destructive operations as high unless concrete evidence lowers the risk.

`collision_domains` lists the concrete files, modules, schemas, generated artifacts, services, or
other exclusively written resources this ticket owns. Omitted or empty ownership is scheduled
conservatively; declare domains so the runner can prove that parallel writers are independent.
`required` is a boolean and defaults to `true`; an optional ticket must say `required: false` explicitly.

Use these sections in order:

# Goal

One independently deliverable outcome owned by this ticket.

# Acceptance

Observable conditions that prove the goal is complete.

# Non-goals

Adjacent behavior excluded from this ticket.

# Context

Relevant paths, contracts, consumers, decisions, dependencies, and task-specific documents. Keep the
ticket self-contained without copying repository-wide rules.

# Validation

Encode the executable form of this plan in `campaigns/<slug>/validation.json` according to
`.agentic/VALIDATION.md`. Commands are reviewed campaign input, not provider output.

## Cheap

List applicable L0/L1 commands and expected evidence.

## Component

List applicable L2/L3 proof and prerequisites.

## Expensive

List only the expensive operations this ticket needs, their prerequisites, resumable phases, and
cleanup. Write `None` when no L4 proof applies.

Medium and high-risk tickets explicitly state their risk hypothesis and validation ladder in Context
and Validation. Declare every ticket dependency and collision domain. Split a ticket when its
acceptance spans independent outcomes, collision domains, or more than one safe worker context.

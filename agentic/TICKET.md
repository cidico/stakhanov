# Campaign ticket contract

Tickets live at `campaigns/<slug>/tickets/<id>.md`. `/to-tickets` (Matt Pocock's skill, installed by `install.sh`)
writes them into the campaign worktree through `.agentic/ISSUE-TRACKER.md`, and `campaign verify` checks them. A
task has no ticket file to write: it is generated from the brief (`.agentic/TASK.md`).

A ticket id is a capitalized prefix, a hyphen and at least three digits (`^[A-Z][A-Z0-9]*-[0-9]{3,}$`, for example
`AUTH-001`). Start every ticket with:

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

## Fields

- `id`, `status`, `risk` and `depends_on` are required. `depends_on` is a list of ticket ids, empty when none.
- `status` is one of `todo`, `in-progress`, `blocked`, `needs-human` and `done`. `READY` is not persisted: the runner
  calculates it when `status == todo` and every dependency is `done`.
- `risk` is one of `low`, `medium` and `high`. Classify remote environments, multi-service Docker, large storage or
  corpora, real auth, external providers, schema migration/cutover, expensive E2E and destructive operations as
  `high` unless concrete evidence lowers the risk.
- `collision_domains` lists the files, modules, schemas, generated artifacts, services or other exclusively written
  resources this ticket owns. Omitted or empty ownership is scheduled conservatively; declare domains so the runner
  can prove that parallel writers are independent.
- `required` is a boolean and defaults to `true`. An optional ticket says `required: false` explicitly.
- `validate_base: skip` and `validate_base_reason` are optional and go together. Without them the runner proves, before
  the ticket's first worker starts, that the ticket's validation fails on its base (`.agentic/VALIDATION.md`). `skip` says
  that the validation cannot fail there (a refactor that the existing tests already prove, documentation), and the
  mandatory `validate_base_reason`, one line, says why; it is recorded in the events. A `skip` without a reason, a reason
  without `skip` and any other value make `campaign verify` fail.

## Sections

Use these sections, in this order.

# Goal

One independently deliverable outcome owned by this ticket.

# Acceptance

Observable conditions that prove the goal is complete.

# Non-goals

Adjacent behavior excluded from this ticket.

# Context

Relevant paths, contracts, consumers, decisions, dependencies and task-specific documents. Keep the ticket
self-contained without copying repository-wide rules.

# Validation

Encode the executable form of this plan in `campaigns/<slug>/validation.json`, as `.agentic/VALIDATION.md` says.
Commands are reviewed campaign input, not provider output.

## Cheap

List the applicable L0/L1 commands and the expected evidence.

## Component

List the applicable L2/L3 proof and its prerequisites.

## Expensive

List only the expensive operations this ticket needs, their prerequisites, resumable phases and cleanup. Write `None`
when no L4 proof applies.

## Rules

- The ticket's `cheap` and `component` commands must fail on the base, before the work: a test that already passes
  proves nothing. Write them so that a missing implementation makes at least one fail, or set `validate_base: skip` with
  its reason.
- A `medium` or `high` risk ticket states its risk hypothesis and validation ladder in Context and Validation.
- Declare every dependency and collision domain.
- Split a ticket when its acceptance spans independent outcomes, collision domains, or more than one safe worker
  context.

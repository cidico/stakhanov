# Agentic Workflow

Success is defined in the project's root instruction file, in the "Functional acceptance first" section installed
from `templates/AGENTS.md`. This file covers the work modes, the ticket lifecycle, failure handling and the
validation ladder. `.agentic/bin/campaign` enforces scheduling, timeouts, repair limits and integration, and
`.agentic/README.md` documents them; agents do not re-implement them.

## Modes

- `direct`: a small, reversible change. No kit.
- `task`: one brief (`.agentic/TASK.md`), one branch, one worker. For work that comes broken into independent
  pieces. Run it with the `campaign task` commands (`.agentic/README.md`).
- `campaign`: dependent tickets of one cohesive unit, scheduled from a `campaign/<slug>` branch.

## Ticket lifecycle

A ticket goes to a fresh worker in an isolated worktree: implement, validate, then a fresh read-only reviewer.
A task is a campaign of one ticket and follows the same lifecycle; its brief can skip the reviewer. Before the first
worker starts, the runner proves that the ticket's validation fails on its base (`.agentic/VALIDATION.md`), or the
ticket says why it cannot (`validate_base: skip`).

- `PASS` integrates the ticket.
- `FIX` returns concrete findings for one focused repair and a fresh review.
- `REPLAN` means the requirement, the dependency or the ticket boundary must change.
- Every rejection justifies each finding: the defect, the rule or failure behind it, and how to fix it. The runner
  refuses a rejection without them.
- Every finding also names its guard: the automatic check (analyzer, lint, test, validate or executor) that would have
  caught it, or `reviewer-only` when none can. `campaign guards` lists the findings that a check could have caught.
- The same category of finding is not fixed by hand twice. The second time it appears, it becomes a ticket that builds its
  guard, and only then is the finding fixed.

Workers:

- Read the project's root and scoped instruction files (`instruction_files` in `.agentic/project.json`), the
  ticket, the SPEC and the relevant contracts.
- Reuse an existing ticket delta instead of reimplementing it.

Only the coordinator stages, commits and integrates. Integrated ticket worktrees and branches are removed afterwards.

## Models per stage

Spend the premium model where one mistake costs the whole campaign, and nowhere else.

| Stage | Model |
| --- | --- |
| SPEC: decisions, requirements, acceptance | Fable |
| Code survey before the SPEC | Sonnet, delegated |
| Tickets and validation commands | Opus (Fable for a delicate campaign) |
| Worker | Opus (high effort) |
| Reviewer and diagnostician | Opus |
| Coordinating `/run-campaign`, `/campaign-status`, `/finalize-campaign` | Sonnet or Opus |

The provider adapter enforces the worker, reviewer and diagnostician models. The other rows are the model of the
interactive session doing that stage.

## Failures and diagnosis

- A known technical cause needs fix → retest, not permission.
- When the cause is obscure or failures repeat, a fresh read-only diagnostician may help. Diagnosis is optional and
  never a retry authorization.
- Preserve useful evidence, prefer a smaller reproduction, and resume from the nearest valid phase.
- Never rerun an expensive operation without a concrete correction or a new hypothesis.
- Provider, adapter, parser and runner failures are harness failures, not product findings: preserve the delta and
  fix the machinery. Incomplete or placeholder reviewer output is a provider failure.

## Human decisions

Ask a human only for product ambiguity, a requirement change, or a destructive operation outside the owned campaign
namespace. Routine commands never need approval. A `needs-human` ticket does not stop independent tickets.

## Validation ladder

- `L0 static`: format, syntax, types, analyzers, lint, architecture and diff checks.
- `L1 unit`: focused deterministic tests without real service boundaries.
- `L2 component`: component, handler or contract proof within one subsystem.
- `L3 targeted integration`: focused proof across real persistence, HTTP or service boundaries.
- `L4 expensive/full proof`: full suites, browser/E2E, remote environments, large corpora or storage, multi-service
  Docker, migrations/cutovers, destructive operations, or costly provider execution.

Run the applicable levels in order; L4 is never discovery.

- Ticket validation runs only the ticket's declared commands.
- Campaign-wide L4 runs only when a ticket opts in, a checkpoint declares it, or `/finalize-campaign` runs. Risk
  level alone never adds validation.
- Before L4, confirm the required inputs, environment, capacity and isolation, and exercise the artifact or process
  this run just built or started.

# Campaign specification contract

The canonical specification is `campaigns/<slug>/SPEC.md`. Matt Pocock's `/to-spec` (installed unmodified by
`install.sh`) produces it and publishes it through the tracker configuration in `.agentic/ISSUE-TRACKER.md`: the skill
writes the spec to a temporary file outside the repository and runs, from the main branch:

```
.agentic/bin/campaign init <spec-path> --slug <short-kebab-name>
```

Remove the temporary input after a successful initialization. A task needs no SPEC: its brief is `.agentic/TASK.md`.

The specification uses the `/to-spec` template, in this order, plus one machine-checked section.

## Problem Statement

The observable problem, from the user's perspective, and who it affects.

## Solution

The solution, from the user's perspective.

## User Stories

A numbered list (`As an <actor>, I want <feature>, so that <benefit>`) that covers every aspect of the campaign.

## Implementation Decisions

Settled decisions that constrain tickets: modules and interfaces, schema and API contracts, architectural,
compatibility and rollout choices. Describe them by behavior and contract, not by file path.

## Testing Decisions

What a good test is for this campaign, which modules are tested, and the prior art to follow.

## Out of Scope

Adjacent work excluded from the campaign.

## Further Notes

Optional. Anything else tickets need.

## Open questions

This section is machine-readable, and the heading is exactly `Open questions`.

- Write exactly `None` when no question remains.
- Otherwise use only list items in the form `- non-blocking: <question and impact>`.
- Execution cannot begin while a question blocks implementation, dependency ordering, safety or acceptance. Resolve
  those before `init` instead of recording them here.

## Init

The first completed specification of a campaign is followed at once by `campaign init`, run from the main branch.

- The slug is the `--slug` value (lowercase letters, digits and hyphens) or, without it, derived from the spec's first
  `# ` heading. There is no fallback to the file name: `init` stops when neither gives a slug.
- `init` creates `campaign/<slug>` from the current main branch, creates the canonical campaign paths in its
  worktree, and prints the campaign worktree. Continue from the printed `Worktree:` path, so that branch inference
  stays deterministic.
- An untracked root `SPEC.md` draft moves into the committed canonical path. Tracked or external input files stay
  untouched. Do not leave a draft on the main branch.

`init` refuses, before creating anything, when:

- the spec lacks a required section or has a blocking open question;
- the current branch is not the main branch;
- the campaign branch already exists;
- the main branch has no committed `.agentic/bin/campaign`. Commit the installed kit (`.agentic`, the skills and
  `AGENTS.md`) on the main branch first: the campaign worktree and the engine come from the committed branch.

Tickets come next: `/to-tickets` writes them into the campaign worktree through the same tracker configuration
(`.agentic/TICKET.md`), and `campaign verify` checks the result.

# Campaign specification contract

The canonical specification is `campaigns/<slug>/SPEC.md`. It is produced by Matt Pocock's `/to-spec`
(installed unmodified from his repository by `install.sh`), which publishes through the tracker configuration in
`docs/agents/issue-tracker.md`: the skill writes the spec to a temporary file outside the repository and
runs `.agentic/bin/campaign init <spec-path> --slug <short-kebab-name>` from the main branch. Remove the
temporary input after a successful initialization.

The specification uses the `/to-spec` template, in this order, plus one machine-checked section:

## Problem Statement

The observable problem, from the user's perspective, and who it affects.

## Solution

The solution, from the user's perspective.

## User Stories

A numbered list of user stories (`As an <actor>, I want <feature>, so that <benefit>`) that covers every
aspect of the campaign.

## Implementation Decisions

Settled decisions that constrain tickets: modules and interfaces, schema and API contracts, architectural,
compatibility and rollout choices. Describe them by behavior and contract rather than by file paths.

## Testing Decisions

What a good test is for this campaign, which modules are tested, and the prior art to follow.

## Out of Scope

Adjacent work excluded from the campaign.

## Further Notes

Optional. Anything else tickets need.

## Open questions

This section is machine-readable, and the heading is exactly `Open questions`. Write exactly `None` when no
question remains. Otherwise, use only
list items in the form `- non-blocking: <question and impact>`. Execution cannot begin while a question
blocks implementation, dependency ordering, safety, or acceptance; resolve blockers before init rather
than recording them here.

The first completed specification for a new campaign is followed immediately by
`.agentic/bin/campaign init <spec-path> --slug <short-kebab-name>`, run from the main branch. The slug is
the `--slug` value (lowercase letters, digits and hyphens) or, without it, derived from the spec's first `# `
heading; there is no fallback to the file name, and `init` stops when neither gives a slug. Initialization
creates `campaign/<slug>` from the current main branch, creates the canonical campaign paths in its worktree,
and prints the campaign worktree. Continue from the printed `Worktree:` path so branch inference remains
deterministic.

`init` refuses, before creating anything, when the spec lacks a required section or has a blocking open
question, when the current branch is not the main branch, when the campaign branch already exists, and when the
main branch has no committed `.agentic/bin/campaign`: commit the installed kit (`.agentic`, the skills,
`AGENTS.md` and `docs/agents/issue-tracker.md`) on the main branch first, because the campaign worktree and the
engine come from the committed branch.

Initialization moves an untracked root `SPEC.md` draft into the committed canonical path. Tracked or
external input files remain untouched. Continue from the returned worktree rather than leaving a draft
on the main branch.

Tickets come next: `/to-tickets` writes them into the campaign worktree through the same tracker
configuration (`.agentic/TICKET.md`), and `campaign verify` checks the result.

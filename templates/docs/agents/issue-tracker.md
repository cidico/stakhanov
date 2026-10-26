# Issue tracker: campaigns of `.agentic`

Specs and tickets are not issues on a hosting service. They are files of a campaign, a `campaign/<slug>`
branch with its own worktree, run by `.agentic/bin/campaign`. This file tells the `to-spec` and `to-tickets`
skills how to publish there. No triage labels apply (ignore `ready-for-agent` and the like), and
nothing goes to GitHub or GitLab issues or to a `.scratch/` folder.

## Specs (`/to-spec`)

`/to-spec` does not interview the user. If a blocking question remains (one that changes implementation,
dependency order, safety or acceptance), stop, say which question it is, and send the user back to
`/grilling`. Publish nothing until none is left.

1. Write the spec with the skill's own template and add a final `## Open questions` section. Its body is
   exactly `None`, or only `- non-blocking: <question and impact>` items. Anything else (`- None.`, an
   unlabeled question) is refused.
2. To publish, save the spec to a temporary file outside the repository, run
   `.agentic/bin/campaign init <file> --slug <short-kebab-name>` from the main branch, and delete the
   temporary file. Derive the slug from the feature (lowercase letters, digits and hyphens, for example
   `auth-sessions`).
3. Continue in the `Worktree:` path that `campaign init` prints. Everything after this point happens there.

`campaign init` refuses when the main branch has no committed `.agentic` (commit the installed kit first), when
it is not run from the main branch, or when the spec lacks a required section. The section contract is in
`.agentic/SPEC.md`.

## Tickets (`/to-tickets`)

Publish in the campaign worktree, one file per ticket, at `campaigns/<slug>/tickets/<ID>.md`, in the format of
`.agentic/TICKET.md`:

- Front matter: `id`, `status: todo`, `risk`, `depends_on` (the blocking edges), `collision_domains`, and
  `required`. An id is a short campaign prefix in capitals, a hyphen and at least three digits, matching
  `^[A-Z][A-Z0-9]*-[0-9]{3,}$`: `AUTH-001`, `AUTH-002`, never `01` or `auth-1`.
- The "what to build" text goes to `# Goal` and the acceptance criteria to `# Acceptance`. Add `# Non-goals`,
  `# Context`, and `# Validation` with `## Cheap`, `## Component` and `## Expensive`.

Write every ticket's commands into `campaigns/<slug>/validation.json` according to `.agentic/VALIDATION.md`,
including the project's `required_checks` (`.agentic/project.json`). Then run `.agentic/bin/campaign verify`
and fix what it reports. Commit the tickets and `validation.json` on the campaign branch: ticket worktrees are
created from the committed branch, so an uncommitted ticket never reaches a worker.

The next step is `/run-campaign`.

---
name: run-campaign
description: Run or attach to the campaign inferred from the current branch.
---

Read the project's instruction files (see `.agentic/project.json`) and `.agentic/RUN-CAMPAIGN.md`, then follow that procedure with provider
`claude`. Use `.agentic/bin/campaign` as the only supervisor.

Pass explicit `interactive` or `unattended` invocation arguments through without asking.
For a missing mode, follow the native structured mode-selection contract in step 3 of
`.agentic/RUN-CAMPAIGN.md`. Use the host’s native structured equivalent when available.
Without a native selector, default automatically to Interactive with the canonical notice; never ask a textual mode question.

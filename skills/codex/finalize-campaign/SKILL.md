---
name: finalize-campaign
description: Validate, integrate, and clean the campaign inferred from the current branch.
disable-model-invocation: true
---

Read the project's instruction files (see `.agentic/project.json`) and `.agentic/FINALIZE-CAMPAIGN.md`, then run
`.agentic/bin/campaign finalize` (for a campaign held by another machine of the fleet, `.agentic/bin/campaign
finalize --campaign <slug>`, which brings it here first). Report its gates and result.

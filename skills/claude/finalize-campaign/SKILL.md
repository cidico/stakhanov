---
name: finalize-campaign
description: Finish a campaign whose tickets are all done. It validates the whole campaign once more, cleans up its planning files, branches and worktrees, and merges it into the main branch by fast-forward. Use when the owner runs /finalize-campaign, or asks to land, merge or close a finished campaign.
---

Read the project's instruction files (see `.agentic/project.json`) and `.agentic/FINALIZE-CAMPAIGN.md`, then run
`.agentic/bin/campaign finalize` (for a campaign held by another machine of the fleet, `.agentic/bin/campaign
finalize --campaign <slug>`, which brings it here first). Report its gates and result.

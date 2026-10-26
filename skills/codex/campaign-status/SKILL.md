---
name: campaign-status
description: Show the progress of every campaign and campaign queue (read-only board).
---

Run `.agentic/bin/campaign overview --json` from any worktree of the repository. It is read-only and
lists every campaign in the runner cache and every campaign queue.

Report in the user's language as a short board, never raw logs or JSON:

- Per campaign: `done/total` tickets, tickets in progress, runner active or inactive.
- Every `blocked` or `needs-human` ticket with its reason in one line (from the latest `ticket-blocked`,
  `ticket-needs-human`, `integration-conflict` or `base-red` event), and every pending decision with its
  options.
- Per queue: state, current campaign, campaigns already finalized, and its message when it is `waiting`
  or `stopped`.

End with what needs the user, if anything. Do not start, stop, recover or finalize anything from this
skill.

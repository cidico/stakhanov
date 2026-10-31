---
name: campaign-status
description: Show the progress of every campaign and campaign queue of the project, on every machine of its fleet (read-only board).
---

Run `.agentic/bin/campaign overview --fleet --json` from any worktree of the repository. It is read-only
(it only fetches the other machines' branches) and lists, for this machine and every other machine of the
project's fleet (`machines`, this one first with `self`), every campaign in its runner cache and every
campaign queue. Without a fleet it lists this machine alone.

Report in the user's language as a short board, never raw logs or JSON. With more than one machine, group by
machine (name, `this machine` for `self`); a machine with `reachable` false is marked unreachable with its `error`
shortened, and its campaigns are the ones last seen (`seen_local_time`, or never seen), possibly out of date:

- Per campaign: `done/total` tickets, tickets in progress (with their `executor` when it is not `local`), runner
  active or inactive.
- Every `blocked` or `needs-human` ticket with its reason in one line (from the latest `ticket-blocked`,
  `ticket-needs-human`, `integration-conflict` or `base-red` event), and every pending decision with its
  options.
- Per queue: state, current campaign, campaigns already finalized, and its message when it is `waiting`
  or `stopped`.

End with what needs the user, if anything, including every entry of `warnings` (a main branch behind or
diverged from another machine's: show its command; it is pulled by hand). Do not start, stop, recover or finalize anything from this
skill.

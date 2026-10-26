---
name: campaign-status
description: Show the progress of every campaign and campaign queue (read-only board).
---

Run `.agentic/bin/campaign overview --json` from any worktree of the repository. It is read-only and
lists every campaign in the runner cache and every campaign queue. Each ticket carries `goal`,
`depends_on`; in-progress tickets add `started_local_time`, `elapsed_seconds`, `phase`,
`phase_local_time`, `phase_seconds` and `unblocks` (todo tickets that depend on it, each with `goal`
and `waits_also`: other unfinished dependencies); blocked/needs-human tickets add `reason`.

Report in the user's language as a short board, never raw logs or JSON. Color comes only from emoji
(the terminal renders Markdown, not ANSI colors). Use exactly these icons:

| Ticket status | Icon | Bar square |
|---|---|---|
| done | ✅ | 🟩 |
| in-progress | 🔄 | 🟦 |
| blocked | ⛔ | 🟥 |
| needs-human | 🙋 | 🟧 |
| todo | ⏳ | ⬜ |

Runner: 🟢 active · ⚪ inactive · 🏁 every required ticket done (waiting for finalize).

Phases of an in-progress ticket (`phase` → label → next step). Report the labels in the user's language:

| phase | Now | Next |
|---|---|---|
| implementing | 🛠️ implementing | validation → review |
| validating | 🧪 validating | review |
| reviewing | 🔍 in review | integration (or repair) |
| review-done | 📦 integrating | done (or repair) |
| repairing | 🔧 repairing review findings | validation → new review |
| diagnosing | 🩺 diagnosing a failure | automatic repair |
| recovering | ♻️ automatic recovery | reimplement with the diagnosis |
| resolving-conflict | 🔀 resolving an integration conflict | validation → review |
| provider-error | ⚠️ provider error | recovery or runner pause |

Any other value: show it as-is with ⚙️.

Layout per campaign:

1. Heading: runner icon, slug, `done/total`, then one bar of colored squares, one per ticket in id
   order (above 30 tickets, group in blocks of 5 by majority status).
2. A tree table of in-progress tickets, columns `| | Ticket | What | Now | Next | Started | Duration |` (headers translated):
   - Parent row per in-progress ticket: 🔄, **id** in bold, **what it does** in bold (the `goal`
     summarized in the user's language, at most 8 words), now (phase label + "N min ago" from
     `phase_seconds`), next step, started (`started_local_time`), duration (`elapsed_seconds` as
     `N min` or `Xh YYmin`).
   - Right below it, one child row per `unblocks` entry, in id order: ⏳, the id prefixed with `├─ `
     (`└─ ` for the last child), its summarized goal (not bold), now `⏸️ waits for <parent>` (plus
     ` + <id>` for each `waits_also`), next `starts when <parent> is done` when `waits_also` is empty,
     otherwise `still waits for <waits_also>`; leave Started and Duration empty. When `waits_also` has
     more than 2 ids, show the first 2 and `+N` (e.g. `still waits for API-002, API-003 +18`).
   - Example:

     ```
     | 🔄 | **AUTH-002** | **Session expiry on logout** | 🛠️ implementing · 5 min ago | validation → review | 20:42 (01/10) | 5 min |
     | ⏳ | ├─ AUTH-003 | Session list for the account page | ⏸️ waits for AUTH-002 | starts when AUTH-002 is done | | |
     | ⏳ | └─ AUTH-008 | Admin session revocation | ⏸️ waits for AUTH-002 + AUTH-006 | still waits for AUTH-006 | | |
     ```
3. One line each for ⛔ blocked and 🙋 needs-human tickets: id, summarized goal and `reason` in one line.
   Every pending decision with its options.
4. One line ✅ with the done ids, and one line ⏳ with the todo count, naming the todo tickets whose
   `depends_on` are all done (they start next) that are not already shown in the tree.

Omit empty sections. A campaign with zero tickets in the listing shows only its heading and a short
note (finalizing, cleaned or not yet planned, judging by the runner state and recent events).

Per queue: state, current campaign, campaigns already finalized, and its message when it is `waiting`
or `stopped`.

Show every time in the display zone using `local_time` fields (`HH:MM (dd/mm)`; the zone comes from
`AGENTIC_DISPLAY_TZ`, then `timezone` in `.agentic/project.json`, then the system zone); never show the raw UTC
`time`.

End with what needs the user, if anything. Do not start, stop, recover or finalize anything from this
skill.

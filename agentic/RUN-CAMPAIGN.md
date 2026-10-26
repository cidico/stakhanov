# Run a campaign

Use this procedure when `/run-campaign` is invoked. The provider wrapper supplies its own provider name
and contains no workflow rules.

1. Run `.agentic/bin/campaign current`. If the current branch is not `campaign/<slug>`, stop with the
   runner's objective error; never ask the user to select a campaign.
2. Run `.agentic/bin/campaign status`. If its runner is active, attach by showing the summarized status
   and follow its events; do not start another supervisor.
3. If no runner is active, resolve the mode in this order:

   - Explicit `run-campaign interactive` → use `interactive` without asking.
   - Explicit `run-campaign unattended` → use `unattended` without asking.
     Skill/provider invocation equivalents (including `/run-campaign <mode>`) use the same rule.
   - Mode omitted + Grok: MUST use `ask_user_question` when available, with one single-select
     question, “How do you want to run?”, and exactly the option labels `Interactive` and `Unattended`.
   - Mode omitted + Codex: MUST use `request_user_input` when available in the current collaboration
     mode. Tool availability includes permission to invoke it in that mode, not merely its listing.
   - Other provider: use its native structured equivalent when available.
   - Mode omitted + no native selector: automatically use `interactive`, without asking. This also
     applies to Codex when `request_user_input` is unavailable in the current collaboration mode.
     Inform the user only: `No native mode selector available; starting Interactive. Use run-campaign unattended to override.`

   Never render a textual mode-selection question, Markdown options, or a numbered selector.
   Native structured choice is the only question path; Interactive is the automatic fallback/default.

   For Codex, pass this structured question to `request_user_input` (exactly two option labels):

   ```json
   {
     "questions": [{
       "header": "Mode",
       "id": "mode",
       "question": "How do you want to run?",
       "options": [
         {"label": "Interactive", "description": "Follow status and events in this session."},
         {"label": "Unattended", "description": "Keep running in the background after this session closes."}
       ]
     }]
   }
   ```

   When a native selector is invoked, wait for its answer; an unanswered selector is not unavailable.
   Map `Interactive` → `interactive` and `Unattended` → `unattended`, then pass that value as `--mode`
   in step 4. A supplied mode skips selection; an active runner follows step 2 without selecting again.
   This is a mode preference, not an operational approval.

4. Run `.agentic/bin/campaign run --provider <provider> --mode <interactive|unattended>`. This is the
   single launcher command: it preflights the provider and starts a detached canonical supervisor,
   which owns all routine filesystem, Git, validation, and subprocess mutations. Pass `--workers` only
   when the user asks for a different concurrency.
5. In interactive mode, show compact status and events while attached. Correct technical harness
   failures and preserve existing deltas. For a pending human decision, present the recorded choices
   and apply the selected value with `.agentic/bin/campaign decide <ticket> <retry|block|cancel>`.
6. In unattended mode, report that the detached runner continues after the UI closes and show how to
   reattach with `/run-campaign`.

## Coordinating an unattended campaign

Every coordinator turn re-reads the whole conversation. A turn spent on a routine transition is
therefore the main cost of supervising a campaign, larger than the provider work itself. Coordinate
from a Sonnet or Opus session, never Fable: supervision is routine. While a runner works unattended:

- Watch with `.agentic/bin/campaign-watch [--slug SLUG] [--until TICKET=STATUS]`, run in the
  background, one watcher at a time. It returns only when the coordinator is needed: runner stopped,
  pending decision, blocked ticket, needs-human ticket whose dependencies are done, a provider timeout or
  harness error, a provider silent longer than `--stall-minutes` (default 45), a `--until` milestone the
  coordinator must act on (for example a cutover gate), or every required ticket done. Otherwise it
  returns a `ROUTINE` line after `--max-minutes` (default
  115). While only an optional ticket still runs, pass `--ignore-required-done` so the watcher waits for
  the runner to stop instead of returning at once.
- Never poll for ticket starts, completions or phase changes, and never build a watcher that wakes on
  them.
- On a `ROUTINE` return, only re-arm. On a `WAKE`, diagnose, fix, and re-arm in the same turn. Do not
  print the board: it is for `/campaign-status`, on request.

Do not paste raw provider logs into the UI. Report ticket state, concise summaries, validation
evidence, and decision requests. Report milestones, actual elapsed time, and failures; a live process
is not proof of progress. Runner mechanics (scheduling, deadlines, timeouts, repair limits,
integration) are documented in `.agentic/README.md`.

To run several prepared campaigns one after another without a coordinator, use a campaign queue
(`.agentic/bin/campaign queue start <file>`, documented in `.agentic/README.md`). Use `/campaign-status`
to see every campaign and queue at once.

## Troubleshooting

- The engine runs from a snapshot of the main branch's committed `.agentic`. Commit runner, adapter or
  config changes on the main branch, then `campaign run` again; uncommitted edits never reach an engine.
- Restarting the engine is safe at any phase: kill the engine's whole process tree, then `campaign run`. A ticket
  that was `implementing` has uncommitted partial work; the runner emits `worker-interrupted` and starts a
  recovery worker on it instead of validating it as complete, so the interrupted ticket is recovered by itself.
- A ticket that legitimately changes an instruction file is rejected with "worker edited coordinator-owned
  instructions". Review the change, remove it from the ticket worktree, commit only that file as coordinator
  on the campaign branch, then `campaign recover <id>` and `campaign run`. Do not ask the human for this.
- Validation commands have no deadline: a stuck test holds its phase until someone kills it. Find it in the
  runner's process tree (the engine's pid is in `runner.pid` in the campaign's cache folder; list its children
  with `pstree -p <pid>` or `ps --forest`) and kill that process; the command then fails like any failed
  validation. `AGENTIC_WORKER_TIMEOUT_SECONDS` limits only a worker, so raise it
  on `campaign run` for a ticket whose worker itself runs long suites.
- A wait loop stuck on `pgrep -f` matches its own shell: kill only that loop's PID, never `pkill -f` with
  the text.
- Before starting, run every `validation.json` command once on the main branch; declare repository-wide
  checks as `baseline`.

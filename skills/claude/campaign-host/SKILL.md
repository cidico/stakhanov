---
name: campaign-host
description: Turn this Claude session into the host that runs the campaign roles (worker, reviewer, diagnostician) as background subagents, instead of separate headless processes (session mode), or stop hosting with `/campaign-host stop`. Keep the session open while campaigns run. Use only when the owner runs /campaign-host.
---

This session runs the campaign roles (worker, reviewer, diagnostician) as background subagents, for the campaigns whose
project sets `AGENTIC_CLAUDE_MODE=session`. Follow these steps exactly and keep every reply to one short line.

1. Run `.agentic/bin/session-host register`.
2. Start `.agentic/bin/session-host wait` with `run_in_background` and end the turn with one short line.
3. When `wait` reports, read its lines:
   - `new <id>`: run `.agentic/bin/session-host brief <id>`; call the Agent tool with exactly the fields it printed
     (`subagent_type`, `model`, `effort`, `description`, `run_in_background`, `prompt`) and nothing else; then run
     `.agentic/bin/session-host claim <id> <agentId>` with the agent id the Agent tool returned. If `brief` fails with
     status 3, skip that id.
   - `cancel <id> <agent_id>`: stop that agent (TaskStop) and run `.agentic/bin/session-host cancelled <id>`.
   - `stopped`: stop; do not start `wait` again.

   Then start `wait` again (`run_in_background`). A notification that a subagent finished needs nothing but making sure
   `wait` is running.
4. Never do a role's work yourself, never ask the owner anything, never summarize a subagent's result, and keep every
   reply to one line.
5. If this session was resumed (after a crash or an account takeover), run `register` again first: it puts the interrupted
   requests back in the queue. Then go on from step 2.
6. `/campaign-host stop`: run `.agentic/bin/session-host unregister` and stop waiting (stop the `wait` task if it runs).

The session needs permission to run without prompts (for example `--permission-mode bypassPermissions`): a subagent
inherits it and there is nobody to answer a prompt.

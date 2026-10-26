# Ticket-specific validation

Validation levels and when to use them are defined in `.agentic/WORKFLOW.md`. This file defines the
executable plan format. Commands are reviewed argv arrays in `campaigns/<slug>/validation.json`;
provider-result text is data, never executable code.

```json
{
  "version": 1,
  "tickets": {
    "AUTH-001": {
      "cheap": [["git", "diff", "--check"]],
      "component": [],
      "expensive": []
    }
  },
  "final": [["git", "diff", "--check"]]
}
```

- `cheap` (L0/L1), `component` (L2/L3), and `expensive` (ticket-scoped L4) run for that ticket.
  Empty phases mean not applicable. Use behavior tests for product changes.
- `final` runs only during `/finalize-campaign`.
- Every ticket's `cheap` phase and the `final` list contain the project's `required_checks`
  (`.agentic/project.json`, argv arrays such as `["npm", "run", "lint"]`). `campaign verify` refuses a plan
  that omits one. Required checks are meant to cover the whole repository and to pass on the base, so any
  finding comes from the ticket: fix it in code, never by exception.
- Optional plan-level `baseline` lists repository-wide commands that must already pass on the campaign
  base (for example the build, the linter and the full unit suite). `campaign run` refuses to start while one fails,
  and a ticket whose failing command is a baseline command that also fails on the base is reported as
  `base-red` instead of being repaired. Ticket-specific proofs (new tests) never belong in `baseline`.
- Optional plan-level `campaign_expensive` lists campaign-wide L4 argv (full suites, shared HTTP
  matrices, cutovers). It runs only for a ticket that sets `"campaign_expensive": true` or during
  finalization. Copying one of those commands into a ticket's `expensive` array does not authorize it.
- Put material prerequisites in the declared commands. Legacy preflight/provenance fields are
  ignored.
- Commands may use resumable phases (preflight, acquisition, preparation, inference, evaluation,
  report). Keep reusable artifacts outside Git; reuse depends on compatible functional inputs.
- Receipts record the operation and outcome as evidence, not authorization. Keep detailed evidence
  sanitized. Secrets belong in protected environment/configuration, never in argv or receipts.

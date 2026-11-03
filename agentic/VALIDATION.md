# Ticket-specific validation

Validation levels and when to use them are defined in `.agentic/WORKFLOW.md`. This file defines the
executable plan format. Commands are reviewed argv arrays in `campaigns/<slug>/validation.json`;
provider-result text is data, never executable code.

```json
{
  "version": 1,
  "timeout_minutes": 90,
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

- `timeout_minutes` (integer, 1 to 1440) at the top of the plan is the deadline of every command that sets none; a
  command written as `{"command": [...], "timeout_minutes": N}` (instead of a plain argv array) has its own. Without
  either, `AGENTIC_VALIDATION_TIMEOUT_MINUTES` applies, then 120 minutes. An overdue command is stopped with its whole
  process group (`SIGTERM`, `SIGKILL` 10 s later) and fails with `exitCode` 124 and `timedOut: true` in the receipt.
  `AGENTIC_VALIDATION_TIMEOUT_SECONDS` overrides all of them (for tests).

- `cheap` (L0/L1), `component` (L2/L3), and `expensive` (ticket-scoped L4) run for that ticket.
  Empty phases mean not applicable. Use behavior tests for product changes.
- `final` runs only during `/finalize-campaign`. When finalize resumes on the same commit after a failure, a `final` command
  that already passed is not run again (its receipt records the commit), so list each check once and in the order it should run.
- Every ticket's `cheap` phase and the `final` list contain the project's `required_checks`
  (`.agentic/project.json`, argv arrays such as `["npm", "run", "lint"]`). `campaign verify` refuses a plan
  that omits one. Required checks are meant to cover the whole repository and to pass on the base, so any
  finding comes from the ticket: fix it in code, never by exception.
- Optional plan-level `baseline` lists repository-wide commands that must already pass on the campaign
  base (for example the build, the linter and the full unit suite). `campaign run` refuses to start while one fails,
  and a ticket whose failing command is a baseline command that also fails on the base is reported as
  `base-red` instead of being repaired. Ticket-specific proofs (new tests) never belong in `baseline`.
- A red phase gets at most `AGENTIC_VALIDATION_REPAIRS` (1) repair workers in one pass of the validation, then the
  ticket is blocked. A command that is not in the PATH (exit 127 with `command not found`, or one that cannot be
  started), runs past its deadline or prints one of the `environment_failure_patterns` of `project.json` failed
  because of the machine: the ticket is blocked as `environment` with no repair. A script or path of the worktree
  that is missing (`bash infra/check.sh`, `./check.sh`) is a defect of the code and is repaired. A task's `validate`
  commands run with no shell: use `bash -c '...'` for `&&`, `|`, redirections, `$` and globs (the plan generator
  refuses them otherwise).
- Optional plan-level `campaign_expensive` lists campaign-wide L4 argv (full suites, shared HTTP
  matrices, cutovers). It runs only for a ticket that sets `"campaign_expensive": true` or during
  finalization. Copying one of those commands into a ticket's `expensive` array does not authorize it.
- A command may run on a remote executor: `[".agentic/bin/offload", "--units", "2", "--each", "PART=1,2,3", "--",
  "make", "test"]` sends it (or one run per value) to the first executor of `project.json` with room, and runs it here
  when none can take it; its status is the command's. `--send PATH` sends a build made here that `exclude` keeps off the
  executor (so it runs the tests without building). Ask for the results a failure needs to be diagnosed with
  `--back PATH` (for example a test results folder); nothing else of the remote worktree comes back. See "Offloading
  commands" in `.agentic/README.md`.
- Put material prerequisites in the declared commands. Legacy preflight/provenance fields are
  ignored.
- Commands may use resumable phases (preflight, acquisition, preparation, inference, evaluation,
  report). Keep reusable artifacts outside Git; reuse depends on compatible functional inputs.
- Receipts record the operation and outcome as evidence, not authorization. Keep detailed evidence
  sanitized. Secrets belong in protected environment/configuration, never in argv or receipts.

## Validation that fails before the change

A validation that already passes on the base does not prove the change. Before the first worker of a ticket starts, the
runner runs the ticket's `cheap` commands and then its `component` commands (never the `expensive` ones) on the ticket's
base commit, in a throwaway worktree, with the same environment, deadlines and process-group handling as any other
validation, and stops at the first command that fails. At least one must fail.

- A command that fails proves the validation (event `validate-base-proves`, naming what failed and what passed before it).
  The worker starts.
- All commands pass, or the ticket has no `cheap` or `component` command: the ticket is refused before any worker runs
  (event `validate-base-passes`), blocked with "validate already passes on the base: it does not prove the change" and
  never retried automatically. Fix the validation and run `campaign recover <ticket>`; the check runs again.
- A command that is not in the PATH, runs past its deadline or prints one of the `environment_failure_patterns` fails
  because of the machine, not the code: the ticket is blocked as `environment: ... on the base`, as in any validation.
- `validate_base: skip` with a `validate_base_reason` in the ticket (or the task's brief) skips the check for a validation
  that cannot fail on the base: a refactor that the existing tests prove, documentation (event `validate-base-skipped`,
  with the reason). Without them the check runs.
- The answer is kept in `state/<ticket>.validate-base` for the same base files and the same commands, so a resumed run
  does not run the check again. A different base (another ticket landed) or a changed plan runs it again.
- Its receipt is `validation/base/<ticket>.base.json`, apart from the ticket's own receipts.

# Task brief contract

A task is one brief: a Markdown file with a front matter, one branch and one worker. It is for work that comes broken
into independent pieces; dependent pieces of one cohesive unit are a campaign (`.agentic/WORKFLOW.md`). The `campaign
task` commands read the brief and turn it into a campaign of one ticket whose plan stays in the runtime; see "Tasks" in
`.agentic/README.md`. The brief is the whole input: write it so a fresh worker can deliver the task from it alone.

The front matter has one field per line. A list is `[a, b]` or one `- item` per line.

| Field | Meaning |
| --- | --- |
| `id` | Required. The task's unique id; its lower case is the task's name, so it must make a valid slug (`GRD-002` → `grd-002`). |
| `title` | Required. What the task delivers, in one line; it is the title of the commit. |
| `after` | Ids of the tasks that must be on the main branch before this one starts. |
| `domains` | Collision labels (letters, digits and `._:/@+-`): two tasks with a label in common never run at the same time. |
| `requires` | What the machine must have to run the task, such as `dotnet` or `docker`. |
| `prefer` | The machine the task should run on, or `any` (the default). |
| `model`, `effort` | The worker's model and effort. |
| `review` | Required, `true` or `false`. `true` runs a fresh reviewer; `false` skips it. |
| `timeout_minutes` | The deadline of each `validate` command, from 1 to 1440. |
| `validate` | Required. The commands that prove the task; at least one. |
| `commit` | Optional. The `type(area)` of the commit, as `feat(analyzers)`; without it the type is `feat(task)`. |
| `units` | Optional. How many machine slots the task takes while it runs (an integer, at least 1). |
| `validate_base`, `validate_base_reason` | Optional, and always together. `validate_base: skip` with a `validate_base_reason` of one line says why the `validate` commands cannot fail on the base (a refactor that existing tests already prove, documentation); the runner then skips the check below and records the reason. Without them the check runs. A `skip` without a reason, a reason without `skip` and any other value are refused. |

No other field is accepted, and a field appears once.

## Body

Sections are `#` headings. The generator finds them by name, in English or Portuguese, and keeps the whole body in the
task's SPEC.

- `Objetivo` / `Goal`: what the task delivers.
- `Aceite` / `Acceptance`: observable conditions that prove it is done.
- `Fora do escopo` / `Out of scope`: what the worker must not touch.
- `Context`: paths, decisions and references the worker needs.

## validate

- Each entry is one command, run by the engine and not by the worker: the worker does not change `validate`.
- A command runs as an argv, with no shell. Quote as a shell would, but anything that needs a shell (`&&`, `|`, `;`,
  redirections, `$`, globs, subshells) goes in `bash -c '…'`. The brief is refused otherwise.
- The same list is the ticket's validation and the final one, so each command must pass on the finished delta.
- When the project lists `required_checks` in `.agentic/project.json`, `validate` carries them as well.
- A `validate` that already passes on the base proves nothing. Before the worker starts, the runner runs the commands
  on the task's base commit, in a throwaway worktree and with the environment and deadlines of any validation, and at
  least one must fail. If all pass, the task is refused before any worker runs ("validate already passes on the base:
  it does not prove the change") and waits for a person: write a `validate` command that fails until the work is done,
  or say `validate_base: skip` and why. The check runs once, in the first round: a later `campaign task fix` round starts
  on the branch that already has the earlier rounds' delta, so it is not made again.

## Example

```markdown
---
id: GRD-002
title: "Rule: at most 6 constructor parameters"
after: [GRD-001]
domains: [analyzer-ctor]
requires: [dotnet]
prefer: any
model: opus
effort: high
review: false
timeout_minutes: 60
validate:
  - "dotnet test platform/analyzers/Analyzers.slnx"
  - "bash -c 'test -s docs/rules/ctor-parameters.md'"
---

# Goal

Add the analyzer rule that flags a constructor with more than 6 parameters.

# Acceptance

- The rule has the id `RULE003` and an error severity.
- A test fails the rule with 7 parameters and passes it with 6.

# Out of scope

- Other rules.

# Context

- GRD-001 created the project: follow its pattern for the tests.
```

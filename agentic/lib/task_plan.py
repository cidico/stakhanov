#!/usr/bin/env python3
"""The plan of a task, a campaign of one ticket whose plan lives in the runtime (see "Tasks" in README.md).

    task_plan.py slug BRIEF        prints the task's name: its id in lower case
    task_plan.py write BRIEF DIR   writes SPEC.md, tickets/T-001.md, validation.json and task.json in DIR

The brief is Markdown with a front matter in the format of the rewrite's tasks: id, title, after, domains, requires,
prefer, model, effort, review, timeout_minutes, validate, and the optional commit, units, validate_base and
validate_base_reason. Every check runs before
anything is written; a brief that fails one is refused with the reason (exit 2). `campaign _task-plan` runs both
commands and checks the result as `campaign verify` checks a plan.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

TICKET_ID = "T-001"
MAX_TIMEOUT_MINUTES = 1440  # validation.py's bound: the brief's timeout_minutes is the plan's
FIELDS = ("id", "title", "after", "domains", "requires", "prefer", "model", "effort", "review", "timeout_minutes",
          "validate", "commit", "units", "validate_base", "validate_base_reason")
KEY = re.compile(r"^([a-z][a-z0-9_]*):(?:[ \t]+(.*?))?[ \t]*$")
ITEM = re.compile(r"^[ \t]*-(?:[ \t]+(.*?))?[ \t]*$")
# A collision domain is a label the ticket's front matter carries as it is.
LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$")
# The type(area) of a Conventional Commit, as in feat(analyzers) or fix.
COMMIT = re.compile(r"^[a-z][a-z0-9-]*(\([^()\s:]+\))?!?$")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$")
FENCE = re.compile(r"^ {0,3}(```|~~~)")
# The brief's sections, by any of their names (lower case).
SECTIONS = {
    "goal": ("objetivo", "objective", "goal"),
    "acceptance": ("aceite", "acceptance"),
    "out_of_scope": ("fora do escopo", "out of scope", "non-goals"),
    "context": ("contexto", "context"),
}


class BriefError(ValueError):
    pass


# --- The front matter: the subset of YAML the briefs use (scalars, quoted strings, flow and block lists). ----------

def read_quoted(text: str, start: int) -> tuple[str, int]:
    """The quoted string that starts at text[start], and the position after it."""
    quote, index = text[start], start + 1
    while index < len(text):
        char = text[index]
        if quote == '"' and char == "\\":
            index += 2
            continue
        if char == quote:
            if quote == "'" and text[index + 1:index + 2] == "'":
                index += 2
                continue
            raw = text[start:index + 1]
            if quote == "'":
                return raw[1:-1].replace("''", "'"), index + 1
            try:
                value = json.loads(raw)
            except ValueError:
                raise BriefError(f"unsupported escape in the string {raw}") from None
            return value, index + 1
        index += 1
    raise BriefError(f"unterminated string: {text[start:]}")


def no_trailer(rest: str, value: str):
    """After a value, only blanks or a comment."""
    rest = rest.strip()
    if rest and not rest.startswith("#"):
        raise BriefError(f"unexpected text after {value}: {rest}")


def plain(token: str):
    """A plain scalar: null, a boolean, an integer or a string; a comment ( #...) ends it."""
    token = re.split(r"[ \t]#", token, maxsplit=1)[0].strip()
    if token in ("", "~", "null", "Null", "NULL"):
        return None
    if token in ("true", "True", "TRUE"):
        return True
    if token in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?[0-9]+", token):
        return int(token)
    if token[0] in "{&*!|>%@`":
        raise BriefError(f"unsupported value {token} (write it quoted)")
    return token


def value_of(text: str):
    """A front matter value: a quoted or plain scalar, or a flow list ([a, "b"])."""
    text = text.strip()
    if text.startswith(("'", '"')):
        value, end = read_quoted(text, 0)
        no_trailer(text[end:], text[:end])
        return value
    if not text.startswith("["):
        return plain(text)
    items, index = [], 1
    while True:
        while index < len(text) and text[index] in " \t":
            index += 1
        if index >= len(text):
            raise BriefError(f"unterminated list: {text}")
        if text[index] == "]" and not items:
            index += 1
            break
        if text[index] in "'\"":
            item, index = read_quoted(text, index)
        else:
            end = index
            while end < len(text) and text[end] not in ",]":
                end += 1
            item = plain(text[index:end])
            if item is None:
                raise BriefError(f"empty item in the list {text}")
            index = end
        items.append(item)
        while index < len(text) and text[index] in " \t":
            index += 1
        if text[index:index + 1] == ",":
            index += 1
            continue
        if text[index:index + 1] == "]":
            index += 1
            break
        raise BriefError(f"malformed list: {text}")
    no_trailer(text[index:], text[:index])
    return items


def split_brief(text: str) -> tuple[dict, str]:
    """The front matter of the brief (fields as written) and its body."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise BriefError("the brief has no front matter: its first line must be ---")
    try:
        end = next(number for number, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration:
        raise BriefError("the front matter has no closing ---") from None
    meta: dict[str, object] = {}
    listing: str | None = None
    for number, raw in enumerate(lines[1:end], 2):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        item = ITEM.match(raw)
        if item and listing is not None:
            try:
                value = value_of(item.group(1) or "")
            except BriefError as error:
                raise BriefError(f"line {number}: {error}") from None
            if value is None:
                raise BriefError(f"line {number}: empty item in {listing}")
            meta[listing].append(value)
            continue
        field = KEY.match(raw)
        if not field:
            raise BriefError(f"line {number}: unsupported front matter syntax: {raw.strip()}")
        key, value = field.groups()
        if key in meta:
            raise BriefError(f"line {number}: {key} appears twice")
        if not value:
            meta[key], listing = [], key
            continue
        try:
            meta[key] = value_of(value)
        except BriefError as error:
            raise BriefError(f"line {number}: {key}: {error}") from None
        listing = None
    return meta, "\n".join(lines[end + 1:])


# --- The fields. -------------------------------------------------------------------------------------------------

def text_value(meta: dict, key: str, default=None, required=False):
    value = meta.get(key, default)
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip() or "\n" in value:
        raise BriefError(f"{key} must be a non-empty string of one line" if key in meta else f"{key} is required")
    return value.strip()


def list_value(meta: dict, key: str, pattern: re.Pattern | None = None) -> list[str]:
    value = meta.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        raise BriefError(f"{key} must be a list of non-empty strings")
    value = [item.strip() for item in value]
    for item in value:
        if pattern is not None and not pattern.fullmatch(item):
            raise BriefError(f"{key}: {item!r} is not a label (letters, digits and ._:/@+- only)")
    return value


def integer_value(meta: dict, key: str, low: int, high: int | None = None):
    value = meta.get(key)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < low or (high is not None and value > high):
        bound = f"from {low} to {high}" if high is not None else f"of at least {low}"
        raise BriefError(f"{key} must be an integer {bound}")
    return value


SHELL_SYNTAX = "&|;<>()`$*?["


def shell_syntax(command: str) -> str | None:
    """The first character outside quotes that a shell would act on (an operator, a redirection, an expansion, a glob);
    None when there is none. A backslash makes the next character an ordinary one."""
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if quote is None and char == "\\":
            index += 2
            continue
        if quote == '"' and char == "\\":
            index += 2
            continue
        if quote is not None:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char in SHELL_SYNTAX:
            return char
        index += 1
    return None


def command_argv(index: int, command) -> list[str]:
    """The argv of a validate command: the string split as a shell would split it, with no shell in between."""
    if not isinstance(command, str) or not command.strip():
        raise BriefError(f"validate: command {index} must be a non-empty string")
    syntax = shell_syntax(command)
    if syntax is not None:
        raise BriefError(f"validate: command {index} ({command}) uses shell syntax ({syntax}) outside quotes, and a "
                         f"command runs with no shell: write it as bash -c '...'")
    try:
        argv = shlex.split(command)
    except ValueError as error:
        raise BriefError(f"validate: command {index} ({command}) cannot be split: {error}") from None
    if not argv or any(not part or "\0" in part for part in argv):
        raise BriefError(f"validate: command {index} ({command}) has an empty argument")
    return argv


def load(path: Path) -> tuple[dict, str]:
    """The task.json of the brief at path (its normalized front matter) and its body."""
    if path.is_symlink() or not path.is_file():
        raise BriefError("the brief must be a regular file")
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as error:
        raise BriefError(f"cannot read the brief: {error}") from None
    meta, body = split_brief(text)
    unknown = sorted(set(meta) - set(FIELDS))
    if unknown:
        raise BriefError(f"unknown field(s): {', '.join(unknown)} (a brief has {', '.join(FIELDS)})")
    task_id = text_value(meta, "id", required=True)
    if not isinstance(meta.get("review"), bool):
        raise BriefError("review must be true or false" if "review" in meta else
                         "review is required: true runs a fresh reviewer, false skips it")
    validate = meta.get("validate")
    if not isinstance(validate, list) or not validate:
        raise BriefError("validate must be a non-empty list of commands")
    for index, command in enumerate(validate, 1):
        command_argv(index, command)
    commit = text_value(meta, "commit")
    if commit is not None and not COMMIT.fullmatch(commit):
        raise BriefError(f"commit must be the type(area) of the commit, as feat(analyzers): not {commit!r}")
    validate_base = text_value(meta, "validate_base")
    validate_base_reason = text_value(meta, "validate_base_reason")
    if validate_base is not None and validate_base != "skip":
        raise BriefError(f"validate_base must be skip (leave it out to run the check on the base), not {validate_base!r}")
    if validate_base == "skip" and validate_base_reason is None:
        raise BriefError("validate_base: skip needs a validate_base_reason saying why the validate commands cannot "
                         "fail on the base")
    if validate_base is None and validate_base_reason is not None:
        raise BriefError("validate_base_reason without validate_base: skip")
    task = {
        "id": task_id,
        "slug": task_id.lower(),
        "title": text_value(meta, "title", required=True),
        "after": list_value(meta, "after"),
        "domains": list_value(meta, "domains", LABEL),
        "requires": list_value(meta, "requires"),
        "prefer": text_value(meta, "prefer") or "any",
        "model": text_value(meta, "model"),
        "effort": text_value(meta, "effort"),
        "review": meta["review"],
        "timeout_minutes": integer_value(meta, "timeout_minutes", 1, MAX_TIMEOUT_MINUTES),
        "validate": [command.strip() for command in validate],
        "commit": commit,
        "units": integer_value(meta, "units", 1),
        "validate_base": validate_base,
        "validate_base_reason": validate_base_reason,
        "ticket": TICKET_ID,
        "brief": str(path.resolve()),
    }
    return task, body


# --- The body: its sections, and its headings moved under the generated ones. ------------------------------------

def headings(lines: list[str]):
    """(index, level, title) of every Markdown heading outside fenced code."""
    fenced = False
    for index, line in enumerate(lines):
        if FENCE.match(line):
            fenced = not fenced
            continue
        match = None if fenced else HEADING.match(line)
        if match:
            yield index, len(match.group(1)), match.group(2)


def demote(text: str, level: int) -> str:
    """text with its headings moved so that the highest is at level (never higher than it was)."""
    lines = text.splitlines()
    found = list(headings(lines))
    if not found:
        return text.strip()
    shift = max(0, level - min(found_level for _, found_level, _ in found))
    for index, _, _ in found:
        lines[index] = "#" * shift + lines[index]
    return "\n".join(lines).strip()


def sections(body: str) -> dict[str, str]:
    """The brief's goal, acceptance, out of scope and context, by the headings of its highest level."""
    lines = body.splitlines()
    found = list(headings(lines))
    if not found:
        return {}
    top = min(level for _, level, _ in found)
    starts = [(index, title) for index, level, title in found if level == top]
    result: dict[str, str] = {}
    for position, (index, title) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        name = next((key for key, names in SECTIONS.items() if title.strip().lower() in names), None)
        if name and name not in result:
            result[name] = "\n".join(lines[index + 1:end]).strip()
    return result


def bullet_commands(task: dict) -> str:
    return "\n".join(f"- `{command}`" for command in task["validate"])


def spec_text(task: dict, body: str, parts: dict[str, str]) -> str:
    domains = ", ".join(f"`{domain}`" for domain in task["domains"]) or "none"
    return f"""# {task['title']}

Task {task['id']}. The runner generated this SPEC from the task's brief, which it carries whole under Solution: the brief
is what the task delivers.

## Problem Statement

{demote(parts.get('goal', ''), 3) or task['title']}

## Solution

The brief of {task['id']}:

{demote(body, 3) or task['title']}

## User Stories

1. As the project's consolidator, I want task {task['id']} delivered as its brief says, so that its acceptance holds.

## Implementation Decisions

- The whole task is one ticket, {TICKET_ID}, which owns the collision domains {domains}.
- The brief's context, above, holds the decisions the task follows.

## Testing Decisions

The runner runs the brief's validate commands, as the ticket's cheap phase and as the final list; the worker does not
change them:

{bullet_commands(task)}

## Out of Scope

{parts.get('out_of_scope') and demote(parts['out_of_scope'], 3) or 'Anything the brief does not ask for.'}

## Open questions

None.
"""


def ticket_text(task: dict, parts: dict[str, str]) -> str:
    # Quoted, so that tickets.py reads a label such as true or null as the text it is.
    domains = "".join(f'\n  - "{domain}"' for domain in task["domains"]) or " []"
    context = demote(parts.get("context", ""), 3)
    # The reason is a JSON string, which a ticket's front matter reads back as the text it is.
    skip = (f'validate_base: skip\nvalidate_base_reason: {json.dumps(task["validate_base_reason"], ensure_ascii=False)}\n'
            if task["validate_base"] else "")
    return f"""---
id: {TICKET_ID}
status: todo
risk: low
depends_on: []
collision_domains:{domains}
{skip}---
# Goal

{demote(parts.get('goal', ''), 3) or task['title']}

# Acceptance

{demote(parts.get('acceptance', ''), 3) or 'What the goal says, proved by the validate commands below.'}

# Non-goals

{demote(parts.get('out_of_scope', ''), 3) or 'Anything the brief does not ask for.'}

# Context

Task {task['id']}: {task['title']}. The SPEC next to this ticket's folder carries the whole brief.{chr(10) * 2 + context if context else ''}

# Validation

The runner runs the brief's validate commands (the task's validation.json); the worker does not change them.

## Cheap

{bullet_commands(task)}

## Component

None.

## Expensive

None.
"""


def plan_of(task: dict) -> dict:
    commands = [command_argv(index, command) for index, command in enumerate(task["validate"], 1)]
    plan: dict[str, object] = {"version": 1}
    if task["timeout_minutes"] is not None:
        plan["timeout_minutes"] = task["timeout_minutes"]
    plan["tickets"] = {TICKET_ID: {"cheap": commands, "component": [], "expensive": []}}
    plan["final"] = commands
    return plan


def save(path: Path, text: str):
    """Written beside its place and moved over it, owner-only."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, staged = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)
    os.replace(staged, path)


def write(brief: Path, directory: Path):
    task, body = load(brief)
    parts = sections(body)
    save(directory / "SPEC.md", spec_text(task, body, parts))
    save(directory / "tickets" / f"{TICKET_ID}.md", ticket_text(task, parts))
    save(directory / "validation.json", json.dumps(plan_of(task), indent=2, ensure_ascii=False) + "\n")
    save(directory / "task.json", json.dumps(task, indent=2, ensure_ascii=False) + "\n")


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="The plan of a task from its brief.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("slug").add_argument("brief", type=Path)
    writer = commands.add_parser("write")
    writer.add_argument("brief", type=Path)
    writer.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "slug":
            print(load(args.brief)[0]["slug"])
        else:
            write(args.brief, args.directory)
    except BriefError as error:
        print(f"campaign: invalid brief {args.brief}: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"campaign: cannot write the plan of {args.brief}: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

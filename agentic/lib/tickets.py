#!/usr/bin/env python3
"""Strict, dependency-aware access to campaign ticket front matter."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

VALID_STATUS = {"todo", "in-progress", "blocked", "needs-human", "done"}
VALID_RISK = {"low", "medium", "high"}
ID_RE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{3,}$")


class TicketError(ValueError):
    pass


def parse_scalar(value: str):
    value = value.strip()
    if value in {"", "null", "~"}:
        return None
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    if value.startswith("[") and value.endswith("]"):
        body = value[1:-1].strip()
        return [] if not body else [parse_scalar(part) for part in body.split(",")]
    return value.strip("\"'")


def parse_ticket(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise TicketError(f"{path}: ticket must be a regular non-symlink file")
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise TicketError(f"{path}: missing YAML front matter")
    try:
        end = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as exc:
        raise TicketError(f"{path}: unterminated YAML front matter") from exc

    meta: dict[str, object] = {}
    active_list: str | None = None
    for number, raw in enumerate(lines[1:end], 2):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        item = re.match(r"^\s+-\s+(.+?)\s*$", raw)
        if item and active_list:
            cast = meta.setdefault(active_list, [])
            assert isinstance(cast, list)
            cast.append(parse_scalar(item.group(1)))
            continue
        field = re.match(r"^([a-z][a-z0-9_-]*):(?:\s*(.*))?$", raw)
        if not field:
            raise TicketError(f"{path}:{number}: unsupported front matter syntax")
        key, value = field.groups()
        if key in meta:
            raise TicketError(f"{path}:{number}: duplicate field {key!r}")
        if value is None or not value.strip():
            meta[key] = []
            active_list = key
        elif value.strip() == "[]":
            meta[key] = []
            active_list = None
        else:
            meta[key] = parse_scalar(value)
            active_list = None

    required = {"id", "status", "risk", "depends_on"}
    missing = sorted(required - meta.keys())
    if missing:
        raise TicketError(f"{path}: missing fields: {', '.join(missing)}")
    ticket_id = meta["id"]
    if not isinstance(ticket_id, str) or not ID_RE.fullmatch(ticket_id):
        raise TicketError(f"{path}: invalid id {ticket_id!r}")
    if meta["status"] not in VALID_STATUS:
        raise TicketError(f"{path}: invalid status {meta['status']!r}")
    if meta["risk"] not in VALID_RISK:
        raise TicketError(f"{path}: invalid risk {meta['risk']!r}")
    if not isinstance(meta["depends_on"], list) or not all(
        isinstance(item, str) and ID_RE.fullmatch(item) for item in meta["depends_on"]
    ):
        raise TicketError(f"{path}: depends_on must be a list of ticket ids")

    sections = set(re.findall(r"(?m)^#{1,2}\s+(.+?)\s*$", text))
    for section in ("Goal", "Acceptance", "Non-goals", "Context", "Validation", "Cheap", "Component", "Expensive"):
        if section not in sections:
            raise TicketError(f"{path}: missing section {section!r}")
    if meta["risk"] in {"medium", "high"}:
        expensive = section_text(text, "Expensive")
        if not expensive.strip():
            raise TicketError(f"{path}: {meta['risk']} risk ticket must state Expensive validation (use 'None' when inapplicable)")
    meta["required"] = meta.get("required", True)
    if not isinstance(meta["required"], bool):
        raise TicketError(f"{path}: required must be true or false")
    for optional_list in ("collision_domains", "expensive_operations"):
        if optional_list in meta and (
            not isinstance(meta[optional_list], list)
            or not all(isinstance(value, str) and value for value in meta[optional_list])
        ):
            raise TicketError(f"{path}: {optional_list} must be a list of strings")
        meta.setdefault(optional_list, [])
    if meta["risk"] in {"medium", "high"}:
        for section in ("Context", "Cheap"):
            if not section_text(text, section).strip():
                raise TicketError(f"{path}: {meta['risk']} risk ticket must explain {section}")
    meta["goal"] = " ".join(section_text(text, "Goal").split())
    meta["path"] = str(path.resolve())
    return meta


def section_text(text: str, name: str) -> str:
    match = re.search(rf"(?ms)^#{{1,2}}\s+{re.escape(name)}\s*$\n(.*?)(?=^#{{1,2}}\s+|\Z)", text)
    return match.group(1).strip() if match else ""


def load(directory: Path) -> list[dict]:
    if directory.is_symlink() or not directory.is_dir():
        raise TicketError(f"{directory}: tickets directory must be a regular directory")
    root = directory.resolve()
    paths = sorted(directory.glob("*.md"))
    for path in paths:
        if path.is_symlink() or path.resolve().parent != root:
            raise TicketError(f"{path}: ticket escapes the tickets directory")
    tickets = [parse_ticket(path) for path in paths]
    by_id: dict[str, dict] = {}
    for ticket in tickets:
        if ticket["id"] in by_id:
            raise TicketError(f"duplicate ticket id {ticket['id']}")
        by_id[str(ticket["id"])] = ticket
    for ticket in tickets:
        for dependency in ticket["depends_on"]:
            if dependency not in by_id:
                raise TicketError(f"{ticket['id']}: unknown dependency {dependency}")
            if dependency == ticket["id"]:
                raise TicketError(f"{ticket['id']}: ticket depends on itself")

    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(ticket_id: str):
        if ticket_id in visiting:
            raise TicketError(f"dependency cycle includes {ticket_id}")
        if ticket_id in visited:
            return
        visiting.add(ticket_id)
        for dependency in by_id[ticket_id]["depends_on"]:
            visit(dependency)
        visiting.remove(ticket_id)
        visited.add(ticket_id)

    for ticket_id in by_id:
        visit(ticket_id)
    return tickets


def unlock_counts(tickets: list[dict]) -> dict[str, int]:
    """Count the unfinished tickets each ticket unblocks transitively, so the critical path starts first."""
    dependents: dict[str, list[str]] = {str(ticket["id"]): [] for ticket in tickets}
    pending = {str(ticket["id"]) for ticket in tickets if ticket["status"] != "done"}
    for ticket in tickets:
        for dependency in ticket["depends_on"]:
            dependents[dependency].append(str(ticket["id"]))
    reach: dict[str, set[str]] = {}

    def unlocked(ticket_id: str) -> set[str]:
        if ticket_id not in reach:
            found: set[str] = set()
            for child in dependents[ticket_id]:
                if child in pending:
                    found.add(child)
                    found |= unlocked(child)
            reach[ticket_id] = found
        return reach[ticket_id]

    return {ticket_id: len(unlocked(ticket_id)) for ticket_id in dependents}


def update_status(path: Path, expected_id: str, status: str):
    if status not in VALID_STATUS:
        raise TicketError(f"invalid target status {status}")
    ticket = parse_ticket(path)
    if ticket["id"] != expected_id:
        raise TicketError(f"ticket id mismatch: expected {expected_id}, got {ticket['id']}")
    text = path.read_text(encoding="utf-8")
    head, marker, body = text.partition("\n---\n")
    if not marker:
        raise TicketError(f"{path}: unterminated YAML front matter")
    replaced, count = re.subn(r"(?m)^status:\s*[^\n]+$", f"status: {status}", head, count=1)
    if count != 1:
        raise TicketError(f"{path}: status field is not unique")
    # Written beside the ticket and moved over it, so a reader never sees the file empty or half written.
    staged = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    staged.write_text(replaced + marker + body, encoding="utf-8")
    os.chmod(staged, path.stat().st_mode & 0o7777)
    os.replace(staged, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    list_parser = sub.add_parser("list")
    list_parser.add_argument("directory", type=Path)
    ready_parser = sub.add_parser("ready")
    ready_parser.add_argument("directory", type=Path)
    get_parser = sub.add_parser("get")
    get_parser.add_argument("directory", type=Path)
    get_parser.add_argument("ticket_id")
    update_parser = sub.add_parser("set-status")
    update_parser.add_argument("path", type=Path)
    update_parser.add_argument("ticket_id")
    update_parser.add_argument("status")
    args = parser.parse_args()
    try:
        if args.command == "set-status":
            update_status(args.path, args.ticket_id, args.status)
            return 0
        tickets = load(args.directory)
        if args.command == "ready":
            done = {str(ticket["id"]) for ticket in tickets if ticket["status"] == "done"}
            unlocks = unlock_counts(tickets)
            tickets = sorted(
                (ticket for ticket in tickets
                 if ticket["status"] == "todo" and set(ticket["depends_on"]).issubset(done)),
                key=lambda ticket: -unlocks[str(ticket["id"])],
            )
        elif args.command == "get":
            tickets = [ticket for ticket in tickets if ticket["id"] == args.ticket_id]
            if not tickets:
                raise TicketError(f"unknown ticket {args.ticket_id}")
            print(json.dumps(tickets[0], separators=(",", ":")))
            return 0
        print(json.dumps(tickets, separators=(",", ":")))
        return 0
    except (OSError, TicketError) as exc:
        print(f"campaign: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3

"""Dependency-free validator for the repository's fixed result schema."""

import json
import os
import re
import sys


PLACEHOLDERS = {"placeholder", "not implemented", "review incomplete", "todo", "stub", "fix it", "fix this",
                "fix the issue", "needs work", "needs improvement", "address this", "improve this", "rework"}


def fail(message: str) -> None:
    print(f"invalid provider result: {message}", file=sys.stderr)
    raise SystemExit(65)


if len(sys.argv) != 4:
    fail("usage: validate-result.py <schema> <expected-role> <result>")

schema_path, expected_role, result_path = sys.argv[1:]
if os.path.getsize(result_path) > 512 * 1024:
    fail("result exceeds 512 KiB")
try:
    with open(schema_path, encoding="utf-8") as stream:
        schema = json.load(stream)
    with open(result_path, encoding="utf-8") as stream:
        result = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    fail(str(error))

required = set(schema["required"])
properties = set(schema["properties"])
if not isinstance(result, dict):
    fail("root must be an object")

secret_pattern = re.compile(
    r"(?i)(?:authorization\s*:\s*(?:bearer|basic)\s+\S+|"
    r"(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|secret)\s*[:=]\s*\S+|"
    r"(?:xai-|sk-)[A-Za-z0-9_-]{10,}|postgres(?:ql)?://[^\s@]+@)"
)


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


if any(secret_pattern.search(value) for value in strings(result)):
    fail("result contains secret-like material")
if not required.issubset(result) or not set(result).issubset(properties):
    fail("result fields do not match RESULT.schema.json")
if result["schema_version"] != "1.0":
    fail("unsupported schema_version")
if result["role"] != expected_role:
    fail("role does not match invocation")

allowed_status = {
    "worker": {"PASS", "BLOCKED", "FAILED"},
    "reviewer": {"PASS", "FIX", "REPLAN"},
    "diagnostician": {"PASS", "BLOCKED"},
}
if result["status"] not in allowed_status[expected_role]:
    fail("status is invalid for role")
if not isinstance(result["summary"], str) or len(result["summary"]) > 4000:
    fail("summary must be a string of at most 4000 characters")
if not isinstance(result["changed_files"], list) or not all(isinstance(item, str) for item in result["changed_files"]):
    fail("changed_files must contain strings")
if len(set(result["changed_files"])) != len(result["changed_files"]):
    fail("changed_files must be unique")


def valid_repo_path(value):
    return (
        isinstance(value, str)
        and value
        and not os.path.isabs(value)
        and ".." not in value.split("/")
        and "\\" not in value
        and not any(ord(character) < 32 for character in value)
    )


if not all(valid_repo_path(path) for path in result["changed_files"]):
    fail("changed_files must be safe repository-relative paths")
if not isinstance(result["validation_evidence"], list):
    fail("validation_evidence must be an array")
for item in result["validation_evidence"]:
    if not isinstance(item, dict) or set(item) != {"level", "status", "command", "evidence", "expensive"}:
        fail("validation evidence has invalid fields")
    if item["level"] not in {"L0", "L1", "L2", "L3", "L4"} or item["status"] not in {"PASS", "FAIL", "NOT_RUN"}:
        fail("validation evidence has invalid level or status")
    if item["command"] is not None and not isinstance(item["command"], str):
        fail("validation command must be string or null")
    if not isinstance(item["evidence"], str) or len(item["evidence"]) > 4000 or not isinstance(item["expensive"], bool):
        fail("validation evidence has invalid values")
if not isinstance(result["needs_diagnosis"], bool):
    fail("needs_diagnosis must be boolean")
if result["blocker"] is not None and (not isinstance(result["blocker"], str) or len(result["blocker"]) > 4000):
    fail("blocker must be string or null")
human_decision = result.get("human_decision")
if human_decision is not None:
    if not isinstance(human_decision, dict) or set(human_decision) != {"category", "question"}:
        fail("human_decision has invalid fields")
    if human_decision["category"] not in {"product-ambiguity", "requirement-change", "destructive-risk"}:
        fail("human_decision category is invalid")
    if not isinstance(human_decision["question"], str) or not 1 <= len(human_decision["question"]) <= 4000:
        fail("human_decision question must be a non-empty string of at most 4000 characters")
if not isinstance(result["findings"], list):
    fail("findings must be an array")
for finding in result["findings"]:
    if not isinstance(finding, dict) or set(finding) != {"severity", "path", "line", "message", "reason", "fix"}:
        fail("finding has invalid fields")
    if (
        finding["severity"] not in {"critical", "major", "minor"}
        or not all(isinstance(finding[key], str) and 1 <= len(finding[key]) <= 4000 for key in ("message", "reason", "fix"))
    ):
        fail("finding has invalid values")
    if finding["path"] is not None and not isinstance(finding["path"], str):
        fail("finding path must be string or null")
    if finding["path"] is not None and not valid_repo_path(finding["path"]):
        fail("finding path must be repository-relative")
    if finding["line"] is not None and (
        isinstance(finding["line"], bool) or not isinstance(finding["line"], int) or finding["line"] < 1
    ):
        fail("finding line must be positive integer or null")
if result["root_cause"] is not None and (not isinstance(result["root_cause"], str) or len(result["root_cause"]) > 8000):
    fail("root_cause must be string or null")
if not isinstance(result["evidence"], list) or not all(
    isinstance(item, str) and 1 <= len(item) <= 4000 for item in result["evidence"]
):
    fail("evidence must contain strings")
reproduction = result["cheap_reproduction"]
if reproduction is not None:
    if not isinstance(reproduction, dict) or set(reproduction) != {"command", "outcome"}:
        fail("cheap_reproduction has invalid fields")
    if not all(isinstance(reproduction[key], str) and reproduction[key] for key in ("command", "outcome")):
        fail("cheap_reproduction values must be non-empty strings")
if not isinstance(result["affected_phases"], list) or not all(
    isinstance(item, str) and item for item in result["affected_phases"]
):
    fail("affected_phases must contain strings")
if len(set(result["affected_phases"])) != len(result["affected_phases"]):
    fail("affected_phases must be unique")
if result["recommended_fix"] is not None and (
    not isinstance(result["recommended_fix"], str) or len(result["recommended_fix"]) > 8000
):
    fail("recommended_fix must be string or null")

if expected_role == "worker":
    if (
        result["findings"]
        or result["root_cause"] is not None
        or result["evidence"]
        or result["cheap_reproduction"] is not None
        or result["affected_phases"]
        or result["recommended_fix"] is not None
    ):
        fail("worker populated fields owned by another role")
    if result["status"] == "BLOCKED" and not result["blocker"]:
        fail("worker BLOCKED requires a blocker")
    if human_decision is not None and result["status"] != "BLOCKED":
        fail("worker human_decision requires BLOCKED status")
elif expected_role == "reviewer":
    if result["changed_files"] or result["validation_evidence"] or result["needs_diagnosis"]:
        fail("reviewer populated worker fields")
    if (
        result["root_cause"] is not None
        or result["evidence"]
        or result["cheap_reproduction"] is not None
        or result["affected_phases"]
        or result["recommended_fix"] is not None
    ):
        fail("reviewer populated diagnostician fields")
    # Findings on PASS are advisory notes. A rejection (FIX or REPLAN) must justify every finding and give the
    # worker a direction: the defect, why it blocks, and what to do about it.
    if result["status"] in {"FIX", "REPLAN"}:
        if not result["findings"]:
            fail(f"reviewer {result['status']} requires findings with message, reason and fix")
        for f in result["findings"]:
            for key in ("message", "reason", "fix"):
                text = f[key].strip()
                if len(text) < 12 or text.lower().rstrip(".") in PLACEHOLDERS:
                    fail(f"reviewer {result['status']} finding needs a concrete {key}, not placeholder output")
            if f["fix"].strip() == f["message"].strip():
                fail("reviewer finding fix must direct the correction, not repeat the defect")
    if result["status"] == "FIX" and not any(f["severity"] in {"critical", "major"} for f in result["findings"]):
        fail("reviewer FIX requires a critical or major finding; minor findings alone are notes on PASS")
    if human_decision is not None and result["status"] != "REPLAN":
        fail("reviewer human_decision requires REPLAN status")
elif expected_role == "diagnostician":
    if human_decision is not None:
        fail("diagnostician cannot request a human decision")
    if result["changed_files"] or result["validation_evidence"] or result["needs_diagnosis"] or result["findings"]:
        fail("diagnostician populated another role's fields")
    if result["status"] == "PASS" and not all(
        [result["root_cause"], result["evidence"], result["recommended_fix"]]
    ):
        fail("diagnostician PASS is missing required diagnosis evidence")

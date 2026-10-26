#!/usr/bin/env python3

"""Extract the canonical RESULT from a provider-native envelope.

The supervisor never sees provider envelopes. Each provider adapter knows its
own stdout shape; this extractor is the only translation into RESULT.schema.json.
It never interprets model prose and never treats another provider's wrapper as required.
"""

import json
import os
import re
import sys
import tempfile


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(65)


if len(sys.argv) != 4:
    fail("usage: extract-result.py <provider> <raw-file> <result-file>")

provider, raw_path, result_path = sys.argv[1:]
try:
    size = os.path.getsize(raw_path)
    if size > 512 * 1024:
        fail(f"{provider} structured output exceeds 512 KiB")
except OSError:
    fail(f"{provider} did not return a structured output file")


def load_json_payload(path):
    try:
        with open(path, encoding="utf-8") as stream:
            raw = stream.read()
    except OSError:
        fail(f"{provider} did not return a JSON result")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    # Codex may wrap an otherwise complete structured result in a Markdown block.
    # Accept only one complete JSON block; the canonical schema is still validated
    # by provider_finish before the supervisor receives the result.
    if provider == "codex" and "```" in raw:
        blocks = re.findall(r"^```(?:json)?[ \t]*\n(.*?)^```[ \t]*$", raw, re.M | re.S)
        if len(blocks) != 1 or raw.count("```") != 2:
            fail("codex returned ambiguous or incomplete fenced JSON")
        try:
            return json.loads(blocks[0])
        except json.JSONDecodeError:
            fail("codex returned invalid fenced JSON")
    last = None
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            last = json.loads(stripped)
        except json.JSONDecodeError:
            continue
    if isinstance(last, dict):
        return last
    start = raw.find("{")
    if start != -1:
        try:
            parsed = json.loads(raw[start:])
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            pass
    fail(f"{provider} did not return a JSON result (bytes={size})")


payload = load_json_payload(raw_path)


def canonical_result(value):
    return (
        isinstance(value, dict)
        and "schema_version" in value
        and "role" in value
        and "status" in value
    )


def json_object(value):
    if isinstance(value, dict):
        return value
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[-1]
        fence = stripped.rfind("```")
        if fence != -1:
            stripped = stripped[:fence]
        stripped = stripped.strip()
        if stripped.lower().startswith("json"):
            stripped = stripped[4:].lstrip()
    if not stripped:
        return None
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def extract_codex(raw):
    return raw if canonical_result(raw) else None


def extract_claude(raw):
    if canonical_result(raw):
        return raw
    if not isinstance(raw, dict):
        return None
    nested = raw.get("structured_output")
    return nested if canonical_result(nested) else None


def extract_message_content(message):
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    direct = json_object(content)
    if canonical_result(direct):
        return direct
    if not isinstance(content, list):
        return None
    texts = [
        block.get("text")
        for block in content
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str)
    ]
    joined = json_object("\n".join(texts))
    return joined if canonical_result(joined) else None


def extract_grok(raw):
    if canonical_result(raw):
        return raw
    if not isinstance(raw, dict):
        return None
    if raw.get("type") == "error":
        return None
    # Grok 1.0.13 --output-format json:
    # {"text": <schema JSON string or object>, "stopReason", "sessionId", "requestId", ...}
    text = json_object(raw.get("text"))
    if canonical_result(text) and "safe_to_retry" in text:
        # Historical native envelopes carried a diagnostic hint; the lean runner
        # does not treat it as execution authorization.
        if text["safe_to_retry"] is not None and type(text["safe_to_retry"]) is not bool:
            return None
        text = dict(text)
        text.pop("safe_to_retry")
        text.setdefault("human_decision", None)
    if canonical_result(text):
        return text
    # Tool-using turns sometimes emit the same payload on `content` instead of `text`.
    # A native envelope may also carry schema output on `structured_output`; a
    # Claude-only `{structured_output: ...}` wrapper is rejected below.
    for key in ("text", "content", "result"):
        value = json_object(raw.get(key))
        if canonical_result(value):
            return value
    native = any(key in raw for key in ("stopReason", "sessionId", "requestId"))
    if native:
        for key in ("structuredOutput", "structured_output"):
            value = json_object(raw.get(key))
            if canonical_result(value):
                return value
    nested = extract_message_content(raw.get("message") if isinstance(raw.get("message"), dict) else raw)
    return nested if canonical_result(nested) else None


extractors = {
    "codex": extract_codex,
    "claude": extract_claude,
    "grok": extract_grok,
}
extractor = extractors.get(provider)
if extractor is None:
    fail(f"unknown provider: {provider}")
result = extractor(payload)
if not canonical_result(result):
    if isinstance(payload, dict):
        keys = ",".join(sorted(str(key) for key in payload))
        stop = payload.get("stopReason") or payload.get("stop_reason") or ""
        fail(
            f"{provider} did not return native structured output "
            f"(keys={keys}; stopReason={stop})"
        )
    fail(f"{provider} did not return native structured output")

schema_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "RESULT.schema.json")
try:
    with open(schema_path, encoding="utf-8") as stream:
        allowed = set(json.load(stream)["properties"])
    result = {key: value for key, value in result.items() if key in allowed}
except (OSError, json.JSONDecodeError, KeyError):
    pass
if not canonical_result(result):
    fail(f"{provider} did not return native structured output")

destination_dir = os.path.dirname(os.path.abspath(result_path))
descriptor, temporary = tempfile.mkstemp(prefix=".result-", dir=destination_dir, text=True)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, separators=(",", ":"))
        stream.write("\n")
    os.replace(temporary, result_path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)

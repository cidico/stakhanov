#!/usr/bin/env bash

set -euo pipefail

umask 077

provider_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
result_schema="$provider_root/../RESULT.schema.json"
result_validator="$provider_root/validate-result.py"
result_extractor="$provider_root/extract-result.py"

provider_usage() {
  printf 'usage: run.sh <worker|reviewer|diagnostician> <worktree> <prompt-file> <result-file> <event-file>\n' >&2
  return 64
}

provider_init() {
  if [[ $# -ne 6 ]]; then
    provider_usage
    return $?
  fi

  provider_name=$1
  role=$2
  worktree=$3
  prompt_file=$4
  result_file=$5
  event_file=$6
  provider_run_id=$(python3 -c 'import uuid; print(uuid.uuid4())')

  case "$role" in
    worker|reviewer|diagnostician) ;;
    *) printf 'invalid role: %s\n' "$role" >&2; return 64 ;;
  esac

  [[ -d "$worktree" ]] || { printf 'worktree unavailable: %s\n' "$worktree" >&2; return 66; }
  [[ -f "$prompt_file" ]] || { printf 'prompt unavailable: %s\n' "$prompt_file" >&2; return 66; }
  [[ -f "$result_schema" ]] || { printf 'result schema unavailable\n' >&2; return 66; }

  mkdir -p -- "$(dirname -- "$result_file")" "$(dirname -- "$event_file")"
  touch -- "$event_file"
}

# What each provider process cost, one usage file per process (a repeated invocation in another account is a second one).
provider_usage_files=()

# provider_usage_record <raw output file>: reads the cost of one provider process from its raw output. Never fails.
provider_usage_record() {
  local usage_file
  usage_file="$1.usage.$((${#provider_usage_files[@]} + 1)).json"
  python3 "$result_extractor" --usage-only "$provider_name" "$1" "$usage_file" || true
  provider_usage_files+=("$usage_file")
}

# Prints the usage summed over the recorded processes as a JSON object, or null when none could be read. A count or
# cost no process reported stays null.
provider_usage_sum() {
  python3 - "$provider_name" "${provider_usage_files[@]}" <<'PY' || printf 'null\n'
import json
import sys

fields = ("cost_usd", "input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens", "num_turns", "duration_ms")
records = []
for path in sys.argv[2:]:
    try:
        with open(path, encoding="utf-8") as stream:
            record = json.load(stream)
        if isinstance(record, dict):
            records.append(record)
    except (OSError, ValueError):
        pass
if not records:
    print("null")
    raise SystemExit
models = {record["model"] for record in records if record.get("model")}
total = {"provider": sys.argv[1], "model": models.pop() if len(models) == 1 else None}
for field in fields:
    values = [record[field] for record in records if record.get(field) is not None]
    total[field] = (round(sum(values), 10) if field == "cost_usd" else sum(values)) if values else None
print(json.dumps(total, separators=(",", ":")))
PY
}

# Writes the summed usage next to the result, as <result>.usage.json. A failure is a warning, never a failed call.
provider_usage_store() {
  local usage
  usage=$(provider_usage_sum)
  rm -f -- "$result_file.usage.json"
  [[ $usage != null ]] || return 0
  { printf '%s\n' "$usage" > "$result_file.usage.json.tmp" && mv -f -- "$result_file.usage.json.tmp" "$result_file.usage.json"; } 2>/dev/null ||
    { rm -f -- "$result_file.usage.json.tmp"; printf '%s usage not recorded: cannot write %s.usage.json\n' "$provider_name" "$result_file" >&2; }
}

provider_event() {
  local state=$1
  local message=$2
  local usage=null attempts=0
  # A finished process, completed or failed, reports what its processes cost.
  if [[ $state == completed || $state == failed ]] && ((${#provider_usage_files[@]} > 0)); then
    attempts=${#provider_usage_files[@]}
    usage=$(provider_usage_sum)
  fi
  PROVIDER_EVENT_PROVIDER=$provider_name \
  PROVIDER_EVENT_ROLE=$role \
  PROVIDER_EVENT_STATE=$state \
  PROVIDER_EVENT_MESSAGE=$message \
  PROVIDER_EVENT_RUN_ID=$provider_run_id \
  PROVIDER_EVENT_PID=$$ \
  PROVIDER_EVENT_USAGE=$usage \
  PROVIDER_EVENT_ATTEMPTS=$attempts \
  python3 - "$event_file" <<'PY'
import datetime
import json
import os
import sys

event = {
    "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "type": "provider",
    "provider": os.environ["PROVIDER_EVENT_PROVIDER"],
    "run_id": os.environ["PROVIDER_EVENT_RUN_ID"],
    "adapter_pid": int(os.environ["PROVIDER_EVENT_PID"]),
    "role": os.environ["PROVIDER_EVENT_ROLE"],
    "state": os.environ["PROVIDER_EVENT_STATE"],
    "message": os.environ["PROVIDER_EVENT_MESSAGE"],
}
if int(os.environ["PROVIDER_EVENT_ATTEMPTS"]) > 0:
    event["usage"] = json.loads(os.environ["PROVIDER_EVENT_USAGE"])
    event["attempts"] = int(os.environ["PROVIDER_EVENT_ATTEMPTS"])
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}

provider_unavailable() {
  provider_event unavailable 'provider unavailable'
  printf '%s provider unavailable\n' "$provider_name" >&2
  return 69
}

provider_prompt() {
  local destination=$1
  # Constrain generation to the same role ownership enforced by the validator.
  # The canonical wire format remains unchanged for every provider.
  python3 - "$result_schema" "$role" "$destination.schema.json" <<'PY'
import json
import sys

schema = json.load(open(sys.argv[1], encoding="utf-8"))
role = sys.argv[2]
properties = schema["properties"]
properties["role"] = {"type": "string", "enum": [role]}
properties["status"]["enum"] = {
    "worker": ["PASS", "BLOCKED", "FAILED"],
    "reviewer": ["PASS", "FIX", "REPLAN"],
    "diagnostician": ["PASS", "BLOCKED"],
}[role]
empty_arrays = []
null_fields = []
if role != "worker":
    empty_arrays += ["changed_files", "validation_evidence"]
    properties["needs_diagnosis"] = {"type": "boolean", "enum": [False]}
if role != "reviewer":
    empty_arrays += ["findings"]
if role != "diagnostician":
    empty_arrays += ["evidence", "affected_phases"]
    null_fields += ["root_cause", "cheap_reproduction", "recommended_fix"]
else:
    null_fields += ["human_decision"]
for name in empty_arrays:
    properties[name]["maxItems"] = 0
for name in null_fields:
    properties[name] = {"type": "null"}
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    json.dump(schema, stream)
PY
  result_schema="$destination.schema.json"
  {
    if [[ ${provider_name:-} == codex ]]; then
      printf '%s\n' 'Complete this role in this single fresh process. Do not spawn, delegate to, or wait for nested agents: ephemeral Codex sessions have no persistent parent thread. The campaign supervisor owns all worker, reviewer, and diagnostician processes. If a skill suggests parallel agents, perform those checks yourself.'
    fi
    printf '%s\n' 'Return only the structured result required by the supplied JSON Schema.'
    printf 'Set role to %s. Use status PASS, BLOCKED, or FAILED for worker; PASS, FIX, or REPLAN for reviewer; PASS or BLOCKED for diagnostician.\n' "$role"
    printf '%s\n' 'Populate fields that do not apply with empty arrays, false, or null as their schema permits.'
    printf '%s\n' 'Keep summary under 3000 characters: state the outcome and the key decisions; put command proof in validation_evidence and long detail in the code or tickets, never in summary.'
    if [[ $role == diagnostician ]]; then
      printf '%s\n' 'Diagnostician: changed_files=[], validation_evidence=[], findings=[], needs_diagnosis=false, human_decision=null. Put all observed proof in evidence and cheap_reproduction.'
    fi
    printf '%s\n' 'Use human_decision only for product ambiguity, requirement change, or destructive risk; never for routine commands or technical failures.'
    printf '%s\n' 'Worker BLOCKED requires a blocker; worker FAILED requires needs_diagnosis=true.'
    printf '%s\n' 'Reviewer FIX or REPLAN: every finding states message (the defect and where), reason (the acceptance item, SPEC requirement or repository rule it breaks, or the concrete failure it causes) and fix (what the worker must do and how to prove it; code optional). FIX needs a critical or major finding; minor findings alone are notes on PASS.'
    printf '%s\n' 'Reviewer: every finding, on PASS too, names its guard {kind, how}: the automatic check (analyzer, lint, test, validate or executor) that would have caught it so it never comes back, with one line saying which rule, test or command asserts what; reviewer-only, with why, when no automatic check can.'
    printf '%s\n\n' 'Never include credentials, tokens, authorization headers, connection strings, or raw secret values in the result.'
    command cat -- "$prompt_file"
  } > "$destination"
}

provider_finish() {
  local raw_file=$1
  local staged_result
  # An adapter that ran more than one process recorded each of them; otherwise the raw file is the only one.
  ((${#provider_usage_files[@]} > 0)) || provider_usage_record "$raw_file"
  staged_result=$(mktemp "$(dirname -- "$result_file")/.result.XXXXXX")
  # The extractor writes the usage of this raw file beside the staged result; the sum over all processes replaces it.
  if ! python3 "$result_extractor" "$provider_name" "$raw_file" "$staged_result" ||
     ! python3 "$result_validator" "$result_schema" "$role" "$staged_result"; then
    rm -f -- "$staged_result" "$staged_result.usage.json"
    provider_event failed 'provider returned an invalid structured result'
    return 65
  fi
  rm -f -- "$staged_result.usage.json"
  mv -f -- "$staged_result" "$result_file"
  provider_usage_store
  provider_event completed 'structured result validated'
}

# Short, single-line tail of a failed provider's output (the "result" text of a JSON envelope when there is one),
# so the sanitized runner log keeps the real error instead of a bare exit status.
provider_tail() {
  local file=$1 text=''
  [[ -s $file ]] || return 0
  text=$(jq -r 'select(type == "object") | (.result // .error // empty) | tostring' "$file" 2>/dev/null | head -c 400) || true
  [[ -n $text ]] || text=$(tail -c 400 -- "$file")
  printf '%s' "$text" | tr -s '[:space:]' ' ' | head -c 400
}

# provider_failed <exit code> [stderr file] [raw output file]
provider_failed() {
  local exit_code=$1 error_tail='' output_tail=''
  provider_event failed "provider exited with status $exit_code"
  if [[ $# -lt 2 ]]; then
    printf '%s provider failed with status %s; raw output was discarded\n' "$provider_name" "$exit_code" >&2
    return "$exit_code"
  fi
  error_tail=$(provider_tail "$2")
  [[ -z ${3:-} ]] || output_tail=$(provider_tail "$3")
  printf '%s provider failed with status %s; stderr: %s; output: %s\n' "$provider_name" "$exit_code" \
    "${error_tail:-(empty)}" "${output_tail:-(empty)}" >&2
  return "$exit_code"
}

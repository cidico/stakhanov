#!/usr/bin/env bash

set -euo pipefail

kit=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

passed=0
failed=0

python3 - "$kit/RESULT.schema.json" <<'PY'
import json
import sys

schema = json.load(open(sys.argv[1], encoding="utf-8"))

def check(node, path="root"):
    if not isinstance(node, dict):
        return
    if "enum" in node or "const" in node:
        assert "type" in node, f"{path}: enum/const must declare type"
    if node.get("type") == "object":
        properties = node.get("properties", {})
        assert set(node.get("required", [])) == set(properties), f"{path}: every property must be required"
    for key, value in node.items():
        if isinstance(value, dict):
            check(value, f"{path}.{key}")
        elif isinstance(value, list):
            for index, item in enumerate(value):
                check(item, f"{path}.{key}[{index}]")

check(schema)
PY

pass() {
  passed=$((passed + 1))
  printf 'ok %s - %s\n' "$passed" "$1"
}

fail() {
  failed=$((failed + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_command() {
  local description=$1
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

make_result() {
  local role=$1
  local status=$2
  local destination=$3
  RESULT_ROLE=$role RESULT_STATUS=$status python3 - "$destination" <<'PY'
import json
import os
import sys

role = os.environ["RESULT_ROLE"]
status = os.environ["RESULT_STATUS"]
result = {
    "schema_version": "1.0",
    "role": role,
    "status": status,
    "summary": "deterministic mock result",
    "changed_files": ["src/example.txt"] if role == "worker" else [],
    "validation_evidence": ([{
        "level": "L0", "status": "PASS", "command": "git diff --check",
        "evidence": "clean", "expensive": False,
    }] if role == "worker" else []),
    "needs_diagnosis": False,
    "blocker": None,
    "human_decision": None,
    "findings": [],
    "root_cause": "fixture mismatch" if role == "diagnostician" else None,
    "evidence": ["cheap check reproduced the mismatch"] if role == "diagnostician" else [],
    "cheap_reproduction": ({"command": "test -f fixture", "outcome": "failed before repair"}
                           if role == "diagnostician" else None),
    "affected_phases": ["preflight", "validate"] if role == "diagnostician" else [],
    "recommended_fix": "repair the fixture source" if role == "diagnostician" else None,
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(result, stream)
PY
}

role_schema_contract() {
  bash -c 'source "$1"; role=diagnostician; prompt_file="$2"; provider_prompt "$3"; python3 - "$result_schema" <<'"'"'PYROLE'"'"'
import json,sys
p=json.load(open(sys.argv[1]))["properties"]
assert p["role"]["enum"] == ["diagnostician"]
assert p["status"]["enum"] == ["PASS", "BLOCKED"]
for key in ("changed_files", "validation_evidence", "findings"):
    assert p[key]["maxItems"] == 0, key
assert p["needs_diagnosis"]["enum"] == [False]
assert p["human_decision"] == {"type": "null"}
assert "maxItems" not in p["evidence"]
PYROLE' _ "$kit/providers/common.sh" /dev/null "$test_root/role-prompt"
}
assert_command 'Diagnostician generation rejects fields owned by other roles' role_schema_contract

workspace="$test_root/worktree"
runtime="$test_root/runtime"
mock_bin="$test_root/bin"
unavailable_bin="$test_root/unavailable-bin"
mkdir -p "$workspace" "$runtime" "$mock_bin" "$unavailable_bin"
for required_command in bash dirname python3 mkdir touch chmod; do
  ln -s "$(command -v "$required_command")" "$unavailable_bin/$required_command"
done
printf 'mock prompt\n' > "$runtime/prompt.md"

make_result worker PASS "$runtime/worker.json"
make_result reviewer PASS "$runtime/reviewer.json"
make_result diagnostician PASS "$runtime/diagnostician.json"

cat > "$mock_bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --help "* ]]; then
  printf '%s\n' '--dangerously-bypass-approvals-and-sandbox --cd --ephemeral --output-schema --output-last-message --json'
  exit 0
fi
output=
while (($#)); do
  printf '%s\n' "$1" >> "$MOCK_ARGS"
  if [[ $1 == --output-last-message ]]; then
    output=$2
    printf '%s\n' "$2" >> "$MOCK_ARGS"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
cp "$MOCK_RESULT" "$output"
printf 'Authorization: Bearer should-never-reach-events\n' >&2
printf '{"type":"completed"}\n'
MOCK

cat > "$mock_bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --help "* ]]; then
  printf '%s\n' '--print --output-format --json-schema --no-session-persistence --permission-mode bypassPermissions --permission-prompts --effort --settings'
  exit 0
fi
printf '%s\n' "$@" > "$MOCK_ARGS"
cat >/dev/null
jq -cn --slurpfile result "$MOCK_RESULT" '{type:"result",subtype:"success",structured_output:$result[0]}'
printf 'api_key=should-never-reach-events\n' >&2
MOCK

cat > "$mock_bin/grok" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --help "* ]]; then
  printf '%s\n' '--always-approve --prompt-file --cwd --output-format --json-schema --no-subagents --permission-mode --reasoning-effort'
  exit 0
fi
printf '%s\n' "$@" > "$MOCK_ARGS"
jq -cn --rawfile text "$MOCK_RESULT" '{text:$text,stopReason:"end_turn",sessionId:"fixture-session",requestId:"fixture-request"}'
printf 'password=should-never-reach-events\n' >&2
MOCK
chmod +x "$mock_bin/codex" "$mock_bin/claude" "$mock_bin/grok"

run_adapter() {
  local provider=$1
  local role=$2
  local fixture=$3
  local result="$runtime/$provider-$role-result.json"
  local events="$runtime/$provider-$role-events.jsonl"
  local args="$runtime/$provider-$role-args"
  PATH="$mock_bin:/usr/bin:/bin" MOCK_RESULT="$fixture" MOCK_ARGS="$args" \
    "$kit/providers/$provider/run.sh" \
    "$role" "$workspace" "$runtime/prompt.md" "$result" "$events" || return
  python3 "$kit/providers/validate-result.py" \
    "$kit/RESULT.schema.json" "$role" "$result" || return
  jq -e -s 'length == 2 and all(.[]; .type == "provider" and (.run_id | test("^[0-9a-f-]{36}$")))' \
    "$events" >/dev/null || return
  ! grep -qiE 'should-never|authorization|api_key|password' "$events"
}

assert_command 'Codex worker contract returns validated JSON' \
  run_adapter codex worker "$runtime/worker.json"
assert_command 'Codex preflight accepts interactive non-interrupting mode' \
  env PATH="$mock_bin:/usr/bin:/bin" "$kit/providers/codex/run.sh" --preflight interactive
assert_command 'Codex reviewer contract returns validated JSON' \
  run_adapter codex reviewer "$runtime/reviewer.json"
assert_command 'Codex diagnostician contract returns validated JSON' \
  run_adapter codex diagnostician "$runtime/diagnostician.json"
for role in worker reviewer diagnostician; do
  assert_command "Codex $role is fresh with explicit full operational access" \
    python3 - "$runtime/codex-$role-args" <<'PYTHON'
import sys
args = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert "resume" not in args and "fork" not in args
assert "--ephemeral" in args
assert args[args.index("--disable") + 1] == "multi_agent"
assert args.index("--dangerously-bypass-approvals-and-sandbox") < args.index("exec")
assert "--sandbox" not in args and "--ask-for-approval" not in args
assert args.index("--cd") < args.index("exec")
PYTHON
done

assert_command 'Claude worker extracts native structured_output' \
  run_adapter claude worker "$runtime/worker.json"
assert_command 'Claude invocation is fresh and non-persistent' \
  bash -c '! grep -qxE -- "--(continue|resume)" "$1" && grep -qxE -- "--no-session-persistence" "$1" && grep -qxE "bypassPermissions" "$1" && grep -qF "disableAllHooks" "$1"' _ "$runtime/claude-worker-args"
assert_command 'Claude preflight accepts unattended non-interrupting mode' \
  env PATH="$mock_bin:/usr/bin:/bin" "$kit/providers/claude/run.sh" --preflight unattended
assert_command 'Claude reviewer is read-only' \
  run_adapter claude reviewer "$runtime/reviewer.json"
assert_command 'Claude reviewer uses plan mode' \
  grep -qxE 'plan' "$runtime/claude-reviewer-args"
claude_model() { python3 -c 'import sys; a=open(sys.argv[1]).read().splitlines(); print(a[a.index("--model")+1])' "$1"; }
export -f claude_model
assert_command 'Claude roles pin their own model instead of the account default' \
  bash -c '[[ $(claude_model "$1") == opus && $(claude_model "$2") == opus ]]' _ \
  "$runtime/claude-worker-args" "$runtime/claude-reviewer-args"

assert_command 'Grok worker extracts native 1.0.13 json text payload' \
  run_adapter grok worker "$runtime/worker.json"
assert_command 'Grok worker extracts a captured 1.0.13 envelope' \
  bash -c 'python3 "$1" grok "$2" "$3" && python3 "$4" "$5" worker "$3"' _ \
  "$kit/providers/extract-result.py" \
  "$kit/tests/fixtures/grok-1.0.13/worker-native.json" \
  "$runtime/grok-captured-result.json" \
  "$kit/providers/validate-result.py" \
  "$kit/RESULT.schema.json"
assert_command 'Grok reviewer extracts native json text payload' \
  run_adapter grok reviewer "$runtime/reviewer.json"
assert_command 'Grok preflight accepts unattended non-interrupting mode' \
  env PATH="$mock_bin:/usr/bin:/bin" "$kit/providers/grok/run.sh" --preflight unattended
assert_command 'Grok invocation is fresh, headless, and non-interrupting' \
  bash -c '! grep -qxE -- "--(continue|resume|no-memory|no-auto-update)" "$1" && grep -qxE -- "--no-subagents" "$1" && grep -qxE -- "--always-approve" "$1" && grep -qxE "bypassPermissions" "$1"' _ "$runtime/grok-worker-args"
assert_command 'Grok diagnostician returns complete diagnosis' \
  run_adapter grok diagnostician "$runtime/diagnostician.json"
assert_command 'Grok diagnostician uses plan mode' \
  grep -qxE 'plan' "$runtime/grok-diagnostician-args"
assert_command 'Grok reviewer disallows shell, monitors, and Agent so plan mode cannot cancel the turn' \
  bash -c 'grep -qxE -- "--disallowed-tools" "$1" && grep -qE "run_terminal" "$1" && grep -qE "monitor" "$1" && grep -qE "Agent" "$1"' _ "$runtime/grok-reviewer-args"
assert_command 'Grok diagnostician disallows shell, monitors, and Agent so plan mode cannot cancel the turn' \
  bash -c 'grep -qxE -- "--disallowed-tools" "$1" && grep -qE "run_terminal" "$1" && grep -qE "monitor" "$1" && grep -qE "Agent" "$1"' _ "$runtime/grok-diagnostician-args"
assert_command 'Grok worker keeps shell' \
  bash -c '! grep -qxE -- "--disallowed-tools" "$1"' _ "$runtime/grok-worker-args"

jq -cn --argjson result "$(cat "$runtime/worker.json")" '{structured_output:$result}' > "$runtime/grok-claude-envelope.json"
assert_command 'Grok rejects a Claude structured_output envelope' \
  bash -c '! python3 "$1" grok "$2" "$3" >/dev/null 2>&1' _ \
  "$kit/providers/extract-result.py" "$runtime/grok-claude-envelope.json" "$runtime/grok-wrong-envelope-result.json"
jq -cn '{text:"{\"schema_version\":\"1.0\",\"role\":\"worker\"}",stopReason:"end_turn",sessionId:"fixture",requestId:"fixture"}' \
  > "$runtime/grok-invalid-payload.json"
assert_command 'Grok native JSON with invalid canonical payload is rejected' \
  bash -c '! python3 "$1" grok "$2" "$3" >/dev/null 2>&1' _ \
  "$kit/providers/extract-result.py" "$runtime/grok-invalid-payload.json" "$runtime/grok-invalid-extracted.json"
jq -cn '{text:"not json",stopReason:"end_turn",sessionId:"fixture",requestId:"fixture"}' > "$runtime/grok-missing-result.json"
assert_command 'Grok rejects native success without canonical JSON payload' \
  bash -c '! python3 "$1" grok "$2" "$3" >/dev/null 2>&1' _ \
  "$kit/providers/extract-result.py" "$runtime/grok-missing-result.json" "$runtime/grok-missing-result-output.json"
jq -cn --slurpfile result "$runtime/worker.json" \
  '{text:"",stopReason:"end_turn",sessionId:"fixture",requestId:"fixture",structuredOutput:$result[0]}' \
  > "$runtime/grok-structured-output.json"
assert_command 'Grok extracts structuredOutput from a native json envelope' \
  bash -c 'python3 "$1" grok "$2" "$3" && python3 "$4" "$5" worker "$3"' _ \
  "$kit/providers/extract-result.py" \
  "$runtime/grok-structured-output.json" \
  "$runtime/grok-structured-output-result.json" \
  "$kit/providers/validate-result.py" \
  "$kit/RESULT.schema.json"
jq -cn --slurpfile result "$runtime/worker.json" \
  '{text:"",stopReason:"end_turn",sessionId:"fixture",requestId:"fixture",structured_output:$result[0]}' \
  > "$runtime/grok-structured-output-snake.json"
assert_command 'Grok extracts snake_case structured_output from a native json envelope' \
  bash -c 'python3 "$1" grok "$2" "$3" && python3 "$4" "$5" worker "$3"' _ \
  "$kit/providers/extract-result.py" \
  "$runtime/grok-structured-output-snake.json" \
  "$runtime/grok-structured-output-snake-result.json" \
  "$kit/providers/validate-result.py" \
  "$kit/RESULT.schema.json"
jq -cn --slurpfile result "$runtime/worker.json" \
  '{text:"",stopReason:"end_turn",sessionId:"fixture",requestId:"fixture",structuredOutput:$result[0]}' \
  > "$runtime/grok-ndjson-last.json"
{
  printf '%s\n' '{"type":"thought","data":"working"}'
  cat "$runtime/grok-ndjson-last.json"
  printf '\n'
} > "$runtime/grok-ndjson.json"
assert_command 'Grok extracts the last native JSON object from NDJSON stdout' \
  bash -c 'python3 "$1" grok "$2" "$3" && python3 "$4" "$5" worker "$3"' _ \
  "$kit/providers/extract-result.py" \
  "$runtime/grok-ndjson.json" \
  "$runtime/grok-ndjson-result.json" \
  "$kit/providers/validate-result.py" \
  "$kit/RESULT.schema.json"
jq -cn '{text:"",stopReason:"cancelled",sessionId:"fixture",requestId:"fixture"}' \
  > "$runtime/grok-cancelled.json"
assert_command 'Grok cancelled turn without payload is rejected' \
  bash -c '! python3 "$1" grok "$2" "$3" >/dev/null 2>&1' _ \
  "$kit/providers/extract-result.py" "$runtime/grok-cancelled.json" "$runtime/grok-cancelled-result.json"

cp "$runtime/worker.json" "$runtime/wrong-role.json"
assert_command 'Validator rejects a result for the wrong role' \
  bash -c '! python3 "$1" "$2" reviewer "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/wrong-role.json"

jq '.summary = "api_key=0123456789abcdef"' "$runtime/worker.json" > "$runtime/secret-result.json"
assert_command 'Validator rejects secret-like result content' \
  bash -c '! python3 "$1" "$2" worker "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/secret-result.json"

jq '.status = "FAILED"' "$runtime/worker.json" > "$runtime/failed-without-diagnosis.json"
assert_command 'Worker FAILED does not require diagnosis' \
  bash -c 'python3 "$1" "$2" worker "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/failed-without-diagnosis.json"

jq '.status = "FIX"' "$runtime/reviewer.json" > "$runtime/fix-without-findings.json"
assert_command 'Reviewer FIX requires findings' \
  bash -c '! python3 "$1" "$2" reviewer "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/fix-without-findings.json"

jq '.status = "FIX" | .findings = [{severity:"major", path:"src/example.txt", line:3,
  message:"The order total ignores the shipping cost on a full refund.",
  reason:"Acceptance A12: the customer receives the full order total back after a refund.",
  fix:"Include the shipping cost in the refunded amount and test a full refund."}]' \
  "$runtime/reviewer.json" > "$runtime/fix-justified.json"
assert_command 'Reviewer FIX with defect, reason and fix is accepted' \
  python3 "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" reviewer "$runtime/fix-justified.json"

jq '.findings[0].fix = "fix it"' "$runtime/fix-justified.json" > "$runtime/fix-without-direction.json"
assert_command 'Reviewer FIX without a direction is rejected' \
  bash -c '! python3 "$1" "$2" reviewer "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/fix-without-direction.json"

jq '.findings[0].severity = "minor"' "$runtime/fix-justified.json" > "$runtime/fix-only-minor.json"
assert_command 'Reviewer FIX with only minor findings is rejected' \
  bash -c '! python3 "$1" "$2" reviewer "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/fix-only-minor.json"

assert_command 'Invalid native result is rejected before canonical install' \
  bash -c 'result=$1; events=$2; rm -f "$result" "$events"; PATH="$3:/usr/bin:/bin" MOCK_RESULT="$4" MOCK_ARGS="$5" "$6" worker "$7" "$8" "$result" "$events" >/dev/null 2>&1; code=$?; [[ $code -eq 65 && ! -e $result ]] && jq -e -s '\''.[-1].state == "failed"'\'' "$events" >/dev/null' _ \
  "$runtime/invalid-result.json" "$runtime/invalid-events.jsonl" "$mock_bin" "$runtime/secret-result.json" \
  "$runtime/invalid-args" "$kit/providers/codex/run.sh" "$workspace" "$runtime/prompt.md"

dd if=/dev/zero of="$runtime/oversized.json" bs=1024 count=513 status=none
assert_command 'Oversized provider output is rejected before JSON parsing' \
  bash -c '! python3 "$1" codex "$2" "$3" >/dev/null 2>&1' _ \
  "$kit/providers/extract-result.py" "$runtime/oversized.json" "$runtime/oversized-result.json"

# A usage limit is a provider failure like any other, with the real error in stderr.
cat > "$mock_bin/claude" <<'MOCK'
#!/usr/bin/env bash
[[ " $* " != *" --help "* ]] || exit 0
cat > /dev/null
printf '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your weekly limit"}\n'
exit 1
MOCK
chmod +x "$mock_bin/claude"
assert_command 'A usage limit fails the role and the real error reaches stderr' \
  bash -c 'result=$1; events=$2; rm -f "$result" "$events"; PATH="$3:/usr/bin:/bin" "$4" worker "$5" "$6" "$result" "$events" 2>"$7"; code=$?; [[ $code -eq 1 && ! -e $result ]] && grep -q "hit your weekly limit" "$7"' _ \
  "$runtime/limit-result.json" "$runtime/limit-events.jsonl" "$mock_bin" \
  "$kit/providers/claude/run.sh" "$workspace" "$runtime/prompt.md" "$runtime/limit-stderr"

# Account hook (AGENTIC_CLAUDE_ACCOUNTS, udarnik-compatible): a fake claude out of quota in the accounts listed in
# HOOK_LIMITED, and a fake hook command that switches from account A to account B.
hook_bin="$test_root/hook-bin"
hook_calls="$test_root/hook-calls"
hook_home="$test_root/hook-home"
mkdir -p "$hook_bin" "$hook_calls" "$hook_home"
hook_a="$hook_home/.claude-a"
hook_b="$hook_home/.claude-b two"
cat > "$hook_bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " != *" --help "* ]] || exit 0
number=$(( $(find "$HOOK_CALLS" -name '*.args' | wc -l) + 1 ))
printf '%s\n' "$@" > "$HOOK_CALLS/$number.args"
printf '%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" > "$HOOK_CALLS/$number.config"
cat > "$HOOK_CALLS/$number.prompt"
if [[ ${HOOK_OTHER_ERROR:-} == 1 ]]; then
  printf '{"type":"result","subtype":"success","is_error":true,"result":"API Error: overloaded"}\n'
  exit 1
fi
if [[ ${HOOK_LIMIT_ALL:-} == 1 || ${CLAUDE_CONFIG_DIR-} == "${HOOK_LIMITED:-none}" ]]; then
  printf '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your weekly limit"}\n'
  exit 1
fi
jq -cn --slurpfile result "$MOCK_RESULT" '{type:"result",subtype:"success",structured_output:$result[0]}'
MOCK
cat > "$hook_bin/accounts" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HOOK_CALLS/hook.log"
case "$1 $2" in
  'account enabled') [[ ${HOOK_ENABLED:-1} == 1 ]] ;;
  'account current') printf '%s\n' "$HOOK_A" ;;
  'account env')
    if [[ $3 == "$HOME/.claude" ]]; then printf 'env -u CLAUDE_CONFIG_DIR\n'; else printf 'env CLAUDE_CONFIG_DIR=%q\n' "$3"; fi ;;
  'account limit')
    text=$(cat)
    printf '%s' "$text" > "$HOOK_CALLS/limit-$(basename -- "$3").txt"
    grep -qi 'hit your .*limit' <<<"$text" || exit 1
    [[ ${HOOK_NONE_LEFT:-0} != 1 && $3 == "$HOOK_A" ]] || exit 75
    printf '%s\n' "$HOOK_B" ;;
  *) exit 64 ;;
esac
MOCK
chmod +x "$hook_bin/claude" "$hook_bin/accounts"
hook_run() { # <name> [extra env...]: a claude worker with the hook; leaves hook-<name>-{result.json,events.jsonl,stderr}
  local name=$1
  shift
  rm -rf "$hook_calls" && mkdir -p "$hook_calls"
  rm -f "$runtime/hook-$name-result.json" "$runtime/hook-$name-events.jsonl"
  env -u CLAUDE_CONFIG_DIR HOME="$hook_home" PATH="$hook_bin:/usr/bin:/bin" AGENTIC_CLAUDE_ACCOUNTS=accounts \
    HOOK_CALLS="$hook_calls" HOOK_A="$hook_a" HOOK_B="$hook_b" MOCK_RESULT="$runtime/worker.json" "$@" \
    "$kit/providers/claude/run.sh" worker "$workspace" "$runtime/prompt.md" \
    "$runtime/hook-$name-result.json" "$runtime/hook-$name-events.jsonl" 2> "$runtime/hook-$name-stderr"
}
hook_calls_count() { find "$hook_calls" -name '*.args' | wc -l; }
export -f hook_run hook_calls_count
export hook_calls hook_a hook_b hook_home hook_bin runtime workspace kit
assert_command 'Account hook: claude runs in the account the hook names' \
  bash -c 'hook_run current && [[ $(hook_calls_count) == 1 && $(cat "$1/1.config") == "$2" ]] && python3 "$3/providers/validate-result.py" "$3/RESULT.schema.json" worker "$4"' _ \
  "$hook_calls" "$hook_a" "$kit" "$runtime/hook-current-result.json"
assert_command 'Account hook: a usage limit retries once in the next account with the same arguments' \
  bash -c 'hook_run limit HOOK_LIMITED="$2" && [[ $(hook_calls_count) == 2 && $(cat "$1/1.config") == "$2" && $(cat "$1/2.config") == "$3" ]] && cmp -s "$1/1.args" "$1/2.args" && grep -q "hit your weekly limit" "$1/limit-.claude-a.txt" && python3 "$4/providers/validate-result.py" "$4/RESULT.schema.json" worker "$5"' _ \
  "$hook_calls" "$hook_a" "$hook_b" "$kit" "$runtime/hook-limit-result.json"
assert_command 'Account hook: the retry event names both accounts and only the retry hears about the cut-off work' \
  bash -c 'jq -e -s "any(.[]; .state == \"account\" and (.message | test(\"account claude-a hit its usage limit; retrying once in account claude-b two\")))" "$1" >/dev/null && ! grep -q "cut off by a provider usage limit" "$2/1.prompt" && grep -q "cut off by a provider usage limit" "$2/2.prompt"' _ \
  "$runtime/hook-limit-events.jsonl" "$hook_calls"
assert_command 'Account hook: exit 75 (no account left) fails the role as before' \
  bash -c 'hook_run none HOOK_LIMITED="$2" HOOK_NONE_LEFT=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 && ! -e $3 ]] && grep -q "hit your weekly limit" "$4" && jq -e -s "any(.[]; .state == \"account\" and (.message | test(\"no other account\")))" "$5" >/dev/null' _ \
  "$hook_calls" "$hook_a" "$runtime/hook-none-result.json" "$runtime/hook-none-stderr" "$runtime/hook-none-events.jsonl"
assert_command 'Account hook: a second usage limit is reported to the hook but not retried' \
  bash -c 'hook_run all HOOK_LIMIT_ALL=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 2 && $(grep -c "^account limit" "$1/hook.log") == 2 ]]' _ "$hook_calls"
assert_command 'Account hook: a failure that is not a usage limit is not retried' \
  bash -c 'hook_run other HOOK_OTHER_ERROR=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 ]] && grep -q "overloaded" "$2"' _ \
  "$hook_calls" "$runtime/hook-other-stderr"
assert_command 'Account hook disabled: claude keeps the caller account and a limit is not retried' \
  bash -c 'hook_run off HOOK_ENABLED=0 HOOK_LIMIT_ALL=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 && $(cat "$1/1.config") == UNSET ]] && ! grep -q "^account limit" "$1/hook.log"' _ "$hook_calls"
assert_command 'Account hook missing: claude runs as today' \
  bash -c 'hook_run missing AGENTIC_CLAUDE_ACCOUNTS=no-such-hook && [[ $(hook_calls_count) == 1 && $(cat "$1/1.config") == UNSET ]] && grep -q "account hook no-such-hook not found" "$2"' _ \
  "$hook_calls" "$runtime/hook-missing-stderr"

printf '#!/usr/bin/env bash\nexit 9\n' > "$mock_bin/claude"
chmod +x "$mock_bin/claude"
assert_command 'Failed provider leaves no canonical result or raw secret output' \
  bash -c 'result=$1; events=$2; rm -f "$result" "$events"; ! PATH="$3:/usr/bin:/bin" "$4" worker "$5" "$6" "$result" "$events" >/dev/null 2>&1 && [[ ! -e $result ]]' _ \
  "$runtime/failed-result.json" "$runtime/failed-events.jsonl" "$mock_bin" \
  "$kit/providers/claude/run.sh" "$workspace" "$runtime/prompt.md"

assert_command 'Unavailable provider fails clearly with structured event' \
  bash -c 'result=$1; events=$2; rm -f "$result" "$events"; PATH="$3" "$4" worker "$5" "$6" "$result" "$events" >/dev/null 2>&1; code=$?; [[ $code -eq 69 ]] && jq -e -s '\''length == 1 and .[0].state == "unavailable" and .[0].message == "provider unavailable"'\'' "$events" >/dev/null' _ \
  "$runtime/unavailable-result.json" "$runtime/unavailable-events.jsonl" "$unavailable_bin" \
  "$kit/providers/claude/run.sh" "$workspace" "$runtime/prompt.md"

# --ready reads the sign-in state without a model turn: 0 signed in, 77 not signed in, 69 missing.
ready_bin="$test_root/ready-bin"
mkdir -p "$ready_bin/in" "$ready_bin/out"
cat >"$ready_bin/in/claude" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "--version" ]] && exit 0
[[ "$*" == "auth status --json" ]] && printf '{"loggedIn":true,"authMethod":"claude.ai"}\n'
EOF
cat >"$ready_bin/out/claude" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "--version" ]] && exit 0
[[ "$*" == "auth status --json" ]] && { printf '{"loggedIn":false}\n'; exit 1; }
EOF
# A wrapper of the system with no installation behind it, for this user.
mkdir -p "$ready_bin/wrapper"
printf '#!/usr/bin/env bash\necho "not installed for this user" >&2\nexit 1\n' >"$ready_bin/wrapper/claude"
printf '#!/usr/bin/env bash\n[[ "$*" == "login status" || "$*" == --version ]]\n' >"$ready_bin/in/codex"
printf '#!/usr/bin/env bash\n[[ "$*" == --version ]]\n' >"$ready_bin/out/codex"
chmod +x "$ready_bin"/in/* "$ready_bin"/out/* "$ready_bin"/wrapper/*
ready_status() { local status=0; env PATH="$1:/usr/bin:/bin" "$kit/providers/$2/run.sh" --ready >/dev/null 2>&1 || status=$?; [[ $status == "$3" ]]; }
assert_command 'Claude is ready when signed in' ready_status "$ready_bin/in" claude 0
assert_command 'Claude is not ready when not signed in' ready_status "$ready_bin/out" claude 77
assert_command 'Claude is unavailable when missing' ready_status "$unavailable_bin" claude 69
assert_command 'Claude is unavailable behind a wrapper with nothing installed' ready_status "$ready_bin/wrapper" claude 69
assert_command 'Codex is ready when signed in' ready_status "$ready_bin/in" codex 0
assert_command 'Codex is not ready when not signed in' ready_status "$ready_bin/out" codex 77

printf '1..%s\n' "$((passed + failed))"
if (( failed != 0 )); then
  exit 1
fi

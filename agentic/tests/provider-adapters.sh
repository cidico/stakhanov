#!/usr/bin/env bash

set -euo pipefail

kit=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
fake_host=''
trap '[[ -z $fake_host ]] || kill "$fake_host" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

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
  printf '%s\n' '--print --output-format --json-schema --no-session-persistence --permission-mode bypassPermissions --permission-prompts --effort --settings --setting-sources --disallowedTools'
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
  bash -c '! grep -qxE -- "--(continue|resume)" "$1" && grep -qxE -- "--no-session-persistence" "$1" && grep -qxE "bypassPermissions" "$1"' _ "$runtime/claude-worker-args"
assert_command 'Claude preflight accepts unattended non-interrupting mode' \
  env PATH="$mock_bin:/usr/bin:/bin" "$kit/providers/claude/run.sh" --preflight unattended
assert_command 'Claude reviewer is read-only' \
  run_adapter claude reviewer "$runtime/reviewer.json"
assert_command 'Claude diagnostician returns validated JSON' \
  run_adapter claude diagnostician "$runtime/diagnostician.json"
claude_setting() { python3 -c 'import sys; a=open(sys.argv[1]).read().splitlines(); print(a[a.index(sys.argv[2])+1])' "$1" "$2"; }
export -f claude_setting
for role in worker reviewer diagnostician; do
  assert_command "Claude $role loads no user settings, and its only hook is the role guard of this kit, for the role" \
    bash -c 'args=$1; role=$2; kit=$3
      [[ $(claude_setting "$args" --setting-sources) == project,local ]] || exit 1
      grep -qF "disableAllHooks" "$args" && exit 1
      settings=$(claude_setting "$args" --settings)
      jq -e --arg command "$kit/bin/role-guard $role" "
        . == {hooks: {PreToolUse: [{matcher: \"Bash\", hooks: [{type: \"command\", command: \$command}]}]}}" <<<"$settings" >/dev/null
      [[ -x $kit/bin/role-guard ]]' _ "$runtime/claude-$role-args" "$role" "$kit"
done
claude_denied() { python3 -c 'import sys; a=open(sys.argv[1]).read().splitlines(); print(a[a.index("--disallowedTools")+1] if "--disallowedTools" in a else "")' "$1"; }
export -f claude_denied
for role in reviewer diagnostician; do
  assert_command "Claude $role does not use plan mode (it makes the CLI call a second model)" \
    bash -c '! grep -qxE -- "plan" "$1" && grep -qxE -- "bypassPermissions" "$1"' _ "$runtime/claude-$role-args"
  assert_command "Claude $role cannot write: the write tools are disallowed, Bash is not" \
    bash -c 'denied=$(claude_denied "$1"); for tool in Edit Write NotebookEdit; do [[ ,$denied, == *",$tool,"* ]] || exit 1; done; [[ ,$denied, != *,Bash*,* ]]' _ "$runtime/claude-$role-args"
done
assert_command 'Claude worker keeps the write tools' \
  bash -c '! grep -qxE -- "--disallowedTools" "$1" && grep -qxE "bypassPermissions" "$1"' _ "$runtime/claude-worker-args"
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
  fix:"Include the shipping cost in the refunded amount and test a full refund.",
  guard:{kind:"test", how:"a unit test that refunds an order with shipping and asserts the whole total comes back"}}]' \
  "$runtime/reviewer.json" > "$runtime/fix-justified.json"
assert_command 'Reviewer FIX with defect, reason, fix and guard is accepted' \
  python3 "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" reviewer "$runtime/fix-justified.json"

jq 'del(.findings[0].guard)' "$runtime/fix-justified.json" > "$runtime/fix-without-guard.json"
assert_command 'Reviewer FIX with a finding without a guard is rejected, and the error asks for the guard' \
  bash -c '! out=$(python3 "$1" "$2" reviewer "$3" 2>&1) && grep -q "finding is missing its guard" <<<"$out"' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/fix-without-guard.json"

jq '.status = "PASS" | .findings[0].severity = "minor" | del(.findings[0].guard)' "$runtime/fix-justified.json" > "$runtime/pass-note-without-guard.json"
assert_command 'A note on PASS needs its guard too' \
  bash -c '! python3 "$1" "$2" reviewer "$3" >/dev/null 2>&1' _ \
  "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/pass-note-without-guard.json"

for guard in '{"kind":"typo","how":"a unit test that refunds an order with shipping"}' \
             '{"kind":["test"],"how":"a unit test that refunds an order with shipping"}' \
             '{"kind":"test","how":["a unit test that refunds an order with shipping"]}' \
             '{"kind":"test"}' \
             '{"kind":"test","how":"a unit test that refunds an order with shipping","extra":1}' \
             '{"kind":"test","how":"line one\nline two of the test"}' \
             '{"kind":"lint","how":"lint"}' \
             '"test"'; do
  jq --argjson guard "$guard" '.findings[0].guard = $guard' "$runtime/fix-justified.json" > "$runtime/fix-bad-guard.json"
  assert_command "Reviewer finding with the guard $guard is rejected" \
    bash -c '! python3 "$1" "$2" reviewer "$3" >/dev/null 2>&1' _ \
    "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" "$runtime/fix-bad-guard.json"
done

for kind in analyzer lint test validate executor reviewer-only; do
  jq --arg kind "$kind" '.findings[0].guard = {kind: $kind, how: "the rule, test or command and what it asserts"}' \
    "$runtime/fix-justified.json" > "$runtime/fix-guard-kind.json"
  assert_command "Reviewer finding with the guard kind $kind is accepted" \
    python3 "$kit/providers/validate-result.py" "$kit/RESULT.schema.json" reviewer "$runtime/fix-guard-kind.json"
done

assert_command 'The schema requires a guard of every finding, and only the six kinds' \
  python3 - "$kit/RESULT.schema.json" <<'PYGUARD'
import json, sys
finding = json.load(open(sys.argv[1]))["properties"]["findings"]["items"]
assert "guard" in finding["required"] and set(finding["properties"]) == set(finding["required"])
guard = finding["properties"]["guard"]
assert guard["additionalProperties"] is False and guard["required"] == ["kind", "how"]
assert guard["properties"]["kind"]["enum"] == ["analyzer", "lint", "test", "validate", "executor", "reviewer-only"]
PYGUARD

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
  printf '{"type":"result","subtype":"success","is_error":true,"result":"API Error: invalid request"}\n'
  exit 1
fi
# The first HOOK_TRANSIENT_FAILS processes fail with an API error: status HOOK_TRANSIENT_STATUS and text HOOK_TRANSIENT_TEXT.
if (( number <= ${HOOK_TRANSIENT_FAILS:-0} )); then
  jq -cn --argjson status "${HOOK_TRANSIENT_STATUS:-529}" --arg text "${HOOK_TRANSIENT_TEXT:-API Error: Overloaded}" \
    '{type:"result",subtype:"success",is_error:true,api_error_status:$status,result:$text,total_cost_usd:0.1,usage:{input_tokens:10,output_tokens:1}}'
  exit 1
fi
if [[ ${HOOK_LIMIT_ALL:-} == 1 || ${CLAUDE_CONFIG_DIR-} == "${HOOK_LIMITED:-none}" ]]; then
  if [[ ${HOOK_USAGE:-} == 1 ]]; then
    printf '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your weekly limit","total_cost_usd":0.5,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0},"num_turns":2,"duration_ms":2000}\n'
  else
    printf '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your weekly limit"}\n'
  fi
  exit 1
fi
if [[ ${HOOK_USAGE:-} == 1 ]]; then
  jq -cn --slurpfile result "$MOCK_RESULT" '{type:"result",subtype:"success",structured_output:$result[0],total_cost_usd:0.25,usage:{input_tokens:50,output_tokens:5,cache_read_input_tokens:500,cache_creation_input_tokens:20},num_turns:1,duration_ms:1000}'
else
  jq -cn --slurpfile result "$MOCK_RESULT" '{type:"result",subtype:"success",structured_output:$result[0]}'
fi
MOCK
cat > "$hook_bin/accounts" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HOOK_CALLS/hook.log"
# An older hook does not know --kind and answers 2 (usage).
[[ ${HOOK_OLD_KIND:-} != 1 || " $* " != *" --kind "* ]] || exit 2
# An older hook does not know --at either: it answers 2 while --at is present.
[[ ${HOOK_OLD_AT:-} != 1 || " $* " != *" --at "* ]] || exit 2
case "$1 $2" in
  'account enabled') [[ ${HOOK_ENABLED:-1} == 1 ]] ;;
  'account current') printf '%s\n' "$HOOK_A" ;;
  'account next') printf '%s\n' "${HOOK_NEXT:-1900000000}" ;;
  # HOOK_CLEAR_STATUS: the status of `clear` (2 is an older hook that does not know it); HOOK_CLEAR_SLEEP: seconds it takes.
  'account clear')
    [[ -z ${HOOK_CLEAR_SLEEP:-} ]] || exec sleep "$HOOK_CLEAR_SLEEP"
    exit "${HOOK_CLEAR_STATUS:-0}" ;;
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
# clear_lines prints the `account clear` lines of the hook log; clear_at <line> prints the --at value of one of them.
clear_lines() { grep '^account clear ' "$hook_calls/hook.log" || true; }
clear_at() { local rest=${1#account clear --at }; printf '%s\n' "${rest%% *}"; }
export -f hook_run hook_calls_count clear_lines clear_at
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
assert_command 'Account hook: no account left exits 75 and says when the first account is back' \
  bash -c 'hook_run none HOOK_LIMITED="$2" HOOK_NONE_LEFT=1 HOOK_NEXT=1900000123; code=$?; [[ $code == 75 && $(hook_calls_count) == 1 && ! -e $3 ]] && grep -q "hit your weekly limit" "$4" && grep -q "accounts-back-at=1900000123" "$4" && jq -e -s "any(.[]; .state == \"account\" and (.message | test(\"no other account\")))" "$5" >/dev/null' _ \
  "$hook_calls" "$hook_a" "$runtime/hook-none-result.json" "$runtime/hook-none-stderr" "$runtime/hook-none-events.jsonl"
assert_command 'Account hook: a second usage limit is reported to the hook, not retried, and exits 75 when no account is left' \
  bash -c 'hook_run all HOOK_LIMIT_ALL=1; code=$?; [[ $code == 75 && $(hook_calls_count) == 2 && $(grep -c "^account limit" "$1/hook.log") == 2 ]] && grep -q "accounts-back-at=1900000000" "$2"' _ "$hook_calls" "$runtime/hook-all-stderr"
assert_command 'Account hook: a failure that is not a usage limit is not retried' \
  bash -c 'hook_run other HOOK_OTHER_ERROR=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 ]] && grep -q "invalid request" "$2"' _ \
  "$hook_calls" "$runtime/hook-other-stderr"
assert_command 'Account hook disabled: claude keeps the caller account and a limit is not retried' \
  bash -c 'hook_run off HOOK_ENABLED=0 HOOK_LIMIT_ALL=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 && $(cat "$1/1.config") == UNSET ]] && ! grep -q "^account limit" "$1/hook.log"' _ "$hook_calls"
assert_command 'Account hook missing: claude runs as today' \
  bash -c 'hook_run missing AGENTIC_CLAUDE_ACCOUNTS=no-such-hook && [[ $(hook_calls_count) == 1 && $(cat "$1/1.config") == UNSET ]] && grep -q "account hook no-such-hook not found" "$2"' _ \
  "$hook_calls" "$runtime/hook-missing-stderr"

assert_command 'Account hook: the usage of both attempts is summed in the usage file and the completed event' \
  bash -c 'hook_run usage HOOK_USAGE=1 HOOK_LIMITED="$1" && jq -e ". == {provider:\"claude\",model:null,cost_usd:0.75,input_tokens:150,output_tokens:15,cache_read_tokens:1500,cache_creation_tokens:20,num_turns:3,duration_ms:3000}" "$2.usage.json" >/dev/null && jq -e -s ".[-1] | .state == \"completed\" and .attempts == 2 and .usage.cost_usd == 0.75 and .usage.num_turns == 3" "$3" >/dev/null' _ \
  "$hook_a" "$runtime/hook-usage-result.json" "$runtime/hook-usage-events.jsonl"
assert_command 'Account hook: two usage limits leave no result and the failed event carries both attempts' \
  bash -c 'hook_run usagefail HOOK_USAGE=1 HOOK_LIMIT_ALL=1; code=$?; [[ $code == 75 && ! -e $1 && ! -e $1.usage.json ]] && jq -e -s ".[-1] | .state == \"failed\" and .attempts == 2 and .usage.cost_usd == 1 and .usage.input_tokens == 200" "$2" >/dev/null' _ \
  "$runtime/hook-usagefail-result.json" "$runtime/hook-usagefail-events.jsonl"

# A call that worked clears its account: `account clear ACCOUNT --kind worker`, after the result is validated, and never a failure.
assert_command 'Clear: a success calls clear with --at (the end of the call, between the start and the end of the test), the account used and --kind worker' \
  bash -c 'before=$(date +%s); hook_run clear; status=$?; after=$(date +%s); line=$(clear_lines); at=$(clear_at "$line")
    [[ $status == 0 && $(clear_lines | wc -l) == 1 && $at =~ ^[0-9]+$ ]] && (( at >= before && at <= after )) && [[ $line == "account clear --at $at $2 --kind worker" && ! -s $3 ]]' _ \
  "$hook_calls" "$hook_a" "$runtime/hook-clear-stderr"
assert_command 'Clear: after an account switch, clear goes to the new account only' \
  bash -c 'hook_run clearswitch HOOK_LIMITED="$2" && [[ $(hook_calls_count) == 2 && $(clear_lines | wc -l) == 1 ]] && line=$(clear_lines) && [[ $line == "account clear --at $(clear_at "$line") $3 --kind worker" ]]' _ \
  "$hook_calls" "$hook_a" "$hook_b"
assert_command 'Clear: a hook that refuses --at (answers 2 while it is present) gets the call without it, and nothing fails' \
  bash -c 'hook_run clearoldat HOOK_OLD_AT=1 && [[ $(clear_lines | wc -l) == 3 && $(clear_lines | tail -n 1) == "account clear $2" ]] && python3 "$3/providers/validate-result.py" "$3/RESULT.schema.json" worker "$4" && [[ ! -s $5 ]]' _ \
  "$hook_calls" "$hook_a" "$kit" "$runtime/hook-clearoldat-result.json" "$runtime/hook-clearoldat-stderr"
assert_command 'Clear: a hook that refuses only --kind gets --at without --kind' \
  bash -c 'hook_run clearoldkind HOOK_OLD_KIND=1 && [[ $(clear_lines | wc -l) == 2 ]] && line=$(clear_lines | tail -n 1) && [[ $line == "account clear --at $(clear_at "$line") $2" && $(clear_at "$line") =~ ^[0-9]+$ && ! -s $3 ]]' _ \
  "$hook_calls" "$hook_a" "$runtime/hook-clearoldkind-stderr"
assert_command 'Clear: a failed call does not clear (other error, usage limit in every account, invalid result)' \
  bash -c 'hook_run clearerr HOOK_OTHER_ERROR=1; [[ $? == 1 && ! -e $2 ]] && ! grep -q "^account clear" "$1/hook.log"
    hook_run clearall HOOK_LIMIT_ALL=1; [[ $? == 75 ]] && ! grep -q "^account clear" "$1/hook.log"
    echo "{}" > "$3"; hook_run clearbad MOCK_RESULT="$3"; [[ $? == 65 && ! -e $4 ]] && ! grep -q "^account clear" "$1/hook.log"' _ \
  "$hook_calls" "$runtime/hook-clearerr-result.json" "$runtime/hook-invalid.json" "$runtime/hook-clearbad-result.json"
assert_command 'Clear: a hook that answers 2 to clear changes neither the result nor the exit code, only a line on stderr' \
  bash -c 'hook_run clear2 HOOK_CLEAR_STATUS=2 && [[ $(grep -c "^account clear " "$1/hook.log") == 3 ]] && grep -qxF "account clear $2" "$1/hook.log" && python3 "$3/providers/validate-result.py" "$3/RESULT.schema.json" worker "$4" && jq -e -s ".[-1].state == \"completed\"" "$5" >/dev/null && [[ $(wc -l < "$6") == 1 ]] && grep -q "could not clear account claude-a (status 2)" "$6"' _ \
  "$hook_calls" "$hook_a" "$kit" "$runtime/hook-clear2-result.json" "$runtime/hook-clear2-events.jsonl" "$runtime/hook-clear2-stderr"
assert_command 'Clear: a hook that fails with another status changes neither the result nor the exit code' \
  bash -c 'hook_run clear1 HOOK_CLEAR_STATUS=1 && python3 "$1/providers/validate-result.py" "$1/RESULT.schema.json" worker "$2" && grep -q "(status 1)" "$3"' _ \
  "$kit" "$runtime/hook-clear1-result.json" "$runtime/hook-clear1-stderr"
assert_command 'Clear: a hook slower than the deadline does not hold the call' \
  bash -c 'start=$SECONDS; hook_run clearslow HOOK_CLEAR_SLEEP=30 AGENTIC_CLAUDE_ACCOUNT_CLEAR_SECONDS=1 && (( SECONDS - start <= 8 )) && python3 "$1/providers/validate-result.py" "$1/RESULT.schema.json" worker "$2" && grep -q "(status 124)" "$3"' _ \
  "$kit" "$runtime/hook-clearslow-result.json" "$runtime/hook-clearslow-stderr"
assert_command 'Clear: a hook that is gone by then (status 127) is a line on stderr and the call still succeeds' \
  bash -c 'hook_run cleargone HOOK_CLEAR_STATUS=127 && python3 "$1/providers/validate-result.py" "$1/RESULT.schema.json" worker "$2" && grep -q "(status 127)" "$3"' _ \
  "$kit" "$runtime/hook-cleargone-result.json" "$runtime/hook-cleargone-stderr"

# Transient API errors (429 that is not the usage limit, 5xx, overloaded) back off and retry inside the adapter. The waits are
# shortened to 1 s, 2 s, 4 s (plus the random delay) through AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS.
assert_command 'Transient: a 529 twice and then success is one call with three attempts, each retry recorded' \
  bash -c 'hook_run t529 HOOK_TRANSIENT_FAILS=2 AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1 && [[ $(hook_calls_count) == 3 ]] && python3 "$1/providers/validate-result.py" "$1/RESULT.schema.json" worker "$2" && jq -e -s "([.[] | select(.state == \"transient\")] | length == 2 and all(.[]; .message | test(\"status 529\\\\); waiting [0-9]+s before retry\"))) and (.[-1] | .state == \"completed\" and .attempts == 3 and .usage.cost_usd == 0.2 and .usage.input_tokens == 20)" "$3" >/dev/null && jq -e ".cost_usd == 0.2" "$2.usage.json" >/dev/null' _ \
  "$kit" "$runtime/hook-t529-result.json" "$runtime/hook-t529-events.jsonl"
assert_command 'Transient: the retry keeps the account and the prompt, and the hook is asked, as a worker, why each process failed' \
  bash -c 'cmp -s "$1/1.args" "$1/3.args" && cmp -s "$1/1.prompt" "$1/3.prompt" && [[ $(cat "$1/3.config") == "$2" ]] && [[ $(grep -c "^account limit .* --kind worker$" "$1/hook.log") == 2 && $(grep -c "^account current --kind worker$" "$1/hook.log") == 1 ]]' _ "$hook_calls" "$hook_a"
assert_command 'Transient: a 429 that keeps coming exhausts the retries and exits with the claude status' \
  bash -c 'hook_run t429 HOOK_TRANSIENT_FAILS=99 HOOK_TRANSIENT_STATUS=429 "HOOK_TRANSIENT_TEXT=API Error: rate limit exceeded" AGENTIC_PROVIDER_TRANSIENT_RETRIES=2 AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 3 && ! -e $1 ]] && grep -q "rate limit exceeded" "$2" && jq -e -s "([.[] | select(.state == \"transient\")] | length == 2) and (.[-1] | .state == \"failed\" and .attempts == 3 and .usage.cost_usd == 0.3)" "$3" >/dev/null' _ \
  "$runtime/hook-t429-result.json" "$runtime/hook-t429-stderr" "$runtime/hook-t429-events.jsonl"
assert_command 'Transient: a status the list does not name, without a transient text, is not retried' \
  bash -c 'hook_run t400 HOOK_TRANSIENT_FAILS=99 HOOK_TRANSIENT_STATUS=400 "HOOK_TRANSIENT_TEXT=API Error: bad request" AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 ]] && ! grep -q transient "$1"' _ "$runtime/hook-t400-events.jsonl"
assert_command 'Transient: AGENTIC_PROVIDER_TRANSIENT_RETRIES=0 turns the backoff off' \
  bash -c 'hook_run t0 HOOK_TRANSIENT_FAILS=99 AGENTIC_PROVIDER_TRANSIENT_RETRIES=0; code=$?; [[ $code == 1 && $(hook_calls_count) == 1 ]] && ! grep -q transient "$1"' _ "$runtime/hook-t0-events.jsonl"
assert_command 'Transient: a usage limit with 429 text goes to the hook and never to the backoff (no account left: exit 75)' \
  bash -c 'hook_run u429 HOOK_TRANSIENT_FAILS=99 HOOK_TRANSIENT_STATUS=429 "HOOK_TRANSIENT_TEXT=API Error: 429 You have hit your weekly limit" HOOK_NONE_LEFT=1 AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1; code=$?; [[ $code == 75 && $(hook_calls_count) == 1 && $(grep -c "^account limit" "$1/hook.log") == 1 ]] && grep -q "accounts-back-at=" "$2" && ! grep -q transient "$3"' _ \
  "$hook_calls" "$runtime/hook-u429-stderr" "$runtime/hook-u429-events.jsonl"
assert_command 'Transient: a usage limit with 429 text switches account, as before, with no backoff' \
  bash -c 'hook_run u429b HOOK_TRANSIENT_FAILS=1 HOOK_TRANSIENT_STATUS=429 "HOOK_TRANSIENT_TEXT=API Error: 429 You have hit your weekly limit" AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1 && [[ $(hook_calls_count) == 2 && $(cat "$1/2.config") == "$2" ]] && ! grep -q transient "$3" && jq -e -s "any(.[]; .state == \"account\")" "$3" >/dev/null' _ \
  "$hook_calls" "$hook_b" "$runtime/hook-u429b-events.jsonl"
assert_command 'Transient: after the backoff a usage limit still goes to the hook and switches account' \
  bash -c 'hook_run tthenu HOOK_TRANSIENT_FAILS=1 HOOK_LIMITED="$1" AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1 && [[ $(hook_calls_count) == 3 && $(cat "$2/3.config") == "$3" ]] && jq -e -s "([.[] | select(.state == \"transient\")] | length == 1) and any(.[]; .state == \"account\") and (.[-1] | .state == \"completed\" and .attempts == 3)" "$4" >/dev/null' _ \
  "$hook_a" "$hook_calls" "$hook_b" "$runtime/hook-tthenu-events.jsonl"
assert_command 'Transient: a hook that does not know --kind gets the call again without it and works as before' \
  bash -c 'hook_run oldkind HOOK_OLD_KIND=1 HOOK_LIMITED="$2" && [[ $(hook_calls_count) == 2 && $(cat "$1/2.config") == "$3" ]] && grep -qx "account current --kind worker" "$1/hook.log" && grep -qx "account current" "$1/hook.log" && grep -q "^account limit .*-a$" "$1/hook.log"' _ \
  "$hook_calls" "$hook_a" "$hook_b"
assert_command 'Transient: a stop request (TERM) ends the wait at once' \
  bash -c 'rm -rf "$1" && mkdir -p "$1"; events=$2; rm -f "$events"
    env -u CLAUDE_CONFIG_DIR HOME="$3" PATH="$4:/usr/bin:/bin" AGENTIC_CLAUDE_ACCOUNTS=accounts HOOK_CALLS="$1" HOOK_A="$5" HOOK_B="$6" \
      MOCK_RESULT="$7/worker.json" HOOK_TRANSIENT_FAILS=99 AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=60 \
      "$8/providers/claude/run.sh" worker "$9" "$7/prompt.md" "$7/hook-term-result.json" "$events" 2>/dev/null &
    pid=$!
    for _ in $(seq 100); do grep -qs "\"state\":\"transient\"" "$events" && break; sleep 0.1; done
    grep -q "\"state\":\"transient\"" "$events" || { kill "$pid"; exit 1; }
    start=$SECONDS; kill -TERM "$pid"; wait "$pid"; code=$?
    (( code == 143 && SECONDS - start <= 2 )) && jq -e -s ".[-1] | .state == \"failed\" and (.message | test(\"stop requested\"))" "$events" >/dev/null && [[ ! -e $7/hook-term-result.json ]]' _ \
  "$hook_calls" "$runtime/hook-term-events.jsonl" "$hook_home" "$hook_bin" "$hook_a" "$hook_b" "$runtime" "$kit" "$workspace"

# Provider usage: what a call cost goes beside the result and into the completed/failed event, and never fails a call.
usage_bin="$test_root/usage-bin"
mkdir -p "$usage_bin"
cat > "$usage_bin/claude" <<'MOCK'
#!/usr/bin/env bash
[[ " $* " != *" --help "* ]] || exit 0
cat > /dev/null
cat -- "$MOCK_ENVELOPE"
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$usage_bin/claude"
usage_run() { # <name> <envelope file> [exit status]: a claude worker; leaves usage-<name>-{result.json,events.jsonl,stderr}
  local name=$1
  rm -f "$runtime/usage-$name-"*
  PATH="$usage_bin:/usr/bin:/bin" MOCK_ENVELOPE=$2 MOCK_EXIT=${3:-0} \
    "$kit/providers/claude/run.sh" worker "$workspace" "$runtime/prompt.md" \
    "$runtime/usage-$name-result.json" "$runtime/usage-$name-events.jsonl" 2> "$runtime/usage-$name-stderr"
}
export -f usage_run
export usage_bin
jq -cn --slurpfile result "$runtime/worker.json" '{type:"result",subtype:"success",structured_output:$result[0],
  total_cost_usd:0.1234,usage:{input_tokens:10,output_tokens:20,cache_read_input_tokens:300,cache_creation_input_tokens:40},
  num_turns:3,duration_ms:4567,modelUsage:{"claude-opus-test":{costUSD:0.1234}}}' > "$runtime/envelope-full.json"
jq -cn --slurpfile result "$runtime/worker.json" '{type:"result",subtype:"success",structured_output:$result[0]}' > "$runtime/envelope-bare.json"
jq -cn --slurpfile result "$runtime/worker.json" '{type:"result",subtype:"success",structured_output:$result[0],
  total_cost_usd:"abc",usage:"oops",num_turns:-1,duration_ms:1.5,modelUsage:{a:{},b:{}}}' > "$runtime/envelope-odd.json"
usage_null='{provider:"claude",model:null,cost_usd:null,input_tokens:null,output_tokens:null,cache_read_tokens:null,cache_creation_tokens:null,num_turns:null,duration_ms:null}'
assert_command 'Usage: an envelope with full usage is recorded in the usage file and the completed event' \
  bash -c 'usage_run full "$1" && jq -e ". == {provider:\"claude\",model:\"claude-opus-test\",cost_usd:0.1234,input_tokens:10,output_tokens:20,cache_read_tokens:300,cache_creation_tokens:40,num_turns:3,duration_ms:4567}" "$2.usage.json" >/dev/null && jq -e -s --slurpfile file "$2.usage.json" ".[-1] | .state == \"completed\" and .attempts == 1 and .usage == \$file[0]" "$3" >/dev/null' _ \
  "$runtime/envelope-full.json" "$runtime/usage-full-result.json" "$runtime/usage-full-events.jsonl"
assert_command 'Usage: the result stays the canonical result, without usage' \
  bash -c 'python3 "$1/providers/validate-result.py" "$1/RESULT.schema.json" worker "$2" && jq -e "has(\"usage\") | not" "$2" >/dev/null && ! grep -q usage "$kit/RESULT.schema.json"' _ "$kit" "$runtime/usage-full-result.json"
assert_command 'Usage: an envelope without usage gives null fields, never invented ones' \
  bash -c 'usage_run bare "$1" && jq -e ". == $2" "$3.usage.json" >/dev/null && jq -e -s ".[-1] | .state == \"completed\" and .attempts == 1 and .usage == $2" "$4" >/dev/null' _ \
  "$runtime/envelope-bare.json" "$usage_null" "$runtime/usage-bare-result.json" "$runtime/usage-bare-events.jsonl"
assert_command 'Usage: odd values (strings, negatives, fractions, several models) are null, and the call still succeeds' \
  bash -c 'usage_run odd "$1" && jq -e ". == $2" "$3.usage.json" >/dev/null' _ \
  "$runtime/envelope-odd.json" "$usage_null" "$runtime/usage-odd-result.json"
printf 'not json at all\n' > "$runtime/envelope-garbage.txt"
assert_command 'Usage: a failed call with an unreadable envelope has usage null, a warning and its own exit status' \
  bash -c 'usage_run garbage "$1" 9; code=$?; [[ $code == 9 && ! -e $2 && ! -e $2.usage.json ]] && jq -e -s ".[-1] | .state == \"failed\" and .attempts == 1 and .usage == null" "$3" >/dev/null && grep -q "usage not recorded" "$4"' _ \
  "$runtime/envelope-garbage.txt" "$runtime/usage-garbage-result.json" "$runtime/usage-garbage-events.jsonl" "$runtime/usage-garbage-stderr"
jq -cn '{type:"result",subtype:"success",is_error:true,result:"API Error: invalid request",total_cost_usd:0.01,usage:{input_tokens:7,output_tokens:1},num_turns:1,duration_ms:300}' > "$runtime/envelope-error.json"
assert_command 'Usage: a failed call with an envelope reports its usage in the failed event' \
  bash -c 'usage_run error "$1" 1; code=$?; [[ $code == 1 && ! -e $2 ]] && jq -e -s ".[-1] | .state == \"failed\" and .usage.cost_usd == 0.01 and .usage.input_tokens == 7 and .usage.cache_read_tokens == null" "$3" >/dev/null' _ \
  "$runtime/envelope-error.json" "$runtime/usage-error-result.json" "$runtime/usage-error-events.jsonl"
jq -cn '{type:"result",subtype:"success",is_error:true,api_error_status:529,result:"Overloaded",total_cost_usd:0.01}' > "$runtime/envelope-overloaded.json"
assert_command 'Transient: without an account hook an overloaded envelope backs off too, then fails with the claude status' \
  bash -c 'AGENTIC_PROVIDER_TRANSIENT_RETRIES=1 AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1 usage_run overloaded "$1" 1; code=$?; [[ $code == 1 && ! -e $2 ]] && jq -e -s "([.[] | select(.state == \"transient\")] | length == 1) and (.[-1] | .state == \"failed\" and .attempts == 2)" "$3" >/dev/null' _ \
  "$runtime/envelope-overloaded.json" "$runtime/usage-overloaded-result.json" "$runtime/usage-overloaded-events.jsonl"
jq -cn '{type:"result",subtype:"success",is_error:true,api_error_status:429,result:"You have hit your weekly limit",total_cost_usd:0.01}' > "$runtime/envelope-limit429.json"
assert_command 'Transient: without an account hook a usage limit with status 429 is not retried' \
  bash -c 'AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS=1 usage_run limit429 "$1" 1; code=$?; [[ $code == 1 ]] && jq -e -s "length == 2 and (.[-1] | .state == \"failed\" and .attempts == 1)" "$2" >/dev/null' _ \
  "$runtime/envelope-limit429.json" "$runtime/usage-limit429-events.jsonl"
mkdir "$runtime/unwritable-result.json.usage.json"
assert_command 'Usage: a usage file that cannot be written is a warning, not a failed extraction' \
  bash -c 'python3 "$1" claude "$2" "$3" 2>"$4" && [[ -s $3 ]] && grep -q "usage not recorded" "$4"' _ \
  "$kit/providers/extract-result.py" "$runtime/envelope-full.json" "$runtime/unwritable-result.json" "$runtime/unwritable-stderr"
assert_command 'Usage: --usage-only never fails, even on garbage' \
  bash -c 'python3 "$1" --usage-only claude "$2" "$3" 2>"$4"; [[ $? == 0 && ! -e $3 ]] && grep -q "usage not recorded" "$4"' _ \
  "$kit/providers/extract-result.py" "$runtime/envelope-garbage.txt" "$runtime/usage-only-garbage.json" "$runtime/usage-only-stderr"

# Codex's last message and Grok's envelope carry no usage: the file and the event have the provider and nulls.
for provider in codex grok; do
  assert_command "Usage: $provider records its provider with every other field null" \
    bash -c 'jq -e ". == {provider:\"$1\",model:null,cost_usd:null,input_tokens:null,output_tokens:null,cache_read_tokens:null,cache_creation_tokens:null,num_turns:null,duration_ms:null}" "$2.usage.json" >/dev/null && jq -e -s ".[-1] | .state == \"completed\" and .attempts == 1 and .usage.provider == \"$1\" and (.usage | del(.provider) | all(.[]; . == null))" "$3" >/dev/null' _ \
    "$provider" "$runtime/$provider-worker-result.json" "$runtime/$provider-worker-events.jsonl"
done
assert_command 'Usage: a captured Grok 1.0.13 envelope gives a usage file of nulls' \
  bash -c 'jq -e ". == {provider:\"grok\",model:null,cost_usd:null,input_tokens:null,output_tokens:null,cache_read_tokens:null,cache_creation_tokens:null,num_turns:null,duration_ms:null}" "$1" >/dev/null' _ \
  "$runtime/grok-captured-result.json.usage.json"

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


# --- Claude session mode (AGENTIC_CLAUDE_MODE=session): no claude process runs. The queue, the host and the subagent's
# transcript are faked here; the adapter sees them as it would see the real ones.
session_dir="$test_root/session"
sleep 600 &
fake_host=$!
proc_start() { sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}'; }
session_reset() { rm -rf -- "$session_dir"; mkdir -p "$session_dir/hosts"; session_extra_env=(); }
session_register_host() {
  jq -cn --argjson pid "$fake_host" --arg start "$(proc_start "$fake_host")" \
    '{pid: $pid, start: $start, session_id: "sess-1", account: "/acct/.claude-a", cwd: "/", cgroup: "", machine: "test", since: 0}' \
    > "$session_dir/hosts/$fake_host.json"
}
# session_adapter ROLE: starts the adapter in the background (session_extra_env adds variables) and sets s_pid, s_result,
# s_events and s_log.
session_adapter() {
  s_result="$runtime/session-$1-result.json"; s_events="$runtime/session-$1-events.jsonl"; s_log="$runtime/session-$1.log"
  rm -f -- "$s_result" "$s_events" "$s_log" "$s_result.usage.json" "$runtime/session-claude-args"
  env -u AGENTIC_CLAUDE_ACCOUNTS -u AGENTIC_CLAUDE_REVIEWER_MODEL AGENTIC_SESSION_DIR="$session_dir" AGENTIC_CLAUDE_MODE=session \
    AGENTIC_SESSION_POLL_SECONDS=0.2 AGENTIC_TICKET=TST-001 AGENTIC_PROJECT=proj "${session_extra_env[@]}" \
    PATH="$mock_bin:/usr/bin:/bin" MOCK_ARGS="$runtime/session-claude-args" \
    "$kit/providers/claude/run.sh" "$1" "$workspace" "$runtime/prompt.md" "$s_result" "$s_events" >"$s_log" 2>&1 &
  s_pid=$!
}
# session_request: waits for the request folder of the adapter (s_req).
session_request() {
  local tries=0 folder
  while ((tries++ < 100)); do
    folder=$(find "$session_dir/requests" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1) || true
    if [[ -n $folder && -f $folder/request.json ]]; then s_req=$folder; return 0; fi
    sleep 0.1
  done
  return 1
}
# session_assign AGENT TRANSCRIPT [AT] [HOST_PID]: what `session-host claim` writes.
session_assign() {
  local host=${4:-$fake_host}
  jq -cn --argjson pid "$host" --arg start "$(proc_start "$host" 2>/dev/null || printf 1)" --arg agent "$1" --arg transcript "$2" \
    --argjson at "${3:-$(date +%s)}" \
    '{host_pid: $pid, host_start: $start, session_id: "sess-1", account: "/acct/.claude-a", agent_id: $agent, transcript: $transcript, at: $at}' \
    > "$s_req/.assigned.tmp" && mv -- "$s_req/.assigned.tmp" "$s_req/assigned"
}
# session_finish: waits (30 s at most) for the adapter to end; sets s_rc.
session_finish() {
  local tries=0
  while kill -0 "$s_pid" 2>/dev/null && ((tries++ < 300)); do sleep 0.1; done
  if kill -0 "$s_pid" 2>/dev/null; then kill -9 "$s_pid"; s_rc=137; else s_rc=0; wait "$s_pid" || s_rc=$?; fi
}
# session_until CONDITION...: waits (10 s at most) for a command to succeed.
session_until() {
  local tries=0
  while ((tries++ < 100)); do "$@" && return 0; sleep 0.1; done
  return 1
}
quiet() { "$@" >/dev/null; }
usage_line='"usage":{"input_tokens":3,"output_tokens":5,"cache_read_input_tokens":7,"cache_creation_input_tokens":11}'
transcript_pending="$test_root/transcript-pending.jsonl"
transcript_finished="$test_root/transcript-finished.jsonl"
transcript_limit="$test_root/transcript-limit.jsonl"
transcript_two="$test_root/transcript-two.jsonl"
printf '{"type":"assistant","uuid":"a1","timestamp":"2026-11-02T10:00:00.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-4-1","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}}],%s}}\n' "$usage_line" > "$transcript_pending"
printf '{"type":"assistant","uuid":"a2","timestamp":"2026-11-02T10:00:30.000Z","message":{"id":"m2","role":"assistant","model":"claude-opus-4-1","stop_reason":"end_turn","content":[{"type":"text","text":"done"}],%s}}\n' "$usage_line" > "$transcript_finished"
{
  cat "$transcript_finished"
  printf '%s\n' '{"type":"assistant","uuid":"lim1","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You'"'"'ve hit your 5-hour limit"}]}}'
} > "$transcript_limit"
cat > "$mock_bin/acct" <<'MOCK'
#!/usr/bin/env bash
# A fake account hook: acct account SUBCOMMAND [ARGUMENT] [--kind worker]
[[ ${1:-} == account ]] || exit 2
case ${2:-} in
  enabled) exit 0 ;;
  limit) cat > "$HOOK_LOG.input"; printf '%s\n' "$3" > "$HOOK_LOG.account"; [[ ${HOOK_LIMIT_STATUS:-75} != 0 ]] || printf '/acct/.claude-b\n'; exit "${HOOK_LIMIT_STATUS:-75}" ;;
  next) printf '1800000000\n' ;;
  clear) printf '%s\n' "$*" >> "$HOOK_LOG.clear" ;;
esac
MOCK
chmod +x "$mock_bin/acct"

check_request() { # ROLE MODEL READ_ONLY
  jq -e --arg role "$1" --arg model "$2" --argjson ro "$3" --arg tree "$workspace" \
    '.role == $role and .model == $model and .effort == "high" and .read_only == $ro and .worktree == $tree
     and .project == "proj" and .ticket == "TST-001" and .attempt == 1 and (.created | type == "number") and (.id | test("^[0-9a-f-]{36}$"))' \
    "$s_req/request.json" >/dev/null &&
    grep -q 'mock prompt' "$(jq -r .prompt "$s_req/request.json")" &&
    [[ $(jq -r .prompt "$s_req/request.json") == "$s_req/prompt.md" && $(jq -r .result "$s_req/request.json") == "$s_req/result.json" ]] &&
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["properties"]["role"]["enum"] == [sys.argv[2]]' "$(jq -r .schema "$s_req/request.json")" "$1"
}

# A worker: the request is filed, a host assigns it, the subagent writes result.json and done.
session_reset; session_register_host
session_adapter worker
assert_command 'Session worker files a request' session_request
assert_command 'Session request carries the role, model, effort, worktree, prompt copy, result path and role schema' check_request worker opus false
cat "$transcript_pending" "$transcript_finished" > "$transcript_two"
session_assign agent-1 "$transcript_two"
assert_command 'Session worker: the adapter notices the assignment' session_until grep -q '"state":"assigned"' "$s_events"
cp "$runtime/worker.json" "$s_req/result.json"; : > "$s_req/done"
session_finish
assert_command 'Session worker: a valid result ends the adapter with 0' test "$s_rc" -eq 0
assert_command 'Session worker: the result is copied to the engine result path and validates' \
  bash -c 'cmp -s "$1" "$2" && python3 "$3" "$4" worker "$1"' _ "$s_result" "$runtime/worker.json" "$kit/providers/validate-result.py" "$kit/RESULT.schema.json"
assert_command 'Session worker: the events tell the request, the assignment and the completion' \
  quiet jq -e -s 'map(.state) as $s | ($s | index("started") != null) and ($s | index("assigned") != null) and $s[-1] == "completed" and all(.[]; .type == "provider" and .provider == "claude")' "$s_events"
assert_command 'Session worker: the usage of the transcript is recorded, each message once' \
  quiet jq -e '.provider == "claude" and .model == "claude-opus-4-1" and .input_tokens == 6 and .output_tokens == 10 and .cache_read_tokens == 14 and .cache_creation_tokens == 22 and .num_turns == 2' "$s_result.usage.json"
assert_command 'Session worker: the request folder of a taken result is removed' test ! -e "$s_req"
assert_command 'Session mode never starts a claude process' test ! -e "$runtime/session-claude-args"

# A reviewer: read-only, its own model, the result must be for its role.
session_reset; session_register_host
session_extra_env=(AGENTIC_CLAUDE_REVIEWER_MODEL=claude-sonnet-5-5)
session_adapter reviewer
assert_command 'Session reviewer files a read-only request with its model' session_request
assert_command 'Session reviewer request is read-only and keeps the full model id' check_request reviewer claude-sonnet-5-5 true
session_assign agent-2 "$transcript_pending"
cp "$runtime/reviewer.json" "$s_req/result.json"; : > "$s_req/done"
session_finish
assert_command 'Session reviewer: a valid result ends the adapter with 0' test "$s_rc" -eq 0

# An invalid result fails the invocation with the contract line the engine re-invokes on.
session_reset; session_register_host
session_adapter worker
session_request
session_assign agent-3 "$transcript_pending"
cp "$runtime/reviewer.json" "$s_req/result.json"; : > "$s_req/done"
session_finish
assert_command 'Session invalid result: exit 1' test "$s_rc" -eq 1
assert_command 'Session invalid result: the log names the contract error' grep -q '^invalid provider result: role does not match invocation' "$s_log"
assert_command 'Session invalid result: no result is copied and the failure is an event' \
  bash -c '[[ ! -e $1 ]] && jq -e -s ".[-1].state == \"failed\"" "$2" >/dev/null' _ "$s_result" "$s_events"
assert_command 'Session invalid result: the request stays, marked finished, for diagnosis' test -e "$s_req/finished"
session_reset; session_register_host
session_adapter worker
session_request
session_assign agent-3b "$transcript_pending"
: > "$s_req/done"
session_finish
assert_command 'Session done without a result file: exit 1 with the contract line' \
  bash -c '[[ $1 -eq 1 ]] && grep -q "^invalid provider result: " "$2"' _ "$s_rc" "$s_log"

# No host, or a dead one: the adapter waits, never idle, and a stop request ends it at once.
session_reset
session_extra_env=(AGENTIC_SESSION_IDLE_SECONDS=1 AGENTIC_SESSION_SAMPLE_SECONDS=1)
session_adapter worker
session_request
sleep 2.5
assert_command 'Session without a host: the adapter keeps waiting, never idle' \
  bash -c 'kill -0 "$1" && [[ ! -e $2/cancel ]]' _ "$s_pid" "$s_req"
assert_command 'Session without a host: one event says it is waiting for a host session' \
  bash -c '[[ $(jq -s "[.[] | select(.message == \"waiting for a host session\")] | length" "$1") == 1 ]]' _ "$s_events"
kill -TERM "$s_pid"
session_finish
assert_command 'Session stop request: exit 143' test "$s_rc" -eq 143
assert_command 'Session stop request: cancel is written with the reason' \
  quiet jq -e '.reason == "stop requested"' "$s_req/cancel"
sleep 600 & dead_host=$!
dead_start=$(proc_start "$dead_host"); kill "$dead_host"; wait "$dead_host" 2>/dev/null || true
session_reset; session_register_host
session_extra_env=(AGENTIC_SESSION_IDLE_SECONDS=1 AGENTIC_SESSION_SAMPLE_SECONDS=1)
session_adapter worker
session_request
touch -d '2 hours ago' "$transcript_pending.old"; cp "$transcript_pending" "$transcript_pending.old"; touch -d '2 hours ago' "$transcript_pending.old"
jq -cn --argjson pid "$dead_host" --arg start "$dead_start" --arg t "$transcript_pending.old" \
  '{host_pid: $pid, host_start: $start, session_id: "sess-0", account: "/acct/.claude-a", agent_id: "dead", transcript: $t, at: (now - 7200 | floor)}' > "$s_req/assigned"
sleep 2.5
assert_command 'Session assigned host dead: the adapter keeps waiting and is not idle' \
  bash -c 'kill -0 "$1" && [[ ! -e $2/cancel ]] && [[ $(jq -s "[.[] | select(.message == \"waiting for a host session\")] | length" "$3") == 1 ]]' _ "$s_pid" "$s_req" "$s_events"
kill -TERM "$s_pid"
session_finish
assert_command 'Session assigned host dead: a stop request still ends it' test "$s_rc" -eq 143

# A usage limit: without a hook, and with a hook that has no other account, the adapter exits 75 with the time.
session_reset; session_register_host
session_adapter worker
session_request
session_assign agent-4 "$transcript_limit"
session_finish
assert_command 'Session usage limit without a hook: exit 75' test "$s_rc" -eq 75
assert_command 'Session usage limit without a hook: the log carries accounts-back-at=0' grep -q 'every account is out of quota; accounts-back-at=0$' "$s_log"
session_reset; session_register_host
export HOOK_LOG="$test_root/hook"
rm -f "$HOOK_LOG".*
session_extra_env=(AGENTIC_CLAUDE_ACCOUNTS=acct HOOK_LOG="$HOOK_LOG" HOOK_LIMIT_STATUS=75)
session_adapter worker
session_request
session_assign agent-5 "$transcript_limit"
session_finish
assert_command 'Session usage limit, no account left: exit 75 with the time the hook gives' \
  bash -c '[[ $1 -eq 75 ]] && grep -q "accounts-back-at=1800000000$" "$2"' _ "$s_rc" "$s_log"
assert_command 'Session usage limit: the hook gets the host account and the error text' \
  bash -c '[[ $(cat "$1.account") == /acct/.claude-a ]] && grep -q "hit your 5-hour limit" "$1.input"' _ "$HOOK_LOG"
session_reset; session_register_host
rm -f "$HOOK_LOG".*
session_extra_env=(AGENTIC_CLAUDE_ACCOUNTS=acct HOOK_LOG="$HOOK_LOG" HOOK_LIMIT_STATUS=0)
session_adapter worker
session_request
session_assign agent-6 "$transcript_limit"
assert_command 'Session usage limit, another account exists: the request goes back to the queue' \
  session_until bash -c '[[ ! -e $1/assigned && -e $1/limited ]]' _ "$s_req"
assert_command 'Session usage limit, another account exists: the limited account is recorded' \
  grep -qx '/acct/.claude-a' "$s_req/limited"
sleep 1
assert_command 'Session usage limit, another account exists: the adapter keeps waiting' kill -0 "$s_pid"
kill -TERM "$s_pid"
session_finish
assert_command 'Session usage limit, another account exists: a stop request ends it' test "$s_rc" -eq 143

# Idle: the transcript is old and nothing runs; the confirming sample finds nothing either.
session_reset; session_register_host
touch -d '2 hours ago' "$transcript_pending"
session_extra_env=(AGENTIC_SESSION_IDLE_SECONDS=1 AGENTIC_SESSION_SAMPLE_SECONDS=1 AGENTIC_SESSION_CANCEL_WAIT_SECONDS=20)
session_adapter worker
session_request
session_assign agent-7 "$transcript_pending" "$(($(date +%s) - 7200))"
assert_command 'Session idle: cancel is written with the reason idle' \
  session_until bash -c 'jq -e ".reason == \"idle\"" "$1/cancel" >/dev/null 2>&1' _ "$s_req"
assert_command 'Session idle: the adapter waits for the host to stop the agent' kill -0 "$s_pid"
: > "$s_req/cancelled"
session_finish
assert_command 'Session idle: exit 124 (the engine reads it as a provider timeout)' test "$s_rc" -eq 124
assert_command 'Session idle: the log says the subagent was idle' grep -q 'the subagent was idle for' "$s_log"
assert_command 'Session idle: the idle check was announced as an event' \
  quiet jq -e -s 'any(.[]; .state == "idle") and .[-1].state == "failed"' "$s_events"

# The subagent ended without writing its result.
session_reset; session_register_host
session_extra_env=(AGENTIC_SESSION_FINISH_GRACE_SECONDS=1)
session_adapter worker
session_request
session_assign agent-8 "$transcript_finished"
session_finish
assert_command 'Session subagent ended without a result: exit 1 with the contract line' \
  bash -c '[[ $1 -eq 1 ]] && grep -q "^invalid provider result: the subagent ended without writing its result$" "$2"' _ "$s_rc" "$s_log"

# Preflight: a live host is needed; print mode is untouched.
session_reset
session_preflight() { env -u AGENTIC_CLAUDE_MODE AGENTIC_SESSION_DIR="$session_dir" "$@" PATH="$unavailable_bin" "$(command -v bash)" "$kit/providers/claude/run.sh" --preflight unattended; }
session_preflight_status() {
  local status=0
  env AGENTIC_SESSION_DIR="$session_dir" AGENTIC_CLAUDE_MODE=session PATH="$mock_bin:/usr/bin:/bin" \
    "$kit/providers/claude/run.sh" --preflight unattended >"$runtime/preflight.out" 2>&1 || status=$?
  printf '%s\n' "$status"
}
assert_command 'Session preflight without a host: exit 69 and says how to open one' \
  bash -c '[[ $1 == 69 ]] && grep -q "no live campaign host session on this machine; open one with /campaign-host" "$2"' _ "$(session_preflight_status)" "$runtime/preflight.out"
session_register_host
assert_command 'Session preflight with a live host: exit 0, with no claude CLI flag to check' test "$(session_preflight_status)" = 0
dead_only="$test_root/dead-session"; mkdir -p "$dead_only/hosts"
jq -cn --argjson pid "$dead_host" --arg start "$dead_start" '{pid: $pid, start: $start}' > "$dead_only/hosts/$dead_host.json"
assert_command 'Session preflight with a dead host only: exit 69' \
  bash -c '! env AGENTIC_SESSION_DIR="$1" AGENTIC_CLAUDE_MODE=session "$2/providers/claude/run.sh" --preflight unattended >/dev/null 2>&1' _ "$dead_only" "$kit"
assert_command 'An invalid AGENTIC_CLAUDE_MODE is refused' \
  bash -c '[[ $(env AGENTIC_CLAUDE_MODE=other "$1/providers/claude/run.sh" --preflight unattended >/dev/null 2>&1; echo $?) == 64 ]]' _ "$kit"
print_bin="$test_root/print-bin"
mkdir -p "$print_bin"
cat > "$print_bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --help "* ]]; then
  printf '%s\n' '--print --output-format --json-schema --no-session-persistence --permission-mode bypassPermissions --permission-prompts --effort --settings --setting-sources --disallowedTools'
  exit 0
fi
printf '%s\n' "$@" > "$MOCK_ARGS"
cat >/dev/null
jq -cn --slurpfile result "$MOCK_RESULT" '{type:"result",subtype:"success",structured_output:$result[0]}'
MOCK
chmod +x "$print_bin/claude"
assert_command 'Print mode preflight does not need a host' \
  env -u AGENTIC_CLAUDE_MODE AGENTIC_SESSION_DIR="$test_root/no-such-queue" PATH="$print_bin:/usr/bin:/bin" "$kit/providers/claude/run.sh" --preflight unattended
assert_command 'Print mode still runs claude with --print when the session variables are set' \
  bash -c 'env -u AGENTIC_CLAUDE_MODE AGENTIC_SESSION_DIR="$6" PATH="$1:/usr/bin:/bin" MOCK_RESULT="$2" MOCK_ARGS="$3" "$4/providers/claude/run.sh" worker "$5" "$7" "$8" "$9" >/dev/null 2>&1 && grep -qxF -- --print "$3"' \
  _ "$print_bin" "$runtime/worker.json" "$runtime/print-mode-args" "$kit" "$workspace" "$session_dir" "$runtime/prompt.md" "$runtime/print-mode-result.json" "$runtime/print-mode-events.jsonl"

printf '1..%s\n' "$((passed + failed))"
if (( failed != 0 )); then
  exit 1
fi

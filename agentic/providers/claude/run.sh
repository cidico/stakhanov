#!/usr/bin/env bash

set -euo pipefail

adapter_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../common.sh
source "$adapter_dir/../common.sh"

if [[ ${1:-} == --preflight ]]; then
  [[ $# == 2 && ($2 == interactive || $2 == unattended) ]] || exit 64
  command -v claude >/dev/null 2>&1 || exit 69
  help=$(claude --help 2>&1) || exit 69
  for option in --print --output-format --json-schema --no-session-persistence --permission-mode --permission-prompts --effort --settings bypassPermissions; do
    grep -Fq -- "$option" <<<"$help" || { printf 'claude preflight: missing option %s\n' "$option" >&2; exit 69; }
  done
  # --help still parses every flag, so this proves the exact invocation without a model turn.
  claude --print --output-format json --json-schema '{"type":"object"}' --no-session-persistence \
    --permission-mode bypassPermissions --permission-prompts none --effort medium \
    --settings '{"disableAllHooks":true}' --help >/dev/null 2>&1 || {
    printf 'claude preflight: fresh non-interrupting structured invocation is unsupported\n' >&2
    exit 69
  }
  exit 0
fi
provider_init claude "$@"

command -v claude >/dev/null 2>&1 || provider_unavailable

case "$role" in
  worker)
    # Workers must run builds and tests; prompts are denied, never answered.
    permission_mode=bypassPermissions
    effort=${AGENTIC_CLAUDE_WORKER_EFFORT:-${AGENTIC_CLAUDE_EFFORT:-high}}
    model=${AGENTIC_CLAUDE_WORKER_MODEL:-${AGENTIC_CLAUDE_MODEL:-opus}}
    ;;
  reviewer)
    permission_mode=plan
    effort=${AGENTIC_CLAUDE_REVIEWER_EFFORT:-${AGENTIC_CLAUDE_EFFORT:-high}}
    model=${AGENTIC_CLAUDE_REVIEWER_MODEL:-${AGENTIC_CLAUDE_MODEL:-opus}}
    ;;
  diagnostician)
    permission_mode=plan
    effort=${AGENTIC_CLAUDE_DIAGNOSTICIAN_EFFORT:-${AGENTIC_CLAUDE_EFFORT:-high}}
    model=${AGENTIC_CLAUDE_DIAGNOSTICIAN_MODEL:-${AGENTIC_CLAUDE_MODEL:-opus}}
    ;;
esac

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT
combined_prompt="$temporary_dir/prompt"
raw_result="$temporary_dir/result.json"
provider_prompt "$combined_prompt"
schema_json=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",", ":")))' "$result_schema")

arguments=(
  --print
  --output-format json
  --json-schema "$schema_json"
  --no-session-persistence
  --permission-mode "$permission_mode"
  --permission-prompts none
  --effort "$effort"
  # Never inherit the account default: it follows the last interactive /model choice.
  --model "$model"
  # User/plugin hooks (e.g. a blocking PermissionRequest hook) would stall a headless worker.
  --settings '{"disableAllHooks":true}'
)
provider_event started 'fresh process started'
set +e
(
  cd -- "$worktree"
  claude "${arguments[@]}" < "$combined_prompt" > "$raw_result" 2>"$temporary_dir/stderr"
)
exit_code=$?
set -e
if (( exit_code != 0 )); then
  provider_failed "$exit_code" "$temporary_dir/stderr" "$raw_result" || true
  exit "$exit_code"
fi
provider_finish "$raw_result"

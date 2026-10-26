#!/usr/bin/env bash

set -euo pipefail

adapter_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../common.sh
source "$adapter_dir/../common.sh"

if [[ ${1:-} == --preflight ]]; then
  [[ $# == 2 && ($2 == interactive || $2 == unattended) ]] || exit 64
  command -v codex >/dev/null 2>&1 || exit 69
  help=$(codex --help 2>&1) || exit 69
  exec_help=$(codex exec --help 2>&1) || exit 69
  for option in --dangerously-bypass-approvals-and-sandbox --cd; do
    grep -Fq -- "$option" <<<"$help" || { printf 'codex preflight: missing global option %s\n' "$option" >&2; exit 69; }
  done
  for option in --ephemeral --output-schema --output-last-message --json; do
    grep -Fq -- "$option" <<<"$exec_help" || { printf 'codex preflight: missing exec option %s\n' "$option" >&2; exit 69; }
  done
  # Exercise clap parsing in the required global-before-subcommand order.
  codex --dangerously-bypass-approvals-and-sandbox --cd "$PWD" exec --help >/dev/null 2>&1 || {
    printf 'codex preflight: non-interrupting invocation is unsupported\n' >&2
    exit 69
  }
  exit 0
fi
provider_init codex "$@"

command -v codex >/dev/null 2>&1 || provider_unavailable

case "$role" in
  worker)
    effort=${AGENTIC_CODEX_WORKER_EFFORT:-${AGENTIC_CODEX_EFFORT:-medium}}
    ;;
  reviewer)
    effort=${AGENTIC_CODEX_REVIEWER_EFFORT:-${AGENTIC_CODEX_EFFORT:-high}}
    ;;
  diagnostician)
    effort=${AGENTIC_CODEX_DIAGNOSTICIAN_EFFORT:-${AGENTIC_CODEX_EFFORT:-high}}
    ;;
esac

# Optional campaign policy overrides inherited role/provider defaults for this process.
# The canonical adapter owns the policy, including when a recovered worktree has stale files.
branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
slug=''
raw_event_file=/dev/null
bounded_connection_retries=false
case "$branch" in
  campaign/*) slug=${branch#campaign/} ;;
  agentic/*/*) slug=${branch#agentic/}; slug=${slug%%/*} ;;
esac
if [[ -n $slug ]]; then
  # The engine may run from a snapshot of .agentic; it exports the campaign root explicitly.
  policy="${AGENTIC_CAMPAIGN_ROOT:-$adapter_dir/../../..}/campaigns/$slug/codex-effort.json"
  if [[ -f $policy ]]; then
    effort=$(python3 - "$policy" "$role" <<'PYCONFIG'
import json, sys
policy = json.load(open(sys.argv[1], encoding='utf-8'))
roles = policy['roles']
allowed = policy['allowed_efforts']
if not allowed or any(value not in ('low', 'medium', 'high', 'xhigh') for value in allowed):
    raise ValueError('invalid campaign effort policy')
for role in ('coordinator', 'worker', 'reviewer', 'diagnostician'):
    if roles[role] not in allowed:
        raise ValueError('campaign role effort is missing or disallowed: ' + role)
print(roles[sys.argv[2]])
PYCONFIG
    ) || exit 64
    record_process_events=$(python3 - "$policy" <<'PYLOG'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8')).get('record_process_events', False)
if not isinstance(value, bool):
    raise ValueError('record_process_events must be boolean')
print('true' if value else 'false')
PYLOG
    ) || exit 64
    bounded_connection_retries=$(python3 - "$policy" <<'PYRETRY'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8')).get('bounded_connection_retries', False)
if not isinstance(value, bool):
    raise ValueError('bounded_connection_retries must be boolean')
print('true' if value else 'false')
PYRETRY
    ) || exit 64
    if [[ $record_process_events == true ]]; then
      # Private runtime evidence for progress/adapter diagnosis; never a validation gate.
      raw_event_file="$event_file.$role.$provider_run_id.codex.ndjson"
    fi
  fi
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT
combined_prompt="$temporary_dir/prompt"
raw_result="$temporary_dir/result.json"
provider_prompt "$combined_prompt"

global_arguments=(
  --dangerously-bypass-approvals-and-sandbox
  # Ephemeral CLI sessions have no persistent parent thread for nested agents.
  # The campaign supervisor already creates each role in its own fresh process.
  --disable multi_agent
  --cd "$worktree"
  --config "model_reasoning_effort=\"$effort\""
)
if [[ $bounded_connection_retries == true ]]; then
  # Let the canonical supervisor recover a failed stream instead of retrying forever.
  global_arguments+=(--disable unbounded_connection_retries)
fi
if [[ -n ${AGENTIC_CODEX_MODEL:-} ]]; then
  global_arguments+=(--model "$AGENTIC_CODEX_MODEL")
fi
exec_arguments=(
  exec
  --ephemeral
  --json
  --output-schema "$result_schema"
  --output-last-message "$raw_result"
)

provider_event started "fresh process started; effort=$effort"
set +e
codex "${global_arguments[@]}" "${exec_arguments[@]}" - < "$combined_prompt" >"$raw_event_file" 2>"$temporary_dir/stderr"
exit_code=$?
set -e
if (( exit_code != 0 )); then
  provider_failed "$exit_code"
  exit "$exit_code"
fi
provider_finish "$raw_result"

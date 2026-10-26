#!/usr/bin/env bash

set -euo pipefail

adapter_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../common.sh
source "$adapter_dir/../common.sh"

if [[ ${1:-} == --preflight ]]; then
  [[ $# == 2 && ($2 == interactive || $2 == unattended) ]] || exit 64
  command -v grok >/dev/null 2>&1 || exit 69
  help=$(grok --help 2>&1) || exit 69
  for option in --always-approve --prompt-file --cwd --output-format --json-schema --no-subagents --permission-mode --reasoning-effort; do
    grep -Fq -- "$option" <<<"$help" || { printf 'grok preflight: missing option %s\n' "$option" >&2; exit 69; }
  done
  grok --always-approve --permission-mode bypassPermissions --output-format json \
    --json-schema '{"type":"object"}' --no-subagents --reasoning-effort medium --help >/dev/null 2>&1 || {
    printf 'grok preflight: fresh non-interrupting structured invocation is unsupported\n' >&2
    exit 69
  }
  exit 0
fi
provider_init grok "$@"

command -v grok >/dev/null 2>&1 || provider_unavailable

case "$role" in
  worker)
    permission_mode=bypassPermissions
    effort=${AGENTIC_GROK_WORKER_EFFORT:-${AGENTIC_GROK_EFFORT:-medium}}
    ;;
  reviewer)
    permission_mode=plan
    effort=${AGENTIC_GROK_REVIEWER_EFFORT:-${AGENTIC_GROK_EFFORT:-high}}
    ;;
  diagnostician)
    permission_mode=plan
    effort=${AGENTIC_GROK_DIAGNOSTICIAN_EFFORT:-${AGENTIC_GROK_EFFORT:-high}}
    ;;
esac

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT
combined_prompt="$temporary_dir/prompt"
raw_result="$temporary_dir/result.json"
provider_prompt "$combined_prompt"
schema_json=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",", ":")))' "$result_schema")

arguments=(
  --always-approve
  --prompt-file "$combined_prompt"
  --cwd "$worktree"
  --output-format json
  --json-schema "$schema_json"
  --no-subagents
  --permission-mode "$permission_mode"
  --reasoning-effort "$effort"
)
if [[ -n ${AGENTIC_GROK_MODEL:-} ]]; then
  arguments+=(--model "$AGENTIC_GROK_MODEL")
fi
if [[ $role != worker ]]; then
  # plan mode cancels a denied shell or subagent permission and aborts the
  # whole headless turn, leaving no canonical RESULT. --no-subagents is not
  # enough: spawn_subagent still appears and a cancel kills the turn.
  arguments+=(--disallowed-tools "run_terminal_cmd,run_terminal_command,monitor,Agent")
  true
fi

provider_event started 'fresh process started'
set +e
grok "${arguments[@]}" > "$raw_result" 2>"$temporary_dir/stderr"
exit_code=$?
set -e
if (( exit_code != 0 )); then
  provider_failed "$exit_code"
  exit "$exit_code"
fi
provider_finish "$raw_result"

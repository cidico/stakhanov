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
# Optional account hook, compatible with udarnik: AGENTIC_CLAUDE_ACCOUNTS names a command. While `<command> account
# enabled` succeeds, claude runs in the account `<command> account current` names, through the env prefix of `<command>
# account env ACCOUNT`. A failure goes to `<command> account limit ACCOUNT` on stdin: when it was a usage limit and the
# hook prints another account, the same invocation runs once more there (exit 75: no account is left). Unset or
# disabled, claude runs in the caller's account.
accounts=${AGENTIC_CLAUDE_ACCOUNTS:-}
account=''
account_env=()
account_key() { local name; name=$(basename -- "${1%/}"); printf '%s\n' "${name#.}"; }
# Sets account_env to the env prefix of an account; fails when the hook does not give one.
use_account() {
  local prefix
  prefix=$("$accounts" account env "$1") || return 1
  eval "account_env=($prefix)" || return 1
  [[ ${account_env[0]:-} == env ]] || { account_env=(); return 1; }
  account=$1
}
if [[ -n $accounts ]]; then
  if ! command -v "$accounts" >/dev/null 2>&1; then
    printf 'claude adapter: account hook %s not found; running in the current account\n' "$accounts" >&2
    accounts=''
  elif ! "$accounts" account enabled >/dev/null 2>&1; then
    accounts=''
  elif ! current=$("$accounts" account current) || [[ -z $current ]] || ! use_account "$current"; then
    printf 'claude adapter: account hook %s gave no usable account; running in the current account\n' "$accounts" >&2
    accounts=''
  fi
fi

run_claude() {
  set +e
  (
    cd -- "$worktree"
    "${account_env[@]}" claude "${arguments[@]}" < "$combined_prompt" > "$raw_result" 2>"$temporary_dir/stderr"
  )
  exit_code=$?
  set -e
}

provider_event started 'fresh process started'
run_claude
if (( exit_code != 0 )) && [[ -n $accounts ]]; then
  limit_status=0
  next=$(command cat -- "$raw_result" "$temporary_dir/stderr" 2>/dev/null | "$accounts" account limit "$account") || limit_status=$?
  if (( limit_status == 0 )) && [[ -n $next ]] && previous=$account && use_account "$next"; then
    provider_event account "account $(account_key "$previous") hit its usage limit; retrying once in account $(account_key "$account")"
    if [[ $role == worker ]]; then
      printf '\n%s\n' "The previous process for this role was cut off by a provider usage limit. Any uncommitted change in the worktree is its partial, unverified work: compare it with the ticket's Acceptance, finish what is missing and remove anything the ticket does not ask for, then run the ticket's cheap checks." >> "$combined_prompt"
    fi
    run_claude
    # Keep the hook's account state true when the second account is out too; there is no further retry.
    if (( exit_code != 0 )); then
      command cat -- "$raw_result" "$temporary_dir/stderr" 2>/dev/null | "$accounts" account limit "$account" >/dev/null 2>&1 || true
    fi
  elif (( limit_status == 75 )); then
    provider_event account "account $(account_key "$account") hit its usage limit and no other account is available"
  fi
fi
if (( exit_code != 0 )); then
  provider_failed "$exit_code" "$temporary_dir/stderr" "$raw_result" || true
  exit "$exit_code"
fi
provider_finish "$raw_result"

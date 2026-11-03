#!/usr/bin/env bash

set -euo pipefail

adapter_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../common.sh
source "$adapter_dir/../common.sh"

# --ready: 0 when claude is installed and signed in, 69 when it is missing, 77 when it is not signed in.
# --install: installs claude for this user (the official installer, into ~/.local/bin). --login: signs in, interactively
# (the link opens in a browser anywhere; the code comes back here).
case ${1:-} in
  --ready)
    # A claude on the PATH may be a wrapper of the system around each user's own installation: it must also run.
    command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1 || { printf 'claude is not installed\n' >&2; exit 69; }
    claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null || { printf 'claude is not signed in\n' >&2; exit 77; }
    exit 0 ;;
  --install) curl -fsSL https://claude.ai/install.sh | bash; exit ;;
  --login) exec claude auth login ;;
esac
# AGENTIC_CLAUDE_MODE: print (the default) runs every role as a headless `claude --print` process. session runs no claude
# process of its own: the role is a background subagent of an interactive host session (session.sh, bin/session-host).
claude_mode=${AGENTIC_CLAUDE_MODE:-print}
case $claude_mode in
  print | session) ;;
  *) printf 'claude adapter: invalid AGENTIC_CLAUDE_MODE %s (print or session)\n' "$claude_mode" >&2; exit 64 ;;
esac
# The hook that keeps a role from editing files through the shell and from writing to git (bin/role-guard). The settings of a
# print-mode role are these and nothing else: the user's settings are not loaded (--setting-sources project,local), so a
# hook of the user or of a plugin that blocks (a PermissionRequest hook waiting for a desktop approval) never stalls a
# headless role, and --settings adds the guard as a PreToolUse hook of Bash. (disableAllHooks would switch the guard off too.)
# role_guard_settings ROLE: the JSON of --settings.
role_guard_settings() {
  local guard
  guard="$(cd -- "$adapter_dir/../.." && pwd -P)/bin/role-guard"
  jq -cn --arg command "$(printf '%q %s' "$guard" "$1")" \
    '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $command}]}]}}'
}
if [[ ${1:-} == --preflight ]]; then
  [[ $# == 2 && ($2 == interactive || $2 == unattended) ]] || exit 64
  if [[ $claude_mode == session ]]; then
    # No flag to check: a role needs a live host session on this machine. The runner retries the preflight later.
    python3 "$adapter_dir/session.py" live || {
      printf 'claude preflight: no live campaign host session on this machine; open one with /campaign-host\n' >&2
      exit 69
    }
    exit 0
  fi
  command -v claude >/dev/null 2>&1 || exit 69
  help=$(claude --help 2>&1) || exit 69
  for option in --print --output-format --json-schema --no-session-persistence --permission-mode --permission-prompts --effort --settings --setting-sources --disallowedTools bypassPermissions; do
    grep -Fq -- "$option" <<<"$help" || { printf 'claude preflight: missing option %s\n' "$option" >&2; exit 69; }
  done
  # --help still parses every flag, so this proves the exact invocation without a model turn.
  claude --print --output-format json --json-schema '{"type":"object"}' --no-session-persistence \
    --permission-mode bypassPermissions --permission-prompts none --effort medium \
    --settings "$(role_guard_settings worker)" --setting-sources project,local \
    --disallowedTools Edit,Write,NotebookEdit,MultiEdit --help >/dev/null 2>&1 || {
    printf 'claude preflight: fresh non-interrupting structured invocation is unsupported\n' >&2
    exit 69
  }
  exit 0
fi
provider_init claude "$@"

[[ $claude_mode == session ]] || command -v claude >/dev/null 2>&1 || provider_unavailable

case "$role" in
  worker)
    # Workers must run builds and tests; prompts are denied, never answered.
    permission_mode=bypassPermissions
    read_only=false
    effort=${AGENTIC_CLAUDE_WORKER_EFFORT:-${AGENTIC_CLAUDE_EFFORT:-high}}
    model=${AGENTIC_CLAUDE_WORKER_MODEL:-${AGENTIC_CLAUDE_MODEL:-opus}}
    ;;
  reviewer)
    # Read-only roles do not use `--permission-mode plan`: that mode makes the CLI call a second model (claude-sonnet next
    # to the one asked for, about 20x the cost of a haiku call). They run without prompts and without the write tools
    # instead; Bash stays for tests and `git diff`, and the runner's reviewer-mutated check is the guarantee.
    permission_mode=bypassPermissions
    read_only=true
    effort=${AGENTIC_CLAUDE_REVIEWER_EFFORT:-${AGENTIC_CLAUDE_EFFORT:-high}}
    model=${AGENTIC_CLAUDE_REVIEWER_MODEL:-${AGENTIC_CLAUDE_MODEL:-opus}}
    ;;
  diagnostician)
    permission_mode=bypassPermissions
    read_only=true
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
  # No user or plugin hooks (a blocking PermissionRequest hook would stall a headless role), and the role-guard hook.
  --settings "$(role_guard_settings "$role")"
  --setting-sources project,local
)
$read_only && arguments+=(--disallowedTools 'Edit,Write,NotebookEdit,MultiEdit')
# Optional account hook, compatible with udarnik: AGENTIC_CLAUDE_ACCOUNTS names a command. While `<command> account
# enabled` succeeds, claude runs in the account `<command> account current` names, through the env prefix of `<command>
# account env ACCOUNT`. A failure goes to `<command> account limit ACCOUNT` on stdin: when it was a usage limit and the
# hook prints another account, the same invocation runs once more there. When no account is left (the hook exits 75)
# the adapter exits 75 and its stderr says when the first account is back (`accounts-back-at=EPOCH`, from `<command>
# account next`), so the runner waits instead of spending an attempt. Unset or disabled, claude runs in the caller's
# account.
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
# `<hook> account SUBCOMMAND [ARGUMENT] --kind worker`: the adapter says it is a worker, so the hook orders the accounts for
# workers. Stdin goes to the hook. A hook that does not know --kind answers 2 (usage): the call is repeated without it.
account_hook() {
  local input status=0 output
  input=$(mktemp "$temporary_dir/hook.XXXXXX")
  command cat > "$input"
  output=$("$accounts" account "$@" --kind worker < "$input") || status=$?
  if (( status == 2 )); then
    status=0
    output=$("$accounts" account "$@" < "$input") || status=$?
  fi
  rm -f -- "$input"
  printf '%s\n' "$output"
  return "$status"
}
# A call that worked proves its account is back: `<hook> account clear --at EPOCH ACCOUNT --kind worker` takes the account off
# the fleet's "out" list (the hook does nothing when it was not on it). EPOCH is when the claude process that produced the
# result ended: the hook compares it with the "out" marks to tell which are older than the proof. It never fails or holds the
# call: a status other than 0 (a hook that does not know `clear`, `--kind` or `--at` answers 2: the call repeats without
# `--kind`, then without `--at` too), a hook past its deadline (AGENTIC_CLAUDE_ACCOUNT_CLEAR_SECONDS, 10 s) or a hook gone is
# one line on stderr. The hook's own output is dropped, and the deadline kills its whole process group.
clear_seconds=${AGENTIC_CLAUDE_ACCOUNT_CLEAR_SECONDS:-10}
[[ $clear_seconds =~ ^[1-9][0-9]{0,3}$ ]] || clear_seconds=10
call_ended=''
account_clear() {
  local status=0
  timeout --kill-after=2 "$clear_seconds" "$accounts" account clear --at "$2" "$1" --kind worker </dev/null >/dev/null 2>&1 || status=$?
  if (( status == 2 )); then
    status=0
    timeout --kill-after=2 "$clear_seconds" "$accounts" account clear --at "$2" "$1" </dev/null >/dev/null 2>&1 || status=$?
  fi
  if (( status == 2 )); then
    status=0
    timeout --kill-after=2 "$clear_seconds" "$accounts" account clear "$1" </dev/null >/dev/null 2>&1 || status=$?
  fi
  (( status == 0 )) || printf 'claude adapter: account hook %s could not clear account %s (status %s); ignored\n' \
    "$accounts" "$(account_key "$1")" "$status" >&2
  return 0
}
if [[ $claude_mode == session ]]; then
  # shellcheck source=session.sh
  source "$adapter_dir/session.sh"
  session_run
fi
if [[ -n $accounts ]]; then
  if ! command -v "$accounts" >/dev/null 2>&1; then
    printf 'claude adapter: account hook %s not found; running in the current account\n' "$accounts" >&2
    accounts=''
  elif ! "$accounts" account enabled >/dev/null 2>&1; then
    accounts=''
  elif ! current=$(account_hook current </dev/null) || [[ -z $current ]] || ! use_account "$current"; then
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
  printf -v call_ended '%(%s)T' -1
  set -e
  # Every process costs, the one cut off by a usage limit too: the events carry the sum over the attempts.
  provider_usage_record "$raw_result"
}

# A transient API error (429 that is not the usage limit, 500, 502, 503, 529, "overloaded") does not mean the role failed: the
# same process runs again inside the adapter, after 30 s, 60 s and 120 s plus up to 50 % of random delay, at most
# AGENTIC_PROVIDER_TRANSIENT_RETRIES times (3 by default). The runner sees one call. A usage limit is never transient.
transient_retries=${AGENTIC_PROVIDER_TRANSIENT_RETRIES:-3}
[[ $transient_retries =~ ^[0-9]{1,3}$ ]] || transient_retries=3
transient_base=${AGENTIC_PROVIDER_TRANSIENT_WAIT_SECONDS:-30}
[[ $transient_base =~ ^[1-9][0-9]{0,3}$ ]] || transient_base=30
transient_tries=0
# Text a usage limit says; without an account hook this is the only way to tell it from a transient 429.
usage_limit_pattern='usage limit|hit your .*limit|limit reached|weekly limit|session limit'
# Prints the API status (or "none" when only the text says so) and succeeds when the failed process hit a transient error.
transient_status() {
  local status text
  status=$(jq -rs '[.[] | objects | .api_error_status // empty | tostring] | last // empty' "$raw_result" 2>/dev/null) || status=''
  text=$(jq -rs '[.[] | objects | .result // empty | tostring] | join(" ")' "$raw_result" 2>/dev/null) || text=''
  text="$text $(command cat -- "$temporary_dir/stderr" 2>/dev/null || true)"
  if [[ $status =~ ^(429|500|502|503|529)$ ]] || grep -Eiq 'overloaded|rate[ _-]?limit' <<<"$text"; then
    printf '%s\n' "${status:-none}"
  else
    return 1
  fi
}
# Waits before the next transient retry; a stop request (TERM, INT) ends the wait and the adapter at once.
transient_backoff() {
  local delay sleeper
  delay=$((transient_base << (transient_tries > 2 ? 2 : transient_tries)))
  delay=$((delay + RANDOM % (delay / 2 + 1)))
  transient_tries=$((transient_tries + 1))
  provider_event transient "transient provider error (status $1); waiting ${delay}s before retry $transient_tries of $transient_retries"
  sleep "$delay" &
  sleeper=$!
  trap 'kill "$sleeper" 2>/dev/null; provider_event failed "stop requested during the wait after a transient provider error"; exit 143' TERM INT
  wait "$sleeper" || true
  trap - TERM INT
}

provider_event started 'fresh process started'
run_claude
no_account=false
switched=false
while (( exit_code != 0 )); do
  failure="$temporary_dir/failure"
  command cat -- "$raw_result" "$temporary_dir/stderr" > "$failure" 2>/dev/null || true
  if [[ -n $accounts ]]; then
    limit_status=0
    next=$(account_hook limit "$account" < "$failure") || limit_status=$?
    if (( limit_status == 0 )); then
      # A usage limit. The first one retries once in the next account; a second is only reported to the hook (above), so its
      # account state stays true.
      if ! $switched && [[ -n $next ]] && previous=$account && use_account "$next"; then
        provider_event account "account $(account_key "$previous") hit its usage limit; retrying once in account $(account_key "$account")"
        if [[ $role == worker ]]; then
          printf '\n%s\n' "The previous process for this role was cut off by a provider usage limit. Any uncommitted change in the worktree is its partial, unverified work: compare it with the ticket's Acceptance, finish what is missing and remove anything the ticket does not ask for, then run the ticket's cheap checks." >> "$combined_prompt"
        fi
        switched=true
        run_claude
        continue
      fi
      break
    elif (( limit_status == 75 )); then
      if $switched; then
        provider_event account "account $(account_key "$account") hit its usage limit too and no other account is available"
      else
        provider_event account "account $(account_key "$account") hit its usage limit and no other account is available"
      fi
      no_account=true
      break
    fi
  elif grep -Eiq "$usage_limit_pattern" "$failure"; then
    break
  fi
  # Not a usage limit: a transient error backs off and runs again; anything else fails the role.
  (( transient_tries < transient_retries )) && status=$(transient_status) || break
  transient_backoff "$status"
  run_claude
done
if (( exit_code != 0 )); then
  provider_failed "$exit_code" "$temporary_dir/stderr" "$raw_result" || true
  if $no_account; then
    back=$("$accounts" account next 2>/dev/null) || back=''
    [[ $back =~ ^[0-9]+$ ]] || back=0
    printf 'claude adapter: every account is out of quota; accounts-back-at=%s\n' "$back" >&2
    exit 75
  fi
  exit "$exit_code"
fi
finish_status=0
provider_finish "$raw_result" || finish_status=$?
# Only a validated result proves the account works; the account used is the one of the process that produced it.
if (( finish_status == 0 )) && [[ -n $accounts ]]; then
  account_clear "$account" "$call_ended"
fi
exit "$finish_status"

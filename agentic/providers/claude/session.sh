#!/usr/bin/env bash
# Session mode of the claude adapter (AGENTIC_CLAUDE_MODE=session). Sourced by run.sh after it computed the role, the model, the
# effort, the combined prompt and the account hook functions; session_run never returns.
#
# No `claude --print` process runs. The adapter files a request in the machine's queue (session.py) and waits for an
# interactive claude session that registered as a host (bin/session-host) to run the role as a background subagent:
#   done           the subagent wrote result.json; it is validated for the role and copied to the engine's result path
#   no host        keeps waiting (never counted as idle), a run simply waits until a host session is open
#   limit          the subagent's transcript ends with a usage-limit error: the account hook decides (see session_limit)
#   idle           nothing moved for AGENTIC_SESSION_IDLE_SECONDS (transcript, and for a pending Bash call the CPU and I/O of its
#                  processes) and a confirming sample of AGENTIC_SESSION_SAMPLE_SECONDS found nothing either: cancel, exit 124
#   finished       the subagent ended and 60 s later there is still no result: exit 1 (the engine re-invokes once)
# A stop request (TERM, INT) writes `cancel` and ends the adapter at once.

session_py="$adapter_dir/session.py"
session_sleeper=''
session_succeeded=false
session_account=''
session_agent=''
session_acknowledged=''

# session_number NAME DEFAULT: the value of the environment variable NAME when it is a positive number (decimals allowed,
# for tests), else DEFAULT.
session_number() {
  local value=${!1:-}
  if [[ $value =~ ^[1-9][0-9]{0,8}(\.[0-9]+)?$ || $value =~ ^0\.[0-9]*[1-9][0-9]*$ ]]; then printf '%s\n' "$value"; else printf '%s\n' "$2"; fi
}

# session_ge A B: succeeds when the number A is at least B.
session_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

# session_mark NAME [CONTENT]: writes a marker of the request atomically.
session_mark() {
  { printf '%s' "${2:-}" > "$request_dir/.$1.tmp" && mv -f -- "$request_dir/.$1.tmp" "$request_dir/$1"; } 2>/dev/null || true
}

session_reason() { jq -cn --arg reason "$1" --argjson at "$(date +%s)" '{reason: $reason, at: $at}'; }

# Waits without holding a stop request back: a TERM or INT during the pause runs the trap at once.
session_pause() {
  sleep "$1" &
  session_sleeper=$!
  wait "$session_sleeper" || true
  session_sleeper=''
}

# Whoever ends the adapter, the request folder of a result that was taken is removed; any other stays marked finished
# (for diagnosis, until a host prunes it) so no host picks it up.
session_exit() {
  if $session_succeeded; then rm -rf -- "$request_dir"; elif [[ -d $request_dir ]]; then session_mark finished; fi
  rm -rf -- "$temporary_dir"
}

session_stop() {
  trap - TERM INT
  [[ -z $session_sleeper ]] || kill "$session_sleeper" 2>/dev/null || true
  session_mark cancel "$(session_reason 'stop requested')"
  provider_event failed 'stop requested while waiting for the subagent'
  exit 143
}

# The usage of the subagent's transcript, recorded like the usage of a --print process.
session_usage() {
  local usage_file="$temporary_dir/session.usage.$((${#provider_usage_files[@]} + 1)).json"
  if python3 "$session_py" usage "$request_dir" "$usage_file" 2>/dev/null; then provider_usage_files+=("$usage_file"); fi
}

session_hook_enabled() {
  [[ -n $accounts ]] && command -v "$accounts" >/dev/null 2>&1 && "$accounts" account enabled >/dev/null 2>&1
}

session_fail() { # STATUS MESSAGE: the subagent's work is lost; the engine decides what to do with the status.
  session_usage
  printf '%s\n' "$2" >&2
  provider_event failed "$2"
  exit "$1"
}

# Takes the result when the subagent finished it: a valid one is copied to the engine's result path and ends the adapter.
session_check_done() {
  [[ -e $request_dir/done ]] || return 0
  local output staged
  if [[ ! -s $request_dir/result.json ]]; then
    output='invalid provider result: the subagent signalled done without writing result.json'
  elif ! output=$(python3 "$result_validator" "$result_schema" "$role" "$request_dir/result.json" 2>&1); then
    output=$(head -n 1 <<<"$output")
    [[ $output == 'invalid provider result:'* ]] || output="invalid provider result: $output"
  else
    output=''
  fi
  [[ -z $output ]] || session_fail 1 "$output"
  session_usage
  staged=$(mktemp "$(dirname -- "$result_file")/.result.XXXXXX")
  cp -- "$request_dir/result.json" "$staged"
  mv -f -- "$staged" "$result_file"
  provider_usage_store
  provider_event completed 'structured result validated'
  # Only a validated result proves the account of the host works.
  if [[ -n $session_account ]] && session_hook_enabled; then account_clear "$session_account" "$(date +%s)"; fi
  session_succeeded=true
  exit 0
}

# The subagent hit a usage limit (its transcript ends with the error). Without an account hook, or when the hook has no
# other account, the adapter exits 75 with the time the first account is back, so the engine waits for quota and invokes
# again. When the hook has another account the request goes back to the queue: hosts of the limited account skip it, and a
# host in another account (the limited session moved there by the takeover, or another session) runs it.
session_limit() { # TEXT ID
  local status=0 next='' back=0
  if session_hook_enabled; then
    next=$(account_hook limit "$session_account" <<<"$1") || status=$?
    if (( status == 0 )); then
      printf '%s\n' "$session_account" >> "$request_dir/limited"
      rm -f -- "$request_dir/assigned"
      provider_event account "account $(account_key "$session_account") hit its usage limit; the request waits for a host session in another account"
      session_agent=''
      return 0
    elif (( status != 75 )); then
      session_acknowledged=$2   # not a usage limit after all: the end of the transcript is judged as any other
      return 0
    fi
  fi
  session_mark cancel "$(session_reason 'usage limit')"
  if session_hook_enabled; then
    back=$("$accounts" account next 2>/dev/null) || back=''
    [[ $back =~ ^[0-9]+$ ]] || back=0
  fi
  session_usage
  provider_event account "the host account ${session_account:+$(account_key "$session_account") }hit its usage limit and no other account is available"
  provider_event failed 'usage limit: every account is out of quota'
  printf 'claude adapter: every account is out of quota; accounts-back-at=%s\n' "$back" >&2
  exit 75
}

# The subagent made no progress. One confirming sample later it is cancelled and the host is given time to stop it.
session_idle() { # IDLE_FOR
  local waited_since=$EPOCHREALTIME
  session_mark cancel "$(session_reason idle)"
  while [[ ! -e $request_dir/cancelled ]] && ! session_ge "$(awk -v n="$EPOCHREALTIME" -v s="$waited_since" 'BEGIN { print n - s }')" "$session_cancel_wait"; do
    session_check_done
    session_pause "$session_poll"
  done
  session_fail 124 "claude adapter: the subagent was idle for $1s (no transcript, CPU or I/O activity) and was stopped"
}

session_run() {
  local alias project ticket idle sample grace out verdict agent confirm_since='' waiting=false when
  alias=$(python3 "$session_py" model-alias "$model") || {
    provider_event failed "model $model cannot run as a subagent"
    printf 'claude adapter: model %s cannot run as a subagent (use opus, sonnet, haiku or fable)\n' "$model" >&2
    exit 64
  }
  idle=$(session_number AGENTIC_SESSION_IDLE_SECONDS 600)
  sample=$(session_number AGENTIC_SESSION_SAMPLE_SECONDS 30)
  grace=$(session_number AGENTIC_SESSION_FINISH_GRACE_SECONDS 60)
  session_poll=$(session_number AGENTIC_SESSION_POLL_SECONDS 5)
  session_cancel_wait=$(session_number AGENTIC_SESSION_CANCEL_WAIT_SECONDS 60)
  ticket=${AGENTIC_TICKET:-$(basename -- "${result_file%.json}")}
  project=${AGENTIC_PROJECT:-$(basename -- "$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$worktree")")}
  request_dir=$(python3 "$session_py" submit --id "$provider_run_id" --project "$project" --ticket "$ticket" --role "$role" \
    --model "$model" --effort "$effort" --read-only "$read_only" --worktree "$worktree" --prompt "$combined_prompt" \
    --schema "$result_schema" --adapter-pid "$$")
  monitor_state="$temporary_dir/session-state.json"
  trap session_exit EXIT
  trap session_stop TERM INT
  provider_event started "session request $provider_run_id filed (model $alias, effort $effort)"
  while :; do
    session_check_done
    out=$(python3 "$session_py" inspect "$request_dir" "$monitor_state" "$idle" ${session_acknowledged:+--ack-limit "$session_acknowledged"}) ||
      out='{"verdict":"working"}'
    verdict=$(jq -r '.verdict // "working"' <<<"$out" 2>/dev/null) || verdict=working
    session_account=$(jq -r '.account // empty' <<<"$out" 2>/dev/null) || session_account=''
    case $verdict in
      unassigned | host-dead)
        confirm_since=''
        session_agent=''
        if ! $waiting; then waiting=true; provider_event waiting 'waiting for a host session'; fi ;;
      *)
        waiting=false
        agent=$(jq -r '.agent_id // empty' <<<"$out" 2>/dev/null) || agent=''
        if [[ -n $agent && $agent != "$session_agent" ]]; then
          session_agent=$agent
          provider_event assigned "running as subagent $agent of a host session in account ${session_account:+$(account_key "$session_account")}"
        fi
        case $verdict in
          limit) session_limit "$(jq -r '.limit_text' <<<"$out")" "$(jq -r '.limit_id' <<<"$out")" ;;
          finished)
            when=$(jq -r '.finished_for' <<<"$out")
            if session_ge "$when" "$grace"; then
              session_check_done
              session_fail 1 'invalid provider result: the subagent ended without writing its result'
            fi ;;
          idle)
            if [[ -z $confirm_since ]]; then
              confirm_since=$EPOCHREALTIME
              provider_event idle "no activity for $(jq -r '.idle_for' <<<"$out")s; confirming over ${sample}s"
            elif session_ge "$(awk -v n="$EPOCHREALTIME" -v s="$confirm_since" 'BEGIN { print n - s }')" "$sample"; then
              session_idle "$(jq -r '.idle_for' <<<"$out")"
            fi ;;
          *) confirm_since='' ;;
        esac ;;
    esac
    session_pause "$session_poll"
  done
}

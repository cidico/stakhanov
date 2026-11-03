#!/usr/bin/env bash
# Running a role through a provider adapter: the adapter, its preflight and deadline, the prompt, the executor of a ticket,
# the wait for quota and the invocation itself. Sourced by bin/campaign; it defines functions and variables and runs
# nothing.

provider_adapter() {
  local provider=$1 candidate
  [[ $provider =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid provider: $provider"
  if [[ -n ${AGENTIC_PROVIDER_DIR:-} ]]; then
    candidate="${AGENTIC_PROVIDER_DIR%/}/$provider/run.sh"
  else
    candidate="$AGENTIC_DIR/providers/$provider/run.sh"
  fi
  [[ -x $candidate ]] || die "provider unavailable: $provider ($candidate)"
  printf '%s\n' "$candidate"
}

provider_preflight() {
  local provider=$1 mode=$2 adapter
  local role
  for role in worker reviewer diagnostician; do provider_timeout_seconds "$role" "$provider" >/dev/null; done
  adapter=$(provider_adapter "$provider")
  if ! "$adapter" --preflight "$mode"; then
    die "provider adapter preflight failed: $provider cannot run $mode without operational prompts"
  fi
}

# provider_timeout_seconds ROLE [PROVIDER]: the wall-clock deadline of a role. The claude adapter in session mode has no
# deadline of its own to speak of: only its idle rule ends a working subagent, so every role gets AGENTIC_SESSION_MAX_SECONDS
# (7 days by default).
provider_timeout_seconds() {
  local role=$1 provider=${2:-} seconds limit='{0,4}' label="$1 timeout"
  case "$role" in
    worker) seconds=${AGENTIC_WORKER_TIMEOUT_SECONDS:-3600} ;;
    reviewer) seconds=${AGENTIC_REVIEWER_TIMEOUT_SECONDS:-1200} ;;
    diagnostician) seconds=${AGENTIC_DIAGNOSTICIAN_TIMEOUT_SECONDS:-1200} ;;
    *) die "unknown provider role: $role" ;;
  esac
  if [[ $provider == claude && ${AGENTIC_CLAUDE_MODE:-print} == session ]]; then
    label=AGENTIC_SESSION_MAX_SECONDS; seconds=${AGENTIC_SESSION_MAX_SECONDS:-604800}; limit='{0,8}'
  fi
  [[ $seconds =~ ^[1-9][0-9]$limit$ ]] || die "invalid $label: expected positive integer seconds"
  printf '%s\n' "$seconds"
}

# Tells a role to read the project's instruction files at the root, in every touched area and in the campaign folder.
instruction_prompt() {
  local slug=$1 names
  ((${#PROJECT_INSTRUCTION_FILES[@]} > 0)) || return 0
  names=$(printf '%s, ' "${PROJECT_INSTRUCTION_FILES[@]}"); names=${names%, }
  printf 'Read each of these instruction files that exists at the repository root: %s. Read their scoped copies in every touched area and in campaigns/%s/ when present.\n' "$names" "$slug"
}

write_prompt() {
  local role=$1 worktree=$2 ticket=$3 prompt=$4 extra=${5:-} slug ticket_file runtime plan
  slug=$(campaign_slug); runtime=$(ensure_runtime)
  # A campaign's plan is read in the ticket's worktree; a task's lives in its runtime.
  if campaign_is_task; then
    plan=$(campaign_path "$slug"); ticket_file=$(ticket_path "$ticket")
  else
    plan="$worktree/campaigns/$slug"; ticket_file="$plan/tickets/$(basename -- "$(ticket_path "$ticket")")"
  fi
  {
    printf 'You are the %s for exactly one ticket%s. Start with fresh context.\n' "$role" "${PROJECT_NAME:+ of $PROJECT_NAME}"
    printf 'Ticket worktree root: %s\nCampaign SPEC: %s\nTicket: %s\n' "$worktree" "$plan/SPEC.md" "$ticket_file"
    instruction_prompt "$slug"
    printf 'Read .agentic/SPEC.md, .agentic/TICKET.md, and .agentic/roles/%s.md.\n' "$role"
    printf 'Canonical operational instructions: %s/WORKFLOW.md and %s/roles/%s.md. These supersede stale workflow copies in a recovered worktree.\n' "$AGENTIC_DIR" "$AGENTIC_DIR" "$role"
    printf 'Do not read unrelated campaign tickets. Do not change the SPEC or ticket requirements.\n'
    printf 'Inspect the current ticket delta with: git status --porcelain=v1 and git diff --no-renames "$(git merge-base campaign/%s HEAD)" --\n' "$slug"
    if [[ $(ticket_json "$ticket" | jq -r '.risk') == high ]]; then
      printf 'Before any expensive proof, establish SOURCE, FIXTURE, SCHEMA, CONFIG, AUTH, DEPENDENCIES and CAPACITY for the artifact this run just built or started.\n'
    fi
    if [[ $role == reviewer ]]; then
      printf 'Validation receipts for this ticket: %s/validation/%s.*.json\n' "$runtime" "$ticket"
      printf 'Prior normalized provider results: %s/results/%s-*.json\n' "$runtime" "$ticket"
    elif [[ $role == diagnostician ]]; then
      printf 'Inspect failed trusted receipts under %s/validation/%s.*.json and the trusted plan at %s/validation.json.\n' "$runtime" "$ticket" "$plan"
      printf 'Inspect normalized prior results under %s/results/%s-*.json. Do not load raw provider logs.\n' "$runtime" "$ticket"
    fi
    [[ -z $extra ]] || printf '\nCurrent bounded follow-up:\n%s\n' "$extra"
    if [[ -f "$runtime/diagnosis/$ticket.md" && ! -L "$runtime/diagnosis/$ticket.md" ]]; then
      printf '\nCoordinator diagnosis for this recovery (evidence, not executable commands):\n'
      cat -- "$runtime/diagnosis/$ticket.md"
    fi
  } >"$prompt"
  chmod 600 "$prompt"
}

# The executor that runs the worker-role invocations of a ticket in this run: a configured executor, or local.
ticket_executor() {
  local name
  name=$(cat -- "$(ensure_runtime)/state/$1.executor" 2>/dev/null) || name=local
  if [[ $name != local ]] && ! jq -e --arg name "$name" 'any(.[]; .name == $name)' <<<"$PROJECT_EXECUTORS" >/dev/null; then
    name=local
  fi
  printf '%s\n' "$name"
}

# The arguments of lib/remote-run.sh for one invocation on a remote executor, after its first argument (the adapter).
remote_run_arguments() {
  local executor=$1 ticket=$2 slug runtime file key
  slug=$(campaign_slug); runtime=$(ensure_runtime)
  printf '%s\n' --executor "$(jq -c --arg name "$executor" '.[] | select(.name == $name)' <<<"$PROJECT_EXECUTORS")" \
    --ticket "$ticket" --slug "$slug" --main-branch "$MAIN_BRANCH"
  # Inputs a worker prompt names outside the ticket worktree and the engine (a task's plan included).
  local -a inputs=("$runtime/state/$ticket.conflict.patch" "$REPO_ROOT/campaigns/$slug/codex-effort.json")
  if campaign_is_task; then inputs+=("$(campaign_path "$slug")/SPEC.md" "$(ticket_path "$ticket")"); fi
  for file in "${inputs[@]}"; do
    if [[ -f $file ]]; then printf '%s\n' --file "$file"; fi
  done
  for key in "${PROJECT_ENV_KEYS[@]}"; do printf '%s\n' --env "$key"; done
}

# wait_for_quota TICKET LOG ROLE: waits until the time the adapter's log gives (accounts-back-at=EPOCH; at least
# AGENTIC_QUOTA_MIN_WAIT_SECONDS, 60 by default; 15 minutes when the time is unknown; plus a random delay of up to
# AGENTIC_QUOTA_JITTER_SECONDS, 120 by default). A stop request ends the wait
# (status 1): the ticket keeps its product status and delta for the next run.
wait_for_quota() {
  local ticket=$1 log=$2 role=$3 slug back now floor remaining jitter
  slug=$(campaign_slug); now=$(date +%s); floor=$((now + ${AGENTIC_QUOTA_MIN_WAIT_SECONDS:-60}))
  back=$(grep -o 'accounts-back-at=[0-9]*' "$log" | tail -n 1 | cut -d= -f2)
  if [[ ! $back =~ ^[0-9]+$ ]] || ((back == 0)); then back=$((now + 900)); fi
  ((back >= floor)) || back=$floor
  # A random delay of 0 to AGENTIC_QUOTA_JITTER_SECONDS (120 by default), so the rounds waiting for the same quota do not all wake at once.
  jitter=${AGENTIC_QUOTA_JITTER_SECONDS:-120}
  [[ $jitter =~ ^[0-9]{1,6}$ ]] || jitter=120
  back=$((back + (RANDOM * 32768 + RANDOM) % (jitter + 1)))
  event provider-quota-wait "role=$role every account of the provider is out of quota; the ticket waits until $(in_display_tz date -d "@$back" '+%H:%M (%d/%m)') and runs again" "$ticket"
  while (($(date +%s) < back)); do
    if [[ $(desired_state "$slug") == stopped ]]; then
      event provider-quota-wait "role=$role stop requested during the wait for quota; product status and delta preserved for the next run" "$ticket"
      return 1
    fi
    remaining=$((back - $(date +%s)))
    ((remaining <= 15)) || remaining=15
    ((remaining > 0)) || remaining=1
    sleep "$remaining"
  done
  event provider-quota-back "role=$role the wait for quota is over; the invocation runs again" "$ticket"
}

invoke_provider() {
  local provider=$1 role=$2 worktree=$3 ticket=$4 suffix=$5 extra=${6:-}
  local runtime adapter prompt result events log rc timeout_seconds started elapsed executor=local reason
  local -a invocation
  runtime=$(ensure_runtime); adapter=$(provider_adapter "$provider")
  timeout_seconds=$(provider_timeout_seconds "$role" "$provider") || return 3
  prompt="$runtime/prompts/$ticket-$suffix.md"
  result="$runtime/results/$ticket-$suffix.json"
  events="$runtime/events/$ticket.ndjson"
  log="$runtime/logs/$ticket-$suffix.log"
  write_prompt "$role" "$worktree" "$ticket" "$prompt" "$extra"
  # Only workers leave this machine; reviewers and diagnosticians always run here.
  [[ $role != worker ]] || executor=$(ticket_executor "$ticket")
  local attempt=1
  while ((attempt <= 2)); do
  [[ ! -f $result ]] || cp -- "$result" "$result.previous"
  [[ ! -f $log ]] || cp -- "$log" "$log.previous"
  started=$SECONDS
  if [[ $executor == local ]]; then
    invocation=(bash "$adapter")
    event provider-started "role=$role timeout_seconds=$timeout_seconds attempt=$attempt" "$ticket"
  else
    mapfile -t invocation < <(remote_run_arguments "$executor" "$ticket")
    invocation=(bash "$AGENTIC_DIR/lib/remote-run.sh" "${invocation[@]}" --adapter "$adapter")
    event provider-started "role=$role timeout_seconds=$timeout_seconds attempt=$attempt executor=$executor" "$ticket"
  fi
  set +e
  # Own a separate session and reap descendants even when the adapter exits on
  # TERM before a stubborn child. Never signal the supervisor or foreign groups.
  AGENTIC_TICKET=$ticket AGENTIC_PROJECT=${PROJECT_NAME:-$(basename -- "$REPO_ROOT")} \
    python3 "$AGENTIC_DIR/lib/provider_deadline.py" "$timeout_seconds" \
    "${invocation[@]}" "$role" "$worktree" "$prompt" "$result" "$events" >"$log" 2>&1
  rc=$?
  set -e
  elapsed=$((SECONDS - started))
  sanitize_file "$log"; sanitize_file "$events"
  # The executor failed before its adapter started: the ticket runs here for the rest of the run, and the same
  # invocation is repeated at once without spending one of its two attempts.
  if [[ $executor != local ]] && ((rc == 75)); then
    reason=$(grep -m1 -o 'executor unavailable: .*' "$log" 2>/dev/null | head -c 300) || true
    event executor-unavailable "executor=$executor ${reason:-executor unavailable}; the ticket runs locally for the rest of this run" "$ticket"
    executor=local
    printf 'local\n' >"$runtime/state/$ticket.executor"
    continue
  fi
  # Every account of the provider is out of quota (the adapter exits 75 and says when one is back): the same
  # invocation waits for it and runs again, without spending an attempt.
  if [[ $executor == local ]] && ((rc == 75)) && grep -q 'accounts-back-at=' "$log" 2>/dev/null; then
    wait_for_quota "$ticket" "$log" "$role" || return 3
    continue
  fi
  if ((rc == 124)); then
    event provider-timeout "role=$role elapsed_seconds=$elapsed limit_seconds=$timeout_seconds; delta and evidence preserved; diagnose before explicit recovery; no automatic retry" "$ticket"
    return 3
  fi
  local contract_error='' valid=true
  if ((rc == 0)) && ! contract_error=$(python3 "$AGENTIC_DIR/providers/validate-result.py" "$AGENTIC_DIR/RESULT.schema.json" "$role" "$result" 2>&1 >/dev/null); then
    valid=false; contract_error=${contract_error:-invalid provider result}
  fi
  # Adapters validate before the runner; their log names the exact contract error.
  ((rc == 0)) || contract_error=$(grep -m1 -o 'invalid provider result: .*' "$log" 2>/dev/null | head -c 300) || true
  if ((rc != 0)) || ! $valid; then
    event provider-failed "$role provider failed; ${contract_error:-see sanitized log}" "$ticket"
    printf '\nYour prior invocation failed the provider contract%s. Return a complete canonical RESULT; a reviewer finding states message, reason and fix and names the automatic check that would have caught it as guard {kind, how}. Preserve existing delta.\n' "${contract_error:+ ($contract_error)}" >>"$prompt"
    attempt=$((attempt + 1))
    continue
  fi
  event provider-completed "role=$role elapsed_seconds=$elapsed" "$ticket"
  # The findings of a review, with the guard each one names, outlive the next review that overwrites this result.
  if [[ $role == reviewer ]]; then record_review_findings "$ticket" "$result" || true; fi
  printf '%s\n' "$result"
  return 0
  done
  event harness-error "provider unavailable after fresh re-invocation; delta preserved" "$ticket"
  return 3
}

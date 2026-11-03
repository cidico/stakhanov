#!/usr/bin/env bash
# Controlling a campaign's runner: run, stop, restart and watch, the supervisor that relaunches it, and the coordinator's
# decide and recover. Sourced by bin/campaign; it defines functions and variables and runs nothing.

# Campaign work yields the CPU to the desktop: the run drops to the lowest priority, and its detached supervisor
# moves to the user's background slice, which systemd weighs below the apps. Without a working user systemd (CI) only
# the priority applies.
yield_cpu() {
  renice -n 19 -p "$$" >/dev/null 2>&1 || true
}

background_scope() {
  BACKGROUND_SCOPE=()
  command -v systemd-run >/dev/null 2>&1 || return 0
  systemd-run --user --scope --quiet --collect -- true >/dev/null 2>&1 || return 0
  BACKGROUND_SCOPE=(systemd-run --user --scope --quiet --collect --slice=background.slice --unit="agentic-$1-$$" --)
}

prepare_agentic_snapshot() {
  local runtime=$1 target staging
  target="$runtime/agentic"; staging="$runtime/agentic.staging"
  rm -rf -- "$staging"; mkdir -p -- "$staging"
  require_committed_kit
  git -C "$REPO_ROOT" archive "$MAIN_BRANCH" .agentic | tar -x -C "$staging"
  rm -rf -- "$target"; mv -- "$staging/.agentic" "$target"; rm -rf -- "$staging"
  printf '%s\n' "$target"
}

# A claude campaign whose project names an account hook (AGENTIC_CLAUDE_ACCOUNTS) says when the hook is missing or off
# here: claude then runs in one account and stops at its usage limit.
account_hook_note() {
  local hook=${AGENTIC_CLAUDE_ACCOUNTS:-}
  [[ $1 == claude && -n $hook ]] || return 0
  if ! command -v "$hook" >/dev/null 2>&1; then
    note "Warning: the account hook $hook (AGENTIC_CLAUDE_ACCOUNTS) is not installed on $(machine_name): claude runs in its default account, with no other account to take over at its usage limit."
  elif ! "$hook" account enabled >/dev/null 2>&1; then
    note "Account hook $hook is off on $(machine_name): claude runs in its default account until it is on ($hook start)."
  fi
}

# The campaign's plan files that are not committed on its branch (modified, staged only, deleted or untracked), one path
# per line. A ticket worktree is born from the branch: what is not committed is not there for the worker.
uncommitted_plan_files() {
  local base entry
  base="campaigns/$1"
  while IFS= read -r -d '' entry; do
    printf '%s\n' "${entry:3}"
    # A rename or a copy carries its source as the next entry.
    [[ ${entry:0:1} != [RC] ]] || IFS= read -r -d '' entry || true
  done < <(git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all -- \
    "$base/SPEC.md" "$base/tickets/*.md" "$base/validation.json" "$base/codex-effort.json")
}

# Refuses to run a plan that is not committed: the worker of a ticket would not find its own ticket file.
assert_plan_committed() {
  local files
  files=$(uncommitted_plan_files "$1")
  [[ -z $files ]] && return 0
  printf 'campaign: the plan of %s is not committed on %s; a ticket worktree starts from the branch and would not have these files:\n' \
    "$1" "$(current_branch)" >&2
  sed 's/^/  /' <<<"$files" >&2
  printf "Commit them first: git add %s && git commit -m 'docs(agentic): plan of %s'\n" \
    "$(paste -sd' ' <<<"$files")" "$1" >&2
  exit 2
}

cmd_run() {
  assert_campaign_branch
  local provider='' mode=interactive workers=2 arg runtime slug child
  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --provider) (($#)) || die '--provider requires a value'; provider=$1; shift ;;
      --mode) (($#)) || die '--mode requires a value'; mode=$1; shift ;;
      --workers) (($#)) || die '--workers requires a value'; workers=$1; shift ;;
      *) die "unknown run option: $arg" ;;
    esac
  done
  [[ -n $provider ]] || die 'run requires --provider codex|claude|grok'
  [[ $mode == interactive || $mode == unattended ]] || die "invalid mode: $mode"
  [[ $workers =~ ^[1-3]$ ]] || die 'workers must be between 1 and 3'
  provider_preflight "$provider" "$mode"
  validation_repair_limit >/dev/null
  cmd_verify >/dev/null
  yield_cpu
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug")
  exec 6>"$runtime/launcher.lock"
  flock -x 6
  if runner_alive "$slug"; then
    if [[ $(desired_state "$slug") == stopped ]]; then
      set_desired_state "$slug" running
      event stop-cancelled 'run again before the runner stopped: it goes on starting tickets'
      note "The stop of $slug is cancelled: the runner goes on."
    fi
    note "Runner already active; attaching to $slug."
    cmd_status
    return
  fi
  [[ -z $(jq -r '.moving // ""' "$runtime/campaign.json" 2>/dev/null) ]] \
    || die "campaign $slug is moving to $(jq -r '.moving' "$runtime/campaign.json")"
  # Not for a runner that is already active (attaching): the engine commits ticket marks while it works.
  assert_plan_committed "$slug"
  set_desired_state "$slug" running
  ensure_supervisor
  # What a relaunch by the supervisor repeats: the provider, the workers and the AGENTIC_* settings of this run.
  jq -cn --arg provider "$provider" --arg mode "$mode" --argjson workers "$workers" --arg queue "${AGENTIC_QUEUE:-}" \
    '{provider:$provider,mode:$mode,workers:$workers,queue:(if $queue == "" then null else $queue end),
      env:($ENV | with_entries(select(.key | startswith("AGENTIC_")) | select(.key != "AGENTIC_SUPERVISED" and .key != "AGENTIC_QUEUE" and .key != "AGENTIC_SLOT" and .key != "AGENTIC_STATE")))}' \
    >"$runtime/run-config.json"
  chmod 600 "$runtime/run-config.json"
  touch "$runtime/events/campaign.ndjson"
  require_green_baseline "$runtime"
  local snapshot
  snapshot=$(prepare_agentic_snapshot "$runtime")
  # The engine runs from a snapshot of the main branch's committed .agentic: fixes reach every campaign on its next
  # run, and editing .agentic on the main branch never changes a script a running engine is reading.
  background_scope "campaign-$slug"
  AGENTIC_CAMPAIGN_ROOT=$REPO_ROOT "${BACKGROUND_SCOPE[@]}" setsid nohup "$snapshot/bin/campaign" _engine \
    "$provider" "$workers" >>"$runtime/logs/runner.log" 2>&1 </dev/null &
  child=$!
  printf '%s\n' "$child" >"$runtime/launcher.pid"
  chmod 600 "$runtime/launcher.pid"
  local observed=false attempt startup_rc=0
  for attempt in {1..50}; do
    if runner_alive "$slug"; then observed=true; break; fi
    kill -0 "$child" 2>/dev/null || break
    sleep 0.05
  done
  if ! $observed; then
    set +e
    wait "$child"
    startup_rc=$?
    set -e
    ((startup_rc == 0)) || die 'campaign runner failed during startup; inspect the sanitized runner log'
  fi
  flock -u 6
  if $observed; then
    note "Campaign runner started detached (pid $child)."
  else
    note 'Campaign runner completed during startup.'
  fi
  note "Worktree: $REPO_ROOT ($(machine_name))"
  note "Open: $(open_command "$REPO_ROOT" "$provider")"
  account_hook_note "$provider"
  if [[ $mode == interactive ]]; then
    # The follower is disposable: closing the UI never signals the detached engine.
    tail -n +1 --pid="$child" -f "$runtime/events/campaign.ndjson" || true
    cmd_status
  else
    note "Use 'campaign status' to attach."
  fi
}

# The pids to signal for the engine PID: every process of its systemd scope when it runs in one of its own (campaign run
# puts it there), else PID and its descendants.
engine_pids() {
  local pid=$1 cgroup
  cgroup=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup" 2>/dev/null) || cgroup=''
  if [[ $cgroup == */agentic-campaign-*.scope && -d /sys/fs/cgroup$cgroup ]]; then
    find "/sys/fs/cgroup$cgroup" -name cgroup.procs -exec cat {} + 2>/dev/null | grep -vx "$$" || true
    return
  fi
  ps -e -o pid=,ppid= | awk -v root="$pid" '
    { parent[$1] = $2; alive[$1] = 1 }
    END {
      keep[root] = 1
      do { changed = 0; for (p in parent) if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; changed = 1 } } while (changed)
      for (p in keep) if (p in alive) print p
    }'
}

# stop_engine PID: TERM to the engine and everything it started, KILL after 10 seconds to what is left.
stop_engine() {
  local pid=$1 pids attempt
  pids=$(engine_pids "$pid" | paste -sd' ')
  [[ -n $pids ]] || return 0
  IFS=' ' read -r -a pids <<<"$pids"
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for attempt in {1..50}; do
    [[ -n $(engine_pids "$pid") ]] || return 0
    sleep 0.2
  done
  pids=$(engine_pids "$pid" | paste -sd' ')
  [[ -z $pids ]] || { IFS=' ' read -r -a pids <<<"$pids"; kill -KILL "${pids[@]}" 2>/dev/null || true; }
}

cmd_stop() {
  assert_campaign_branch
  local now=false arg slug runtime pid=''
  for arg in "$@"; do
    case $arg in --now) now=true ;; *) die "unknown stop option: $arg" ;; esac
  done
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug")
  set_desired_state "$slug" stopped
  if ! runner_alive "$slug"; then
    note "The runner of $slug is not active; it stays stopped until campaign run."
    return
  fi
  if ! $now; then
    event stop-requested 'no new ticket starts; the runner stops when the running ones end'
    note "Stopping $slug: no new ticket starts, and the runner stops when the running ones end (stop --now: at once)."
    return
  fi
  { read -r pid <"$runtime/runner.pid"; } 2>/dev/null || pid=''
  [[ $pid =~ ^[0-9]+$ ]] || die "the runner of $slug holds its lock but its pid is unknown"
  stop_engine "$pid"
  for _ in {1..50}; do runner_alive "$slug" || break; sleep 0.2; done
  runner_alive "$slug" && die "the runner of $slug did not stop"
  rm -f -- "$runtime/runner.pid" "$runtime"/state/*.active
  event runner-stopped 'stopped at once on request; partial work stays in the ticket worktrees and the next run recovers it'
  note "Stopped $slug at once; the next run recovers the interrupted tickets."
}

# campaign restart [--now] [run options]: stop, wait for the runner, then run with the last run's provider and workers
# unless the options say otherwise.
cmd_restart() {
  assert_campaign_branch
  local now=false provider='' workers='' slug runtime config attempt
  local -a run_args=()
  while (($#)); do
    case $1 in
      --now) now=true; shift ;;
      --provider) (($# >= 2)) || die '--provider requires a value'; provider=$2; shift 2 ;;
      --workers) (($# >= 2)) || die '--workers requires a value'; workers=$2; shift 2 ;;
      *) die "unknown restart option: $1" ;;
    esac
  done
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug"); config="$runtime/run-config.json"
  [[ -n $provider || -f $config ]] || die "$slug never ran here: campaign run --provider NAME"
  [[ -n $provider ]] || provider=$(jq -r '.provider' "$config")
  [[ -n $workers ]] || workers=$(jq -r '.workers // 2' "$config" 2>/dev/null || printf '2')
  if $now; then cmd_stop --now; else cmd_stop; fi
  if runner_alive "$slug"; then
    note "Waiting for the running tickets of $slug to end..."
    while runner_alive "$slug"; do sleep "${AGENTIC_RESTART_POLL_SECONDS:-5}"; done
  fi
  # The last run's AGENTIC_* settings, unless this environment sets them.
  local assignment variable
  while IFS= read -r -d '' assignment; do
    variable=${assignment%%=*}
    [[ -n ${!variable+x} ]] || export "$assignment"
  done < <(jq -j '.env // {} | to_entries[] | "\(.key)=\(.value)\u0000"' "$config" 2>/dev/null || true)
  run_args=(--provider "$provider" --workers "$workers" --mode unattended)
  cmd_run "${run_args[@]}"
}

cmd_watch() {
  assert_campaign_branch
  exec "$AGENTIC_DIR/bin/campaign-watch" --slug "$(campaign_slug)" "$@"
}

# The supervisor of this repository's campaigns on this machine: a systemd user service, installed and refreshed by
# campaign run, that relaunches a campaign that should be running (after a technical pause, a crash or a reboot).
supervisor_unit() { printf 'agentic-supervisor-%s.service\n' "$(repo_id)"; }

ensure_supervisor() {
  [[ ${AGENTIC_SUPERVISOR:-} != off && -z ${AGENTIC_SUPERVISED:-} ]] || return 0
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 || return 0
  local tree unit dir file snapshot content
  tree=$(main_worktree); [[ -n $tree ]] || return 0
  unit=$(supervisor_unit); dir="$(runtime_base)/supervisor"; file="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit"
  mkdir -p -- "$dir" "$(dirname -- "$file")"; chmod 700 "$dir"
  snapshot=$(prepare_agentic_snapshot "$dir")
  content="[Unit]
Description=Stakhanov supervisor of the campaigns of $tree

[Service]
WorkingDirectory=$tree
Environment=AGENTIC_CACHE=$(dirname -- "$(runtime_base)")
ExecStart=$snapshot/bin/campaign _supervise
Restart=always
RestartSec=30

[Install]
WantedBy=default.target"
  if [[ ! -f $file || $(<"$file") != "$content" ]]; then
    printf '%s\n' "$content" >"$file"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  systemctl --user enable "$unit" >/dev/null 2>&1 || true
  systemctl --user restart "$unit" >/dev/null 2>&1 || note "Warning: the supervisor $unit did not start"
}

supervise_loop() {
  local file once=${1:-}
  export AGENTIC_SUPERVISED=1 PATH="$PATH:$HOME/.local/bin"
  while :; do
    for file in "$(runtime_base)"/*/campaign.json; do
      [[ -f $file ]] && { supervise_campaign "$file" || true; }
    done
    [[ $once != --once ]] || return 0
    sleep "${AGENTIC_SUPERVISOR_POLL_SECONDS:-60}"
  done
}

# One campaign: when it should run, has run before, and its runner is down, it is relaunched with its last settings after
# the relaunch delay, three times at most without a ticket ending. Waiting on the coordinator, done, finalizing or in a
# queue (the queue relaunches its own), it is left alone.
supervise_campaign() {
  local file=$1 runtime slug tree config status state done_now relaunches=0 done_before=0 since=0 now queue
  runtime=$(dirname -- "$file"); slug=$(jq -r '.slug' "$file"); tree=$(jq -r '.worktree' "$file")
  config="$runtime/run-config.json"; state="$runtime/state/supervisor"
  [[ $(jq -r '.desired // "running"' "$file") == running && -f $config && -d $tree && ! -f $runtime/finalize.json ]] || return 0
  if runner_alive "$slug"; then rm -f -- "$state"; return 0; fi
  queue=$(jq -r '.queue // ""' "$config")
  if [[ -n $queue && -f $(queue_dir "$queue")/pid ]] && kill -0 "$(<"$(queue_dir "$queue")/pid")" 2>/dev/null; then return 0; fi
  status=$(cd "$tree" && "$AGENTIC_DIR/bin/campaign" status --json 2>/dev/null) || return 0
  jq -e 'all(.tickets[]; .status == "done" or .required == false)' >/dev/null <<<"$status" && return 0
  jq -e 'any(.tickets[]; .status == "blocked" or .status == "needs-human") or (.decisions | length > 0)' >/dev/null <<<"$status" && return 0
  done_now=$(jq '[.tickets[] | select(.status == "done")] | length' <<<"$status")
  now=$(date +%s)
  [[ ! -f $state ]] || read -r relaunches done_before since <"$state" || true
  if ((done_now > done_before)); then relaunches=0; done_before=$done_now; fi
  ((since > 0)) || since=$now
  printf '%s %s %s\n' "$relaunches" "$done_before" "$since" >"$state"
  ((relaunches < 3)) || return 0
  ((now - since >= ${AGENTIC_SUPERVISOR_DELAY_SECONDS:-300})) || return 0
  relaunches=$((relaunches + 1))
  printf '%s %s %s\n' "$relaunches" "$done_before" "$now" >"$state"
  (cd "$tree" && REPO_ROOT=$tree && event supervisor-relaunch "the runner was down; relaunch $relaunches/3 with the last run's settings")
  (
    cd "$tree" || exit 1
    while IFS= read -r -d '' assignment; do export "$assignment"; done < <(jq -j '.env // {} | to_entries[] | "\(.key)=\(.value)\u0000"' "$config")
    exec "$AGENTIC_DIR/bin/campaign" run --provider "$(jq -r '.provider' "$config")" --workers "$(jq -r '.workers // 2' "$config")" \
      --mode unattended
  ) >>"$runtime/logs/supervisor.log" 2>&1 </dev/null || true
}

cmd_decide() {
  assert_campaign_branch
  (($# == 2)) || die 'decide requires TICKET and retry|block|cancel'
  local ticket=$1 decision=$2 runtime file config provider workers target
  runtime=$(ensure_runtime); file="$runtime/decisions/$ticket.json"
  [[ -f $file ]] || die "no pending decision for $ticket"
  jq -e --arg decision "$decision" '.options | index($decision)' "$file" >/dev/null || die "invalid decision: $decision"
  if [[ $ticket == FINALIZE ]]; then
    jq -cn --arg decision "$decision" '{stage:"needs-human",decision:$decision}' >"$runtime/finalize.json"
    rm -f -- "$file"
    event decision-applied "$decision" FINALIZE
    return
  fi
  case "$decision" in
    retry) target=todo ;;
    block) target=blocked ;;
    cancel) target=needs-human ;;
  esac
  # A status that is already the target (after `recover`, for example) has nothing to commit.
  if [[ $(ticket_json "$ticket" | jq -r '.status') == "$target" ]]; then
    note "$ticket is already $target; nothing to change in its status."
  else
    mark_ticket "$ticket" "$target"
    note "$ticket marked $target."
  fi
  rm -f -- "$file"
  event decision-applied "$decision" "$ticket"
  note "Decision '$decision' applied to $ticket."
  if [[ $decision == retry ]] && ! runner_alive "$(campaign_slug)"; then
    config="$runtime/run-config.json"
    [[ -f $config ]] || die 'cannot resume: prior runner configuration is missing'
    provider=$(jq -er '.provider' "$config"); workers=$(jq -er '.workers' "$config")
    local mode
    mode=$(jq -er '.mode // "unattended"' "$config")
    cmd_run --provider "$provider" --workers "$workers" --mode "$mode"
  fi
}

cmd_recover() {
  assert_campaign_branch
  (($# == 1)) || die 'recover requires one ticket id'
  local ticket=$1 runtime worktree
  runtime=$(ensure_runtime)
  if runner_alive "$(campaign_slug)" && [[ -f "$runtime/state/$ticket.active" ]]; then
    die 'cannot recover a ticket whose worker is active'
  fi
  ticket_json "$ticket" >/dev/null
  worktree="$runtime/worktrees/$ticket"
  [[ -d $worktree && $(git -C "$worktree" symbolic-ref --quiet --short HEAD) == "agentic/$(campaign_slug)/$ticket" ]] || die 'recovery worktree ownership mismatch'
  if [[ $(ticket_json "$ticket" | jq -r '.status') != todo ]]; then
    mark_ticket "$ticket" todo
  fi
  rm -f -- "$runtime/state/$ticket.active"
  # A ticket the base check refused is checked again: the coordinator changed what it runs on or its validation. One it
  # passed or skipped is not.
  if [[ $(jq -r '.outcome // ""' "$runtime/state/$ticket.validate-base" 2>/dev/null) == refused ]]; then
    rm -f -- "$runtime/state/$ticket.validate-base"
  fi
  printf 'explicit coordinator recovery\n' >"$runtime/state/$ticket.retry"
  chmod 600 "$runtime/state/$ticket.retry"
  event recovery-scheduled 'existing delta preserved; validate then fresh review' "$ticket"
}

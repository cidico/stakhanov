#!/usr/bin/env bash
# The campaign queue: campaigns run in sequence, resumable. Sourced by bin/campaign; it defines functions and variables and
# runs nothing.

# ---------------------------------------------------------------------------------------------------------
# Campaign queue: runs campaigns in sequence (init → run → finalize), resuming where it stopped. It waits
# for the coordinator only for human decisions, exhausted automatic recoveries or a failed finalize.
# ---------------------------------------------------------------------------------------------------------
queue_dir() { printf '%s/queue/%s\n' "$(runtime_base)" "$1"; }
queue_poll() { printf '%s\n' "${AGENTIC_QUEUE_POLL_SECONDS:-60}"; }
queue_relaunch_delay() { printf '%s\n' "${AGENTIC_QUEUE_RELAUNCH_SECONDS:-300}"; }
queue_campaign_bin() { printf '%s/bin/campaign\n' "$AGENTIC_DIR"; }

campaign_worktree_of() {
  git -C "$REPO_ROOT" worktree list --porcelain | awk -v branch="refs/heads/campaign/$1" '
    /^worktree / {path=substr($0,10)} $0 == "branch " branch {print path}'
}

in_campaign_tree() { local tree=$1; shift; (cd "$tree" && "$(queue_campaign_bin)" "$@"); }

queue_status_write() {
  local name=$1 state=$2 message=$3 current=${4:-} dir
  dir=$(queue_dir "$name")
  jq -n --arg name "$name" --arg state "$state" --arg message "$message" --arg current "$current" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile finalized "$dir/done.json" --slurpfile definition "$dir/definition.json" \
    '{name:$name, state:$state, message:$message, current:(if $current == "" then null else $current end),
      updated:$updated, campaigns:[$definition[0].campaigns[].slug], finalized:$finalized[0]}' >"$dir/status.json.tmp"
  mv -f -- "$dir/status.json.tmp" "$dir/status.json"
  printf '%s %s %s\n' "$(date '+%F %T')" "$state" "$message" >>"$dir/queue.log"
}

queue_path() {
  local base=$1 value=$2
  [[ $value == /* ]] && printf '%s\n' "$value" || printf '%s/%s\n' "$base" "$value"
}

queue_needs_coordinator() {
  in_campaign_tree "$1" status --json | jq -e 'any(.tickets[]; .status == "blocked" or .status == "needs-human") or (.decisions | length > 0)' >/dev/null
}

queue_runner_active() { in_campaign_tree "$1" status --json | jq -e '.runner.active' >/dev/null; }

queue_init_campaign() {
  local name=$1 index=$2 dir definition base slug spec tickets validation main_tree tree file
  dir=$(queue_dir "$name"); definition="$dir/definition.json"; base=$(<"$dir/base-dir")
  slug=$(jq -r ".campaigns[$index].slug" "$definition")
  spec=$(queue_path "$base" "$(jq -r ".campaigns[$index].spec" "$definition")")
  tickets=$(queue_path "$base" "$(jq -r ".campaigns[$index].tickets" "$definition")")
  validation=$(queue_path "$base" "$(jq -r ".campaigns[$index].validation" "$definition")")
  main_tree=$(main_worktree)
  [[ -n $main_tree && $(git -C "$main_tree" symbolic-ref --quiet --short HEAD) == "$MAIN_BRANCH" ]] || { queue_status_write "$name" stopped "$slug: no $MAIN_BRANCH worktree to initialize from" "$slug"; return 1; }
  if ! (cd "$main_tree" && "$(queue_campaign_bin)" init "$spec" --slug "$slug") >>"$dir/queue.log" 2>&1; then
    queue_status_write "$name" stopped "$slug: init failed (see queue.log)" "$slug"; return 1
  fi
  tree=$(campaign_worktree_of "$slug")
  mkdir -p -- "$tree/campaigns/$slug/tickets"
  cp -- "$tickets"/*.md "$tree/campaigns/$slug/tickets/"
  cp -- "$validation" "$tree/campaigns/$slug/validation.json"
  while IFS= read -r file; do
    [[ -n $file ]] && cp -- "$(queue_path "$base" "$file")" "$tree/campaigns/$slug/"
  done < <(jq -r ".campaigns[$index].files // [] | .[]" "$definition")
  git -C "$tree" add -- "campaigns/$slug"
  git_hooked -C "$tree" commit -q -m "docs(agentic): define $slug tickets and validation"
  if ! in_campaign_tree "$tree" verify >>"$dir/queue.log" 2>&1; then
    queue_status_write "$name" stopped "$slug: verify failed (see queue.log)" "$slug"; return 1
  fi
}

queue_run_until_done() {
  local name=$1 slug=$2 tree=$3 provider=$4 workers=$5 dir state relaunches=0 done_before=0 done_now
  dir=$(queue_dir "$name")
  # A finalize checkpoint means the campaign already ran to the end: the cleanup removed its planning files from the
  # branch, so status and run would refuse it forever.
  [[ -f "$(runtime_dir "$slug")/finalize.json" ]] && return 0
  while :; do
    if ! queue_runner_active "$tree"; then
      in_campaign_tree "$tree" status --json | jq -e 'all(.tickets[]; .status == "done" or .required == false)' >/dev/null && return 0
      if ! AGENTIC_QUEUE=$name in_campaign_tree "$tree" run --provider "$provider" --workers "$workers" --mode unattended >>"$dir/queue.log" 2>&1 9>&-; then
        queue_status_write "$name" waiting "$slug: the runner refused to start (red baseline or provider preflight); retrying" "$slug"
        sleep "$(queue_relaunch_delay)"; continue
      fi
    fi
    queue_status_write "$name" running "$slug running" "$slug"
    while queue_runner_active "$tree"; do sleep "$(queue_poll)"; done
    state=$(in_campaign_tree "$tree" status --json)
    jq -e 'all(.tickets[]; .status == "done" or .required == false)' >/dev/null <<<"$state" && return 0
    if queue_needs_coordinator "$tree"; then
      queue_status_write "$name" waiting "$slug: coordinator must resolve $(jq -c '[.tickets[] | select(.status == "blocked" or .status == "needs-human") | .id]' <<<"$state")" "$slug"
      until queue_runner_active "$tree" || ! queue_needs_coordinator "$tree"; do sleep "$(queue_poll)"; done
      relaunches=0; continue
    fi
    done_now=$(jq '[.tickets[] | select(.status == "done")] | length' <<<"$state")
    if ((done_now > done_before)); then relaunches=0; done_before=$done_now; fi
    if ((relaunches >= 3)); then
      queue_status_write "$name" waiting "$slug: paused by technical errors 3 times without progress; coordinator must diagnose" "$slug"
      until queue_runner_active "$tree"; do sleep "$(queue_poll)"; done
      relaunches=0; continue
    fi
    relaunches=$((relaunches + 1))
    queue_status_write "$name" running "$slug paused by technical errors; relaunch $relaunches/3" "$slug"
    sleep "$(queue_relaunch_delay)"
  done
}

queue_finalize() {
  local name=$1 slug=$2 tree=$3 dir main_tree signature last=''
  dir=$(queue_dir "$name"); main_tree=$(main_worktree)
  # The campaign branch, not its worktree, says the campaign is not finalized yet: a worktree detached by a manual
  # rebase still holds the whole campaign.
  while git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$slug"; do
    if [[ -n $(main_dirty_overlap "$main_tree" "$tree" "$slug") ]]; then
      queue_status_write "$name" waiting "$slug is ready to finalize but the main worktree has uncommitted changes in its files" "$slug"
      sleep "$(queue_poll)"; continue
    fi
    signature="$(git -C "$main_tree" rev-parse HEAD) $(git -C "$tree" rev-parse HEAD)"
    if [[ $signature != "$last" ]]; then
      queue_status_write "$name" finalizing "$slug finalizing (final validation)" "$slug"
      in_campaign_tree "$tree" finalize >>"$dir/queue.log" 2>&1 && return 0
      last=$signature
      queue_status_write "$name" waiting "$slug: finalize failed (see queue.log); retried when $MAIN_BRANCH or the campaign changes" "$slug"
    fi
    sleep "$(queue_poll)"
  done
}

queue_mark_done() {
  local name=$1 slug=$2 message=$3 dir
  dir=$(queue_dir "$name")
  jq --arg slug "$slug" '. + [$slug]' "$dir/done.json" >"$dir/done.json.tmp" && mv -f -- "$dir/done.json.tmp" "$dir/done.json"
  queue_status_write "$name" running "$slug $message" "$slug"
}

# Finalized outside the queue (by hand): the marker is there and the campaign branch is gone.
queue_finalized_elsewhere() {
  [[ -f "$(finalized_marker "$1")" ]] && ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$1"
}

queue_loop() {
  (($# == 1)) || die 'invalid queue invocation'
  local name=$1 dir definition count index slug tree provider workers
  dir=$(queue_dir "$name"); definition="$dir/definition.json"
  exec 9>"$dir/lock"; flock -n 9 || die "queue $name is already running"
  printf '%s\n' "$$" >"$dir/pid"
  # Campaign worktrees disappear on finalize; the queue always works from the main worktree.
  REPO_ROOT=$(main_worktree); [[ -n $REPO_ROOT ]] || die "queue requires a $MAIN_BRANCH worktree"
  cd -- "$REPO_ROOT"
  provider=$(jq -r '.provider' "$definition"); workers=$(jq -r '.workers // 2' "$definition")
  count=$(jq '.campaigns | length' "$definition")
  for ((index = 0; index < count; index++)); do
    slug=$(jq -r ".campaigns[$index].slug" "$definition")
    jq -e --arg slug "$slug" 'index($slug) != null' "$dir/done.json" >/dev/null && continue
    if queue_finalized_elsewhere "$slug"; then queue_mark_done "$name" "$slug" "was already finalized into $MAIN_BRANCH (outside the queue)"; continue; fi
    tree=$(campaign_worktree_of "$slug")
    if [[ -z $tree ]]; then queue_init_campaign "$name" "$index" || return 1; tree=$(campaign_worktree_of "$slug"); fi
    queue_run_until_done "$name" "$slug" "$tree" "$provider" "$workers"
    queue_finalize "$name" "$slug" "$tree"
    queue_mark_done "$name" "$slug" "finalized into $MAIN_BRANCH"
  done
  queue_status_write "$name" done "all campaigns finalized into $MAIN_BRANCH (nothing pushed)"
  rm -f -- "$dir/pid"
}

queue_start() {
  local file='' foreground=false arg name dir snapshot
  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --foreground) foreground=true ;;
      --*) die "unknown queue start option: $arg" ;;
      *) [[ -z $file ]] || die 'queue start accepts one definition file'; file=$arg ;;
    esac
  done
  [[ -n $file && -f $file ]] || die 'queue start requires a queue definition file'
  file=$(realpath -- "$file")
  jq -e --argjson reserved "$(reserved_slugs_json)" '(.name | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and (.provider | type == "string")
    and (.campaigns | type == "array" and length > 0)
    and all(.campaigns[]; (.slug | type == "string" and test("^[a-z0-9][a-z0-9-]*$") and (. as $slug | $reserved | index($slug) | not))
      and (.spec | type == "string") and (.tickets | type == "string") and (.validation | type == "string"))' "$file" >/dev/null \
    || die "queue definition is malformed (name, provider, campaigns[].slug/spec/tickets/validation; a slug cannot be one of the reserved names: ${RESERVED_SLUGS[*]})"
  name=$(jq -r '.name' "$file"); dir=$(queue_dir "$name")
  mkdir -p -- "$dir"; chmod 700 "$dir"
  [[ -f $dir/done.json ]] || printf '[]\n' >"$dir/done.json"
  cp -- "$file" "$dir/definition.json"; dirname -- "$file" >"$dir/base-dir"
  yield_cpu
  if $foreground; then queue_loop "$name"; return; fi
  ( flock -n 9 ) 9>"$dir/lock" || die "queue $name is already running"
  snapshot=$(prepare_agentic_snapshot "$dir")
  background_scope "queue-$name"
  "${BACKGROUND_SCOPE[@]}" setsid nohup "$snapshot/bin/campaign" _queue "$name" >>"$dir/queue.log" 2>&1 </dev/null &
  note "Queue $name started detached (pid $!). Follow it with: campaign queue status $name"
}

queue_status() {
  local json=false name='' file
  while (($#)); do case "$1" in --json) json=true ;; *) name=$1 ;; esac; shift; done
  if [[ -n $name ]]; then file="$(queue_dir "$name")/status.json"; [[ -f $file ]] || die "unknown queue: $name"
  else file=''; fi
  if $json; then
    if [[ -n $file ]]; then cat -- "$file"; else (cat "$(runtime_base)"/queue/*/status.json 2>/dev/null || true) | jq -s '.'; fi
    return
  fi
  for file in ${file:-$(runtime_base)/queue/*/status.json}; do
    [[ -f $file ]] || continue
    jq -r '"Queue \(.name): \(.state) — \(.message)\n  campaigns: \(.campaigns | join(" → "))\n  finalized: \(.finalized | join(", "))\n  updated: \(.updated)"' "$file"
  done
}

queue_stop() {
  local name=${1:-} dir pid
  [[ -n $name ]] || die 'queue stop requires a queue name'
  dir=$(queue_dir "$name"); [[ -f $dir/pid ]] || die "queue $name is not running"
  # The detached queue leads its own process group; campaign engines run in their own sessions and keep going.
  pid=$(<"$dir/pid"); kill -- "-$pid" 2>/dev/null || kill -- "$pid" 2>/dev/null || true; rm -f -- "$dir/pid"
  queue_status_write "$name" stopped 'stopped by the coordinator; campaign runners were not touched'
}

cmd_queue() {
  local action=${1:-status}
  (($#)) && shift
  case "$action" in
    start) queue_start "$@" ;;
    status) queue_status "$@" ;;
    stop) queue_stop "$@" ;;
    *) die "unknown queue action: $action (start|status|stop)" ;;
  esac
}

#!/usr/bin/env bash
# Tasks on this machine (see "Tasks" in README.md): campaign task new, list, status, log, diff, stop, restart, fix, accept
# and drop. A task is a campaign of one ticket whose plan lives in its runtime (cmd_task_plan of lib/plan.sh writes it from
# the brief): these commands reach it by its name from any worktree of the project and drive it with the commands of every
# campaign; accept lands its delta in the main branch as one commit, under main.lock. Sourced by bin/campaign for the task
# command; it defines functions and variables and runs nothing.

# The one ticket of every task (lib/task_plan.py).
TASK_TICKET=T-001

task_usage() {
  cat <<'EOF'
Usage: campaign task <command> [options]

  new BRIEF [--base REV] [--context FILE]... [--no-start]
                                  Create the task of BRIEF from REV (default: the main branch) and run it
  list [--json]                   The tasks of this machine: state, phase, base, round and age
  status NAME [--json]            The task's state, then its campaign's status
  log NAME [--follow]             The events of the task's current round (--follow: until its runner stops)
  diff NAME [GIT DIFF OPTIONS]    The worker's delta: git diff <base> campaign/<name>
  stop NAME [--now]               Start no new round (--now: stop at once)
  restart NAME [--now]            Stop, then run again with the brief's model, effort and deadline
  fix NAME (--note TEXT | --brief FILE) [--rebase]
                                  A new round on the same branch with the coordinator's findings; --rebase moves the base
                                  to the main branch, re-applies the delta and has an integration repair resolve it
  accept NAME [--body TEXT]       Land the delivered task in the main branch as one commit (rebase, regen, validation,
                                  fast-forward), then clean it up
  drop NAME                       Stop the task and remove its worktrees, branches and runtime (history archived)

NAME is the brief's id in lower case (GRD-002 is grd-002).
EOF
}

cmd_task() {
  local command=${1:-}
  (($#)) && shift
  case $command in
    new) task_new "$@" ;;
    list) task_list "$@" ;;
    status) task_status "$@" ;;
    log) task_log "$@" ;;
    diff) task_diff "$@" ;;
    stop) task_stop "$@" ;;
    restart) task_restart "$@" ;;
    fix) task_fix "$@" ;;
    accept) task_accept "$@" ;;
    drop) task_drop "$@" ;;
    '' | help | -h | --help) task_usage ;;
    *) task_usage >&2; die "unknown task command: $command" ;;
  esac
}

# task_name NAME: the name of a task, its brief's id in lower case.
task_name() {
  local name=${1,,}
  validate_slug "$name"
  printf '%s\n' "$name"
}

# task_enter NAME [--allow-missing]: the task NAME of this machine becomes this process's campaign: its campaign worktree
# is REPO_ROOT and the current folder, so the campaign's functions (status, stop, run, events, the plan in the runtime)
# act on it. Sets TASK_SLUG, TASK_RUNTIME, TASK_TREE (the campaign worktree) and TASK_PROJECT_ROOT (the worktree the
# command started in). With --allow-missing a task whose campaign worktree is gone is entered too (for drop).
task_enter() {
  local slug runtime file
  [[ -n ${1:-} ]] || die 'a task command needs the task NAME (campaign task list)'
  slug=$(task_name "$1")
  runtime=$(runtime_dir "$slug"); file="$runtime/campaign.json"
  [[ -f $file && $(jq -r '.kind // ""' "$file" 2>/dev/null) == task ]] || die "no task named $slug on $(machine_name) (campaign task list)"
  TASK_SLUG=$slug TASK_RUNTIME=$runtime TASK_PROJECT_ROOT=$REPO_ROOT
  TASK_TREE=$(jq -r '.worktree' "$file")
  if [[ -d $TASK_TREE ]]; then
    REPO_ROOT=$TASK_TREE
    cd -- "$TASK_TREE"
  elif [[ ${2:-} != --allow-missing ]]; then
    die "the worktree of task $slug is missing ($TASK_TREE); campaign task drop $slug removes what is left"
  fi
}

task_json() { jq -r "$1" "$TASK_RUNTIME/campaign.json"; }

# task_lock: takes the task's launcher.lock on descriptor 6, as campaign run takes it, so no run starts meanwhile; a task
# that an accept or a drop removed while this waited is gone.
task_lock() {
  exec 6>"$TASK_RUNTIME/launcher.lock"
  flock -x 6
  [[ -f $TASK_RUNTIME/campaign.json ]] || die "task $TASK_SLUG is gone: an accept or a drop removed it meanwhile"
}

# task_update FILTER [JQ OPTION...]: rewrites the task's campaign.json through the jq FILTER.
task_update() {
  local file="$TASK_RUNTIME/campaign.json" filter=$1
  shift
  jq "$@" "$filter" "$file" >"$file.tmp" && chmod 600 "$file.tmp" && mv -f -- "$file.tmp" "$file"
}

task_ticket_tree() { printf '%s/worktrees/%s\n' "$TASK_RUNTIME" "$TASK_TICKET"; }
task_ticket_status() { ticket_json "$TASK_TICKET" | jq -r '.status'; }

# The commit the task's delta starts from: the base of its campaign.json while it is an ancestor of the task's branch,
# else where the branch leaves the main branch.
task_base() {
  local base tip
  tip=$(git -C "$REPO_ROOT" rev-parse "campaign/$TASK_SLUG")
  base=$(task_json '.base // ""')
  if [[ -n $base ]] && git -C "$REPO_ROOT" merge-base --is-ancestor "$base" "$tip" 2>/dev/null; then
    printf '%s\n' "$base"
  else
    git -C "$REPO_ROOT" merge-base "$MAIN_BRANCH" "$tip"
  fi
}

# The brief's model, effort and deadline for the task's worker, exported for its run; campaign run keeps them in
# run-config.json for the restarts and the supervisor.
task_worker_env() {
  local task="$TASK_RUNTIME/plan/task.json" model effort minutes
  model=$(jq -r '.model // ""' "$task"); effort=$(jq -r '.effort // ""' "$task"); minutes=$(jq -r '.timeout_minutes // ""' "$task")
  [[ -z $model ]] || export AGENTIC_CLAUDE_WORKER_MODEL=$model
  [[ -z $effort ]] || export AGENTIC_CLAUDE_WORKER_EFFORT=$effort
  [[ -z $minutes ]] || export AGENTIC_WORKER_TIMEOUT_SECONDS=$((minutes * 60))
}

# task_start: runs the entered task as `campaign run --provider claude --workers 1 --mode unattended`, with the brief's
# settings.
task_start() {
  task_worker_env
  cmd_run --provider claude --workers 1 --mode unattended
}

# --- The worktree of a task: its context and links, never committed. ----------------------------------------------

# task_link_target PATH: a path of task_links, with ~ expanded on this machine.
task_link_target() {
  case $1 in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# task_links: "name<TAB>target" for every entry of task_links, its target resolved here. The command stops, naming it,
# at a target that does not exist on this machine.
task_links() {
  local name path target
  while IFS=$'\t' read -r name path; do
    [[ -n $name ]] || continue
    target=$(task_link_target "$path")
    [[ -e $target ]] || die "task_links of $PROJECT_CONFIG_SOURCE: $name points to $target, which does not exist on $(machine_name); create it there (or change task_links) first"
    printf '%s\t%s\n' "$name" "$target"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$PROJECT_TASK_LINKS")
}

# task_link TREE: the links of task_links at the root of TREE.
task_link() {
  local tree=$1 name target links
  links=$(task_links)
  while IFS=$'\t' read -r name target; do
    [[ -n $name ]] || continue
    [[ -L $tree/$name || ! -e $tree/$name ]] || die "cannot link $name at the root of $tree: a file of that name is there"
    ln -sfn -- "$target" "$tree/$name"
  done <<<"$links"
}

# task_exclude: .task/ and the names of task_links in the clone's info/exclude, which every worktree reads, so that they
# never enter a commit.
task_exclude() {
  local common file line
  local -a lines=(/.task)
  common=$(git -C "$REPO_ROOT" rev-parse --git-common-dir)
  [[ $common == /* ]] || common="$REPO_ROOT/$common"
  file="$common/info/exclude"
  mkdir -p -- "$common/info"
  [[ -f $file ]] || : >"$file"
  while IFS= read -r line; do [[ -z $line ]] || lines+=("/$line"); done < <(jq -r 'keys[]' <<<"$PROJECT_TASK_LINKS")
  for line in "${lines[@]}"; do
    grep -Fxq -- "$line" "$file" && continue
    if [[ -s $file && -n $(tail -c 1 -- "$file") ]]; then printf '\n' >>"$file"; fi
    grep -Fxq -- '# campaign task: the context and links of a task worktree' "$file" \
      || printf '%s\n' '# campaign task: the context and links of a task worktree' >>"$file"
    printf '%s\n' "$line" >>"$file"
  done
}

# task_ticket_checkout: the task's ticket worktree as the engine makes it, when it is missing: its branch
# agentic/<name>/T-001, made from campaign/<name> when it does not exist yet.
task_ticket_checkout() {
  local tree branch="agentic/$TASK_SLUG/$TASK_TICKET"
  tree=$(task_ticket_tree)
  [[ ! -d $tree ]] || return 0
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git_hooked -C "$REPO_ROOT" worktree add --quiet "$tree" "$branch"
  else
    git_hooked -C "$REPO_ROOT" worktree add --quiet -b "$branch" "$tree" "campaign/$TASK_SLUG"
  fi
}

# task_mount: the task's ticket worktree (task_ticket_checkout) with .task/ (TASK.md and the context files of task new) and
# the links of task_links at its root.
task_mount() {
  local tree
  tree=$(task_ticket_tree)
  task_exclude
  task_ticket_checkout
  mkdir -p -- "$tree/.task"
  cp -a -- "$TASK_RUNTIME/context/." "$tree/.task/"
  task_link "$tree"
}

# task_remove_worktree TREE: removes a worktree of the task's runtime, whatever it holds.
task_remove_worktree() {
  local tree=$1
  case $tree in "$TASK_RUNTIME"/worktrees/?*) ;; *) die "unsafe task worktree path: $tree" ;; esac
  if git -C "$TASK_PROJECT_ROOT" worktree list --porcelain | grep -Fxq -- "worktree $tree"; then
    keep_task_result "$TASK_SLUG" "$tree"
    git -C "$TASK_PROJECT_ROOT" worktree remove --force -- "$tree"
  fi
  rm -rf -- "$tree"
}

# --- task new ------------------------------------------------------------------------------------------------------

task_new() {
  local brief='' base_ref=$MAIN_BRANCH start=true slug runtime base file name seen tracked id title
  local -a contexts=() names=() links=()
  while (($#)); do
    case $1 in
      --base) (($# >= 2)) || die '--base requires a revision'; base_ref=$2; shift 2 ;;
      --context) (($# >= 2)) || die '--context requires a file'; contexts+=("$2"); shift 2 ;;
      --no-start) start=false; shift ;;
      -*) die "unknown task new option: $1" ;;
      *) [[ -z $brief ]] || die 'task new takes one BRIEF'; brief=$1; shift ;;
    esac
  done
  [[ -n $brief ]] || die 'task new needs a BRIEF (campaign task --help)'
  [[ $brief == /* ]] || brief="$PWD/$brief"
  [[ -f $brief ]] || die "brief not found: $brief"
  for file in "${!contexts[@]}"; do
    [[ ${contexts[file]} == /* ]] || contexts[file]="$PWD/${contexts[file]}"
    [[ -e ${contexts[file]} ]] || die "context file not found: ${contexts[file]}"
    name=$(basename -- "${contexts[file]}")
    [[ $name != TASK.md && $name != RESULT.md ]] || die "a context file cannot be named $name: .task/$name belongs to the task"
    for seen in "${names[@]}"; do
      [[ $seen != "$name" ]] || die "two context files are named $name: .task/ holds one of each name"
    done
    names+=("$name")
  done
  require_committed_kit
  slug=$(python3 "$TASK_PLAN_TOOL" slug "$brief") || exit 2
  (validate_slug "$slug") || die "invalid brief $brief: its id does not make a valid task name ($slug)"
  runtime=$(runtime_dir "$slug")
  [[ ! -e $runtime ]] || die "a task or campaign named $slug already exists on $(machine_name) ($runtime); campaign task list"
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$slug" ||
     [[ -n $(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' "refs/heads/agentic/$slug/") ]]; then
    die "a task or campaign named $slug already exists on $(machine_name): its branch campaign/$slug (or agentic/$slug/*) is there"
  fi
  base=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$base_ref^{commit}") || die "--base $base_ref is not a commit of this repository"
  # What the task brings into its worktree can never be a file of its base.
  mapfile -t links < <(jq -r 'keys[]' <<<"$PROJECT_TASK_LINKS")
  tracked=$(git -C "$REPO_ROOT" ls-tree --name-only "$base" -- .task "${links[@]}" | paste -sd, -)
  [[ -z $tracked ]] || die "$base_ref holds $tracked, the name of a task's context (.task) or of a link of task_links"
  task_links >/dev/null
  if [[ -n $PROJECT_TASK_PREAMBLE ]]; then
    git -C "$REPO_ROOT" cat-file -e "$MAIN_BRANCH:$PROJECT_TASK_PREAMBLE" 2>/dev/null \
      || die "task_preamble of $PROJECT_CONFIG_SOURCE is $PROJECT_TASK_PREAMBLE, which $MAIN_BRANCH does not hold: commit it there"
  fi

  # From here a failure removes whatever was created.
  TASK_NEW_SLUG=$slug TASK_NEW_ROOT=$REPO_ROOT
  trap task_new_abort EXIT
  runtime=$(ensure_runtime "$slug")
  (cmd_task_plan "$brief" "$runtime/plan") >/dev/null
  cp -- "$brief" "$runtime/brief.md"
  mkdir -p -- "$runtime/context"
  chmod 700 "$runtime/context"
  {
    if [[ -n $PROJECT_TASK_PREAMBLE ]]; then
      git -C "$REPO_ROOT" show "$MAIN_BRANCH:$PROJECT_TASK_PREAMBLE" | sed -e '$a\'
      printf '\n---\n\n'
    fi
    cat -- "$brief"
  } >"$runtime/context/TASK.md"
  for file in "${contexts[@]}"; do cp -a -- "$file" "$runtime/context/"; done
  git_hooked -C "$REPO_ROOT" worktree add --quiet -b "campaign/$slug" "$runtime/worktrees/campaign" "$base"
  id=$(jq -r '.id' "$runtime/plan/task.json"); title=$(jq -r '.title' "$runtime/plan/task.json")
  jq -n --arg slug "$slug" --arg tree "$runtime/worktrees/campaign" --arg spec "$runtime/plan/SPEC.md" --arg id "$id" \
    --arg title "$title" --arg base "$base" --arg base_ref "$base_ref" --arg brief "$runtime/brief.md" --arg path "$brief" \
    --arg home "$(machine_name)" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg desired "$($start && echo running || echo stopped)" \
    '{slug: $slug, kind: "task", branch: "campaign/\($slug)", worktree: $tree, spec: $spec, id: $id, title: $title,
      base: $base, base_ref: $base_ref, brief: $brief, brief_path: $path, home: $home, epoch: 1, round: 1,
      created: $created, desired: $desired}' >"$runtime/campaign.json"
  chmod 600 "$runtime/campaign.json"
  rm -f -- "$(finalized_marker "$slug")" "$(runtime_base)/moved/$slug.json"
  task_enter "$slug"
  task_mount
  event task-created "task $id from $base_ref ($base); brief $brief"
  event task-round "round 1: the brief"
  trap - EXIT
  note "Task $slug created: $title"
  note "Base: $base ($base_ref)"
  note "Worktree: $(task_ticket_tree)"
  if $start; then
    task_start
  else
    note "Not started (--no-start): campaign task restart $slug runs it."
  fi
}

# Undoes a task new that failed half way: its worktrees, its branches and its runtime.
task_new_abort() {
  local status=$? slug=${TASK_NEW_SLUG:-} root=${TASK_NEW_ROOT:-} runtime tree branch
  [[ -n $slug && -n $root ]] || return 0
  cd -- "$root" || return 0
  REPO_ROOT=$root
  runtime=$(runtime_dir "$slug")
  for tree in "$runtime/worktrees/$TASK_TICKET" "$runtime/worktrees/campaign"; do
    git -C "$root" worktree remove --force -- "$tree" >/dev/null 2>&1 || true
  done
  for branch in "agentic/$slug/$TASK_TICKET" "campaign/$slug"; do
    git -C "$root" branch -D -- "$branch" >/dev/null 2>&1 || true
  done
  rm -rf -- "$runtime"
  git -C "$root" worktree prune >/dev/null 2>&1 || true
  printf 'campaign: task new of %s failed; nothing of it was kept\n' "$slug" >&2
  return "$status"
}

# --- What a task is now: list, status, log and diff. --------------------------------------------------------------

# task_info FILE: the task whose campaign.json is FILE, as JSON. Its state: running (stopping) while its runner is
# active; else new (it never ran), stopped, delivered (its ticket is done), conflict or accept-failed (an accept that did
# not land it), failed (blocked after its automatic recoveries), blocked (an environment failure) or needs-human.
task_info() {
  local file=$1 runtime slug tickets active=false ran=false result='' task
  runtime=$(dirname -- "$file"); slug=$(jq -r '.slug' "$file")
  task="$runtime/plan/task.json"
  [[ -f $task ]] || task=/dev/null
  tickets=$(python3 "$TICKET_TOOL" list "$runtime/plan/tickets" 2>/dev/null || printf '[]')
  if runner_alive "$slug"; then
    active=true
    [[ ! -f $runtime/state/$TASK_TICKET.active ]] || tickets=$(jq -c 'map(.status = "in-progress")' <<<"$tickets")
  fi
  [[ ! -f $runtime/run-config.json ]] || ran=true
  if [[ -f $runtime/worktrees/$TASK_TICKET/.task/RESULT.md ]]; then result="$runtime/worktrees/$TASK_TICKET/.task/RESULT.md"
  elif [[ -f $runtime/RESULT.md ]]; then result="$runtime/RESULT.md"; fi
  jq -n --slurpfile campaign "$file" --slurpfile task "$task" --argjson active "$active" --argjson ran "$ran" \
    --argjson ticket "$(ticket_progress "$tickets" "$runtime/events/campaign.ndjson" | jq -c '.[0] // {}')" \
    --arg result "$result" --arg ticket_tree "$runtime/worktrees/$TASK_TICKET" '
    $campaign[0] as $c | $task[0] as $t | ($ticket.status // "todo") as $status
    | (if $active then (if ($c.desired // "running") == "stopped" then "stopping" else "running" end)
       elif $status == "done" then ($c.accept.state // "delivered")
       elif $status == "blocked" then (if ($ticket.reason // "") | startswith("environment:") then "blocked" else "failed" end)
       elif $status == "needs-human" then "needs-human"
       elif $ran | not then "new"
       else "stopped" end) as $state
    | {name: $c.slug, id: ($t.id // $c.id), title: ($t.title // $c.title), state: $state,
       phase: (if $active then ($ticket.phase // "starting") else null end),
       reason: (if $state == "conflict" or $state == "accept-failed" then $c.accept.reason else $ticket.reason end // null),
       ticket: $status, base: ($c.base // null), base_ref: ($c.base_ref // null), round: ($c.round // 1),
       created: ($c.created // null),
       age_seconds: (if $c.created then ((now - ($c.created | fromdateiso8601)) | floor) else null end),
       home: ($c.home // null), epoch: ($c.epoch // null), desired: ($c.desired // "running"), runner_active: $active,
       branch: "campaign/\($c.slug)", worktree: $c.worktree, ticket_worktree: $ticket_tree,
       result: (if $result == "" then null else $result end), accept: ($c.accept // null),
       model: ($t.model // null), effort: ($t.effort // null), review: $t.review}'
}

# The jq definition of a task's age as a person reads it.
TASK_AGE_JQ='def age: if . == null then "-" elif . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m"
  elif . < 86400 then "\(. / 3600 | floor)h \(. % 3600 / 60 | floor)m" else "\(. / 86400 | floor)d \(. % 86400 / 3600 | floor)h" end;'

task_list() {
  local json=false arg file records='[]'
  for arg in "$@"; do
    case $arg in --json) json=true ;; *) die "unknown task list option: $arg" ;; esac
  done
  for file in "$(runtime_base)"/*/campaign.json; do
    [[ -f $file && $(jq -r '.kind // ""' "$file" 2>/dev/null) == task ]] || continue
    records=$(jq -c --argjson record "$(task_info "$file")" '. + [$record]' <<<"$records")
  done
  if $json; then
    jq -n --arg machine "$(machine_name)" --argjson tasks "$records" '{machine: $machine, tasks: $tasks}'
    return
  fi
  if [[ $records == '[]' ]]; then note "No tasks on $(machine_name)."; return; fi
  jq -r "$TASK_AGE_JQ"' .[] | [.name, (.state + (if .phase then " (\(.phase))" else "" end)),
    "base \((.base // "?")[0:9])\(if .base_ref then " (\(.base_ref))" else "" end)", "round \(.round)",
    (.age_seconds | age), .title] | join("\t")' <<<"$records"
}

task_status() {
  local name='' json=false arg info
  for arg in "$@"; do
    case $arg in
      --json) json=true ;;
      -*) die "unknown task status option: $arg" ;;
      *) [[ -z $name ]] || die 'task status takes one NAME'; name=$arg ;;
    esac
  done
  task_enter "$name"
  info=$(task_info "$TASK_RUNTIME/campaign.json")
  if $json; then
    jq -n --argjson status "$(cmd_status --json)" --argjson task "$info" '$status + {task: $task}'
    return
  fi
  jq -r "$TASK_AGE_JQ"' "Task \(.name) (\(.id)): \(.title)",
    "State: \(.state)\(if .phase then " (\(.phase))" else "" end)\(if .reason then " — \(.reason)" else "" end)",
    "Base: \(.base // "?")\(if .base_ref then " (\(.base_ref))" else "" end) · round \(.round) · created \(.age_seconds | age) ago on \(.home // "?")",
    "Branch: \(.branch)",
    (if .result then "Result: \(.result)" else empty end),
    (if .accept.evidence then "Evidence: \(.accept.evidence)" else empty end)' <<<"$info"
  cmd_status
}

# One line per event of a task's events log (NDJSON on stdin), in the display time zone.
task_log_lines() {
  in_display_tz jq -R --unbuffered -r 'fromjson? // empty
    | "\(.time | sub("\\.[0-9]+"; "") | fromdateiso8601 | localtime | strftime("%d/%m %H:%M:%S"))  \(.type)\(if .ticket then " \(.ticket)" else "" end)\(if (.message // "") != "" then "  \(.message)" else "" end)"'
}

task_log() {
  local name='' follow=false arg file start pid=''
  for arg in "$@"; do
    case $arg in
      --follow | -f) follow=true ;;
      -*) die "unknown task log option: $arg" ;;
      *) [[ -z $name ]] || die 'task log takes one NAME'; name=$arg ;;
    esac
  done
  task_enter "$name"
  file="$TASK_RUNTIME/events/campaign.ndjson"
  [[ -f $file ]] || { note "Task $TASK_SLUG has no events yet."; return 0; }
  # The current round starts at its task-round event.
  start=$(grep -n '"type":"task-round"' -- "$file" | tail -n 1 | cut -d: -f1)
  start=${start:-1}
  if $follow && runner_alive "$TASK_SLUG"; then
    { read -r pid <"$TASK_RUNTIME/runner.pid"; } 2>/dev/null || pid=''
  fi
  if [[ $pid =~ ^[0-9]+$ ]]; then
    tail -n "+$start" --pid="$pid" -f -- "$file" | task_log_lines
  else
    tail -n "+$start" -- "$file" | task_log_lines
  fi
}

# task_diff NAME [GIT DIFF OPTIONS]: the worker's delta, campaign/<name> against the base. While the ticket worktree holds
# work that campaign/<name> has not got yet (a round in progress, its commits not integrated, or the delta `fix --rebase`
# re-applied, which moved the branch to the main branch's tip), the delta is there: that worktree against the base, new
# files included, with a note on stderr.
task_diff() {
  local name=${1:-} tree index rc=0
  (($#)) && shift
  [[ $name != -* ]] || die 'usage: campaign task diff NAME [GIT DIFF OPTIONS]'
  task_enter "$name"
  tree=$(task_ticket_tree)
  if [[ ! -d $tree ]] || { [[ -z $(git -C "$tree" status --porcelain=v1) ]] &&
                           git -C "$tree" merge-base --is-ancestor HEAD "campaign/$TASK_SLUG"; }; then
    git -C "$REPO_ROOT" diff "$(task_base)" "campaign/$TASK_SLUG" "$@"
    return
  fi
  printf 'campaign: the ticket worktree of %s holds work that campaign/%s has not got yet (a round in progress, or the delta campaign task fix --rebase re-applied): this is that worktree against the base\n' \
    "$TASK_SLUG" "$TASK_SLUG" >&2
  # A copy of its index takes the worktree as it is, without touching the round's own index; the prefixes are those of
  # the delta between two commits (a/, b/), whatever diff.mnemonicPrefix says.
  index=$(mktemp -d)
  cp -- "$(git -C "$tree" rev-parse --path-format=absolute --git-path index)" "$index/index"
  GIT_INDEX_FILE=$index/index git -C "$tree" add -A &&
    GIT_INDEX_FILE=$index/index git -C "$tree" -c diff.mnemonicPrefix=false diff --cached "$(task_base)" "$@" || rc=$?
  rm -rf -- "$index"
  return "$rc"
}

# --- Running it: stop, restart and fix. -----------------------------------------------------------------------------

task_stop() {
  local name='' arg
  local -a options=()
  for arg in "$@"; do
    case $arg in
      --now) options+=(--now) ;;
      -*) die "unknown task stop option: $arg" ;;
      *) [[ -z $name ]] || die 'task stop takes one NAME'; name=$arg ;;
    esac
  done
  task_enter "$name"
  cmd_stop "${options[@]}"
}

task_restart() {
  local name='' arg
  local -a options=()
  for arg in "$@"; do
    case $arg in
      --now) options+=(--now) ;;
      -*) die "unknown task restart option: $arg" ;;
      *) [[ -z $name ]] || die 'task restart takes one NAME'; name=$arg ;;
    esac
  done
  task_enter "$name"
  [[ $(task_ticket_status) != done ]] \
    || die "task $TASK_SLUG is delivered: there is nothing to run (campaign task fix $TASK_SLUG runs another round)"
  task_mount
  if [[ -f $TASK_RUNTIME/run-config.json ]]; then
    task_worker_env
    cmd_restart "${options[@]}"
  else
    task_start
  fi
}

# task_reapply: the task's base becomes the main branch's tip and its delta is re-applied there mechanically
# (reapply_delta, the path of an integration conflict): campaign/<name> moves to the main branch, the ticket worktree gets
# the delta with conflict markers where both sides changed the same code, and the round starts with an integration repair
# (state/T-001.reapplied, which names the conflicting paths for run_ticket). The worker never rebases. A task without a
# delta (it never committed) only has its base moved, and its round starts with a worker. The delta is re-applied before
# anything else moves: when no worker could resolve it from markers (reapply_delta fails with 2: the main branch deleted or
# renamed a file it changes, both sides changed a file git merges without markers, such as a binary file or one with a
# -merge attribute, or git apply rejected the whole patch), the ticket worktree
# goes back to its tip, the branch, the base and the round stay as they were, the copy of the delta stays in
# state/T-001.conflict.patch, and the command stops saying why.
task_reapply() {
  local tree old_base new_base previous output patch rc=0
  tree=$(task_ticket_tree); patch="$TASK_RUNTIME/state/$TASK_TICKET.conflict.patch"
  old_base=$(task_base)
  new_base=$(git -C "$REPO_ROOT" rev-parse "$MAIN_BRANCH")
  if [[ $new_base == "$old_base" ]]; then
    note "The base of $TASK_SLUG already is the tip of $MAIN_BRANCH: nothing to re-apply."
    return 0
  fi
  if [[ -d $tree ]]; then
    [[ -z $(git -C "$tree" status --porcelain=v1) ]] \
      || die "the ticket worktree of $TASK_SLUG has uncommitted changes (an interrupted round): campaign task restart $TASK_SLUG finishes it, or fix it without --rebase"
  fi
  task_ticket_checkout
  previous=$(git -C "$tree" rev-parse HEAD)
  if git -C "$tree" merge-base --is-ancestor HEAD "campaign/$TASK_SLUG"; then
    git_hooked -C "$tree" merge --ff-only -q "campaign/$TASK_SLUG"
  fi
  output=$(reapply_delta "$tree" "$old_base" "$new_base" "$patch") || rc=$?
  if ((rc != 0)); then
    git -C "$tree" reset -q --hard "$previous"
    if ((rc != 2)); then
      rm -f -- "$patch"
      die "re-applying the delta of $TASK_SLUG on $MAIN_BRANCH failed; nothing moved: its branch and its base are as they were"
    fi
    event task-rebase-refused "the delta does not apply on $MAIN_BRANCH ($new_base), $output" "$TASK_TICKET"
    die "the delta of task $TASK_SLUG does not apply on $MAIN_BRANCH, $output. Nothing moved: its branch, its base and its round are as they were, and a copy of the delta is in $patch. Carry the delta (campaign task diff $TASK_SLUG) over by hand, or drop the task and create it again from the current $MAIN_BRANCH."
  fi
  git -C "$TASK_TREE" reset -q --hard "$new_base"
  task_update '.base = $base | .base_ref = $ref' --arg base "$new_base" --arg ref "$MAIN_BRANCH"
  if [[ ! -s $patch ]]; then
    rm -f -- "$patch"
    event task-rebased "the base moved to $MAIN_BRANCH ($new_base); the task had no delta to re-apply" "$TASK_TICKET"
    return 0
  fi
  printf '%s\n' "$output" >"$TASK_RUNTIME/state/$TASK_TICKET.reapplied"
  chmod 600 "$TASK_RUNTIME/state/$TASK_TICKET.reapplied"
  event task-rebased "the base moved to $MAIN_BRANCH ($new_base) and the delta was re-applied there; conflicts in: $(paste -sd, - <<<"$output" | sed 's/^$/none/')" "$TASK_TICKET"
}

task_fix() {
  local name='' note='' findings='' rebase=false round status base kept tree
  while (($#)); do
    case $1 in
      --note) (($# >= 2)) || die '--note requires a text'; note=$2; shift 2 ;;
      --brief) (($# >= 2)) || die '--brief requires a file'; findings=$2; shift 2 ;;
      --rebase) rebase=true; shift ;;
      -*) die "unknown task fix option: $1" ;;
      *) [[ -z $name ]] || die 'task fix takes one NAME'; name=$1; shift ;;
    esac
  done
  [[ -n $note || -n $findings ]] || die "task fix needs the coordinator's findings: --note TEXT or --brief FILE"
  [[ -z $note || -z $findings ]] || die 'task fix takes --note or --brief, not both'
  if [[ -n $findings ]]; then
    [[ $findings == /* ]] || findings="$PWD/$findings"
    [[ -f $findings ]] || die "findings not found: $findings"
  fi
  task_enter "$name"
  task_lock
  ! runner_alive "$TASK_SLUG" || die "task $TASK_SLUG is running: campaign task stop $TASK_SLUG first (--now: at once)"
  [[ -z $(git -C "$TASK_TREE" status --porcelain=v1) ]] || die "the campaign worktree of task $TASK_SLUG is dirty: $TASK_TREE"
  round=$(($(task_json '.round // 1') + 1))
  if $rebase; then task_reapply; fi
  task_mount
  base=$(task_base); tree=$(task_ticket_tree)
  # The findings of the round, kept apart: they are the diagnosis write_prompt gives the round's first worker, and every
  # automatic recovery's diagnosis opens with them (write_recovery_diagnosis), until the round is integrated.
  kept="$TASK_RUNTIME/state/$TASK_TICKET.findings.md"
  {
    if git -C "$tree" diff --quiet "$base" HEAD && [[ -z $(git -C "$tree" status --porcelain=v1) ]]; then
      printf "Round %s of task %s (campaign task fix): the task has no delta on its base %s yet. Do what its brief asks, with the coordinator's findings below, run the task's validate commands and write .task/RESULT.md.\n\n" \
        "$round" "$(task_json '.id')" "$base"
    else
      printf "Round %s of task %s (campaign task fix): the coordinator reviewed what the earlier rounds delivered and asks for the changes below. That work is the task's delta since its base %s (git diff %s HEAD%s). Keep every valid part of it, apply each finding, run the task's validate commands and update .task/RESULT.md.\n\n" \
        "$round" "$(task_json '.id')" "$base" "$base" "$([[ -f $TASK_RUNTIME/state/$TASK_TICKET.reapplied ]] && printf ', with the delta re-applied in the worktree')"
    fi
    if [[ -n $note ]]; then printf '%s\n' "$note"; else cat -- "$findings"; fi
  } >"$kept"
  chmod 600 "$kept"
  mkdir -p -- "$TASK_RUNTIME/diagnosis"
  cp -- "$kept" "$TASK_RUNTIME/diagnosis/$TASK_TICKET.md"
  chmod 600 "$TASK_RUNTIME/diagnosis/$TASK_TICKET.md"
  # A new round: the ticket is todo again with a fresh budget of automatic recoveries, and its first worker applies the
  # findings (the retry marker and the diagnosis make it a recovery).
  status=$(task_ticket_status)
  [[ $status == todo ]] || set_ticket_status "$TASK_TICKET" todo
  rm -f -- "$TASK_RUNTIME/decisions/$TASK_TICKET.json" "$TASK_RUNTIME/state/$TASK_TICKET.recoveries"
  printf 'campaign task fix: round %s\n' "$round" >"$TASK_RUNTIME/state/$TASK_TICKET.retry"
  chmod 600 "$TASK_RUNTIME/state/$TASK_TICKET.retry"
  task_update '.round = $round | del(.accept)' --argjson round "$round"
  event task-round "round $round: campaign task fix$($rebase && printf ' --rebase') with the coordinator's findings"
  note "Task $TASK_SLUG: round $round$($rebase && printf ', on %s' "$MAIN_BRANCH")."
  flock -u 6
  task_start
}

# --- Landing it or dropping it. -------------------------------------------------------------------------------------

# task_commands PHASE TREE DIR COMMANDS: runs a JSON list of commands of the settings (argv arrays or the object form)
# in TREE through lib/validation.py, with AGENTIC_TASK=<name>: each one with its deadline, in its own process group and
# with no descriptor of this process but the standard ones. PHASE baseline runs every command; final reuses a command
# that already passed on the same commit. The receipt is DIR/campaign.PHASE.json, the logs are in DIR/logs.
task_commands() {
  local phase=$1 tree=$2 dir=$3 commands=$4
  mkdir -p -- "$dir"
  jq -n --argjson commands "$commands" --arg phase "$phase" \
    '{version: 1, tickets: {}, final: $commands} + (if $phase == "baseline" then {baseline: $commands} else {} end)' >"$dir/plan.json"
  AGENTIC_TASK=$TASK_SLUG python3 "$AGENTIC_DIR/lib/validation.py" "$tree" "$dir/plan.json" "$dir" campaign "$phase" 6>&- 7>&-
}

# task_failure RECEIPT: what failed, as the reason of an accept-failed task.
task_failure() {
  local failure
  if failure=$(validation_environment_failure "$1"); then printf 'environment: %s' "$failure"; return; fi
  jq -r '"\(.failed_command // [] | join(" ")): \(.reason // "failed")"' "$1" 2>/dev/null || printf 'no receipt was written (%s)' "$1"
}

# task_accept_stop STATE REASON [EVIDENCE]: the accept stops without landing anything: the task is marked STATE (conflict
# or accept-failed) with its reason and evidence, and its branch is as it was.
task_accept_stop() {
  local state=$1 reason=$2 evidence=${3:-} next
  task_remove_worktree "$TASK_RUNTIME/worktrees/accept"
  task_update '.accept = {state: $state, reason: $reason, evidence: (if $evidence == "" then null else $evidence end), at: $at}' \
    --arg state "$state" --arg reason "$reason" --arg evidence "$evidence" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  event "task-$state" "$reason${evidence:+ (evidence: $evidence)}"
  if [[ $state == conflict ]]; then
    next="campaign task fix $TASK_SLUG --rebase --note TEXT re-applies it on $MAIN_BRANCH for an integration repair"
  else
    next="the evidence is in $evidence; campaign task fix $TASK_SLUG --note TEXT repairs it, or accept again once the cause is fixed"
  fi
  die "task $TASK_SLUG was not accepted ($state): $reason. Its branch is as it was; $next."
}

# task_integrate BODY: lands the entered task in the main branch, holding main.lock (and the slot of its validation, which
# it gives back): the gates, the squash rebased onto the main branch, accept_regen, the validation and the fast-forward.
task_integrate() {
  local body=$1 status tip base main_tip main_tree dirty temp squash message conflicted lost commands head receipt
  status=$(task_ticket_status)
  [[ $status == done ]] || die "task $TASK_SLUG is not delivered: its ticket is $status (campaign task status $TASK_SLUG)"
  [[ -z $(git -C "$TASK_TREE" status --porcelain=v1) ]] || die "the campaign worktree of task $TASK_SLUG is dirty: $TASK_TREE"
  tip=$(git -C "$REPO_ROOT" rev-parse "campaign/$TASK_SLUG"); base=$(task_base)
  [[ $tip != "$base" ]] || die "task $TASK_SLUG delivered no change (campaign/$TASK_SLUG is its base): campaign task drop $TASK_SLUG"
  main_tip=$(git -C "$REPO_ROOT" rev-parse "$MAIN_BRANCH")
  main_tree=$(main_worktree)
  if [[ -n $main_tree ]]; then
    dirty=$(main_dirty_overlap "$main_tree" "$TASK_TREE" "$TASK_SLUG")
    [[ -z $dirty ]] || die "main worktree has uncommitted changes in files task $TASK_SLUG changes ($dirty); refusing the accept"
  fi

  # The delta as one commit with the brief's message on the task's base, rebased onto the main branch in a temporary
  # worktree: the task's branch stays as it is until the accept lands.
  temp="$TASK_RUNTIME/worktrees/accept"
  task_remove_worktree "$temp"
  git_hooked -C "$REPO_ROOT" worktree add --quiet --detach "$temp" "$tip"
  git -C "$temp" reset -q --soft "$base"
  if git -C "$temp" diff --cached --quiet; then
    task_remove_worktree "$temp"
    die "task $TASK_SLUG delivered no change (its branch holds the tree of its base): campaign task drop $TASK_SLUG"
  fi
  message=$(task_commit_message "$TASK_SLUG")
  [[ -z $body ]] || message+=$'\n\n'"$body"
  git_hooked -C "$temp" commit -q -m "$message"
  squash=$(git -C "$temp" rev-parse HEAD)
  if [[ $main_tip != "$base" ]]; then
    if ! git_hooked -C "$temp" rebase "$MAIN_BRANCH" >/dev/null 2>&1; then
      conflicted=$(git -C "$temp" diff --name-only --diff-filter=U | paste -sd, -)
      git_hooked -C "$temp" rebase --abort >/dev/null 2>&1 || true
      task_accept_stop conflict "the rebase onto $MAIN_BRANCH conflicted in: ${conflicted:-unknown}"
    fi
    if ! lost=$(verify_rebase_kept_changes "$temp" "$squash" "$base" "$MAIN_BRANCH"); then
      task_accept_stop conflict "the rebase onto $MAIN_BRANCH dropped the task's changes in: $(paste -sd, - <<<"$lost")"
    fi
  fi
  task_exclude
  task_link "$temp"

  # What accept_regen regenerates lands as a commit of its own, after the worker's, and is validated with it.
  if [[ $PROJECT_ACCEPT_REGEN != '[]' ]]; then
    receipt="$TASK_RUNTIME/validation/accept-regen/campaign.baseline.json"
    task_commands baseline "$temp" "$(dirname -- "$receipt")" "$PROJECT_ACCEPT_REGEN" \
      || task_accept_stop accept-failed "accept_regen failed: $(task_failure "$receipt")" "$receipt"
    if [[ -n $(git -C "$temp" status --porcelain=v1) ]]; then
      git -C "$temp" add -A
      git_hooked -C "$temp" commit -q -m "chore(regen): $TASK_SLUG"
    fi
  fi

  # The task's validate commands when the main branch moved since its base (with the plan's deadline), and the project's
  # accept_checks always.
  commands=$PROJECT_ACCEPT_CHECKS
  if [[ $main_tip != "$base" ]]; then
    commands=$(jq -c --argjson checks "$PROJECT_ACCEPT_CHECKS" '. as $plan
      | [.final[] | if type == "object" then . else {command: .} end
         | if has("timeout_minutes") or $plan.timeout_minutes == null then . else .timeout_minutes = $plan.timeout_minutes end]
      + $checks' "$(campaign_path)/validation.json")
  fi
  if [[ $commands != '[]' ]]; then
    receipt="$TASK_RUNTIME/validation/accept/campaign.final.json"
    task_commands final "$temp" "$(dirname -- "$receipt")" "$commands" \
      || task_accept_stop accept-failed "$(task_failure "$receipt")" "$receipt"
  fi
  slot_release

  # The fast-forward, if nothing moved the main branch by hand meanwhile.
  head=$(git -C "$temp" rev-parse HEAD)
  git -C "$REPO_ROOT" merge-base --is-ancestor "$MAIN_BRANCH" "$head" \
    || die "$MAIN_BRANCH moved during the accept of $TASK_SLUG; run campaign task accept $TASK_SLUG again"
  main_tree=$(main_worktree)
  if [[ -n $main_tree ]]; then
    dirty=$(main_dirty_overlap "$main_tree" "$temp" "$TASK_SLUG")
    [[ -z $dirty ]] || die "main worktree has uncommitted changes in files task $TASK_SLUG changes ($dirty); refusing the accept"
    git_hooked -C "$main_tree" merge --ff-only -q "$head"
  else
    git -C "$REPO_ROOT" update-ref "refs/heads/$MAIN_BRANCH" "$head" "$(git -C "$REPO_ROOT" rev-parse "$MAIN_BRANCH")"
  fi
  mark_finalized "$TASK_SLUG" "$REPO_ROOT"
  event task-accepted "landed in $MAIN_BRANCH at $head: $(git -C "$REPO_ROOT" log --format=%s "$main_tip..$head" | paste -sd'|' - | sed 's/|/ · /g')"
  TASK_ACCEPTED=$head
}

task_accept() {
  local name='' body=''
  while (($#)); do
    case $1 in
      --body) (($# >= 2)) || die '--body requires a text'; body=$2; shift 2 ;;
      -*) die "unknown task accept option: $1" ;;
      *) [[ -z $name ]] || die 'task accept takes one NAME'; name=$1; shift ;;
    esac
  done
  task_enter "$name"
  yield_cpu
  # The validation's machine slot is taken before any lock (a slot is never asked for holding another lock), as finalize
  # takes its own.
  slot_take validation "$TASK_SLUG/accept" || { (($? == 1)) && die 'the wait for a machine slot ended'; exit 2; }
  task_lock
  exec 7>"$TASK_RUNTIME/runner.lock"
  flock -n 7 || die "cannot accept task $TASK_SLUG while its runner is active (campaign task stop $TASK_SLUG)"
  # From its gates to the fast-forward the accept decides on, and moves, this machine's main branch: another accept or a
  # finalize waits for it, then rebases on what it left.
  main_lock_acquire
  task_integrate "$body"
  main_lock_release
  # The task's own locks stay held until task_forget has removed its runtime, and it is stopped meanwhile: no relaunch
  # starts an engine in a runtime that is going away.
  set_desired_state "$TASK_SLUG" stopped
  task_forget
  exec 6>&- 7>&-
  note "Task $TASK_SLUG accepted into $MAIN_BRANCH ($TASK_ACCEPTED)."
}

# task_forget: what accept and drop leave of the entered task: they run the project's task_cleanup commands (with
# AGENTIC_TASK=<name>, from the main worktree), then remove its worktrees, its branches (what entered the main branch
# stays there) and its runtime, whose history is archived as finalize archives a campaign's.
task_forget() {
  local main_tree tree branch
  # The main worktree, else the clone's own folder: never a worktree of the task, which goes away.
  main_tree=$(main_worktree)
  if [[ -z $main_tree || ! -d $main_tree ]]; then
    main_tree=$(git -C "$TASK_PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir)
    main_tree=$(dirname -- "$main_tree")
  fi
  cd -- "$main_tree"
  if [[ $PROJECT_TASK_CLEANUP != '[]' ]] &&
     ! task_commands baseline "$main_tree" "$TASK_RUNTIME/validation/task-cleanup" "$PROJECT_TASK_CLEANUP" >/dev/null; then
    printf 'campaign: warning: a task_cleanup command failed for %s: %s\n' "$TASK_SLUG" \
      "$(task_failure "$TASK_RUNTIME/validation/task-cleanup/campaign.baseline.json")" >&2
  fi
  for tree in "$TASK_RUNTIME"/worktrees/*; do
    [[ -e $tree ]] || continue
    task_remove_worktree "$tree"
  done
  # A worktree whose folder is gone still holds its branch until it is pruned.
  git -C "$main_tree" worktree prune
  while IFS= read -r branch; do
    [[ -n $branch ]] || continue
    git -C "$main_tree" branch -D -- "$branch" >/dev/null
  done < <(git -C "$main_tree" for-each-ref --format='%(refname:short)' "refs/heads/campaign/$TASK_SLUG" "refs/heads/agentic/$TASK_SLUG/")
  REPO_ROOT=$main_tree
  archive_campaign_history "$TASK_SLUG" "$TASK_RUNTIME" "$main_tree"
  rm -rf -- "$TASK_RUNTIME"
  git -C "$main_tree" worktree prune
}

task_drop() {
  local name=${1:-} pid=''
  (($# <= 1)) || die 'task drop takes one NAME'
  task_enter "$name" --allow-missing
  task_lock
  set_desired_state "$TASK_SLUG" stopped
  if runner_alive "$TASK_SLUG"; then
    if [[ -d $TASK_TREE ]]; then
      cmd_stop --now
    else
      # Without its campaign worktree there is no campaign to stop: the engine is stopped by its pid.
      { read -r pid <"$TASK_RUNTIME/runner.pid"; } 2>/dev/null || pid=''
      [[ $pid =~ ^[0-9]+$ ]] || die "the runner of $TASK_SLUG holds its lock but its pid is unknown: stop it, then drop the task again"
      stop_engine "$pid"
      for _ in {1..50}; do runner_alive "$TASK_SLUG" || break; sleep 0.2; done
      ! runner_alive "$TASK_SLUG" || die "the runner of $TASK_SLUG did not stop; nothing of the task was removed"
    fi
  fi
  [[ ! -d $TASK_TREE ]] \
    || event task-dropped "dropped at round $(task_json '.round // 1'): worktrees, branches and runtime removed, history archived"
  # launcher.lock stays held until the runtime is gone: no run starts in it meanwhile.
  task_forget
  exec 6>&-
  note "Task $TASK_SLUG dropped."
}

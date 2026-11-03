#!/usr/bin/env bash
# The campaign's plan: init, current, verify, ready and status, with the SPEC, plan and ticket checks they share. Sourced
# by bin/campaign; it defines functions and variables and runs nothing.

derive_slug() {
  local spec=$1 heading slug
  heading=$(sed -n -E 's/^#[[:space:]]+//p' "$spec" | head -1)
  [[ -n $heading ]] || die 'the SPEC has no "# " heading to name the campaign: pass --slug <short-kebab-name> or start the SPEC with "# <Title>"'
  slug=$(printf '%s' "$heading" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$heading")
  slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
  [[ -n $slug ]] || die 'could not derive a campaign slug from the SPEC heading: pass --slug <short-kebab-name>'
  printf '%.60s\n' "$slug"
}

# The campaign worktree and the engine snapshot come from the main branch: the runner and the role documents must be
# committed there.
require_committed_kit() {
  git -C "$REPO_ROOT" cat-file -e "$MAIN_BRANCH:.agentic/bin/campaign" 2>/dev/null \
    || die "$MAIN_BRANCH has no committed .agentic/bin/campaign: commit the installed .agentic on $MAIN_BRANCH first (git add .agentic && git commit); the campaign worktree would otherwise lack the runner and the role documents"
}

cmd_init() {
  local spec='' slug='' arg runtime branch worktree canonical current
  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --slug) (($#)) || die '--slug requires a value'; slug=$1; shift ;;
      --*) die "unknown init option: $arg" ;;
      *) [[ -z $spec ]] || die 'init accepts only one SPEC path'; spec=$arg ;;
    esac
  done
  [[ -n $spec ]] || spec="$REPO_ROOT/SPEC.md"
  [[ $spec == /* ]] || spec="$PWD/$spec"
  [[ -f $spec ]] || die "SPEC not found: $spec"
  [[ -n $slug ]] || slug=$(derive_slug "$spec")
  validate_slug "$slug"
  verify_spec "$spec"
  current=$(current_branch) || die 'init requires a branch, not detached HEAD'
  [[ $current == "$MAIN_BRANCH" ]] || die "init requires $MAIN_BRANCH; current branch is '$current'"
  require_committed_kit
  branch="campaign/$slug"
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch" && die "campaign branch already exists: $branch"
  fleet_lib
  fleet_init_check "$slug"

  runtime=$(ensure_runtime "$slug")
  worktree="$runtime/worktrees/campaign"
  [[ ! -e $worktree ]] || die "campaign worktree path already exists: $worktree"
  git_hooked -C "$REPO_ROOT" worktree add -b "$branch" "$worktree" "$MAIN_BRANCH" >/dev/null
  rm -f -- "$(finalized_marker "$slug")" "$(runtime_base)/moved/$slug.json"
  canonical="$worktree/campaigns/$slug/SPEC.md"
  mkdir -p -- "$worktree/campaigns/$slug/tickets"
  cp -- "$spec" "$canonical"
  git -C "$worktree" add -- "campaigns/$slug/SPEC.md"
  git_hooked -C "$worktree" commit -m "docs(agentic): initialize $slug campaign" >/dev/null
  # The default planning draft has now moved to committed canonical history.
  # Preserve arbitrary external inputs and tracked files on the main branch.
  if [[ $spec == "$REPO_ROOT/SPEC.md" && ! -L $spec ]] &&
      ! git -C "$REPO_ROOT" ls-files --error-unmatch -- SPEC.md >/dev/null 2>&1; then
    rm -- "$spec"
  fi
  jq -cn --arg slug "$slug" --arg branch "$branch" --arg worktree "$worktree" --arg spec "$canonical" \
    '{slug:$slug,branch:$branch,worktree:$worktree,spec:$spec}' >"$runtime/campaign.json"
  chmod 600 "$runtime/campaign.json"
  note "Campaign initialized: $slug"
  note "Worktree: $worktree"
  note "SPEC: $canonical"
}

cmd_current() {
  local json=false slug branch
  [[ ${1:-} == --json ]] && json=true
  branch=$(current_branch) || die 'detached HEAD has no current campaign'
  slug=$(campaign_slug_from_branch "$branch") || die "branch '$branch' is outside campaign/<slug>"
  validate_slug "$slug"
  if $json; then jq -cn --arg slug "$slug" --arg branch "$branch" '{slug:$slug,branch:$branch}'; else note "$slug"; fi
}

# A SPEC has every section of the current layout, or every section of the legacy one (campaigns created before the
# kit: accepted, never produced). Sections of the two are never combined to complete one.
verify_spec() {
  local spec=$1 section questions none='^None\.?$'
  local -a missing=() missing_legacy=()
  [[ -f $spec ]] || die "missing campaign SPEC: $spec"
  for section in 'Problem Statement' 'Solution' 'User Stories' 'Implementation Decisions' 'Testing Decisions' 'Out of Scope' 'Open questions'; do
    grep -Eq "^#+[[:space:]]+$section[[:space:]]*$" "$spec" || missing+=("$section")
  done
  for section in 'Problem' 'Goals' 'Non-goals' 'Decisions' 'Requirements' 'Constraints' 'Acceptance' 'Open questions'; do
    grep -Eq "^#+[[:space:]]+$section[[:space:]]*$" "$spec" || missing_legacy+=("$section")
  done
  if ((${#missing[@]} > 0)); then
    ((${#missing_legacy[@]} == 0)) || die "SPEC missing sections: ${missing[*]}"
    # The legacy layout also wrote "Nenhuma" for no open question.
    none='^(None|Nenhuma)\.?$'
  fi
  questions=$(awk '
    /^#+[[:space:]]+Open questions[[:space:]]*$/ {inside=1; next}
    inside && /^#/ {exit}
    inside {print}
  ' "$spec")
  questions=$(printf '%s\n' "$questions" | sed -E '/^[[:space:]]*$/d; s/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ ! $questions =~ $none ]] && \
     ! awk 'NF && $0 !~ /^([-*][[:space:]]*)?[Nn]on-blocking:/ {exit 1}' <<<"$questions"; then
    die "SPEC Open questions must be 'None' or explicitly non-blocking"
  fi
}

# One line for every required check (project.json) that a ticket's cheap phase or the plan's final list lacks. A
# command of the plan is an argv array or {"command": [...], "timeout_minutes": N}.
missing_required_checks() {
  jq -r --argjson required "$PROJECT_REQUIRED_CHECKS" '
    def has_check($list; $check): ($list // [] | map(if type == "object" then .command else . end) | index([$check])) != null;
    . as $plan | $required[] as $check
    | ($plan.tickets | to_entries[] | select(has_check(.value.cheap; $check) | not)
        | "ticket \(.key): the cheap phase lacks the required check \($check | tojson)"),
      (select(has_check($plan.final // $plan.campaign_expensive; $check) | not) | "the final list lacks the required check \($check | tojson)")
  ' "$1"
}

# The trusted validation plan against the campaign's tickets (a JSON list) and the required_checks of project.json. A
# plan without a final list uses its campaign_expensive list as the final one (legacy layout, accepted, not produced).
# A command is an argv array or {"command": [...], "timeout_minutes": N}, with the deadline bounds of lib/validation.py.
verify_plan() {
  local plan=$1 tickets_json=$2 ticket_ids plan_ids missing
  [[ -f $plan && ! -L $plan ]] || die "missing trusted validation plan: $plan"
  jq -e '
    def argv: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    def minutes: type == "number" and . == floor and . >= 1 and . <= 1440;
    def command: argv or (type == "object" and (keys - ["command", "timeout_minutes"]) == [] and (.command | argv)
                          and ((has("timeout_minutes") | not) or (.timeout_minutes | minutes)));
    def commands: type == "array" and all(.[]; command);
    ((has("timeout_minutes") | not) or (.timeout_minutes | minutes)) and
    .version == 1 and (.tickets|type == "object") and ((.final // .campaign_expensive)|commands) and ((.baseline // [])|commands) and
    ((.campaign_expensive // [])|commands) and
    all(.tickets[]; (.cheap|commands) and (.component|commands) and (.expensive|commands))
  ' "$plan" >/dev/null || die 'trusted validation plan is malformed'
  ticket_ids=$(jq -c '[.[].id] | sort' <<<"$tickets_json")
  plan_ids=$(jq -c '[.tickets | keys[]] | sort' "$plan")
  [[ $ticket_ids == "$plan_ids" ]] || die 'validation plan ticket keys do not exactly match campaign tickets'
  missing=$(missing_required_checks "$plan")
  [[ -z $missing ]] || die "validation plan lacks the required checks of $PROJECT_CONFIG_SOURCE:"$'\n'"$missing"
}

cmd_verify() {
  assert_campaign_branch
  (($# == 0)) || die 'verify accepts no options'
  local slug campaign tickets_json
  slug=$(campaign_slug); campaign=$(campaign_path "$slug")
  verify_spec "$campaign/SPEC.md"
  [[ -d $campaign/tickets ]] || die "missing tickets directory: $campaign/tickets"
  tickets_json=$(python3 "$TICKET_TOOL" list "$campaign/tickets")
  jq -e 'type == "array"' >/dev/null <<<"$tickets_json"
  verify_plan "$campaign/validation.json" "$tickets_json"
  note "Campaign $slug verified ($(jq 'length' <<<"$tickets_json") tickets)."
}

TASK_PLAN_TOOL="$AGENTIC_DIR/lib/task_plan.py"

# campaign _task-plan BRIEF DIR: the plan of a task (a campaign of one ticket whose plan lives in the runtime) from its
# brief, in DIR: SPEC.md, tickets/T-001.md, validation.json and task.json, checked as campaign verify checks a plan
# before it replaces DIR's. Prints the task's name (its id in lower case).
cmd_task_plan() {
  (($# == 2)) || die 'usage: campaign _task-plan BRIEF DIR'
  local brief=$1 dir=$2 slug staging file
  [[ -f $brief ]] || die "brief not found: $brief"
  [[ ! -L $dir && ! -L $dir/tickets ]] || die "the plan folder must not be a symlink: $dir"
  slug=$(python3 "$TASK_PLAN_TOOL" slug "$brief") || exit 2
  (validate_slug "$slug") || die "invalid brief $brief: its id does not make a valid task name ($slug)"
  mkdir -p -- "$(dirname -- "$dir")"
  staging=$(mktemp -d "$(dirname -- "$dir")/.task-plan.XXXXXX")
  python3 "$TASK_PLAN_TOOL" write "$brief" "$staging" || { rm -rf -- "$staging"; exit 2; }
  if ! (
      verify_spec "$staging/SPEC.md"
      tickets_json=$(python3 "$TICKET_TOOL" list "$staging/tickets") || exit 2
      verify_plan "$staging/validation.json" "$tickets_json"
    ); then
    rm -rf -- "$staging"
    die "invalid brief $brief: its plan does not pass campaign verify"
  fi
  mkdir -p -- "$dir/tickets"
  chmod 700 "$dir" "$dir/tickets"
  for file in SPEC.md validation.json task.json tickets/T-001.md; do mv -f -- "$staging/$file" "$dir/$file"; done
  rm -rf -- "$staging"
  printf '%s\n' "$slug"
}

cmd_ready() {
  assert_campaign_branch
  local json=false tickets runtime active_ids='[]'
  [[ ${1:-} == --json ]] && json=true
  tickets=$(python3 "$TICKET_TOOL" ready "$(tickets_path)")
  runtime=$(ensure_runtime)
  if runner_alive "$(campaign_slug)" && compgen -G "$runtime/state/*.active" >/dev/null; then
    active_ids=$(for file in "$runtime"/state/*.active; do basename -- "$file" .active; done | jq -Rsc 'split("\n")|map(select(length>0))')
    tickets=$(jq --argjson ids "$active_ids" '[.[] | select((.id as $id | $ids | index($id)) == null)]' <<<"$tickets")
  fi
  if $json; then jq '.' <<<"$tickets"; else jq -r '.[] | "\(.id)\t\(.risk)\t\(.path)"' <<<"$tickets"; fi
}

# {ticket: executor} for the tickets of a runtime that have an assigned executor (local or a remote name).
active_executors() {
  local file
  for file in "$1"/state/*.executor; do
    [[ -f $file ]] || continue
    jq -cn --arg id "$(basename -- "$file" .executor)" --arg executor "$(head -n 1 -- "$file")" '{($id): $executor}'
  done | jq -sc 'add // {}'
}

cmd_status() {
  assert_campaign_branch
  local json=false slug tickets runtime active=false pid='' decisions='[]' desired provider location
  [[ ${1:-} == --json ]] && json=true
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug")
  tickets=$(python3 "$TICKET_TOOL" list "$(tickets_path "$slug")")
  if runner_alive "$(campaign_slug)" && compgen -G "$runtime/state/*.active" >/dev/null; then
    local active_ids
    active_ids=$(for file in "$runtime"/state/*.active; do basename -- "$file" .active; done | jq -Rsc 'split("\n")|map(select(length>0))')
    tickets=$(jq --argjson ids "$active_ids" --argjson executors "$(active_executors "$runtime")" \
      'map(if (.id as $id | $ids | index($id)) != null then .status="in-progress" | .executor=($executors[.id] // "local") else . end)' <<<"$tickets")
  fi
  if runner_alive "$slug"; then
    active=true
    # The runner may finish between the lock check and reading its PID.
    { read -r pid <"$runtime/runner.pid"; } 2>/dev/null || pid=''
  fi
  if compgen -G "$runtime/decisions/*.json" >/dev/null; then
    decisions=$(jq -s '.' "$runtime"/decisions/*.json)
  fi
  desired=$(desired_state "$slug")
  provider=$(jq -r '.provider // "claude"' "$runtime/run-config.json" 2>/dev/null || printf 'claude')
  location=$(jq -cn --arg machine "$(machine_name)" --arg project "$(main_worktree)" --arg worktree "$REPO_ROOT" \
    --arg provider "$provider" --arg open "$(open_command "$REPO_ROOT" "$provider")" \
    '{machine:$machine, project:$project, worktree:$worktree, provider:$provider, open:$open}')
  if $json; then
    jq -cn --arg slug "$slug" --argjson active "$active" --arg pid "$pid" --arg desired "$desired" \
      --argjson tickets "$tickets" --argjson decisions "$decisions" --argjson location "$location" \
      '{campaign:$slug,runner:{active:$active,pid:(if $pid=="" then null else ($pid|tonumber) end),desired:$desired},location:$location,tickets:$tickets,decisions:$decisions}'
  else
    note "Campaign: $slug"
    note "Runner: $(if $active; then printf 'active (pid %s)' "$pid"; else printf 'inactive'; fi)$(
      [[ $desired != stopped ]] || { $active && printf ', stopping' || printf ', stopped'; })"
    jq -r '"Machine: \(.machine)\nProject: \(.project)\nWorktree: \(.worktree)\nOpen: \(.open)"' <<<"$location"
    jq -r '.[] | "\(.id)\t\(.status)\t\(.risk)\(if .executor then "\texecutor=\(.executor)" else "" end)"' <<<"$tickets"
    jq -r '.[] | "DECISION\t\(.ticket)\t\(.reason)\toptions=\(.options|join(","))"' <<<"$decisions"
  fi
}

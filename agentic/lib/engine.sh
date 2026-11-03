#!/usr/bin/env bash
# The campaign engine: decisions, ticket status and recovery, the worker delta, validation, review, integration, the run of
# one ticket and the loop that schedules them. Sourced by bin/campaign; it defines functions and variables and runs
# nothing.

create_decision() {
  local ticket=$1 category=$2 reason=$3 allow_retry=${4:-true} runtime options
  case "$category" in
    product-ambiguity|requirement-change|destructive-risk) ;;
    *) die "invalid human decision category: $category" ;;
  esac
  runtime=$(ensure_runtime)
  if [[ $allow_retry == true ]]; then options='["retry","block","cancel"]'; else options='["block","cancel"]'; fi
  jq -cn --arg ticket "$ticket" --arg category "$category" --arg reason "$reason" --argjson options "$options" \
    '{ticket:$ticket,category:$category,reason:$reason,options:$options,created_at:(now|todate)}' \
    >"$runtime/decisions/$ticket.json"
  chmod 600 "$runtime/decisions/$ticket.json"
  event decision-requested "$reason" "$ticket"
}

create_result_decision() {
  local ticket=$1 result=$2 category question
  category=$(jq -er '.human_decision.category' "$result") || return 1
  question=$(jq -er '.human_decision.question' "$result") || return 1
  create_decision "$ticket" "$category" "$question"
}

mark_ticket() {
  local ticket=$1 status=$2 reason=${3:-} slug runtime
  slug=$(campaign_slug); runtime=$(ensure_runtime)
  (
    flock -x 9
    commit_campaign_status "$ticket" "$status"
  ) 9>"$runtime/git.lock"
  case "$status" in
    blocked) event ticket-blocked "${reason:-blocked without a recorded reason}" "$ticket" ;;
    needs-human) event ticket-needs-human "${reason:-waiting for a human decision}" "$ticket" ;;
  esac
}

auto_recovery_limit() {
  local limit=${AGENTIC_AUTO_RECOVERIES:-2}
  [[ $limit =~ ^[0-9]$ ]] || die 'AGENTIC_AUTO_RECOVERIES must be a single digit'
  printf '%s\n' "$limit"
}

# Writes the evidence of the latest attempt as the diagnosis the next worker receives, after the coordinator's findings
# for the round (state/<ticket>.findings.md, which `campaign task fix` writes): a recovery never loses them.
write_recovery_diagnosis() {
  local ticket=$1 reason=$2 attempt=$3 limit=$4 runtime file receipt findings
  runtime=$(ensure_runtime); findings="$runtime/state/$ticket.findings.md"
  mkdir -p -- "$runtime/diagnosis"
  {
    if [[ -f $findings ]]; then
      printf "The coordinator's findings for this round, which the round must still apply:\n"
      cat -- "$findings"
      printf '\n'
    fi
    printf 'Automatic recovery %s/%s for %s. The previous attempt stopped: %s\n' "$attempt" "$limit" "$ticket" "$reason"
    printf 'Keep every valid part of the existing delta. Fix exactly what the evidence below reports, run the affected checks, and return PASS with that evidence. Do not return BLOCKED for lack of time.\n\n'
    for file in "$runtime/results/$ticket-review.json" "$runtime/results/$ticket-review-repair.json" \
                "$runtime/results/$ticket-worker.json" "$runtime/results/$ticket-repair.json"; do
      [[ -f $file ]] || continue
      printf -- '- %s: ' "$(basename -- "$file" .json)"
      jq -c '{status, summary: (.summary // "" | .[0:1500]), blocker, findings}' "$file" 2>/dev/null || printf 'unreadable\n'
    done
    for receipt in "$runtime"/validation/"$ticket".*.json; do
      [[ -f $receipt ]] || continue
      jq -e '.status == "FAIL"' "$receipt" >/dev/null 2>&1 || continue
      printf -- '- failed validation %s: ' "$(basename -- "$receipt" .json)"
      jq -c '{failed_command, reason, failed_tests: [.evidence[]?.failedTests[]?]}' "$receipt"
    done
  } >"$runtime/diagnosis/$ticket.md"
  chmod 600 "$runtime/diagnosis/$ticket.md"
}

# A technical block gets up to AGENTIC_AUTO_RECOVERIES fresh attempts guided by the evidence of the
# last one. Human decisions, a red campaign base and a failure of the environment are never retried automatically.
block_ticket() {
  local ticket=$1 status=$2 reason=$3 runtime count limit
  runtime=$(ensure_runtime); limit=$(auto_recovery_limit)
  count=$(cat -- "$runtime/state/$ticket.recoveries" 2>/dev/null || printf 0)
  if [[ $status == blocked && $reason != base-red:* && $reason != environment:* ]] && ((count < limit)); then
    count=$((count + 1))
    printf '%s\n' "$count" >"$runtime/state/$ticket.recoveries"
    write_recovery_diagnosis "$ticket" "$reason" "$count" "$limit"
    printf 'automatic recovery %s/%s\n' "$count" "$limit" >"$runtime/state/$ticket.retry"
    chmod 600 "$runtime/state/$ticket.retry" "$runtime/state/$ticket.recoveries"
    event ticket-blocked "$reason" "$ticket"
    event recovery-scheduled "automatic recovery $count/$limit with the previous evidence as diagnosis" "$ticket"
    return 0
  fi
  mark_ticket "$ticket" "$status" "$reason"
}

# After a rebase, every file the ticket changed must still carry the ticket's intent: identical to the
# ticket tip, or still different from the new upstream (merged). Prints lost files and fails otherwise.
verify_rebase_kept_changes() {
  local worktree=$1 old_tip=$2 old_base=$3 upstream=$4 file
  local -a lost=()
  while IFS= read -r -d '' file; do
    git -C "$worktree" diff --quiet "$old_tip" HEAD -- "$file" && continue
    git -C "$worktree" diff --quiet "$upstream" HEAD -- "$file" || continue
    lost+=("$file")
  done < <(git -C "$worktree" diff --no-renames --name-only -z "$old_base" "$old_tip")
  ((${#lost[@]} == 0)) && return 0
  printf '%s\n' "${lost[@]}"
  return 1
}

prepare_ticket() {
  local ticket=$1 slug runtime worktree branch
  slug=$(campaign_slug); runtime=$(ensure_runtime); worktree="$runtime/worktrees/$ticket"; branch="agentic/$slug/$ticket"
  (
    flock -x 9
    if [[ -d $worktree ]]; then
      [[ $(git -C "$worktree" symbolic-ref --quiet --short HEAD) == "$branch" ]] || die 'worktree ownership mismatch'
      rm -f -- "$runtime/state/$ticket.retry"
      # A clean worktree without commits of its own would validate stale code once the campaign advanced: catch it up.
      if [[ -z $(git -C "$worktree" status --porcelain=v1 --untracked-files=all) ]] &&
         git -C "$worktree" merge-base --is-ancestor HEAD "campaign/$slug"; then
        git_hooked -C "$worktree" merge --ff-only "campaign/$slug" >/dev/null || die "could not bring $ticket up to campaign/$slug"
      fi
    else
      git_hooked -C "$REPO_ROOT" worktree add -b "$branch" "$worktree" "campaign/$slug" >/dev/null
    fi
    printf '%s\n' "$$" >"$runtime/state/$ticket.active"
  ) 9>"$runtime/git.lock"
  printf '%s\n' "$worktree"
}

# True for a project instruction file (by name, at the root or in any folder), for the plan, runner and
# provider files that only the coordinator edits, and for the coordinator_paths globs of project.json.
is_coordinator_owned() {
  local path=$1 name
  for name in "${PROJECT_INSTRUCTION_FILES[@]}"; do
    [[ ${path##*/} == "$name" ]] && return 0
  done
  case "$path" in
    campaigns/*/SPEC.md|campaigns/*/tickets/*|campaigns/*/validation.json|campaigns/*/codex-effort.json|.agentic/*|.codex/*|.claude/*|.grok/*|.agents/skills/*) return 0 ;;
  esac
  ((${#PROJECT_COORDINATOR_REGEXES[@]} > 0)) && path_matches "$path" "${PROJECT_COORDINATOR_REGEXES[@]}" && return 0
  return 1
}

# drop_regen_paths WORKTREE TICKET: a task's worker may regenerate the regen_paths of project.json to validate, but its
# change never enters the commit: accept_regen regenerates them on the accept. A changed file goes back to HEAD, a new
# one is removed, and the event names them.
drop_regen_paths() {
  local worktree=$1 ticket=$2 path
  local -a dropped=()
  ((${#PROJECT_REGEN_REGEXES[@]} > 0)) || return 0
  while IFS= read -r -d '' path; do
    path_matches "$path" "${PROJECT_REGEN_REGEXES[@]}" || continue
    if git -C "$worktree" cat-file -e "HEAD:$path" 2>/dev/null; then
      # A checkout of a path runs the post-checkout hook, and the engine's runner.lock is open here.
      git_hooked -C "$worktree" checkout -q HEAD -- "$path" || return 1
    else
      git -C "$worktree" rm -q --cached --ignore-unmatch -- "$path" >/dev/null || return 1
      rm -f -- "$worktree/$path"
    fi
    dropped+=("$path")
  done < <(git -C "$worktree" diff --no-renames --name-only -z HEAD; git -C "$worktree" ls-files --others --exclude-standard -z)
  ((${#dropped[@]} == 0)) && return 0
  event regen-paths-dropped "the worker's changes to regen_paths stay out of the task's commit (accept_regen regenerates them): $(printf '%s, ' "${dropped[@]}" | sed 's/, $//' | head -c 1500)" "$ticket"
}

# True when an uncommitted path of the worktree is coordinator-owned (a plan or instruction edit awaiting review).
worktree_has_coordinator_changes() {
  local entry skip=false
  while IFS= read -r -d '' entry; do
    if $skip; then skip=false; is_coordinator_owned "$entry" && return 0; continue; fi
    [[ ${entry:0:1} == [RC] ]] && skip=true
    is_coordinator_owned "${entry:3}" && return 0
  done < <(git -C "$1" status --porcelain=v1 -z --untracked-files=all)
  return 1
}

commit_worker_delta() {
  local worktree=$1 ticket=$2 path whitespace message="feat(agentic): complete $2" fork
  [[ $(git -C "$worktree" symbolic-ref --quiet --short HEAD) == "agentic/$(campaign_slug)/$ticket" ]] || return 1
  fork=$(git -C "$worktree" merge-base "campaign/$(campaign_slug)" HEAD) || return 1
  # A task's commits carry its brief's message, and never its worker's change to a regen path.
  if campaign_is_task; then
    message=$(task_commit_message) || return 1
    drop_regen_paths "$worktree" "$ticket" || return 1
  fi
  # Enforce role ownership on actual edited files, without historical identity gates. A file the worker committed itself
  # (fork..HEAD) is as much its change as one it left uncommitted.
  while IFS= read -r -d '' path; do
    case "$path" in
      campaigns/*/validation.json)
        # A worker may propose a plan change; only the coordinator's reviewed copy is executable.
        cmp -s -- "$worktree/$path" "$REPO_ROOT/$path" && continue
        event harness-error 'validation plan change awaits coordinator review; delta preserved' "$ticket"
        return 1 ;;
    esac
    if is_coordinator_owned "$path"; then
      event harness-error 'worker edited coordinator-owned instructions; delta preserved' "$ticket"
      return 1
    fi
  done < <(git -C "$worktree" diff --no-renames --name-only -z "$fork" HEAD; git -C "$worktree" diff --no-renames --name-only -z HEAD; git -C "$worktree" ls-files --others --exclude-standard -z)
  # A CRLF file is not trailing whitespace: the configured whitespace checks stay, with cr-at-eol added.
  whitespace=$(git -C "$worktree" config --get core.whitespace || true)
  git -C "$worktree" -c "core.whitespace=${whitespace:+$whitespace,}cr-at-eol" diff --check || return 1
  if [[ -n $(git -C "$worktree" status --porcelain=v1) ]]; then
    git -C "$worktree" add -A || return 1
    git_hooked -C "$worktree" commit -m "$message" >/dev/null || return 1
  fi

}

result_status() { jq -r '.status | ascii_upcase' "$1"; }

# A failing baseline command is re-run on the campaign base (cached per campaign head). When the base fails
# too, the ticket did not cause it: report base-red instead of asking a worker to repair unrelated code. Never for a
# task, which usually creates what it validates.
base_is_red() {
  local runtime head marker
  if campaign_is_task; then return 1; fi
  runtime=$(ensure_runtime); head=$(git -C "$REPO_ROOT" rev-parse HEAD)
  marker="$runtime/state/baseline.$head"
  if [[ ! -f $marker ]]; then
    (
      flock -x 7
      [[ -f $marker ]] && exit 0
      if validation_baseline "$REPO_ROOT" >/dev/null 2>&1; then printf 'green\n' >"$marker"; else printf 'red\n' >"$marker"; fi
    ) 7>"$runtime/baseline.lock"
  fi
  [[ $(<"$marker") == red ]]
}

# --- Validation that fails before the change ------------------------------------------------------------------------
# Before the first worker of a ticket starts, its cheap and component commands run on the ticket's base commit, in a
# throwaway worktree: at least one must fail, or the validation does not prove the change and the ticket is refused before
# any worker runs. A ticket says validate_base: skip (with validate_base_reason) when its validation cannot fail on the
# base (a refactor, documentation). The outcome is kept in state/<ticket>.validate-base for as long as the base and the
# commands stay the same (validate_base_key), so a resumed run neither runs the check again nor forgets that the ticket was
# refused.

# validate_base_key WORKTREE TICKET: what an answer of the check depends on: the files of the base (the campaign's own
# folder aside: the status commits of the runner move the branch without changing what a command sees) and the cheap and
# component commands of the ticket's plan. The same key, the same answer.
validate_base_key() {
  {
    git -C "$1" ls-tree HEAD | awk -F'\t' '$2 != "campaigns"'
    jq -c --arg ticket "$2" '.tickets[$ticket] | [.cheap, .component]' "$(campaign_path)/validation.json"
  } | sha256sum | cut -c1-40
}

# validate_base_record STATE BASE KEY OUTCOME REASON: proves, skipped or refused, for that base (the commit, for people) and
# key (what decides whether the answer still holds).
validate_base_record() {
  jq -cn --arg base "$2" --arg key "$3" --arg outcome "$4" --arg reason "$5" --arg time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '{base:$base,key:$key,outcome:$outcome,reason:$reason,time:$time}' >"$1"
  chmod 600 "$1"
}

# The command line of an argv array for a person: quotes only what a shell would.
JQ_WORDS='map(if test("^[A-Za-z0-9_./:=@%+,-]+$") then . else @sh end) | join(" ")'

# validate_base_commands RECEIPT: the commands of the receipt that passed, separated by "; ".
validate_base_commands() {
  jq -r "[(.evidence // [])[] | select(.exitCode == 0) | .command | $JQ_WORDS | .[0:160]] | join(\"; \")" "$1"
}

# validate_base_remove TREE: the throwaway worktree of a base check, if it exists (a killed run leaves one).
validate_base_remove() {
  local tree=$1 runtime
  runtime=$(ensure_runtime)
  case $tree in "$runtime"/validate-base/?*) ;; *) die "unsafe validate-base path: $tree" ;; esac
  (
    flock -x 9
    if git -C "$REPO_ROOT" worktree list --porcelain | grep -Fx "worktree $tree" >/dev/null; then
      git -C "$REPO_ROOT" worktree remove --force -- "$tree" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$tree"
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  ) 9>"$runtime/git.lock"
}

# validate_base_checkout TREE BASE WORKTREE: TREE is a detached checkout of BASE. A task's ticket worktree also holds the
# brief's context (.task/) and the task_links, which no commit has: the check sees them too.
validate_base_checkout() {
  local tree=$1 base=$2 worktree=$3 runtime
  runtime=$(ensure_runtime)
  validate_base_remove "$tree"
  (
    flock -x 9
    git_hooked -C "$REPO_ROOT" worktree add --quiet --detach "$tree" "$base"
  ) 9>"$runtime/git.lock" || return 1
  if campaign_is_task; then
    if [[ -d $worktree/.task ]]; then cp -a -- "$worktree/.task" "$tree/.task" || return 1; fi
    (task_link "$tree") || return 1
  fi
}

# validate_base_check WORKTREE TICKET: 0 when the ticket may go to its worker; 3 when the check could not run (a harness
# error); 7 when a failure of the environment stopped it (`reason`, run_ticket's, says which); 9 when the ticket is refused
# because its validation passes on the base (or runs nothing there), its reason in `reason`.
validate_base_check() {
  local worktree=$1 ticket=$2 runtime state base key meta note tree receipt rc=0 failure passed failed detail short round
  runtime=$(ensure_runtime); state="$runtime/state/$ticket.validate-base"; receipt="$runtime/validation/base/$ticket.base.json"
  base=$(git -C "$worktree" rev-parse HEAD) || return 3
  short=${base:0:9}
  key=$(validate_base_key "$worktree" "$ticket") || return 3
  if [[ -f $state && $(jq -r '.key // ""' "$state" 2>/dev/null) == "$key" ]]; then
    [[ $(jq -r '.outcome' "$state") != refused ]] && return 0
    reason=$(jq -r '.reason' "$state")
    return 9
  fi
  # Only the first round of a task has a base without its delta: a later round (campaign task fix) starts on the branch that
  # already holds what the earlier rounds delivered, where its validate commands pass.
  round=$(jq -r 'if .kind == "task" then (.round // 1) else 1 end' "$runtime/campaign.json" 2>/dev/null) || round=1
  if [[ $round =~ ^[0-9]+$ ]] && ((round > 1)); then
    note="round $round of the task: its branch already holds the delta of the earlier rounds, so the validation may pass on the base $short"
    validate_base_record "$state" "$base" "$key" skipped "$note"
    event validate-base-skipped "$note" "$ticket"
    return 0
  fi
  meta=$(ticket_json "$ticket") || return 3
  if [[ $(jq -r '.validate_base // ""' <<<"$meta") == skip ]]; then
    note=$(jq -r '.validate_base_reason // ""' <<<"$meta")
    validate_base_record "$state" "$base" "$key" skipped "$note"
    event validate-base-skipped "validate_base: skip, so the validation was not run on the base $short: $note" "$ticket"
    return 0
  fi
  event validate-base-started "running the ticket's cheap and component commands on its base $short, in a throwaway worktree: at least one must fail" "$ticket"
  tree="$runtime/validate-base/$ticket"
  validate_base_checkout "$tree" "$base" "$worktree" || {
    event harness-error "could not check out the base $short to prove that the validation fails on it" "$ticket"
    return 3
  }
  rm -f -- "$receipt"
  validation_base "$tree" "$ticket" >"$runtime/logs/$ticket-validate-base.log" 2>&1 || rc=$?
  validate_base_remove "$tree"
  if ((rc == 0)); then
    if [[ $(jq -r '.status' "$receipt" 2>/dev/null) == NOT_REQUIRED ]]; then
      detail='it has no cheap or component command to run'
    else
      detail="passed: $(validate_base_commands "$receipt")"
    fi
    reason="validate already passes on the base: it does not prove the change ($detail)"
    validate_base_record "$state" "$base" "$key" refused "$reason"
    event validate-base-passes "$(head -c 1500 <<<"$reason"); base $short; set validate_base: skip and validate_base_reason in the ticket when it cannot fail there" "$ticket"
    return 9
  fi
  # A receipt written by this run tells which command failed; none means the check itself could not run.
  if [[ $(jq -r '.status // ""' "$receipt" 2>/dev/null) != FAIL ]]; then
    event harness-error "the check of the validation on the base $short could not run (see $runtime/logs/$ticket-validate-base.log)" "$ticket"
    return 3
  fi
  if failure=$(validation_environment_failure "$receipt"); then
    reason="environment: $failure, on the base"
    event environment-failure "base validation: $failure; blocked without a repair or an automatic recovery" "$ticket"
    return 7
  fi
  failed=$(jq -r ".failed_command | $JQ_WORDS | .[0:200]" "$receipt")
  passed=$(validate_base_commands "$receipt")
  validate_base_record "$state" "$base" "$key" proves ""
  event validate-base-proves "validate fails on the base $short, as it must: failed $failed; passed ${passed:-none}" "$ticket"
}

# Repairs of a red validation in one pass of validate_ticket (default 1, one digit).
validation_repair_limit() {
  local limit=${AGENTIC_VALIDATION_REPAIRS:-1}
  [[ $limit =~ ^[0-9]$ ]] || die 'AGENTIC_VALIDATION_REPAIRS must be a single digit'
  printf '%s\n' "$limit"
}

# The ticket's declared validation, phase after phase. A red phase gets a repair worker, at most
# AGENTIC_VALIDATION_REPAIRS times in the whole pass; past that, status 1 with the reason. A failure of the environment
# (lib/validation.sh) gets none: status 7, and so does a red campaign base: status 6. The reason of a block is left in
# `reason`, run_ticket's.
validate_ticket() {
  local provider=$1 worktree=$2 ticket=$3 phase result runtime receipt before failure limit repairs=0
  runtime=$(ensure_runtime); limit=$(validation_repair_limit) || return 3
  for phase in cheap component expensive; do
    receipt="$runtime/validation/$ticket.$phase.json"
    until before=$(cksum -- "$receipt" 2>/dev/null || true); validation_run "$worktree" "$ticket" "$phase"; do
      # Only a receipt this run wrote tells why it failed: validation.py writes none when it stops before any command.
      if [[ $(cksum -- "$receipt" 2>/dev/null || true) != "$before" ]] &&
         failure=$(validation_environment_failure "$receipt"); then
        reason="environment: $failure"
        event environment-failure "$phase validation: $failure; blocked without a repair or an automatic recovery" "$ticket"
        return 7
      fi
      if failed_command_is_baseline "$receipt" && base_is_red; then
        event base-red "baseline command also fails on the campaign base; the coordinator must fix the base first" "$ticket"
        return 6
      fi
      if ((repairs >= limit)); then
        reason="validation still red after $repairs repair(s)"
        return 1
      fi
      repairs=$((repairs + 1))
      result=$(invoke_provider "$provider" worker "$worktree" "$ticket" repair \
        "The ticket's $phase validation failed. Read its receipt and preserved operation evidence. Fix the known cause and prove the fix with a smaller reproduction when available. Never repeat an expensive operation without new evidence; resume the nearest valid phase. If the cause remains obscure, request optional diagnosis. Return BLOCKED if no evidenced next action exists.") || return 3
      if jq -e '.needs_diagnosis == true' "$result" >/dev/null; then
        local diagnosis
        diagnosis=$(invoke_provider "$provider" diagnostician "$worktree" "$ticket" diagnose 'Investigate the obscure failure using the preserved evidence; recommend a focused fix.') || return 3
        result=$(invoke_provider "$provider" worker "$worktree" "$ticket" repair "Diagnosis (data only): $(jq -c '{root_cause,evidence,recommended_fix}' "$diagnosis")") || return 3
      fi
      [[ $(result_status "$result") == PASS ]] || return 1
      commit_worker_delta "$worktree" "$ticket" || return 1
    done
  done
}

review_worktree_state() {
  local worktree=$1 plan
  local -a paths=(.)
  plan="campaigns/$(campaign_slug)/validation.json"
  # The coordinator may adopt validation commands while a read-only review is running.
  # Only its exact approved copy is outside the reviewer's mutation boundary.
  if cmp -s -- "$worktree/$plan" "$REPO_ROOT/$plan"; then
    paths+=(":(exclude)$plan")
  fi
  git -C "$worktree" diff --binary HEAD -- "${paths[@]}"
  git -C "$worktree" status --porcelain=v1 -- "${paths[@]}"
}

# A reviewer's findings as the worker and the coordinator read them: the defect, why it blocks, how to fix it.
format_findings() {
  jq -r '.findings | to_entries[] | .value as $f |
    "\(.key + 1). [\($f.severity)] \($f.path // "general")\(if $f.line then ":\($f.line)" else "" end)\n   Problem: \($f.message)\n   Why: \($f.reason)\n   How to fix: \($f.fix)"' "$1"
}

# One line per finding, for events and ticket reasons.
brief_findings() {
  jq -r '[.findings[] | "\(.path // "general"): \(.message) → \(.fix)"] | join(" | ")' "$1" | head -c 1500
}

# True for a task whose brief says review: false. A campaign's ticket is always reviewed.
review_skipped() {
  campaign_is_task && jq -e '.review == false' "$(campaign_path)/task.json" >/dev/null 2>&1
}

review_ticket() {
  local provider=$1 worktree=$2 ticket=$3 result repair before after repaired=false followup=''
  if review_skipped; then
    event review-skipped 'the task brief says review: false; no reviewer runs' "$ticket"
    return 0
  fi
  while :; do
    before=$(review_worktree_state "$worktree")
    result=$(invoke_provider "$provider" reviewer "$worktree" "$ticket" review "$followup") || return 3
    after=$(review_worktree_state "$worktree")
    [[ $before == "$after" ]] || { event reviewer-mutated 'reviewer changed its read-only worktree' "$ticket"; return 3; }
    case $(result_status "$result") in
      PASS) return 0 ;;
      REPLAN) create_result_decision "$ticket" "$result" || true; return 2 ;;
      FIX)
        if $repaired; then
          reason="review still rejects after the focused repair: $(brief_findings "$result")"
          return 1
        fi
        repaired=true
        repair=$(invoke_provider "$provider" worker "$worktree" "$ticket" review-repair \
          "The reviewer rejected this ticket. Review summary: $(jq -r '.summary' "$result" | head -c 1500)
$(format_findings "$result")
Apply each 'How to fix' (or an equivalent change that resolves the same 'Why'), then run the affected checks only. If a finding is factually wrong, do not work around it: keep the code and state the evidence in your summary; the next review reads it.") || return 3
        [[ $(result_status "$repair") == PASS ]] || { reason="the repair worker could not apply the review: $(jq -r '.blocker // .summary' "$repair" | head -c 800)"; return 1; }
        commit_worker_delta "$worktree" "$ticket" || return 1
        # The repaired code must pass the ticket's declared validation again before a fresh review.
        validate_ticket "$provider" "$worktree" "$ticket" || return $?
        # The fresh review judges the previous findings first; it does not move the goalposts.
        followup="Second review after a focused repair. Your previous findings:
$(format_findings "$result")
Repair worker summary: $(jq -r '.summary' "$repair" | head -c 1500)
Verify each previous finding against the code first. Return FIX again only for a previous finding that is still unresolved, or for a critical or major defect the repair introduced; say which in each finding."
        ;;
    esac
  done
}

# Exit codes: 0 integrated; 1 git failure; 4 rebase conflict or dropped change (aborted, delta preserved);
# 5 revalidation on the new base failed.
integrate_ticket() {
  local provider=$1 worktree=$2 ticket=$3 slug runtime branch rc=0
  slug=$(campaign_slug); runtime=$(ensure_runtime); branch="agentic/$slug/$ticket"
  (
    flock -x 9
    old_tip=$(git -C "$worktree" rev-parse HEAD) || exit 1
    old_base=$(git -C "$worktree" merge-base HEAD "campaign/$slug") || exit 1
    if ! rebase_output=$(git_hooked -C "$worktree" rebase "campaign/$slug" 2>&1); then
      conflicted=$(git -C "$worktree" diff --name-only --diff-filter=U | paste -sd, -)
      git_hooked -C "$worktree" rebase --abort >/dev/null 2>&1 || git -C "$worktree" reset -q --hard "$old_tip"
      printf '%s\n' "${conflicted:-unknown}" >"$runtime/state/$ticket.conflict"
      event integration-conflict "rebase onto campaign/$slug conflicted in: ${conflicted:-unknown}; aborted, delta preserved" "$ticket"
      exit 4
    fi
    if ! lost=$(verify_rebase_kept_changes "$worktree" "$old_tip" "$old_base" "campaign/$slug"); then
      git -C "$worktree" reset -q --hard "$old_tip"
      lost=$(paste -sd, - <<<"$lost")
      printf '%s\n' "$lost" >"$runtime/state/$ticket.conflict"
      event integration-conflict "rebase dropped ticket changes in: $lost; restored the ticket tip" "$ticket"
      exit 4
    fi
    if [[ $rebase_output != *"is up to date."* ]]; then
      # Re-run trusted non-expensive proof after the integrated base changed.
      validation_run "$worktree" "$ticket" cheap || exit 5
      validation_run "$worktree" "$ticket" component || exit 5
    fi
    git_hooked -C "$REPO_ROOT" merge --ff-only "$branch" >/dev/null || exit 1
    set_ticket_status "$ticket" done || exit 1
    # A task's status lives in its runtime: nothing to commit.
    if ! campaign_is_task; then
      git -C "$REPO_ROOT" add -- "$(ticket_path "$ticket")" || exit 1
      git_hooked -C "$REPO_ROOT" commit -m "chore(agentic): mark $ticket done" >/dev/null || exit 1
    fi
  ) 9>"$runtime/git.lock" || rc=$?
  ((rc == 0)) || return "$rc"
  safe_remove_ticket_worktree "$slug" "$ticket"
  rm -f -- "$runtime/state/$ticket.active" "$runtime/state/$ticket.base" "$runtime/state/$ticket.retry" \
    "$runtime/state/$ticket.recoveries" "$runtime/state/$ticket.conflict" "$runtime/state/$ticket.conflict.patch" \
    "$runtime/state/$ticket.reapplied" "$runtime/state/$ticket.findings.md" "$runtime/state/$ticket.validate-base" \
    "$runtime/diagnosis/$ticket.md"
  if review_skipped; then
    event ticket-done 'ticket passed validation and was integrated (review skipped)' "$ticket"
  else
    event ticket-done 'ticket passed review and was integrated' "$ticket"
  fi
}

# reapply_delta WORKTREE BASE ONTO PATCH: the delta of WORKTREE since BASE (its commits), saved in PATCH, re-applied on
# ONTO, where WORKTREE is reset. Conflicting hunks stay as markers in the working tree, and the index is left clean for the
# worker; prints the paths that conflicted, one per line. A file the delta deletes and ONTO no longer has stays out of
# PATCH: both sides agree. An empty delta (WORKTREE holds the tree of BASE, or only such deletions) only resets WORKTREE.
# A delta that no worker could resolve from markers fails with 2 (1 is a git error): WORKTREE goes back to its HEAD, PATCH
# stays, and the reason is printed on one line, as the clause that follows "the delta does not apply on ONTO":
# - git apply is atomic, and a path the delta changes that ONTO no longer has (deleted or renamed since BASE) has no
#   3-way fallback: the whole patch is rejected, with no conflict at all;
# - a conflict git leaves without markers (unmarked_conflicts: a binary file, a -merge or merge=binary attribute, a merge
#   driver) shows one side's version alone, and a worker resolving markers would commit it: a person merges it;
# - any other rejection of the whole patch (a delta that deletes a file ONTO changed, say) gives git apply's errors.
reapply_delta() {
  local worktree=$1 base=$2 onto=$3 patch=$4 head errors conflicted path lost unmarked why='' rc=0
  local -a agreed=()
  head=$(git -C "$worktree" rev-parse HEAD) || return 1
  while IFS= read -r -d '' path; do
    git -C "$worktree" cat-file -e "$onto:$path" 2>/dev/null || agreed+=(":(top,literal,exclude)$path")
  done < <(git -C "$worktree" diff -z --name-only --no-renames --diff-filter=D "$base" "$head")
  git -C "$worktree" diff --binary "$base" "$head" -- "${agreed[@]}" >"$patch" || return 1
  chmod 600 "$patch"
  git -C "$worktree" reset -q --hard "$onto" || return 1
  [[ -s $patch ]] || return 0
  errors=$(git -C "$worktree" apply --3way "$patch" 2>&1 >/dev/null) || rc=$?
  conflicted=$(git -C "$worktree" -c core.quotePath=false diff --name-only --diff-filter=U) || return 1
  if [[ -n $conflicted ]]; then
    if unmarked=$(unmarked_conflicts "$worktree" <<<"$conflicted"); then
      why="where both sides changed files that git merges without conflict markers (binary, or a merge attribute such as -merge), which only a person can merge: ${unmarked//$'\n'/; }"
    fi
  elif ((rc != 0)); then
    if lost=$(delta_lost_paths "$worktree" "$base" "$head" "$onto"); then
      why="which no longer has files it changes: ${lost//$'\n'/; }"
    else
      errors=$(grep -E '^(error|fatal):' <<<"$errors" | head -n 5) || true
      why="as git apply rejected the whole patch: ${errors:-it printed no error}"
      why=${why//$'\n'/; }
    fi
  fi
  if [[ -n $why ]]; then
    git -C "$worktree" reset -q --hard "$head" || return 1
    printf '%s\n' "$(head -c 1200 <<<"$why")"
    return 2
  fi
  [[ -z $conflicted ]] || printf '%s\n' "$conflicted"
  git -C "$worktree" reset -q || return 1
}

# unmarked_conflicts WORKTREE: of the conflicted paths read from stdin, one per line, the ones git left without conflict
# markers: the working tree holds one side's version whole (or no file), so the other side's change shows nowhere.
# Fails when there is none.
unmarked_conflicts() {
  local worktree=$1 path ours theirs current found=false
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    ours=$(git -C "$worktree" rev-parse -q --verify ":2:$path") || ours=''
    theirs=$(git -C "$worktree" rev-parse -q --verify ":3:$path") || theirs=''
    current=$(git -C "$worktree" hash-object -- "$path" 2>/dev/null) || current=''
    [[ $ours != "$theirs" ]] || continue
    [[ -z $current || $current == "$ours" || $current == "$theirs" ]] || continue
    printf '%s\n' "$path"
    found=true
  done
  $found
}

# delta_lost_paths WORKTREE BASE HEAD ONTO: one line per path that the delta BASE..HEAD changes and ONTO no longer has,
# "PATH (renamed to NEW since the base)" or "PATH (deleted since the base)"; fails when there is none. A path the delta
# deletes is never listed: ONTO either still has it or deleted it too, and then reapply_delta left it out of the patch.
delta_lost_paths() {
  local worktree=$1 base=$2 head=$3 onto=$4 path renamed found=false
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    git -C "$worktree" cat-file -e "$onto:$path" 2>/dev/null && continue
    renamed=$(git -C "$worktree" -c core.quotePath=false diff --name-status -M --diff-filter=R "$base" "$onto" \
      | awk -F'\t' -v path="$path" '$2 == path { print $3; exit }')
    if [[ -n $renamed ]]; then printf '%s (renamed to %s since the base)\n' "$path" "$renamed"
    else printf '%s (deleted since the base)\n' "$path"; fi
    found=true
  done < <(git -C "$worktree" -c core.quotePath=false diff --name-only --no-renames --diff-filter=MT "$base" "$head")
  $found
}

# integration_repair PROVIDER WORKTREE TICKET PROMPT: a fresh worker resolves the conflict markers of a re-applied delta;
# fails (1) when it does not PASS or a marker remains.
integration_repair() {
  local provider=$1 worktree=$2 ticket=$3 result
  result=$(invoke_provider "$provider" worker "$worktree" "$ticket" integration-repair "$4") || return 3
  [[ $(result_status "$result") == PASS ]] || { reason="the integration repair worker returned $(result_status "$result"): $(jq -r '.blocker // .summary' "$result" | head -c 800)"; return 1; }
  if git -C "$worktree" grep --untracked -I -q -E '^(<<<<<<<|>>>>>>>)( |$)' -- .; then
    event harness-error 'conflict markers remain after the integration repair; delta preserved' "$ticket"
    reason='conflict markers remain after the integration repair'
    return 1
  fi
}

# Re-applies the ticket's delta on the current campaign head and lets a fresh worker resolve the conflict
# markers, then proves the result again (validation and review) before the next integration attempt. A delta that no
# worker could resolve from markers fails with 8, its reason in `reason`: the ticket waits for a person (needs-human).
resolve_integration_conflict() {
  local provider=$1 worktree=$2 ticket=$3 slug runtime files patch output rc=0
  slug=$(campaign_slug); runtime=$(ensure_runtime)
  files=$(cat -- "$runtime/state/$ticket.conflict" 2>/dev/null || printf unknown)
  patch="$runtime/state/$ticket.conflict.patch"
  output=$(
    exec 9>"$runtime/git.lock"
    flock -x 9
    base=$(git -C "$worktree" merge-base HEAD "campaign/$slug") || exit 1
    reapply_delta "$worktree" "$base" "campaign/$slug" "$patch"
  ) || rc=$?
  if ((rc == 2)); then
    # No worker can resolve it from markers, nor can an automatic recovery: the ticket keeps its commits (and the copy
    # of its delta stays until it integrates), and a person decides.
    reason="the ticket's delta does not apply on campaign/$slug, $output; its commits and a copy of the delta ($patch) are kept"
    event harness-error "$reason" "$ticket"
    return 8
  fi
  ((rc == 0)) || return 1
  integration_repair "$provider" "$worktree" "$ticket" \
    "The campaign advanced while this ticket ran and integrating it conflicted in: ${files}. The ticket's changes were re-applied on top of the current campaign; conflict markers (<<<<<<<, =======, >>>>>>>) remain where both sides changed the same code. Resolve every marker keeping both intents: the campaign's newer changes and this ticket's acceptance. Then run the ticket's affected checks. The original ticket delta is at ${patch} for reference." || return $?
  commit_worker_delta "$worktree" "$ticket" || return 1
  validate_ticket "$provider" "$worktree" "$ticket" || return $?
  review_ticket "$provider" "$worktree" "$ticket" || return $?
}

# The prompt of the integration repair that starts a task's round after `campaign task fix --rebase` re-applied its delta
# on the main branch (state/<ticket>.reapplied names the paths that conflicted).
reapplied_prompt() {
  local ticket=$1 runtime files
  runtime=$(ensure_runtime)
  files=$(paste -sd, - <"$runtime/state/$ticket.reapplied" 2>/dev/null)
  printf "The task's base moved to the current %s (task fix --rebase): its delta was re-applied mechanically on top of it, never rebased, and conflicted in: %s. Conflict markers (<<<<<<<, =======, >>>>>>>) remain where both sides changed the same code. Resolve every marker keeping both intents: the newer changes of %s and this task's acceptance. Then apply the coordinator's findings below and run the task's checks. The task's delta before the move is at %s for reference." \
    "$MAIN_BRANCH" "${files:-none, it applied cleanly}" "$MAIN_BRANCH" "$runtime/state/$ticket.conflict.patch"
}

# The final validation runs in a machine slot of its own: finalize takes it before its locks, and a caller that holds
# none takes it here.
run_final_validation() {
  local held=${AGENTIC_SLOT:-} rc=0
  slot_take validation "$(campaign_slug)/final" || return $?
  validation_final "$@" || rc=$?
  [[ -n $held ]] || slot_release
  return "$rc"
}

# The campaign's hooks of lib/slots.sh: the wait for a machine slot and its take are events of the round's ticket
# (slot_ticket, set by run_ticket) or of the campaign (finalize, which also says it on stderr), and a stop request ends
# the wait of a round as it ends a wait for quota. So does the death of the engine that started the round ($$ is the
# engine's pid in its background rounds): an orphan round waiting for a slot would hold the runner.lock it inherited for
# as long as the machine stays full, and the campaign could not be launched again.
slot_waiting() {
  [[ -n ${slot_ticket:-} ]] || printf 'campaign: waiting for a machine slot (%s of %s in the queue, %s slots)\n' "$2" "$3" "$4" >&2
  event waiting-slot "kind=$1 position=$2 queue=$3 slots=$4; every slot of this machine is busy, this waits its turn" "${slot_ticket:-}"
}
slot_taken() { event slot-taken "kind=$1 slot=$2 slots=$3" "${slot_ticket:-}"; }
slot_stopping() {
  [[ -n ${slot_ticket:-} ]] || return 1
  if ! engine_alive "$$"; then
    event waiting-slot "kind=$1 the engine that started this round is gone; the wait for a machine slot ends, product status and delta preserved for the next run" "$slot_ticket"
    return 0
  fi
  [[ $(desired_state) == stopped ]] || return 1
  event waiting-slot "kind=$1 stop requested during the wait for a machine slot; product status and delta preserved for the next run" "$slot_ticket"
}
# engine_alive PID: PID runs (a zombie waiting to be reaped does not).
engine_alive() {
  local stat
  kill -0 "$1" 2>/dev/null || return 1
  IFS= read -r stat 2>/dev/null <"/proc/$1/stat" || return 1
  [[ ${stat##*) } != Z* ]]
}

WORKER_INTERRUPTED_DIAGNOSIS="The previous worker stopped before it finished (for example, a provider usage limit or a restart killed it). Any uncommitted change in the worktree is its partial, unverified work: compare it with the ticket's Acceptance, finish what is missing and remove anything the ticket does not ask for, then run the ticket's cheap checks."

run_ticket() {
  local provider=$1 ticket=$2 worktree result runtime rc=0 existing=false recovering=false interrupted=false attempt reason='' base
  runtime=$(ensure_runtime)
  if [[ -d "$runtime/worktrees/$ticket" ]]; then
    # The ticket's own delta: its commits and uncommitted changes since the merge base, never the campaign's newer commits.
    base=$(git -C "$runtime/worktrees/$ticket" merge-base "campaign/$(campaign_slug)" HEAD)
    if ! git -C "$runtime/worktrees/$ticket" diff --quiet "$base" -- . ':(exclude)campaigns' ||
       [[ -n $(git -C "$runtime/worktrees/$ticket" ls-files --others --exclude-standard) ]]; then
      existing=true
    fi
  fi
  # A recovery with a diagnosis always starts with a worker applying it (prepare_ticket consumes the marker).
  if [[ -f "$runtime/state/$ticket.retry" && -f "$runtime/diagnosis/$ticket.md" ]]; then recovering=true; fi
  # The runner commits the worker delta right after a PASS, so uncommitted changes mean the worker never finished
  # (for example, a provider usage limit killed it). An explicit `campaign recover` keeps meaning "use the delta".
  # Changes awaiting coordinator review (plan, instructions) are the exception: the runner refused to commit a
  # finished delta, so it is validated as it is once reviewed.
  if $existing && ! $recovering && [[ ! -f "$runtime/state/$ticket.retry" ]]; then
    if [[ -n $(git -C "$runtime/worktrees/$ticket" status --porcelain) ]] &&
       ! worktree_has_coordinator_changes "$runtime/worktrees/$ticket"; then
      interrupted=true
    fi
  fi
  worktree=$(prepare_ticket "$ticket") || return 3
  event ticket-started 'fresh ticket context; existing delta is reused' "$ticket"
  # The round holds one slot of the machine to its end (this subshell's exit): worker, validation, diagnosis, repairs,
  # review and integration, and a wait for quota keeps it. Taken after the start, so the overview shows the ticket in
  # progress, waiting for a slot.
  local slot_ticket=$ticket
  trap slot_release EXIT
  slot_take provider "$(campaign_slug)/$ticket" || { rc=$?; return $((rc == 1 ? 3 : rc)); }
  if [[ -f "$runtime/state/$ticket.reapplied" ]]; then
    # `campaign task fix --rebase` re-applied the task's delta on the main branch: the round starts with the integration
    # repair, which resolves the conflict markers and applies the coordinator's findings (the diagnosis).
    integration_repair "$provider" "$worktree" "$ticket" "$(reapplied_prompt "$ticket")" || rc=$?
    if ((rc == 3)); then return 3; fi
    if ((rc != 0)); then
      rm -f -- "$runtime/state/$ticket.active"
      block_ticket "$ticket" blocked "${reason:-the integration repair could not resolve the re-applied delta}"
      return 0
    fi
    rm -f -- "$runtime/state/$ticket.reapplied"
  elif ! $existing || $recovering || $interrupted; then
    if $interrupted; then
      event worker-interrupted 'the previous worker stopped before finishing; its uncommitted delta goes to a recovery worker' "$ticket"
      result=$(invoke_provider "$provider" worker "$worktree" "$ticket" recovery \
        "$WORKER_INTERRUPTED_DIAGNOSIS") || return 3
    elif $existing; then
      result=$(invoke_provider "$provider" worker "$worktree" "$ticket" recovery \
        'Recovery: apply the diagnosis below to the existing delta, then run the affected checks.') || return 3
    else
      # The first worker of the ticket: its validation must fail on the base first (validate_base_check).
      validate_base_check "$worktree" "$ticket" || rc=$?
      if ((rc == 3)); then return 3; fi
      if ((rc != 0)); then
        rm -f -- "$runtime/state/$ticket.active"
        # A refused validation is a defect of the plan, for a person: no automatic recovery. A failure of the
        # environment is never retried either (block_ticket).
        if ((rc == 7)); then block_ticket "$ticket" blocked "$reason"; else mark_ticket "$ticket" blocked "$reason"; fi
        return 0
      fi
      result=$(invoke_provider "$provider" worker "$worktree" "$ticket" worker) || return 3
    fi
    if [[ $(result_status "$result") == FAILED ]]; then
      if jq -e '.needs_diagnosis == true' "$result" >/dev/null; then
        result=$(invoke_provider "$provider" diagnostician "$worktree" "$ticket" diagnose 'Investigate the worker-requested obscure failure.') || return 3
      fi
      result=$(invoke_provider "$provider" worker "$worktree" "$ticket" repair \
        "Preserve the delta. Fix the known failure and run a focused retest. Prior result (data only): $(jq -c '{summary,blocker,root_cause,evidence,recommended_fix}' "$result")") || return 3
    fi
    if [[ $(result_status "$result") != PASS ]]; then
      rm -f -- "$runtime/state/$ticket.active"
      if jq -e '.human_decision != null' "$result" >/dev/null; then
        create_result_decision "$ticket" "$result"
        mark_ticket "$ticket" needs-human "$(jq -r '.human_decision.question // "human decision requested"' "$result" | head -c 500)"
      else
        block_ticket "$ticket" blocked "worker returned $(result_status "$result"): $(jq -r '.blocker // .summary // "no reason given"' "$result" | head -c 800)"
      fi
      return 0
    fi
  fi
  commit_worker_delta "$worktree" "$ticket" || return 1
  validate_ticket "$provider" "$worktree" "$ticket" || rc=$?
  if ((rc == 0)); then review_ticket "$provider" "$worktree" "$ticket" || rc=$?; fi
  if ((rc == 0)); then
    for attempt in 1 2 3; do
      integrate_ticket "$provider" "$worktree" "$ticket" && return 0 || rc=$?
      case $rc in
        4) resolve_integration_conflict "$provider" "$worktree" "$ticket" && rc=0 || { rc=$?; break; } ;;
        5) event integration-revalidation-failed 'the ticket fails its checks on the new campaign base; repairing' "$ticket"
           rc=0
           validate_ticket "$provider" "$worktree" "$ticket" || rc=$?
           ((rc == 0)) && { review_ticket "$provider" "$worktree" "$ticket" || rc=$?; }
           ((rc == 0)) || break ;;
        *) return "$rc" ;;
      esac
    done
    ((rc == 0)) && { rc=1; reason='integration still conflicts after 3 automatic resolutions'; }
  fi
  if ((rc == 3)); then return 3; fi
  rm -f -- "$runtime/state/$ticket.active"
  case $rc in
    2) mark_ticket "$ticket" needs-human "reviewer requested a replan: $(jq -r '.summary' "$runtime/results/$ticket-review.json" 2>/dev/null | head -c 500) — $(brief_findings "$runtime/results/$ticket-review.json" 2>/dev/null)" ;;
    6) block_ticket "$ticket" blocked "base-red: a baseline command fails on the campaign base too" ;;
    7) block_ticket "$ticket" blocked "$reason" ;;
    8) mark_ticket "$ticket" needs-human "$reason" ;;
    *) block_ticket "$ticket" blocked "${reason:-validation or review could not reach PASS after the focused repair}" ;;
  esac
  return 0
}

# A ticket scan of the campaign branch. An integration rewrites ticket files there (the merged files git checks out, the
# status it marks), so a scan in that instant can find one missing or half written: it reads again before giving up.
scan_tickets() {
  local attempt
  for attempt in 1 2 3 4; do
    python3 "$TICKET_TOOL" "$@" 2>/dev/null && return 0
    sleep 1
  done
  python3 "$TICKET_TOOL" "$@"
}

engine_loop() {
  local provider=$1 workers=$2 slug runtime ready statuses running=0 ticket pid active_json candidate domains occupied collision domain wait_rc
  local capacity=$2 executor name slots busy executors='' machine_slots
  assert_campaign_branch; slug=$(campaign_slug); runtime=$(ensure_runtime "$slug")
  # The engine outlives whoever launched it: a slot it inherited is not its rounds' (each round takes its own).
  unset AGENTIC_SLOT
  machine_slots=$(slot_capacity)
  exec 8>"$runtime/runner.lock"
  # A just-finished follower can release its process before every inherited
  # descriptor is reaped. Allow that bounded handoff, while still refusing a
  # genuinely concurrent supervisor.
  flock -w 1 8 || die "runner already active for $slug"
  printf '%s\n' "$$" >"$runtime/runner.pid"
  chmod 600 "$runtime/runner.pid"
  trap "rm -f -- '$runtime/runner.pid'" EXIT
  # Stopped (campaign stop --now): end here, without going on from the interrupted wait.
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # Capacity is the local workers plus every executor's. A starting ticket takes the first executor (in settings order)
  # with a free slot, else a local one, and keeps that slot until it ends, even when it goes on locally because its
  # executor became unavailable.
  local -a executor_names=()
  declare -A executor_slots=()
  while IFS=$'\t' read -r name slots; do
    [[ -n $name ]] || continue
    executor_names+=("$name"); executor_slots[$name]=$slots; capacity=$((capacity + slots)); executors+=" $name:$slots"
  done < <(jq -r '.[] | "\(.name)\t\(.workers)"' <<<"$PROJECT_EXECUTORS")
  event runner-started "provider=$provider workers=$workers${executors:+ executors=${executors# } capacity=$capacity}${machine_slots:+ machine_slots=$machine_slots}"
  # Interrupted processes leave evidence and worktrees intact; stale markers are not authority.
  rm -f -- "$runtime"/state/*.active "$runtime"/state/*.executor
  declare -A jobs=()
  declare -A job_domains=()
  declare -A job_executors=()
  local failed_ids='[]'
  while :; do
    # A coordinator recovery authorizes one new attempt after a known technical repair. The ticket is released
    # here; the marker itself stays until prepare_ticket consumes it, so run_ticket still knows the recovery was
    # explicit (use the existing delta) and does not take an uncommitted delta for an interrupted worker.
    while IFS= read -r ticket; do
      if [[ -f "$runtime/state/$ticket.retry" ]]; then
        failed_ids=$(jq --arg id "$ticket" 'map(select(. != $id))' <<<"$failed_ids")
      fi
    done < <(jq -r '.[]' <<<"$failed_ids")
    ready=$(scan_tickets ready "$(tickets_path)")
    ready=$(jq --argjson ids "$failed_ids" '[.[] | select((.id as $id | $ids | index($id)) == null)]' <<<"$ready")
    active_json=$(printf '%s\n' "${jobs[@]:-}" | jq -Rsc 'split("\n") | map(select(length>0))')
    ready=$(jq --argjson active "$active_json" '[.[] | select((.id as $id | $active | index($id)) == null)]' <<<"$ready")
    while ((running < capacity)) && (($(jq 'length' <<<"$ready") > 0)) && [[ $(desired_state "$slug") != stopped ]]; do
      candidate=''; occupied=$'\n'
      for pid in "${!job_domains[@]}"; do occupied+="${job_domains[$pid]}"$'\n'; done
      while (($(jq 'length' <<<"$ready") > 0)); do
        ticket=$(jq -r '.[0].id' <<<"$ready")
        domains=$(jq -r '.[0].collision_domains | if length == 0 then ["__unknown_scope__"] else . end | .[]' <<<"$ready")
        ready=$(jq '.[1:]' <<<"$ready")
        collision=false
        while IFS= read -r domain; do
          [[ -z $domain ]] && continue
          if grep -Fxq -- "$domain" <<<"$occupied"; then collision=true; break; fi
        done <<<"$domains"
        if ! $collision; then candidate=$ticket; break; fi
      done
      [[ -n $candidate ]] || break
      ticket=$candidate
      executor=local
      for name in "${executor_names[@]}"; do
        busy=0
        for pid in "${!job_executors[@]}"; do
          if [[ ${job_executors[$pid]} == "$name" ]]; then busy=$((busy + 1)); fi
        done
        if ((busy < ${executor_slots[$name]})); then executor=$name; break; fi
      done
      # Every worker-role invocation of the ticket in this run reads its executor from this file.
      printf '%s\n' "$executor" >"$runtime/state/$ticket.executor"
      if ((${#executor_names[@]} > 0)); then event executor-assigned "executor=$executor" "$ticket"; fi
      run_ticket "$provider" "$ticket" &
      pid=$!; jobs[$pid]=$ticket; job_domains[$pid]=$domains; job_executors[$pid]=$executor; running=$((running + 1))
    done
    if ((running > 0)); then
      # A free slot rescans the queue every minute, so a ticket released by `decide` or `recover`, or added to the
      # plan, starts without waiting for a running ticket to end.
      rescan_timer=''
      # The timer does not inherit the runner.lock: an engine killed alone would stay "active" for the whole minute.
      if ((running < capacity)); then sleep "${AGENTIC_RESCAN_SECONDS:-60}" 8>&- & rescan_timer=$!; fi
      set +e; wait -n -p pid; wait_rc=$?; set -e
      if [[ -n $rescan_timer ]]; then
        [[ $pid == "$rescan_timer" ]] && continue
        kill "$rescan_timer" 2>/dev/null; wait "$rescan_timer" 2>/dev/null || true
      fi
      ticket=${jobs[$pid]}
      unset 'jobs[$pid]' 'job_domains[$pid]' 'job_executors[$pid]'; running=$((running - 1))
      rm -f -- "$runtime/state/$ticket.executor"
      if ((wait_rc != 0)); then
        rm -f -- "$runtime/state/$ticket.active"
        failed_ids=$(jq --arg id "$ticket" '. + [$id]' <<<"$failed_ids")
        event harness-error 'pipeline unavailable; product status and delta preserved' "$ticket"
      fi
      continue
    fi
    if [[ $(desired_state "$slug") == stopped ]]; then
      event runner-stopped 'stopped on request: no new ticket started and the running ones ended'
      break
    fi
    statuses=$(scan_tickets list "$(tickets_path)")
    if jq -e 'all(.[]; .status == "done" or (.required == false))' >/dev/null <<<"$statuses"; then
      event campaign-complete 'all required tickets done; campaign-wide proof belongs to finalize'
    elif jq -e 'any(.[]; .status == "todo")' >/dev/null <<<"$statuses"; then
      event runner-paused 'remaining todo tickets have unsatisfied dependencies'
    else
      event runner-paused 'campaign has blocked or needs-human tickets'
    fi
    break
  done
}

# The baseline lists repository-wide commands that must already pass on the campaign base. A red base would
# fail every ticket, so the runner refuses to start until the coordinator fixes it.
require_green_baseline() {
  local runtime=$1 head marker
  plan_has_baseline || return 0
  head=$(git -C "$REPO_ROOT" rev-parse HEAD); marker="$runtime/state/baseline.$head"
  [[ -f $marker && $(<"$marker") == green ]] && return 0
  if validation_baseline "$REPO_ROOT" >/dev/null 2>&1; then
    printf 'green\n' >"$marker"
    return 0
  fi
  printf 'red\n' >"$marker"
  event baseline-red 'a baseline command fails on the campaign base; no ticket was started'
  die "campaign base is red: a baseline command fails before any ticket runs (see $runtime/validation/campaign.baseline.json)"
}

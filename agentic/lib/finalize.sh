#!/usr/bin/env bash
# Finalizing a campaign into the main branch, and cleaning up after it: the history archive, the finalized marker, the
# finalizing marker, the checkpointed finalize and cleanup. Sourced by bin/campaign; it defines functions and variables
# and runs nothing.

# Keeps what the campaign learned (events, results, decisions, diagnoses, receipts) after its cache is removed.
archive_campaign_history() {
  local slug=$1 runtime=$2 tree=$3 target item relative=${PROJECT_ARCHIVE_DIR%/}
  # project.json archive_dir ({date}, {slug}) is used only inside the main worktree and only when git ignores it.
  relative=${relative//\{date\}/$(date +%F)}; relative=${relative//\{slug\}/$slug}
  if [[ -n $relative && $relative != /* && /$relative/ != */../* ]] &&
     git -C "$tree" check-ignore -q "$relative/events" 2>/dev/null; then
    target="$tree/$relative"
  else
    target="$(dirname -- "$runtime")/archive/$slug-$(date +%Y%m%dT%H%M%S)"
  fi
  mkdir -p -- "$target"
  for item in events results decisions diagnosis validation run-config.json finalize.json campaign.json brief.md RESULT.md; do
    [[ -e $runtime/$item ]] && cp -a -- "$runtime/$item" "$target/"
  done
  rm -rf -- "$target/validation/logs"
  note "Campaign history archived at $target"
}

# Durable proof that a campaign reached the main branch, kept outside its runtime (which finalize deletes). A queue started
# again never initializes a slug that carries one; `campaign init` of the same slug clears it.
finalized_marker() { printf '%s/finalized/%s.json\n' "$(runtime_base)" "$1"; }

mark_finalized() {
  local slug=$1 tree=$2 file
  file=$(finalized_marker "$slug")
  mkdir -p -- "$(dirname -- "$file")"
  jq -cn --arg slug "$slug" --arg head "$(git -C "$tree" rev-parse "$MAIN_BRANCH")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{slug:$slug,main_branch_head:$head,finalizedAtUtc:$at}' >"$file"
  chmod 600 "$file"
}

# <cache>/main.lock (flock) serializes whatever moves this machine's main branch: two finalizes, or a finalize and an
# accept, would otherwise race between the is-ancestor check and the fast-forward. Its holder (pid and command) is
# written next to it, in main.lock.holder, for whoever has to wait. The lock is held as a machine slot is (slot_guard of
# lib/slots.sh): by a guard process of the holder that has no other descriptor and ends with it, so no command the holder
# starts inherits it, a process the validation leaves running (a build server, a container) never holds the main branch,
# and the lock comes back when the holder ends, even by SIGKILL.
main_lock_file() { printf '%s/main.lock\n' "$(runtime_base)"; }

# "pid N (command)" of the process that holds main.lock, as it last wrote itself down.
main_lock_holder() {
  local pid='' command=''
  IFS=$'\t' read -r pid command <"$(main_lock_file).holder" 2>/dev/null || true
  if [[ $pid =~ ^[0-9]+$ ]]; then printf 'pid %s (%s)' "$pid" "${command:-unknown command}"; else printf 'an unknown process'; fi
}

# main_lock_acquire: takes main.lock, waiting up to AGENTIC_MAIN_LOCK_WAIT_SECONDS (default 1800) for its holder, then
# dies saying who holds it. A process that already holds it keeps it (the lock is not counted).
main_lock_acquire() {
  local file wait=${AGENTIC_MAIN_LOCK_WAIT_SECONDS:-1800} holder fd slot_guard_pid
  [[ -z ${MAIN_LOCK_GUARD:-} ]] || return 0
  [[ $wait =~ ^[0-9]+$ ]] || die "AGENTIC_MAIN_LOCK_WAIT_SECONDS must be a whole number of seconds: $wait"
  file=$(main_lock_file)
  mkdir -p -- "$(dirname -- "$file")"
  chmod 700 "$(dirname -- "$file")" 2>/dev/null || true
  exec {fd}>>"$file"
  if ! flock -n "$fd"; then
    note "Waiting for the main branch lock, held by $(main_lock_holder) (up to ${wait}s)..."
    if ! flock -w "$wait" "$fd"; then
      holder=$(main_lock_holder)
      exec {fd}>&-
      die "main.lock is still held by $holder after ${wait}s ($file); wait for it to end, or raise AGENTIC_MAIN_LOCK_WAIT_SECONDS"
    fi
  fi
  # The guard takes the descriptor over and this process closes its own, before it starts anything else. slot_guard names
  # its guard in SLOT_GUARD, which belongs to the slot this process may hold: it is given back.
  slot_guard_pid=${SLOT_GUARD:-}
  slot_guard "$fd"
  MAIN_LOCK_GUARD=$SLOT_GUARD SLOT_GUARD=$slot_guard_pid
  exec {fd}>&-
  # Kept for the release: the cache path is resolved from the worktree, which finalize removes before it releases.
  MAIN_LOCK_HOLDER_FILE="$file.holder"
  printf '%s\t%s\n' "$$" "$(tr '\0' ' ' <"/proc/$$/cmdline" 2>/dev/null | sed 's/ *$//')" >"$file.holder"
}

main_lock_release() {
  local guard=${MAIN_LOCK_GUARD:-}
  [[ -n $guard ]] || return 0
  MAIN_LOCK_GUARD=''
  rm -f -- "${MAIN_LOCK_HOLDER_FILE:-}"
  kill "$guard" 2>/dev/null || true
  wait "$guard" 2>/dev/null || true
}

# with_main_lock COMMAND [ARGUMENT...]: runs the command holding main.lock, and returns its status.
with_main_lock() {
  local held=${MAIN_LOCK_GUARD:-} status=0
  main_lock_acquire
  "$@" || status=$?
  [[ -n $held ]] || main_lock_release
  return "$status"
}

main_worktree() {
  git -C "$REPO_ROOT" worktree list --porcelain | awk -v main="$MAIN_BRANCH" '
    /^worktree / {path=substr($0,10)}
    $0 == "branch refs/heads/" main && !found {print path; found=1}
  '
}

# What makes a worktree dirty, for the message that refuses it: a newline and `git status --short`, 20 lines at most.
dirty_files() {
  local lines
  lines=$(git -C "$1" status --short --untracked-files=all)
  printf '\n%s' "$(head -n 20 <<<"$lines")"
  (($(wc -l <<<"$lines") <= 20)) || printf '\n  ... and %d more' "$(($(wc -l <<<"$lines") - 20))"
}

# Uncommitted main-branch paths that the campaign also changes (its planning files excluded: finalize removes them before
# integrating). Only these can collide with the fast-forward; other sessions' unrelated edits are left untouched.
main_dirty_overlap() {
  local main_tree=$1 campaign_tree=$2 slug=$3 base
  base=$(git -C "$campaign_tree" merge-base HEAD "$MAIN_BRANCH")
  python3 - "$slug" <(git -C "$main_tree" status --porcelain=v1 -z --untracked-files=all) \
    <(git -C "$campaign_tree" diff --no-renames --name-only -z "$base" HEAD) <<'PY'
import sys
slug = sys.argv[1]
entries = open(sys.argv[2], 'rb').read().split(b'\0')
dirty, i = set(), 0
while i < len(entries):
    entry = entries[i]; i += 1
    if len(entry) < 4: continue
    dirty.add(entry[3:].decode())
    if entry[0:1] in (b'R', b'C') and i < len(entries): dirty.add(entries[i].decode()); i += 1
changed = {p.decode() for p in open(sys.argv[3], 'rb').read().split(b'\0') if p}
changed = {p for p in changed if not p.startswith(f'campaigns/{slug}/')}
print(','.join(sorted(dirty & changed)))
PY
}

# Until the planning cleanup, the final proof follows the validation plan committed on the campaign branch, so a fix
# to it applies when finalize resumes. Succeeds (and says so) when the checkpoint's copy changed.
refresh_validation_manifest() {
  local slug=$1 tree=$2 copy=$3 relative="campaigns/$1/validation.json" fresh
  git -C "$tree" cat-file -e "HEAD:$relative" 2>/dev/null || return 1
  fresh=$(mktemp "$copy.XXXXXX")
  git -C "$tree" show "HEAD:$relative" >"$fresh"
  if cmp -s -- "$fresh" "$copy"; then rm -f -- "$fresh"; return 1; fi
  chmod 600 "$fresh"; mv -f -- "$fresh" "$copy"
  event finalize-plan-refreshed "the validation plan changed on the campaign branch; the final proof uses the new plan"
}

# Machine-local marker of a finalize that is validating: <cache>/finalizing/<slug>.json (slug, pid, startedAt, tree). It
# lives outside the campaign's runtime, which finalize removes at its end, and exists only while the final validation
# runs. `campaign finalizing` lists the live ones, so a project's heavy tools can leave the machine to the validation.
finalizing_dir() { printf '%s/finalizing\n' "$(runtime_base)"; }
finalizing_file() { printf '%s/%s.json\n' "$(finalizing_dir)" "$1"; }

# finalizing_begin SLUG TREE: writes the marker, and removes it again when this process exits for any reason (a die, a
# signal), after the EXIT trap already set, if any.
finalizing_begin() {
  local slug=$1 tree=$2 file previous
  file=$(finalizing_file "$slug")
  mkdir -p -- "$(finalizing_dir)"
  chmod 700 "$(finalizing_dir)"
  jq -cn --arg slug "$slug" --argjson pid "$$" --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tree "$tree" \
    '{slug:$slug,pid:$pid,startedAt:$startedAt,tree:$tree}' >"$file.tmp"
  chmod 600 "$file.tmp"; mv -f -- "$file.tmp" "$file"
  previous=$(trap -p EXIT)
  if [[ -n $previous ]]; then eval "set -- $previous"; previous=$3; fi
  trap "${previous:+$previous; }rm -f -- $(printf '%q' "$file") $(printf '%q' "$file.tmp")" EXIT
}

finalizing_end() { rm -f -- "$(finalizing_file "$1")"; }

cmd_finalizing() {
  case ${1:-} in
    '') ;;
    -h | --help)
      note 'Usage: campaign finalizing'
      note 'One line per finalize validating on this machine: <slug> since <time> (pid <pid>). Exit status 0 when there is'
      note 'at least one, 1 when none. A marker left by a finalize that is gone is removed.'
      return 0 ;;
    *) die "unknown finalizing option: $1 (only --help)" ;;
  esac
  (($# == 0)) || die 'finalizing takes no arguments'
  local file pid slug started live=false
  for file in "$(finalizing_dir)"/*.json; do
    [[ -f $file ]] || continue
    pid=$(jq -r '.pid // ""' "$file" 2>/dev/null) || pid=''
    # Alive, and still a campaign process: a reused pid is not this finalize.
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) == *campaign* ]]; then
      slug=$(jq -r '.slug // ""' "$file"); started=$(jq -r '.startedAt // ""' "$file")
      printf '%s since %s (pid %s)\n' "${slug:-$(basename -- "$file" .json)}" \
        "$(in_display_tz date -d "$started" '+%H:%M (%d/%m)' 2>/dev/null || printf '%s' "$started")" "$pid"
      live=true
    else
      rm -f -- "$file"
    fi
  done
  $live
}

cmd_finalize() {
  assert_campaign_branch
  local slug runtime tickets campaign_branch campaign_tree main_tree branch dirty manifest_copy same_tree=false state_file stage snapshot recorded validated
  yield_cpu
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug"); campaign_branch="campaign/$slug"; campaign_tree=$REPO_ROOT
  # The final validation's machine slot, taken before any lock (a slot is never asked for holding another lock) and
  # given back once the validation is over.
  slot_take validation "$slug/finalize" || { (($? == 1)) && die 'the wait for a machine slot ended'; exit 2; }
  exec 6>"$runtime/launcher.lock"
  flock -x 6
  exec 7>"$runtime/runner.lock"
  flock -n 7 || die 'cannot finalize while runner is active'
  # From here to the end of the main branch's cleanup, this finalize decides on, and moves, this machine's main branch:
  # another finalize (or an accept) waits, then rebases on what this one left. A die releases it by ending the process.
  main_lock_acquire
  state_file="$runtime/finalize.json"; snapshot="$runtime/tickets.snapshot.json"; manifest_copy="$runtime/validation-manifest.json"
  stage=start
  [[ -f $state_file ]] && stage=$(jq -er '.stage' "$state_file")
  # A checkpoint of the older order (cleanup before rebase) resumes at the rebase; the cleanup is idempotent.
  [[ $stage == validated || $stage == cleaned ]] && stage=gated
  # proved and ready vouch for the exact commit that was validated. When the branch is anywhere else (a manual
  # rebase after a conflict, a new commit) or the checkpoint predates the recorded tip, validate again; the cleanup
  # below is idempotent.
  if [[ $stage == proved || $stage == ready ]]; then
    recorded=$(jq -r '.tip // empty' "$state_file")
    [[ $recorded == "$(git -C "$campaign_tree" rev-parse HEAD)" ]] || stage=rebased
  fi
  # The main branch moved after the rebase (a commit landed during the final validation): rebase and prove again.
  if [[ $stage == rebased || $stage == proved || $stage == ready ]] \
    && ! git -C "$campaign_tree" merge-base --is-ancestor "$MAIN_BRANCH" "$campaign_branch"; then
    stage=gated
  fi
  if [[ $stage == start ]]; then
    tickets=$(python3 "$TICKET_TOOL" list "$(tickets_path)")
    jq -e 'all(.[]; (.required == false) or .status == "done")' >/dev/null <<<"$tickets" || die 'required tickets are not all done'
    jq -e 'all(.[]; .status != "blocked" and .status != "needs-human" and .status != "in-progress")' >/dev/null <<<"$tickets" || die 'campaign has blocking tickets or active workers'
    [[ -z $(git -C "$campaign_tree" status --porcelain=v1) ]] || die "campaign worktree is dirty:$(dirty_files "$campaign_tree")"
  else
    [[ -f $snapshot && -f $manifest_copy ]] || die 'finalization checkpoint is incomplete'
    tickets=$(<"$snapshot")
    if refresh_validation_manifest "$slug" "$campaign_tree" "$manifest_copy" && [[ $stage == proved || $stage == ready ]]; then
      stage=rebased
    fi
  fi
  main_tree=$(main_worktree)
  if [[ -n $main_tree ]]; then
    dirty=$(main_dirty_overlap "$main_tree" "$campaign_tree" "$slug")
    [[ -z $dirty ]] || die "main worktree has uncommitted changes in files this campaign changes ($dirty); refusing finalization"
    [[ -z $(git -C "$main_tree" status --porcelain=v1) ]] || note "Unrelated uncommitted changes in the main worktree are left untouched."
  else
    main_tree=$campaign_tree
    same_tree=true
  fi

  if [[ $stage == start ]]; then
    printf '%s\n' "$tickets" >"$snapshot"
    cp -- "$(campaign_path "$slug")/validation.json" "$manifest_copy"
    chmod 600 "$snapshot" "$manifest_copy"
    jq -cn '{stage:"gated"}' >"$state_file"; chmod 600 "$state_file"
    stage=gated
  fi
  if [[ $stage == gated ]]; then
    local old_tip old_base conflicted lost
    old_tip=$(git -C "$campaign_tree" rev-parse HEAD); old_base=$(git -C "$campaign_tree" merge-base HEAD "$MAIN_BRANCH")
    if ! git_hooked -C "$campaign_tree" rebase "$MAIN_BRANCH" >/dev/null 2>&1; then
      conflicted=$(git -C "$campaign_tree" diff --name-only --diff-filter=U | paste -sd, -)
      git_hooked -C "$campaign_tree" rebase --abort >/dev/null 2>&1 || git -C "$campaign_tree" reset -q --hard "$old_tip"
      event finalize-conflict "rebase onto $MAIN_BRANCH conflicted in: ${conflicted:-unknown}; aborted, campaign intact"
      die "finalize rebase onto $MAIN_BRANCH conflicted in: ${conflicted:-unknown}. The campaign is intact: rebase campaign/$slug onto $MAIN_BRANCH (rerere stays disabled), prove it, then run finalize again."
    fi
    if ! lost=$(verify_rebase_kept_changes "$campaign_tree" "$old_tip" "$old_base" "$MAIN_BRANCH"); then
      git -C "$campaign_tree" reset -q --hard "$old_tip"
      die "finalize rebase dropped campaign changes in: $(paste -sd, - <<<"$lost"); the campaign tip was restored"
    fi
    jq -cn '{stage:"rebased"}' >"$state_file"; stage=rebased
  fi
  # The only final validation: on the rebased tree that the main branch fast-forwards to (the planning cleanup below
  # changes no validated file), and before that cleanup, so a failure leaves the campaign recoverable.
  if [[ $stage == rebased ]]; then
    refresh_validation_manifest "$slug" "$campaign_tree" "$manifest_copy" || true
    verify_plan "$manifest_copy" "$tickets"
    # The marker tells this machine's other tools that a final validation is running; AGENTIC_FINALIZE tells the
    # validation's own commands that they are that validation, and must never wait for it.
    validated=true
    finalizing_begin "$slug" "$campaign_tree"
    AGENTIC_FINALIZE=$slug run_final_validation "$campaign_tree" "$manifest_copy" || validated=false
    finalizing_end "$slug"
    if ! $validated; then
      die 'final validation failed; preserve evidence, repair the cause, then resume finalize'
    fi
    jq -cn --arg tip "$(git -C "$campaign_tree" rev-parse HEAD)" '{stage:"proved",tip:$tip}' >"$state_file"
    stage=proved
  fi
  slot_release
  if [[ $stage == proved ]]; then
    rm -rf -- "$campaign_tree/campaigns/$slug"
    # --ignore-unmatch: the main branch may already carry the cleanup (a campaign integrated by hand).
    git -C "$campaign_tree" rm -r -q --cached --ignore-unmatch -- "campaigns/$slug" >/dev/null
    if ! git -C "$campaign_tree" diff --cached --quiet; then
      git_hooked -C "$campaign_tree" commit -m "chore(agentic): finalize $slug campaign" >/dev/null
    fi
    jq -cn --arg tip "$(git -C "$campaign_tree" rev-parse HEAD)" '{stage:"ready",tip:$tip}' >"$state_file"; stage=ready
  fi
  [[ $stage == ready ]] || die "finalization is $stage"

  # Establish that every remaining owned branch is integrated before the main branch moves.
  while IFS= read -r branch; do
    [[ $branch == agentic/"$slug"/* ]] || continue
    git -C "$campaign_tree" merge-base --is-ancestor "$branch" "$campaign_branch" || die "unintegrated runner branch blocks finalization: $branch"
    safe_remove_ticket_worktree "$slug" "${branch##*/}"
  done < <(git -C "$campaign_tree" for-each-ref --format='%(refname:short)' "refs/heads/agentic/$slug/")
  # The main branch moved while the final validation ran: the checkpoint stays, and the next run rebases and proves again.
  git -C "$campaign_tree" merge-base --is-ancestor "$MAIN_BRANCH" "$campaign_branch" \
    || die "$MAIN_BRANCH moved during finalize; run finalize again: it rebases and validates again"
  if $same_tree; then git_hooked -C "$main_tree" switch "$MAIN_BRANCH" >/dev/null; fi
  git_hooked -C "$main_tree" merge --ff-only "$campaign_branch" >/dev/null
  # Before the campaign worktree goes away: the cache path is resolved from it.
  mark_finalized "$slug" "$main_tree"

  # Delete only resources in the runner-owned namespace for this slug.
  while IFS= read -r branch; do
    [[ $branch == agentic/"$slug"/* ]] || continue
    git -C "$main_tree" branch -d -- "$branch" >/dev/null
  done < <(git -C "$main_tree" for-each-ref --format='%(refname:short)' "refs/heads/agentic/$slug/")
  if ! $same_tree && [[ $campaign_tree != "$main_tree" ]] && git -C "$main_tree" worktree list --porcelain | grep -Fx "worktree $campaign_tree" >/dev/null; then
    [[ -z $(git -C "$campaign_tree" status --porcelain=v1) ]] || die "campaign worktree became dirty after merge:$(dirty_files "$campaign_tree")"
    git -C "$main_tree" worktree remove -- "$campaign_tree"
  fi
  git -C "$main_tree" branch -d -- "$campaign_branch" >/dev/null
  main_lock_release
  archive_campaign_history "$slug" "$runtime" "$main_tree"
  rm -rf -- "$runtime"
  git -C "$main_tree" worktree prune
  note "Campaign $slug finalized into $MAIN_BRANCH with FF-only integration."
  note "Main worktree: $main_tree"
}

cmd_cleanup() {
  assert_campaign_branch
  local slug ticket='' arg runtime status
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug")
  while (($#)); do
    arg=$1; shift
    case "$arg" in --ticket) (($#)) || die '--ticket requires an id'; ticket=$1; shift ;; *) die "unknown cleanup option: $arg" ;; esac
  done
  if [[ -n $ticket ]]; then
    status=$(ticket_json "$ticket" | jq -r '.status')
    [[ $status == done ]] || die "cleanup only removes completed ticket resources; $ticket is $status"
    safe_remove_ticket_worktree "$slug" "$ticket"
    rm -f -- "$runtime/results/$ticket-"* "$runtime/prompts/$ticket-"* "$runtime/logs/$ticket-"* 2>/dev/null || true
  else
    while IFS= read -r ticket; do safe_remove_ticket_worktree "$slug" "$ticket"; done \
      < <(python3 "$TICKET_TOOL" list "$(tickets_path)" | jq -r '.[] | select(.status=="done") | .id')
    find "$runtime/logs" -type f -size 0 -delete 2>/dev/null || true
  fi
  git -C "$REPO_ROOT" worktree prune
}

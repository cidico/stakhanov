#!/usr/bin/env bash
# Moving a campaign between the machines of a fleet (see "Moving a campaign" in .agentic/README.md). Sourced by
# bin/campaign with lib/fleet.sh; it defines functions and variables and runs nothing.
#
# The machine that holds a campaign owns it: its runner, its worktrees, its branches campaign/<slug> and
# agentic/<slug>/*, its runtime. campaign move stops the campaign there, pushes its branches and its uncommitted work
# (as commits under refs/agentic/move/<slug>/) to the target's clone, sends the runtime, has the target adopt it
# (campaign _adopt), and only then forgets it here, leaving a tombstone. The epoch in campaign.json grows by one at each
# move.

# What stays behind: the machine's own runner state, the engine snapshot and the worktrees (rebuilt there).
MOVE_EXCLUDES=(--exclude=/worktrees/ --exclude=/agentic/ --exclude=/agentic.staging/ --exclude=/runner.pid
  --exclude=/runner.lock --exclude=/launcher.lock --exclude=/launcher.pid --exclude=/state/*.active
  --exclude=/state/*.executor --exclude=/state/supervisor --exclude=/campaign.json)

# PATH SLUG: on the target, its clone at PATH can adopt campaign SLUG (`campaign _adopt --check`).
read -r -d '' MOVE_CHECK <<'SCRIPT' || true
export PATH="$PATH:$HOME/.local/bin"
cd -- "$1" 2>/dev/null || { printf 'no clone at %s\n' "$1"; exit 1; }
grep -q '_adopt' ./.agentic/bin/campaign 2>/dev/null \
  || { printf 'the kit of %s cannot adopt a campaign: pull the main branch there first\n' "$1"; exit 1; }
exec ./.agentic/bin/campaign _adopt --check "$2"
SCRIPT

# PATH ARGUMENT...: `campaign _adopt ARGUMENT...` in the clone at PATH.
read -r -d '' MOVE_ADOPT <<'SCRIPT' || true
export PATH="$PATH:$HOME/.local/bin"
cd -- "$1" || exit 1
shift
exec ./.agentic/bin/campaign _adopt "$@"
SCRIPT

moved_marker() { printf '%s/moved/%s.json\n' "$(runtime_base)" "$1"; }

# wip_commit WORKTREE: a commit of WORKTREE's uncommitted work (untracked files included, ignored ones not) on top of its
# HEAD, without touching its index or branch; nothing (status 1) when the worktree is clean.
wip_commit() {
  local tree=$1 index content
  [[ -n $(git -C "$tree" status --porcelain=v1 --untracked-files=all) ]] || return 1
  index=$(mktemp "$fleet_temp/index.XXXXXX")
  GIT_INDEX_FILE=$index git -C "$tree" read-tree HEAD
  GIT_INDEX_FILE=$index git -C "$tree" add -A
  content=$(GIT_INDEX_FILE=$index git -C "$tree" write-tree)
  git -C "$tree" -c user.name=agentic -c user.email=agentic@localhost commit-tree "$content" -p HEAD \
    -m 'agentic: uncommitted work carried to another machine'
}

# restore_wip WORKTREE COMMIT: WORKTREE's files become COMMIT's (deletions included) while its index and branch stay at
# HEAD: the work is uncommitted again, as it was before the move.
restore_wip() {
  local tree=$1 commit=$2
  git -C "$tree" checkout -q "$commit" -- . 2>/dev/null || true
  git -C "$tree" diff --name-only -z --diff-filter=D HEAD "$commit" | while IFS= read -r -d '' file; do
    rm -f -- "$tree/$file"
  done
  git -C "$tree" reset -q
}

# campaign move --to MACHINE [--now] [--start | --no-start], in the campaign's worktree on the machine that holds it.
cmd_move() {
  assert_campaign_branch
  local target='' now=false start='' arg slug runtime file was main_tree path destination epoch name ref tree wip
  local adopted='' provider workers rc=0 marker
  local -a refs=()
  while (($#)); do
    arg=$1; shift
    case $arg in
      --to) (($#)) || die '--to requires a machine'; target=$1; shift ;;
      --now) now=true ;;
      --start) start=true ;;
      --no-start) start=false ;;
      *) die "unknown move option: $arg" ;;
    esac
  done
  [[ -n $target ]] || die 'usage: campaign move --to MACHINE [--now] [--start | --no-start]'
  slug=$(campaign_slug); runtime=$(ensure_runtime "$slug"); file="$runtime/campaign.json"; marker=$(moved_marker "$slug")
  [[ -f $file ]] || die "campaign $slug has no campaign.json here"
  fleet_load
  [[ -n $FLEET_SELF ]] || die 'this machine is not in a fleet: campaign fleet join first'
  [[ $target != "$FLEET_SELF" ]] || die "campaign $slug is already on $target"
  path=$(jq -r --arg project "$FLEET_PROJECT" --arg m "$target" '.projects[$project].paths[$m] // ""' <<<"$FLEET")
  destination=$(fleet_ssh_of "$target")
  [[ -n $path && -n $destination ]] || die "$target holds no clone of $FLEET_PROJECT in the fleet"
  main_tree=$(main_worktree)
  [[ -z $(jq -r '.moving // ""' "$file") ]] || die "campaign $slug is already moving to $(jq -r '.moving' "$file")"
  was=$(desired_state "$slug")
  epoch=$(jq -r '.epoch // 0' "$file")
  if [[ -z $start ]]; then
    start=false
    [[ $was != running || ! -f $runtime/run-config.json ]] || start=true
  fi

  note "Checking $target..."
  remote_script "$MOVE_CHECK" "$path" "$slug" >"$fleet_temp/check.out" 2>&1 \
    || die "$target cannot take campaign $slug: $(fleet_reason "$fleet_temp/check.out")"

  # From here on nothing relaunches it: not run, not the supervisor.
  jq --arg target "$target" '.moving = $target' "$file" >"$file.tmp" && mv -f -- "$file.tmp" "$file"
  set_desired_state "$slug" stopped
  if runner_alive "$slug"; then
    if $now; then
      cmd_stop --now >/dev/null
    else
      event stop-requested "moving to $target: no new ticket starts; the move goes on when the running ones end"
      note "Waiting for the running tickets of $slug to end (campaign move --now stops them at once)..."
      while runner_alive "$slug"; do sleep "${AGENTIC_MOVE_POLL_SECONDS:-5}"; done
    fi
  fi

  # The uncommitted work of every worktree of the campaign, as commits only the move refers to.
  for tree in "$runtime"/worktrees/*; do
    [[ -d $tree ]] || continue
    name=$(basename -- "$tree")
    if wip=$(wip_commit "$tree"); then
      git -C "$REPO_ROOT" update-ref "refs/agentic/move/$slug/$name" "$wip"
      note "Carrying the uncommitted work of $name."
    fi
  done
  refs=("+refs/heads/campaign/$slug:refs/heads/campaign/$slug")
  while IFS= read -r ref; do
    [[ -n $ref ]] && refs+=("+$ref:$ref")
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' "refs/heads/agentic/$slug/" "refs/agentic/move/$slug/")

  note "Sending $slug to $target..."
  if ! GIT_SSH_COMMAND=$ssh_line GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" push --quiet --no-verify "$destination:$path" \
      "${refs[@]}" 2>"$fleet_temp/push.error"; then
    rc=1
  elif ! rsync -a --delete --mkpath "${MOVE_EXCLUDES[@]}" -e "$ssh_line" "$runtime/" \
      "$destination:$path/.git/agentic-move/$slug/" 2>"$fleet_temp/push.error"; then
    rc=1
  elif ! adopted=$(remote_script "$MOVE_ADOPT" "$path" "$slug" --from "$FLEET_SELF" --epoch "$((epoch + 1))" \
      --desired "$was" 2>"$fleet_temp/push.error"); then
    rc=1
  fi
  if ((rc != 0)); then
    remote_script "$MOVE_ADOPT" "$path" --abort "$slug" --from "$FLEET_SELF" >/dev/null 2>&1 || true
    git -C "$REPO_ROOT" for-each-ref --format='%(refname)' "refs/agentic/move/$slug/" | while IFS= read -r ref; do
      git -C "$REPO_ROOT" update-ref -d "$ref"
    done
    jq 'del(.moving)' "$file" >"$file.tmp" && mv -f -- "$file.tmp" "$file"
    set_desired_state "$slug" "$was"
    die "moving $slug to $target failed, and it stays here ($was): $(fleet_reason "$fleet_temp/push.error")"
  fi
  adopted=${adopted##*$'\n'}

  # It lives there now: here, only a tombstone is left. The campaign worktree this command runs in goes too.
  provider=$(jq -r '.provider // ""' "$runtime/run-config.json" 2>/dev/null || true)
  workers=$(jq -r '.workers // 2' "$runtime/run-config.json" 2>/dev/null || printf '2')
  cp -- "$runtime/run-config.json" "$fleet_temp/run-config.json" 2>/dev/null || printf '{}\n' >"$fleet_temp/run-config.json"
  cd -- "$main_tree"; REPO_ROOT=$main_tree
  for tree in "$runtime"/worktrees/*; do
    [[ -d $tree ]] && git -C "$main_tree" worktree remove --force -- "$tree" 2>/dev/null || rm -rf -- "$tree"
  done
  git -C "$main_tree" worktree prune
  git -C "$main_tree" for-each-ref --format='%(refname)' "refs/heads/campaign/$slug" "refs/heads/agentic/$slug/" \
    "refs/agentic/move/$slug/" | while IFS= read -r ref; do
    git -C "$main_tree" update-ref -d "$ref"
  done
  rm -rf -- "$runtime"
  mkdir -p -- "$(dirname -- "$marker")"
  jq -n --arg slug "$slug" --arg to "$target" --argjson epoch "$((epoch + 1))" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{slug: $slug, moved_to: $to, epoch: $epoch, at: $at}' >"$marker"
  note "Campaign $slug moved to $target ($adopted)."

  if $start; then
    [[ -n $provider ]] || { note "Not started on $target: it never ran (campaign run --campaign $slug --provider NAME)."; return 0; }
    note "Starting it there, with the last run's settings..."
    local -a settings
    mapfile -d '' -t settings < <(travelling_settings "$fleet_temp/run-config.json")
    remote_script "$FLEET_CAMPAIGN" "$adopted" "${settings[@]}" -- run --provider "$provider" --workers "$workers" --mode unattended \
      || die "$slug moved to $target but did not start there: campaign run --campaign $slug --provider $provider"
  fi
}

# campaign _adopt SLUG --from MACHINE --epoch N --desired STATE: in the main clone, takes in the campaign that MACHINE
# pushed (its branches, its refs/agentic/move/SLUG/ work) and sent (.git/agentic-move/SLUG): rebuilds its worktrees here,
# its uncommitted work uncommitted again, and prints the campaign worktree. `--check SLUG` says whether it can;
# `--abort SLUG --from MACHINE` removes what a failed adoption of MACHINE's left.
cmd_adopt() {
  local mode=adopt slug='' from='' epoch=1 desired=stopped staged runtime tree branch name ref
  while (($#)); do
    case $1 in
      --check) mode=check; slug=${2:-}; shift 2 ;;
      --abort) mode=abort; slug=${2:-}; shift 2 ;;
      --from) from=${2:-}; shift 2 ;;
      --epoch) epoch=${2:-}; shift 2 ;;
      --desired) desired=${2:-}; shift 2 ;;
      -*) die "unknown _adopt option: $1" ;;
      *) slug=$1; shift ;;
    esac
  done
  validate_slug "$slug"
  staged="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)/agentic-move/$slug"
  runtime=$(runtime_dir "$slug")
  case $mode in
    check)
      if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$slug" || [[ -f $runtime/campaign.json ]]; then
        die "campaign $slug already exists here"
      fi
      note ok
      return ;;
    abort)
      if [[ ! -f $runtime/campaign.json || $(jq -r '.moved_from // ""' "$runtime/campaign.json") == "$from" ]]; then
        for tree in "$runtime"/worktrees/*; do
          [[ -d $tree ]] && git -C "$REPO_ROOT" worktree remove --force -- "$tree" 2>/dev/null || true
        done
        git -C "$REPO_ROOT" worktree prune
        git -C "$REPO_ROOT" for-each-ref --format='%(refname)' "refs/heads/campaign/$slug" "refs/heads/agentic/$slug/" \
          "refs/agentic/move/$slug/" | while IFS= read -r ref; do git -C "$REPO_ROOT" update-ref -d "$ref"; done
        rm -rf -- "$runtime"
      fi
      rm -rf -- "$staged"
      return ;;
  esac
  [[ $desired == running || $desired == stopped ]] || die "invalid desired state: $desired"
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$slug" || die "campaign/$slug did not arrive"
  [[ -d $staged ]] || die "the runtime of $slug did not arrive"
  [[ ! -f $runtime/campaign.json ]] || die "campaign $slug already exists here"
  runtime=$(ensure_runtime "$slug")
  cp -a -- "$staged/." "$runtime/"
  tree="$runtime/worktrees/campaign"
  git -C "$REPO_ROOT" worktree add -q "$tree" "campaign/$slug"
  while IFS= read -r branch; do
    [[ -n $branch ]] || continue
    name=${branch##*/}
    git -C "$REPO_ROOT" worktree add -q "$runtime/worktrees/$name" "$branch"
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/agentic/$slug/")
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    name=${ref##*/}
    [[ ! -d $runtime/worktrees/$name ]] || restore_wip "$runtime/worktrees/$name" "$ref"
    git -C "$REPO_ROOT" update-ref -d "$ref"
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' "refs/agentic/move/$slug/")
  jq -n --arg slug "$slug" --arg tree "$tree" --arg desired "$desired" --argjson epoch "$epoch" --arg from "$from" \
    '{slug: $slug, branch: "campaign/\($slug)", worktree: $tree, spec: "\($tree)/campaigns/\($slug)/SPEC.md",
      desired: $desired, epoch: $epoch, moved_from: $from}' >"$runtime/campaign.json"
  chmod 600 "$runtime/campaign.json"
  jq -cn --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg from "$from" --argjson epoch "$epoch" \
    '{time: $time, type: "campaign-moved", message: "moved here from \($from) (epoch \($epoch))"}' >>"$runtime/events/campaign.ndjson"
  rm -f -- "$(moved_marker "$slug")"
  rm -rf -- "$staged"
  printf '%s\n' "$tree"
}

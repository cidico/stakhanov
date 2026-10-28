#!/usr/bin/env bash
# One remote executor (see "Remote executors" in .agentic/README.md), shared by lib/remote-run.sh (a worker-role
# provider invocation) and bin/offload (a command). Sourced; it defines functions and variables and runs nothing.
#
# executor_load JSON reads one normalized entry of the executors list (lib/common.sh). A local absolute path /x lives
# at <root>/x on the executor host, and the executor's run prefix presents it at /x to what it runs; without run, root
# is empty and the paths are the same. The caller sets `temporary` (a private folder) and then, in this order:
# mirror_for, executor_reach, executor_admit, executor_checkout, executor_sync_worktree, executor_sync_paths_out,
# run_environment and remote_run. A step that fails before the run makes the executor unavailable: `unavailable` prints
# the reason and exits 75, so a caller that may try another executor runs the steps in a subshell.

# AGENTIC_SSH replaces the ssh command, here and as rsync's and git's transport.
IFS=' ' read -r -a ssh_command <<<"${AGENTIC_SSH:-ssh}"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=15)
ssh_line="${AGENTIC_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=15"
# A run gets a connection of its own (remote_run): when this side dies, that connection's end is how the executor (its
# run prefix) can tell, while a shared ControlMaster session would outlive it.
own_connection=()

# executor_load JSON: the executor's fields, as name, destination, root, run_prefix, exclude_arguments, rsync_options,
# sync_paths, admit, requires, executor_env (NAME=VALUE words) and worker_units.
executor_load() {
  name=$(jq -r '.name' <<<"$1")
  destination=$(jq -r '.ssh' <<<"$1")
  root=$(jq -r '.root // "" | sub("/+$"; "")' <<<"$1")
  mapfile -t run_prefix < <(jq -r '(.run // [])[]' <<<"$1")
  mapfile -t exclude_arguments < <(jq -r '(.exclude // [])[] | "--exclude=\(.)"' <<<"$1")
  mapfile -t rsync_options < <(jq -r '(.rsync_options // [])[]' <<<"$1")
  mapfile -t sync_paths < <(jq -r '(.sync_paths // [])[]' <<<"$1")
  mapfile -t admit < <(jq -r '(.admit // [])[]' <<<"$1")
  mapfile -t requires < <(jq -r '(.requires // [])[]' <<<"$1")
  mapfile -d '' -t executor_env < <(jq -j '(.env // {}) | to_entries[] | "\(.key)=\(.value)\u0000"' <<<"$1")
  worker_units=$(jq -r '.worker_units // 1' <<<"$1")
}

remote_path() { printf '%s%s\n' "$root" "$1"; }

# remote_script SCRIPT ARG...: runs SCRIPT with bash on the executor, with ARG... as its positional parameters. The
# script travels on stdin inside one { } group, so bash reads all of it before running any command.
remote_script() {
  local script=$1 line='set --' argument
  shift
  for argument in "$@"; do line+=" $(printf '%q' "$argument")"; done
  printf '%s\n{\n%s\n}\n' "$line" "$script" | "${ssh_command[@]}" "${ssh_options[@]}" "${own_connection[@]}" "$destination" bash -s
}

unavailable() {
  printf 'executor unavailable: %s\n' "$*" >&2
  exit 75
}

# step DESCRIPTION COMMAND...: a setup command; its failure makes the executor unavailable, with the description and
# the end of the error output as the reason.
step() {
  local description=$1 rc=0 detail
  shift
  "$@" 2>"$temporary/stderr" || rc=$?
  cat -- "$temporary/stderr" >&2
  ((rc == 0)) && return 0
  detail=$(tail -c 300 -- "$temporary/stderr" | tr -s '[:space:]' ' '); detail=${detail% }
  if ((rc == 255)); then
    unavailable "$name: $description: ssh could not reach $destination${detail:+ ($detail)}"
  fi
  unavailable "$name: $description failed (exit $rc)${detail:+: $detail}"
}

# Owners and groups never travel: on the executor (ssh as root) a file would keep this side's numeric owner, which there
# is another user or none; it belongs to the login and to the group of its folder instead (setgid on an executor
# installed by executor/install.sh).
rsync_to() { rsync -a --no-owner --no-group "${rsync_options[@]}" -e "$ssh_line" "$@"; }

read -r -d '' PREPARE <<'SCRIPT' || true
set -eu
root=$1 mirror=$2
shift 2
for command in git rsync setsid; do
  command -v "$command" >/dev/null 2>&1 || { printf 'the executor lacks the command %s\n' "$command" >&2; exit 3; }
done
base=${root:-$HOME}
mkdir -p "$base/.agentic/mirror" "$base/.agentic/run"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do mkdir -p "$1"; shift; done
[ "$#" -eq 0 ] || shift
rm -f "$@"
[ -d "$base/$mirror" ] || git init --bare -q "$base/$mirror"
printf '%s\n' "$base"
SCRIPT

# Prints the first command it cannot find (it runs through the run prefix, so it sees the run's PATH).
read -r -d '' REQUIRES <<'SCRIPT' || true
for command do
  command -v "$command" >/dev/null 2>&1 || { printf '%s\n' "$command"; exit 1; }
done
SCRIPT

# A remote worktree another user owns (a run user's files, or an older sync that kept owners) is still this login's
# to check out: git's ownership guard is lifted for these commands only.
read -r -d '' CHECKOUT <<'SCRIPT' || true
set -eu
mirror=$1 tree=$2 sha=$3 head_ref=$4 branch=$5
shift 5
git() { command git -c safe.directory='*' "$@"; }
git -c init.defaultBranch=agentic init -q "$tree"
specs=("+$head_ref:refs/remotes/mirror/checkout")
for name in "$@"; do specs+=("+refs/heads/$name:refs/remotes/mirror/$name"); done
git -C "$tree" fetch -q --force --no-tags "$mirror" "${specs[@]}"
if [ -n "$branch" ]; then
  git -C "$tree" checkout -q --force -B "$branch" "$sha"
else
  git -C "$tree" checkout -q --force --detach "$sha"
fi
# A worker measures its delta with git merge-base campaign/<slug> HEAD.
for name in "$@"; do
  [ "$name" = "$branch" ] || git -C "$tree" branch -q -f "$name" "refs/remotes/mirror/$name"
done
SCRIPT

# The command runs in its own session; its process group id is recorded so an interrupted run can stop it.
read -r -d '' RUN <<'SCRIPT' || true
pgid_file=$1
shift
rm -f "$pgid_file"
setsid -w bash -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' agentic-remote "$pgid_file" "$@" </dev/null &
child=$!
rc=0
wait "$child" || rc=$?
rm -f "$pgid_file"
exit "$rc"
SCRIPT

read -r -d '' STOP <<'SCRIPT' || true
pgid_file=$1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$pgid_file" ] && break; sleep 0.1; done
group=$(cat "$pgid_file" 2>/dev/null) || exit 0
case $group in ''|*[!0-9]*) exit 0 ;; esac
if kill -TERM -- "-$group" 2>/dev/null; then
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    kill -0 -- "-$group" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$group" 2>/dev/null || true
fi
rm -f "$pgid_file"
SCRIPT

# mirror_for WORKTREE: the mirror is per repository: the main worktree's folder name and a short hash of its path (key),
# at mirror under the executor's base.
mirror_for() {
  local common top
  common=$(git -C "$1" rev-parse --git-common-dir)
  [[ $common == /* ]] || common="$1/$common"
  top=$(realpath -m -- "$common")
  [[ $(basename -- "$top") != .git ]] || top=$(dirname -- "$top")
  key=$(basename -- "$top"); key=${key//[^A-Za-z0-9._-]/-}
  key="$key-$(printf '%s' "$top" | sha256sum | cut -c1-12)"
  mirror=".agentic/mirror/$key.git"
}

# executor_reach DIRECTORY... -- STALE...: reaches the host, prepares the mirror and the remote DIRECTORY... and removes
# the STALE remote files; sets base, the folder that holds .agentic/mirror and .agentic/run there.
executor_reach() {
  base=$(step 'preparing the executor' remote_script "$PREPARE" "$root" "$mirror" "$@") || exit "$?"
  base=${base##*$'\n'}
  [[ $base == /* ]] || unavailable "$name: preparing the executor printed no folder"
}

# executor_admit UNITS KIND: the commands the executor requires, checked through its run prefix (which receives
# AGENTIC_UNITS=0: the check needs no capacity), then its own admission (admit, with AGENTIC_UNITS=UNITS and
# AGENTIC_RUN_KIND=KIND, worker or offload: a worker also needs a model account there): a host that lacks a command or
# has no room now sends the run back instead of making it wait there.
executor_admit() {
  local units=$1 kind=$2 rc=0 missing detail
  if ((${#requires[@]} > 0)); then
    missing=$(remote_script 'exec "$@"' env AGENTIC_UNITS=0 "${run_prefix[@]}" sh -c "$REQUIRES" agentic-requires \
      "${requires[@]}" 2>"$temporary/requires") || rc=$?
    missing=${missing##*$'\n'}
    if ((rc == 1)) && [[ -n $missing ]]; then unavailable "$name: requires $missing"; fi
    detail=$(tail -c 200 -- "$temporary/requires" | tr -s '[:space:]' ' '); detail=${detail% }
    ((rc == 0)) || unavailable "$name: checking its required commands failed (exit $rc)${detail:+: $detail}"
  fi
  if ((${#admit[@]} > 0)); then
    rc=0
    remote_script 'exec "$@"' env "AGENTIC_UNITS=$units" "AGENTIC_RUN_KIND=$kind" "${admit[@]}" >"$temporary/admit" 2>&1 || rc=$?
    ((rc == 0)) || unavailable "$name: no room ($(tail -c 200 -- "$temporary/admit" | tr -s '[:space:]' ' ' | sed 's/ $//')${rc:+, admit exited $rc})"
  fi
}

# executor_checkout WORKTREE HEAD_REF BRANCH NAME...: pushes the worktree's HEAD (as HEAD_REF) and the local branches
# NAME... to the mirror only, then checks that commit out in the remote worktree, on BRANCH (detached when empty), with
# the branches NAME... next to it.
executor_checkout() {
  local worktree=$1 head_ref=$2 branch=$3 sha
  shift 3
  mirror_refspecs=("HEAD:$head_ref")
  local branch_name
  for branch_name in "$@"; do mirror_refspecs+=("refs/heads/$branch_name:refs/heads/$branch_name"); done
  mirror_worktree=$worktree
  sha=$(git -C "$worktree" rev-parse HEAD)
  # Two runs on the same executor may push at once; one retry covers a lost ref lock.
  step 'pushing the commits to the mirror' mirror_push_with_retry
  step 'checking out the remote worktree' remote_script "$CHECKOUT" "$base/$mirror" "$(remote_path "$worktree")" "$sha" \
    "$head_ref" "$branch" "$@"
}
mirror_push() {
  GIT_SSH_COMMAND=$ssh_line GIT_TERMINAL_PROMPT=0 git -C "$mirror_worktree" push --force --quiet --no-verify \
    "$destination:$base/$mirror" "${mirror_refspecs[@]}"
}
mirror_push_with_retry() { mirror_push || { sleep 1; mirror_push; }; }

# executor_sync_worktree WORKTREE: the working files, uncommitted changes and deletions included.
executor_sync_worktree() {
  step 'syncing the worktree' rsync_to --delete --exclude=/.git "${exclude_arguments[@]}" \
    "$1/" "$destination:$(remote_path "$1")/"
}

# Project folders outside the worktree that a run reads and may add to (sync_paths): sent before, brought back after,
# never deleting on either side; a file newer on this side is kept.
executor_sync_paths_out() {
  local path
  for path in "${sync_paths[@]}"; do
    if [[ -d $path ]]; then
      step "syncing $path" rsync_to --mkpath "$path/" "$destination:$(remote_path "$path")/"
    fi
  done
}
# executor_sync_paths_back: the rsync status of the first copy that failed, else 0.
executor_sync_paths_back() {
  local path
  for path in "${sync_paths[@]}"; do
    rsync_to --update --mkpath --ignore-missing-args "$destination:$(remote_path "$path")/" "$path/" || return "$?"
  done
}

# run_environment WORKTREE NAME...: sets environment to the NAME=VALUE words a run receives: every AGENTIC_* variable
# but the transport ones, the variables NAME... that are set, the executor's env, then this side's git settings with
# WORKTREE marked safe for git (the executor may see the files under another owner). A later word wins.
run_environment() {
  local worktree=$1 variable count index key_name value_name
  shift
  local -A forwarded=()
  environment=()
  while IFS= read -r variable; do
    [[ $variable == AGENTIC_* && $variable != AGENTIC_SSH && $variable != AGENTIC_EXECUTORS ]] || continue
    forwarded[$variable]=1; environment+=("$variable=${!variable}")
  done < <(compgen -e)
  for variable in "$@"; do
    [[ -z ${forwarded[$variable]:-} && -n ${!variable+x} ]] || continue
    forwarded[$variable]=1; environment+=("$variable=${!variable}")
  done
  environment+=("${executor_env[@]}")
  count=${GIT_CONFIG_COUNT:-0}
  [[ $count =~ ^[0-9]+$ ]] || count=0
  for ((index = 0; index < count; index++)); do
    key_name="GIT_CONFIG_KEY_$index" value_name="GIT_CONFIG_VALUE_$index"
    environment+=("$key_name=${!key_name:-}" "$value_name=${!value_name:-}")
  done
  environment+=("GIT_CONFIG_KEY_$count=safe.directory" "GIT_CONFIG_VALUE_$count=$worktree" "GIT_CONFIG_COUNT=$((count + 1))")
}

# remote_run PGID_FILE UNITS COMMAND...: runs COMMAND with the local paths, through the run prefix (which receives
# AGENTIC_UNITS=UNITS and maps them), in its own process group recorded in PGID_FILE, on a connection of its own.
# Returns COMMAND's status (255 when ssh failed).
remote_run() {
  local pgid_file=$1 units=$2
  shift 2
  local -a own_connection=(-o ControlMaster=no -o ControlPath=none)
  remote_script "$RUN" "$pgid_file" env "AGENTIC_UNITS=$units" "${run_prefix[@]}" "$@"
}

# remote_stop PGID_FILE: stops the process group of an interrupted run (TERM, then KILL after 3 seconds).
remote_stop() { remote_script "$STOP" "$1" >/dev/null 2>&1; }

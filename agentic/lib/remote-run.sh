#!/usr/bin/env bash
# Runs one worker-role provider invocation on a remote executor (see "Remote executors" in .agentic/README.md):
#
#   remote-run.sh --executor JSON --ticket ID --slug SLUG --main-branch BRANCH [--file PATH]... [--env NAME]...
#                 --adapter PATH ROLE WORKTREE PROMPT RESULT EVENTS
#
# JSON is one normalized entry of the executors list (lib/common.sh). A local absolute path /x lives at <root>/x on
# the executor host, and the executor's run prefix presents it at /x to the adapter; without run, root is empty and
# the paths are the same. The steps: reach the host; push the ticket's commit, the campaign branch and the main branch
# to a bare mirror there; check that commit out in the remote worktree; sync the working files (uncommitted delta and
# deletions included), the engine, the prompt, the events and every --file; run the adapter in its own process group;
# copy the result, the events and the working files back. --env names a variable forwarded to the adapter besides
# every AGENTIC_* one.
#
# Exit status: 75 when the executor is unavailable before the adapter started (nothing local changed); otherwise the
# adapter's own status, or 1 when the copy back failed after it ran. An adapter status of 75 becomes 1, so it never
# reads as an unavailable executor. TERM or INT while the adapter runs stops its remote process group (TERM, then KILL
# after 3 seconds) and copies the working files back within 5 seconds, so the partial work survives as it would here.
set -euo pipefail
umask 077

agentic_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

usage() {
  printf 'usage: remote-run.sh --executor JSON --ticket ID --slug SLUG --main-branch BRANCH [--file PATH]... [--env NAME]...\n' >&2
  printf '                     --adapter PATH ROLE WORKTREE PROMPT RESULT EVENTS\n' >&2
  exit 64
}

executor_json='' ticket='' slug='' main_branch='' adapter=''
files=() env_names=()
while (($#)); do
  case $1 in
    --executor|--ticket|--slug|--main-branch|--file|--env|--adapter) (($# >= 2)) || usage ;;&
    --executor) executor_json=$2; shift 2 ;;
    --ticket) ticket=$2; shift 2 ;;
    --slug) slug=$2; shift 2 ;;
    --main-branch) main_branch=$2; shift 2 ;;
    --file) files+=("$2"); shift 2 ;;
    --env) env_names+=("$2"); shift 2 ;;
    --adapter) adapter=$2; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
(($# == 5)) && [[ -n $executor_json && -n $ticket && -n $slug && -n $main_branch && -n $adapter ]] || usage
role=$1 worktree=$2 prompt=$3 result=$4 events=$5

name=$(jq -r '.name' <<<"$executor_json")
destination=$(jq -r '.ssh' <<<"$executor_json")
root=$(jq -r '.root // "" | sub("/+$"; "")' <<<"$executor_json")
mapfile -t run_prefix < <(jq -r '(.run // [])[]' <<<"$executor_json")
mapfile -t exclude_arguments < <(jq -r '(.exclude // [])[] | "--exclude=\(.)"' <<<"$executor_json")
mapfile -t rsync_options < <(jq -r '(.rsync_options // [])[]' <<<"$executor_json")

# AGENTIC_SSH replaces the ssh command, here and as rsync's and git's transport.
read -r -a ssh_command <<<"${AGENTIC_SSH:-ssh}"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=15)
ssh_line="${AGENTIC_SSH:-ssh} ${ssh_options[*]}"

# The adapter's run gets a connection of its own: when this runner dies, that connection's end is how the executor
# (its run prefix) can tell, while a shared ControlMaster session would outlive it.
own_connection=()
temporary=$(mktemp -d)
run_pid='' pgid_file=''
trap 'rm -rf -- "$temporary"' EXIT

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

rsync_to() { rsync -a "${rsync_options[@]}" -e "$ssh_line" "$@"; }

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

read -r -d '' CHECKOUT <<'SCRIPT' || true
set -eu
mirror=$1 tree=$2 sha=$3 ticket_ref=$4 branch=$5 campaign=$6 main=$7
git -c init.defaultBranch=agentic init -q "$tree"
git -C "$tree" fetch -q --force --no-tags "$mirror" "+$ticket_ref:refs/remotes/mirror/ticket" \
  "+refs/heads/$campaign:refs/remotes/mirror/$campaign" "+refs/heads/$main:refs/remotes/mirror/$main"
if [ -n "$branch" ]; then
  git -C "$tree" checkout -q --force -B "$branch" "$sha"
else
  git -C "$tree" checkout -q --force --detach "$sha"
fi
# The worker measures its delta with git merge-base campaign/<slug> HEAD.
for name in "$campaign" "$main"; do
  [ "$name" = "$branch" ] || git -C "$tree" branch -q -f "$name" "refs/remotes/mirror/$name"
done
SCRIPT

# The adapter runs in its own session; its process group id is recorded so an interrupted run can stop it.
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

# A deadline stops the run with TERM and kills the whole group 10 seconds later (provider_deadline.py): stop the
# remote adapter, then bring its partial work back within what is left, as a local worker's delta would survive.
on_signal() {
  trap '' TERM INT
  if [[ -n $run_pid ]]; then
    printf 'remote-run: interrupted; stopping the %s on %s and copying its partial work back\n' "$role" "$destination" >&2
    kill "$run_pid" 2>/dev/null || true
    remote_script "$STOP" "$pgid_file" >/dev/null 2>&1 \
      || printf 'remote-run: could not stop the remote process group; it may still run on %s\n' "$destination" >&2
    timeout 5 rsync -a "${rsync_options[@]}" -e "$ssh_line" --delete --exclude=/.git "${exclude_arguments[@]}" \
      "$destination:$(remote_path "$worktree")/" "$worktree/" \
      || printf 'remote-run: the partial work was not copied back; it stays at %s:%s\n' "$destination" "$(remote_path "$worktree")" >&2
  fi
  exit "$((128 + $1))"
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT

# The mirror is per repository: the main worktree's folder name and a short hash of its path.
common=$(git -C "$worktree" rev-parse --git-common-dir)
[[ $common == /* ]] || common="$worktree/$common"
top=$(realpath -m -- "$common")
[[ $(basename -- "$top") != .git ]] || top=$(dirname -- "$top")
key=$(basename -- "$top"); key=${key//[^A-Za-z0-9._-]/-}
key="$key-$(printf '%s' "$top" | sha256sum | cut -c1-12)"
mirror=".agentic/mirror/$key.git"

# The provider folder travels too when the adapter lives outside the engine (AGENTIC_PROVIDER_DIR).
provider_root=''
[[ $adapter == "$agentic_dir"/* ]] || provider_root=$(dirname -- "$(dirname -- "$adapter")")
inputs=("$prompt")
for file in "$events" "${files[@]}"; do
  if [[ -f $file ]]; then inputs+=("$file"); fi
done
directories=("$(remote_path "$(dirname -- "$worktree")")" "$(remote_path "$agentic_dir")")
[[ -z $provider_root ]] || directories+=("$(remote_path "$provider_root")")
for file in "${inputs[@]}" "$result" "$events"; do directories+=("$(remote_path "$(dirname -- "$file")")"); done
# A stale remote result or events file would come back as this run's.
stale=("$(remote_path "$result")")
[[ -f $events ]] || stale+=("$(remote_path "$events")")

printf 'remote-run: the %s runs on %s (%s) in %s:%s\n' "$role" "$name" "$destination" "$destination" "$(remote_path "$worktree")" >&2

# 1. Reach the host and prepare the mirror and the folders.
base=$(step 'preparing the executor' remote_script "$PREPARE" "$root" "$mirror" "${directories[@]}" -- "${stale[@]}") || exit "$?"
base=${base##*$'\n'}
[[ $base == /* ]] || unavailable "$name: preparing the executor printed no folder"

# 2. Push the ticket's commit and the branches its worker compares against, to the mirror only.
sha=$(git -C "$worktree" rev-parse HEAD)
if branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD); then
  ticket_ref="refs/heads/$branch"
else
  branch='' ticket_ref="refs/agentic/$ticket"
fi
push() {
  GIT_SSH_COMMAND=$ssh_line GIT_TERMINAL_PROMPT=0 git -C "$worktree" push --force --quiet --no-verify \
    "$destination:$base/$mirror" "HEAD:$ticket_ref" "refs/heads/campaign/$slug:refs/heads/campaign/$slug" \
    "refs/heads/$main_branch:refs/heads/$main_branch"
}
# Two tickets on the same executor may push at once; one retry covers a lost ref lock.
push_with_retry() { push || { sleep 1; push; }; }
step 'pushing the commits to the mirror' push_with_retry

# 3. The remote worktree at the same commit, with the campaign and main branches next to it.
step 'checking out the remote worktree' remote_script "$CHECKOUT" "$base/$mirror" "$(remote_path "$worktree")" "$sha" \
  "$ticket_ref" "$branch" "campaign/$slug" "$main_branch"

# 4. The working files (uncommitted changes and deletions included), the engine and the inputs.
step 'syncing the worktree' rsync_to --delete --exclude=/.git "${exclude_arguments[@]}" \
  "$worktree/" "$destination:$(remote_path "$worktree")/"
step 'syncing the engine' rsync_to --delete "$agentic_dir/" "$destination:$(remote_path "$agentic_dir")/"
[[ -z $provider_root ]] || step 'syncing the provider adapter' rsync_to --delete "$provider_root/" \
  "$destination:$(remote_path "$provider_root")/"
step 'syncing the prompt and events' rsync_to -R --no-implied-dirs "${inputs[@]}" "$destination:${root:-/}"

# 5. Run the adapter with the local paths; the run prefix maps them. The adapter gets every AGENTIC_* variable (but
# the transport ones), the --env ones and the runner's git settings, with its worktree marked safe for git (a container
# may see the files under another owner).
declare -A forwarded=()
environment=()
while IFS= read -r variable; do
  [[ $variable == AGENTIC_* && $variable != AGENTIC_SSH && $variable != AGENTIC_EXECUTORS ]] || continue
  forwarded[$variable]=1; environment+=("$variable=${!variable}")
done < <(compgen -e)
for variable in "${env_names[@]}"; do
  [[ -z ${forwarded[$variable]:-} && -n ${!variable+x} ]] || continue
  forwarded[$variable]=1; environment+=("$variable=${!variable}")
done
count=${GIT_CONFIG_COUNT:-0}
[[ $count =~ ^[0-9]+$ ]] || count=0
for ((index = 0; index < count; index++)); do
  key_name="GIT_CONFIG_KEY_$index" value_name="GIT_CONFIG_VALUE_$index"
  environment+=("$key_name=${!key_name:-}" "$value_name=${!value_name:-}")
done
environment+=("GIT_CONFIG_KEY_$count=safe.directory" "GIT_CONFIG_VALUE_$count=$worktree" "GIT_CONFIG_COUNT=$((count + 1))")

pgid_file="$base/.agentic/run/$key-$ticket-$$.pgid"
rc=0
own_connection=(-o ControlMaster=no -o ControlPath=none)
remote_script "$RUN" "$pgid_file" "${run_prefix[@]}" env "${environment[@]}" \
  bash "$adapter" "$role" "$worktree" "$prompt" "$result" "$events" &
run_pid=$!
own_connection=()
wait "$run_pid" || rc=$?
run_pid=''
if ((rc == 75)); then
  printf 'remote-run: the adapter exited 75 on %s; reported as 1\n' "$destination" >&2
  rc=1
fi

# 6. Copy back: the result (only when the adapter wrote one), the events, then the working files. Excluded folders
# on this side are kept.
rm -f -- "$result"
copy_rc=0
rsync_to --ignore-missing-args "$destination:$(remote_path "$result")" "$result" || copy_rc=$?
((copy_rc != 0)) || rsync_to --ignore-missing-args "$destination:$(remote_path "$events")" "$events" || copy_rc=$?
((copy_rc != 0)) || rsync_to --delete --exclude=/.git "${exclude_arguments[@]}" \
  "$destination:$(remote_path "$worktree")/" "$worktree/" || copy_rc=$?
if ((copy_rc != 0)); then
  printf 'remote-run: copying the work back from %s failed (rsync exit %s) after the adapter exited %s; the remote work stays at %s:%s\n' \
    "$destination" "$copy_rc" "$rc" "$destination" "$(remote_path "$worktree")" >&2
  exit 1
fi
exit "$rc"

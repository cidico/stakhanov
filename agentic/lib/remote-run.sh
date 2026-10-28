#!/usr/bin/env bash
# Runs one worker-role provider invocation on a remote executor (see "Remote executors" in .agentic/README.md):
#
#   remote-run.sh --executor JSON --ticket ID --slug SLUG --main-branch BRANCH [--file PATH]... [--env NAME]...
#                 --adapter PATH ROLE WORKTREE PROMPT RESULT EVENTS
#
# JSON is one normalized entry of the executors list (lib/common.sh); lib/remote.sh holds the steps, shared with
# bin/offload. The steps: reach the host; check its required commands and its admission for the executor's
# worker_units; push the ticket's commit, the campaign branch and the main branch to a bare mirror there; check that
# commit out in the remote worktree; sync the working files (uncommitted delta and deletions included), the engine,
# the prompt, the events, every --file and the executor's sync_paths; run the adapter in its own process group; copy the
# result, the events, the working files and the sync_paths back. --env names a variable forwarded to the adapter besides
# every AGENTIC_* one.
#
# Exit status: 75 when the executor is unavailable before the adapter started (unreachable, failing setup, a required
# command missing, or refused by its admit command; nothing local changed); otherwise the
# adapter's own status, or 1 when the copy back failed after it ran. An adapter status of 75 becomes 1, so it never
# reads as an unavailable executor. TERM or INT while the adapter runs stops its remote process group (TERM, then KILL
# after 3 seconds) and copies the working files back within 5 seconds, so the partial work survives as it would here.
set -euo pipefail
umask 077

agentic_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=remote.sh
source "$agentic_dir/lib/remote.sh"

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

executor_load "$executor_json"

temporary=$(mktemp -d)
run_pid='' pgid_file=''
trap 'rm -rf -- "$temporary"' EXIT

# A deadline stops the run with TERM and kills the whole group 10 seconds later (provider_deadline.py): stop the
# remote adapter, then bring its partial work back within what is left, as a local worker's delta would survive.
on_signal() {
  trap '' TERM INT
  if [[ -n $run_pid ]]; then
    printf 'remote-run: interrupted; stopping the %s on %s and copying its partial work back\n' "$role" "$destination" >&2
    kill "$run_pid" 2>/dev/null || true
    remote_stop "$pgid_file" \
      || printf 'remote-run: could not stop the remote process group; it may still run on %s\n' "$destination" >&2
    timeout 5 rsync -a "${rsync_options[@]}" -e "$ssh_line" --delete --exclude=/.git "${exclude_arguments[@]}" \
      "$destination:$(remote_path "$worktree")/" "$worktree/" \
      || printf 'remote-run: the partial work was not copied back; it stays at %s:%s\n' "$destination" "$(remote_path "$worktree")" >&2
  fi
  exit "$((128 + $1))"
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT

mirror_for "$worktree"

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

# 1. Reach the host and prepare the mirror and the folders; then its required commands and its own admission (admit):
# a host that has no room now sends the ticket back here instead of making the worker wait there.
executor_reach "${directories[@]}" -- "${stale[@]}"
executor_admit "$worker_units" worker

# 2. Push the ticket's commit and the branches its worker compares against, to the mirror only, and check that commit
# out in the remote worktree with the campaign and main branches next to it.
if branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD); then
  ticket_ref="refs/heads/$branch"
else
  branch='' ticket_ref="refs/agentic/$ticket"
fi
executor_checkout "$worktree" "$ticket_ref" "$branch" "campaign/$slug" "$main_branch"

# 3. The working files (uncommitted changes and deletions included), the engine and the inputs.
executor_sync_worktree "$worktree"
step 'syncing the engine' rsync_to --delete "$agentic_dir/" "$destination:$(remote_path "$agentic_dir")/"
[[ -z $provider_root ]] || step 'syncing the provider adapter' rsync_to --delete "$provider_root/" \
  "$destination:$(remote_path "$provider_root")/"
step 'syncing the prompt and events' rsync_to -R --no-implied-dirs "${inputs[@]}" "$destination:${root:-/}"
executor_sync_paths_out

# 4. Run the adapter with the local paths; the run prefix maps them. The adapter gets every AGENTIC_* variable (but
# the transport ones), the --env ones, the executor's env and the runner's git settings, with its worktree marked safe
# for git (a container may see the files under another owner).
run_environment "$worktree" "${env_names[@]}"
pgid_file="$base/.agentic/run/$key-$ticket-$$.pgid"
rc=0
remote_run "$pgid_file" "$worker_units" env "${environment[@]}" \
  bash "$adapter" "$role" "$worktree" "$prompt" "$result" "$events" &
run_pid=$!
wait "$run_pid" || rc=$?
run_pid=''
if ((rc == 75)); then
  printf 'remote-run: the adapter exited 75 on %s; reported as 1\n' "$destination" >&2
  rc=1
fi

# 5. Copy back: the result (only when the adapter wrote one), the events, then the working files. Excluded folders
# on this side are kept.
rm -f -- "$result"
copy_rc=0
rsync_to --ignore-missing-args "$destination:$(remote_path "$result")" "$result" || copy_rc=$?
((copy_rc != 0)) || rsync_to --ignore-missing-args "$destination:$(remote_path "$events")" "$events" || copy_rc=$?
((copy_rc != 0)) || rsync_to --delete --exclude=/.git "${exclude_arguments[@]}" \
  "$destination:$(remote_path "$worktree")/" "$worktree/" || copy_rc=$?
((copy_rc != 0)) || executor_sync_paths_back || copy_rc=$?
if ((copy_rc != 0)); then
  printf 'remote-run: copying the work back from %s failed (rsync exit %s) after the adapter exited %s; the remote work stays at %s:%s\n' \
    "$destination" "$copy_rc" "$rc" "$destination" "$(remote_path "$worktree")" >&2
  exit 1
fi
exit "$rc"

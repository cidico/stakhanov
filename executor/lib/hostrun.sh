# executor_host_run NAME DIR NAME=VALUE... -- COMMAND...: runs COMMAND straight on this host as the run user
# (EXECUTOR_USER), from DIR, with exactly the environment NAME=VALUE... (env -i), in the scope NAME.scope inside
# EXECUTOR_SLICE (the CPU and memory cap), in the network namespace EXECUTOR_NETNS when one is set, and in a mount
# namespace of its own where each EXECUTOR_BIND_PATHS entry P is <EXECUTOR_ROOT>/P bound at P (how the controlling
# machine's paths exist here). Waits, then stops the scope, so nothing COMMAND left (test hosts, build servers) keeps
# running or holding units; TERM or INT stop it at once (exit 143). Returns COMMAND's status. Needs root; load config.sh
# first.
executor_host_run() {
  local name=$1 dir=$2 rc=0 path saved
  shift 2
  local -a environment=() bind=() netns=()
  while (($#)) && [[ $1 != -- ]]; do environment+=("$1"); shift; done
  (($#)) && shift
  for path in "${EXECUTOR_BINDS[@]}"; do
    # Created only when missing: install -d resets the mode of a folder that exists (install.sh sets these up).
    [[ -d $path ]] || install -d -m 755 -- "$path"
    [[ -d $EXECUTOR_ROOT$path ]] || install -d -m 2770 -g "$EXECUTOR_GROUP" -- "$EXECUTOR_ROOT$path"
    bind+=("$EXECUTOR_ROOT$path" "$path")
  done
  bind=(unshare --mount --propagation private -- sh -c \
    'while [ "$1" != -- ]; do mount --bind "$1" "$2" || exit 1; shift 2; done; shift; exec "$@"' agentic-bind "${bind[@]}" --)
  [[ -z $EXECUTOR_NETNS ]] || netns=(ip netns exec "$EXECUTOR_NETNS")
  systemd-run --scope --quiet --unit="$name" --slice="$EXECUTOR_SLICE" --description="agentic executor run $name" -- \
    "${bind[@]}" "${netns[@]}" setpriv --reuid="$EXECUTOR_USER" --regid="$EXECUTOR_GROUP" --init-groups \
    env -i "${environment[@]}" bash -c 'cd "$1" && umask 002 && shift && exec "$@"' agentic-executor-run "$dir" "$@" &
  local pid=$!
  saved=$(trap -p TERM INT)
  trap 'systemctl stop "'"$name"'.scope" >/dev/null 2>&1; exit 143' TERM INT
  wait "$pid" || rc=$?
  trap - TERM INT
  eval "$saved"
  systemctl stop "$name.scope" >/dev/null 2>&1 || true
  return "$rc"
}

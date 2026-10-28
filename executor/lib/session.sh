# executor_watch_session COMMAND...: runs COMMAND once the ssh session that started this process ends while this process
# still runs, so a runner killed on the controlling machine never leaves a run going (or waiting, or holding units) here.
# The watcher polls the nearest sshd ancestor every 5 seconds, holds no unit and none of the session's streams, and ends
# with this process; without an sshd ancestor it does nothing. Call it before taking units.
executor_watch_session() {
  local pid=$$ owner=$$ comm
  while [[ ${pid:-1} -gt 1 ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
    case $comm in sshd*) break ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  [[ ${pid:-1} -gt 1 ]] || return 0
  (
    while kill -0 "$pid" 2>/dev/null; do
      kill -0 "$owner" 2>/dev/null || exit 0
      sleep 5
    done
    if kill -0 "$owner" 2>/dev/null; then "$@"; fi
  ) </dev/null >/dev/null 2>&1 &
  disown
}

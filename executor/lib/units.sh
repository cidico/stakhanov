# The executor's capacity: EXECUTOR_UNITS units, each a lock file in <EXECUTOR_STATE_DIR>/units held with flock while a
# run lasts (by every process that inherited its descriptor, so until the run's last process exits). Load config.sh
# first.
#
# executor_units_try K takes K units now or fails; executor_units_wait K waits for them, and while one waits neither
# executor_units_try nor agentic-executor-admit succeeds, so a large run is never starved by small ones. The descriptors
# of the units just taken are in EXECUTOR_UNITS_HELD: a caller that hands them to a background child closes its own
# copies with executor_units_release_here.
EXECUTOR_UNITS_HELD=()

executor_units_dir() { printf '%s/units\n' "$EXECUTOR_STATE_DIR"; }

# _executor_units_grab K: holds K units (their descriptors stay open in this shell) or none. The lock files are left
# group-writable, so a run's own processes may take units too.
_executor_units_grab() {
  local k=$1 i fd mutex dir mask got=()
  dir=$(executor_units_dir)
  mask=$(umask); umask 002
  exec {mutex}>>"$dir/mutex" || { umask "$mask"; return 1; }
  flock "$mutex"
  for ((i = 1; i <= EXECUTOR_UNITS && ${#got[@]} < k; i++)); do
    exec {fd}>>"$dir/u$i"
    if flock -n "$fd"; then got+=("$fd"); else exec {fd}>&-; fi
  done
  if ((${#got[@]} < k)); then
    for fd in "${got[@]}"; do exec {fd}>&-; done
    got=()
  fi
  exec {mutex}>&-
  umask "$mask"
  EXECUTOR_UNITS_HELD=("${got[@]}")
  ((${#got[@]} == k))
}

# executor_units_release_here: closes this shell's copies of the units last taken (a child that inherited them keeps
# them).
executor_units_release_here() {
  local fd
  for fd in "${EXECUTOR_UNITS_HELD[@]}"; do exec {fd}>&-; done
  EXECUTOR_UNITS_HELD=()
}

# executor_units_waiting: true while a run waits for units (its marker is less than a minute old).
executor_units_waiting() {
  local marker
  marker="$(executor_units_dir)/waiting"
  [[ -e $marker ]] && (($(date +%s) - $(stat -c %Y -- "$marker") < 60))
}

executor_units_try() { # K
  ! executor_units_waiting || return 1
  _executor_units_grab "$1"
}

executor_units_wait() { # K
  local said=''
  until _executor_units_grab "$1"; do
    touch -- "$(executor_units_dir)/waiting"
    [[ -n $said ]] || { printf 'agentic-executor: busy; waiting for %s of %s units\n' "$1" "$EXECUTOR_UNITS" >&2; said=1; }
    sleep "$EXECUTOR_UNITS_POLL_SECONDS"
  done
  rm -f -- "$(executor_units_dir)/waiting"
}

# executor_units_free: prints how many units are free now.
executor_units_free() {
  local i fd mutex free=0 dir
  dir=$(executor_units_dir)
  exec {mutex}>>"$dir/mutex" || return 1
  flock "$mutex"
  for ((i = 1; i <= EXECUTOR_UNITS; i++)); do
    exec {fd}>>"$dir/u$i"
    if flock -n "$fd"; then free=$((free + 1)); fi
    exec {fd}>&-
  done
  exec {mutex}>&-
  printf '%s\n' "$free"
}

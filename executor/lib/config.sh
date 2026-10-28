# The executor's settings (see executor.conf.example): /etc/agentic/executor.conf, or the file AGENTIC_EXECUTOR_CONF names
# (the tests use their own), read as shell KEY=VALUE lines, then the defaults below. Sourced by every command of the
# package; EXECUTOR_PACKAGE is the installed package folder.
EXECUTOR_PACKAGE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)

executor_config_error() {
  printf '%s: %s (%s)\n' "${0##*/}" "$*" "$EXECUTOR_CONF" >&2
  return 1
}

# executor_config_load: reads and checks the settings; prints the problem and fails when they are unusable.
executor_config_load() {
  local path account
  EXECUTOR_CONF=${AGENTIC_EXECUTOR_CONF:-/etc/agentic/executor.conf}
  [[ -r $EXECUTOR_CONF ]] || { executor_config_error 'cannot read the executor settings'; return 1; }
  # shellcheck source=/dev/null
  . "$EXECUTOR_CONF" || { executor_config_error 'the settings failed to load'; return 1; }
  : "${EXECUTOR_USER:=agentic}" "${EXECUTOR_GROUP:=$EXECUTOR_USER}" "${EXECUTOR_USER_GROUPS:=}"
  : "${EXECUTOR_ROOT:=/srv/agentic/work}" "${EXECUTOR_BIND_PATHS:=}" "${EXECUTOR_STATE_DIR:=/srv/agentic/state}"
  : "${EXECUTOR_UNITS:=4}" "${EXECUTOR_WORKER_UNITS:=1}"
  : "${EXECUTOR_SLICE:=agentic-executor.slice}" "${EXECUTOR_CPU_QUOTA:=}" "${EXECUTOR_MEMORY_MAX:=}"
  : "${EXECUTOR_NETNS:=}" "${EXECUTOR_NETNS_BRIDGE:=}" "${EXECUTOR_NETNS_ADDRESS:=}" "${EXECUTOR_NETNS_GATEWAY:=}"
  : "${EXECUTOR_NETNS_AFTER:=}" "${EXECUTOR_PROXY:=}" "${EXECUTOR_NO_PROXY:=localhost,127.0.0.1}"
  : "${EXECUTOR_ACCOUNTS_DIR:=/srv/agentic/accounts}" "${EXECUTOR_ACCOUNTS:=}"
  : "${EXECUTOR_CLAUDE:=/usr/local/lib/agentic-claude/claude}" "${EXECUTOR_ENV_FILE:=/etc/agentic/executor.env}"
  : "${EXECUTOR_PATH:=}"
  # How often a run waiting for units looks again (seconds); the tests shorten it.
  : "${EXECUTOR_UNITS_POLL_SECONDS:=10}"
  local name='^[a-z_][a-z0-9_-]*$'
  [[ $EXECUTOR_USER =~ $name && $EXECUTOR_GROUP =~ $name ]] || { executor_config_error 'EXECUTOR_USER and EXECUTOR_GROUP must be user and group names'; return 1; }
  for path in "$EXECUTOR_ROOT" "$EXECUTOR_STATE_DIR" "$EXECUTOR_ACCOUNTS_DIR"; do
    [[ $path == /?* ]] || { executor_config_error "EXECUTOR_ROOT, EXECUTOR_STATE_DIR and EXECUTOR_ACCOUNTS_DIR must be absolute paths: $path"; return 1; }
  done
  read -r -a EXECUTOR_BINDS <<<"$EXECUTOR_BIND_PATHS"
  ((${#EXECUTOR_BINDS[@]} > 0)) || { executor_config_error 'EXECUTOR_BIND_PATHS must name at least one path (the home of the controlling user)'; return 1; }
  for path in "${EXECUTOR_BINDS[@]}"; do
    [[ $path == /?* && $path != */ ]] || { executor_config_error "EXECUTOR_BIND_PATHS takes absolute paths without a trailing slash: $path"; return 1; }
  done
  [[ $EXECUTOR_UNITS =~ ^[1-9][0-9]*$ && $EXECUTOR_WORKER_UNITS =~ ^[1-9][0-9]*$ ]] && ((EXECUTOR_WORKER_UNITS <= EXECUTOR_UNITS)) \
    || { executor_config_error 'EXECUTOR_UNITS and EXECUTOR_WORKER_UNITS must be positive integers, EXECUTOR_WORKER_UNITS at most EXECUTOR_UNITS'; return 1; }
  [[ $EXECUTOR_UNITS_POLL_SECONDS =~ ^[0-9]+(\.[0-9]+)?$ ]] || { executor_config_error 'EXECUTOR_UNITS_POLL_SECONDS must be a number of seconds'; return 1; }
  [[ $EXECUTOR_SLICE =~ ^[A-Za-z0-9_.-]+\.slice$ ]] || { executor_config_error "EXECUTOR_SLICE must be a slice unit name (NAME.slice): $EXECUTOR_SLICE"; return 1; }
  if [[ -n $EXECUTOR_NETNS ]]; then
    [[ $EXECUTOR_NETNS =~ ^[A-Za-z0-9_-]+$ && -n $EXECUTOR_NETNS_BRIDGE && -n $EXECUTOR_NETNS_ADDRESS ]] \
      || { executor_config_error 'EXECUTOR_NETNS needs a plain name, EXECUTOR_NETNS_BRIDGE and EXECUTOR_NETNS_ADDRESS'; return 1; }
  fi
  read -r -a EXECUTOR_ACCOUNT_NAMES <<<"$EXECUTOR_ACCOUNTS"
  for account in "${EXECUTOR_ACCOUNT_NAMES[@]}"; do
    [[ $account =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { executor_config_error "EXECUTOR_ACCOUNTS takes folder names: $account"; return 1; }
  done
  [[ $EXECUTOR_CLAUDE == /?* ]] || { executor_config_error "EXECUTOR_CLAUDE must be an absolute path: $EXECUTOR_CLAUDE"; return 1; }
  return 0
}

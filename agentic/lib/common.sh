#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
IFS=$'\n\t'
# Reached over ssh without a login session (an sshd without PAM, as from another machine of the fleet), the shell lacks
# the user's runtime folder, and the supervisor and the background scope would silently be skipped: systemctl --user
# and systemd-run --user cannot reach the user's manager. It is the usual one.
if [[ -z ${XDG_RUNTIME_DIR:-} && -d /run/user/$(id -u) ]]; then export XDG_RUNTIME_DIR="/run/user/$(id -u)"; fi
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && -S ${XDG_RUNTIME_DIR:-/nonexistent}/bus ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

die() { printf 'campaign: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command unavailable: $1"; }
for command_name in git jq python3 flock setsid cmp; do require_command "$command_name"; done
unset command_name

AGENTIC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'campaign: not inside a Git repository\n' >&2
  exit 2
}
REPO_ROOT=$(cd -- "$REPO_ROOT" && pwd -P)
TICKET_TOOL="$AGENTIC_DIR/lib/tickets.py"
# Never replay conflict resolutions recorded elsewhere (rerere may be enabled globally); applies to every git
# command of the runner and of the commands it starts.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=rerere.enabled GIT_CONFIG_VALUE_0=false

note() { printf '%s\n' "$*"; }

# Project settings. The effective config is the main branch's committed .agentic/project.json, so the launcher in a
# campaign worktree and the engine (a snapshot of the main branch) always agree; the local copy under $AGENTIC_DIR only
# names the main branch and is the fallback while the main branch has no committed copy (before the first commit).
# A missing file means all defaults.
PROJECT_CONFIG="$AGENTIC_DIR/project.json"
PROJECT_CONFIG_SOURCE=$PROJECT_CONFIG
PROJECT_NAME='' PROJECT_TIMEZONE='' PROJECT_ARCHIVE_DIR=''
PROJECT_INSTRUCTION_FILES=(AGENTS.md CLAUDE.md)
PROJECT_REQUIRED_CHECKS='[]'
# What a machine must prove it has (name -> argv of the proof); see `campaign machine`.
PROJECT_CAPABILITIES='{}'
# Python regular expressions (a JSON list): a failed validation command whose output matches one failed because of its
# environment, not of the code.
PROJECT_ENVIRONMENT_FAILURE_PATTERNS='[]'
PROJECT_ENV_KEYS=()
# Remote machines that run workers (a JSON list); AGENTIC_EXECUTORS=local empties it.
PROJECT_EXECUTORS='[]'
# What a task asks of the project (see "Tasks" in README.md): the preamble of its TASK.md (a file of the main branch), the
# links of its worktree (a JSON map of name to path), the commands of its cleanup, of its accept's regeneration and checks
# (JSON lists of commands), and the regular expressions of the regen_paths and coordinator_paths globs (glob_regex).
PROJECT_TASK_PREAMBLE='' PROJECT_TASK_LINKS='{}' PROJECT_TASK_CLEANUP='[]' PROJECT_ACCEPT_REGEN='[]' PROJECT_ACCEPT_CHECKS='[]'
PROJECT_REGEN_REGEXES=() PROJECT_COORDINATOR_REGEXES=()
# Variables an env map of the settings may not set: they would redirect the runner itself.
REFUSED_ENV_NAMES='^(PATH|HOME|IFS|ENV|BASH_ENV|BASHOPTS|SHELLOPTS|PS4)$|^(GIT_|LD_|PYTHON)'

# The branch campaigns branch from and are finalized into: the main_branch of the local project.json, else main, else master.
resolve_main_branch() {
  local branch=''
  [[ ! -f $PROJECT_CONFIG ]] || branch=$(jq -r '.main_branch // "" | if type == "string" then . else "" end' "$PROJECT_CONFIG" 2>/dev/null) || branch=''
  if [[ -n $branch ]]; then
    git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch" \
      || die "main branch '$branch' (main_branch in $PROJECT_CONFIG) does not exist in this repository"
  elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/main; then
    branch=main
  elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/master; then
    branch=master
  else
    die "cannot find the main branch: neither 'main' nor 'master' exists; set \"main_branch\" in .agentic/project.json"
  fi
  printf '%s\n' "$branch"
}
MAIN_BRANCH=$(resolve_main_branch)

# The executors list of the settings, checked entry by entry so the error names the field. Missing optional fields
# are filled in (root "", empty lists and env, worker_units 1) and a trailing slash of root or of a sync path is dropped.
load_executors() {
  local error
  error=$(jq -r --arg refused "$REFUSED_ENV_NAMES" '
    def strings: type == "array" and all(.[]; type == "string" and length > 0);
    def positive: type == "number" and . >= 1 and . == floor;
    def fail($i; $message): "executor \($i + 1)\(if (.name | type) == "string" then " (\(.name))" else "" end): \($message)";
    def bad_env_name: .env | keys | map(select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)) | first;
    def refused_env_name: .env | keys | map(select(test($refused))) | first;
    ["name", "ssh", "workers", "root", "run", "exclude", "rsync_options", "sync_paths", "admit", "env", "requires",
     "worker_units"] as $fields
    | (.executors // []) as $list
    | if ($list | type) != "array" then "executors must be a list"
      else
        ([$list | to_entries[] | .key as $i | .value
          | if type != "object" then "executor \($i + 1): must be an object"
            elif (keys - $fields) != [] then fail($i; "unknown field \((keys - $fields)[0])")
            elif (.name | type) != "string" or (.name | test("^[a-z0-9-]+$") | not) then fail($i; "name must match [a-z0-9-]+")
            elif .name == "local" then fail($i; "the name local is reserved for this machine")
            elif (.ssh | type) != "string" or (.ssh | test("^[^-\\s]\\S*$") | not) then fail($i; "ssh must be an ssh destination or alias")
            elif (.workers | positive | not) then fail($i; "workers must be a positive integer")
            elif (.root // "" | type) != "string" or (.root // "" | . == "" or startswith("/") | not) then fail($i; "root must be an absolute path or empty")
            elif .run != null and (.run | strings | not) then fail($i; "run must be a list of non-empty strings")
            elif (.run // []) == [] and (.root // "" | sub("/+$"; "")) != "" then
              fail($i; "root needs a run prefix that presents <root>/x at /x; without run the remote paths are the local ones")
            elif .exclude != null and (.exclude | strings | not) then fail($i; "exclude must be a list of non-empty strings")
            elif .rsync_options != null and (.rsync_options | strings | not) then fail($i; "rsync_options must be a list of non-empty strings")
            elif .sync_paths != null and ((.sync_paths | strings | not) or any(.sync_paths[]; startswith("/") | not)) then
              fail($i; "sync_paths must be a list of absolute paths")
            elif .admit != null and (.admit | strings | not) then fail($i; "admit must be a list of non-empty strings")
            elif .env != null and ((.env | type) != "object" or any(.env[]; type != "string")) then
              fail($i; "env must be a map of strings")
            elif .env != null and bad_env_name != null then fail($i; "invalid environment variable name in env: \(bad_env_name)")
            elif .env != null and refused_env_name != null then
              fail($i; "env variable \(refused_env_name) would redirect the runner itself and is not allowed")
            elif .requires != null and ((.requires | strings | not) or any(.requires[]; test("^[A-Za-z0-9_.+/-]+$") | not)) then
              fail($i; "requires must be a list of command names")
            elif .worker_units != null and (.worker_units | positive | not) then fail($i; "worker_units must be a positive integer")
            else empty end]
         + [$list | map(objects | .name) | group_by(.)[] | select(length > 1) | "executor name \(.[0]) is not unique"])
        | first // empty
      end' <<<"$1") || die "invalid executors in $PROJECT_CONFIG_SOURCE"
  [[ -z $error ]] || die "invalid executors in $PROJECT_CONFIG_SOURCE: $error"
  PROJECT_EXECUTORS=$(jq -c '[(.executors // [])[]
    | .root = (.root // "" | sub("/+$"; "")) | .run = (.run // []) | .exclude = (.exclude // []) | .rsync_options = (.rsync_options // [])
    | .sync_paths = (.sync_paths // [] | map(sub("/+$"; ""))) | .admit = (.admit // []) | .env = (.env // {})
    | .requires = (.requires // []) | .worker_units = (.worker_units // 1)]' <<<"$1")
}

# glob_regex GLOB: sets GLOB_REGEX to the extended regular expression of a path glob of the settings (regen_paths,
# coordinator_paths), read as .gitignore reads one: * and ? never cross a /, ** crosses any number of folders, a glob
# without a / (a trailing one aside) matches at any depth while one with a / (or a leading one) is anchored at the root,
# and a match also covers everything under it. It starts no process.
glob_regex() {
  local glob=$1 regex='' char class index anchored=false
  if [[ $glob == /* ]]; then anchored=true; glob=${glob#/}; fi
  glob=${glob%/}
  [[ $glob != */* ]] || anchored=true
  for ((index = 0; index < ${#glob}; index++)); do
    char=${glob:index:1}
    case $char in
      '*')
        if [[ ${glob:index+1:1} != '*' ]]; then
          regex+='[^/]*'
        elif [[ ${glob:index+2:1} == / ]]; then
          regex+='(.*/)?'; index=$((index + 2))
        else
          regex+='.*'; index=$((index + 1))
        fi ;;
      '?') regex+='[^/]' ;;
      '[')
        class=${glob:index+1}
        if [[ $class == ?*']'* ]]; then
          class=${class%%]*}
          index=$((index + ${#class} + 1))
          [[ ${class:0:1} != '!' ]] || class="^${class:1}"
          regex+="[$class]"
        else
          regex+='\['
        fi ;;
      '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '\') regex+="\\$char" ;;
      *) regex+=$char ;;
    esac
  done
  if $anchored; then regex="^$regex"; else regex="(^|/)$regex"; fi
  GLOB_REGEX="$regex(/.*)?\$"
}

# path_matches PATH REGEX...: PATH (relative to the repository root) matches one of the regular expressions of glob_regex.
path_matches() {
  local path=$1 regex
  shift
  for regex in "$@"; do [[ $path =~ $regex ]] && return 0; done
  return 1
}

# The settings of the tasks, checked field by field so the error names the field.
load_task_settings() {
  local error glob
  local -a globs=()
  error=$(jq -r '
    def argv: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    def minutes: type == "number" and . == floor and . >= 1 and . <= 1440;
    def command: argv or (type == "object" and (keys - ["command", "timeout_minutes"]) == [] and (.command | argv)
                          and ((has("timeout_minutes") | not) or (.timeout_minutes | minutes)));
    def commands: type == "array" and all(.[]; command);
    def one_line: type == "string" and (test("\n") | not);
    def relative: (startswith("/") | not) and (split("/") | any(. == "..") | not);
    def globs: type == "array" and all(.[]; one_line and (ltrimstr("/") | length > 0 and relative));
    def message($field): "\($field) must be a list of commands (argv arrays or {\"command\": [...], \"timeout_minutes\": N})";
    if .task_preamble != null and (.task_preamble | (one_line | not) or (. != "" and (relative | not))) then
      "task_preamble must be the path of a file of the main branch, relative to the repository root"
    elif .task_links != null and (.task_links | type != "object"
         or any(to_entries[]; (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not)
                or (.value | (one_line | not) or (. == "~" or startswith("~/") or startswith("/") | not)))) then
      "task_links must map file names (letters, digits, dots, dashes and underscores) to absolute paths or paths under ~/"
    elif .task_cleanup != null and (.task_cleanup | commands | not) then message("task_cleanup")
    elif .accept_regen != null and (.accept_regen | commands | not) then message("accept_regen")
    elif .accept_checks != null and (.accept_checks | commands | not) then message("accept_checks")
    elif .regen_paths != null and (.regen_paths | globs | not) then
      "regen_paths must be a list of globs relative to the repository root"
    elif .coordinator_paths != null and (.coordinator_paths | globs | not) then
      "coordinator_paths must be a list of globs relative to the repository root"
    else empty end' <<<"$1") || die "invalid settings in $PROJECT_CONFIG_SOURCE (see project.json.example)"
  [[ -z $error ]] || die "invalid settings in $PROJECT_CONFIG_SOURCE: $error"
  PROJECT_TASK_PREAMBLE=$(jq -r '.task_preamble // ""' <<<"$1")
  PROJECT_TASK_LINKS=$(jq -c '.task_links // {}' <<<"$1")
  PROJECT_TASK_CLEANUP=$(jq -c '.task_cleanup // []' <<<"$1")
  PROJECT_ACCEPT_REGEN=$(jq -c '.accept_regen // []' <<<"$1")
  PROJECT_ACCEPT_CHECKS=$(jq -c '.accept_checks // []' <<<"$1")
  mapfile -t globs < <(jq -r '(.regen_paths // [])[]' <<<"$1")
  for glob in "${globs[@]}"; do glob_regex "$glob"; PROJECT_REGEN_REGEXES+=("$GLOB_REGEX"); done
  mapfile -t globs < <(jq -r '(.coordinator_paths // [])[]' <<<"$1")
  for glob in "${globs[@]}"; do glob_regex "$glob"; PROJECT_COORDINATOR_REGEXES+=("$GLOB_REGEX"); done
}

load_project_config() {
  local key value config error
  if config=$(git -C "$REPO_ROOT" show "$MAIN_BRANCH:.agentic/project.json" 2>/dev/null); then
    PROJECT_CONFIG_SOURCE="$MAIN_BRANCH:.agentic/project.json"
  elif [[ -f $PROJECT_CONFIG ]]; then
    config=$(<"$PROJECT_CONFIG")
  else
    return 0
  fi
  jq -e . <<<"$config" >/dev/null 2>&1 || die "invalid JSON in $PROJECT_CONFIG_SOURCE"
  jq -e '
    def text: . == null or type == "string";
    def argv: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    type == "object" and (.name | text) and (.main_branch | text) and (.timezone | text) and (.archive_dir | text)
    and (.instruction_files == null or (.instruction_files | type == "array"
         and all(.[]; type == "string" and length > 0 and (contains("/") | not))))
    and (.env == null or (.env | type == "object" and all(.[]; type == "string")))
    and (.required_checks == null or (.required_checks | type == "array" and all(.[]; argv)))
    and (.capabilities == null or (.capabilities | type == "object"
         and all(to_entries[]; (.key | test("^[A-Za-z0-9_.+/-]+$")) and (.value | argv))))
    and (.environment_failure_patterns == null
         or (.environment_failure_patterns | type == "array" and all(.[]; type == "string" and length > 0)))
  ' <<<"$config" >/dev/null || die "invalid settings in $PROJECT_CONFIG_SOURCE (see project.json.example)"
  load_executors "$config"
  load_task_settings "$config"
  PROJECT_ENVIRONMENT_FAILURE_PATTERNS=$(jq -c '.environment_failure_patterns // []' <<<"$config")
  if [[ $PROJECT_ENVIRONMENT_FAILURE_PATTERNS != '[]' ]]; then
    error=$(python3 -c '
import json, re, sys
for pattern in json.loads(sys.argv[1]):
    try:
        re.compile(pattern)
    except re.error as error:
        print(f"{pattern!r}: {error}")
        raise SystemExit(1)
' "$PROJECT_ENVIRONMENT_FAILURE_PATTERNS") \
      || die "invalid environment_failure_patterns in $PROJECT_CONFIG_SOURCE: ${error:-not Python regular expressions}"
  fi
  PROJECT_NAME=$(jq -r '.name // ""' <<<"$config")
  PROJECT_TIMEZONE=$(jq -r '.timezone // ""' <<<"$config")
  PROJECT_ARCHIVE_DIR=$(jq -r '.archive_dir // ""' <<<"$config")
  PROJECT_REQUIRED_CHECKS=$(jq -c '.required_checks // []' <<<"$config")
  PROJECT_CAPABILITIES=$(jq -c '.capabilities // {}' <<<"$config")
  if [[ $(jq '.instruction_files != null' <<<"$config") == true ]]; then
    mapfile -t PROJECT_INSTRUCTION_FILES < <(jq -r '.instruction_files[]' <<<"$config")
  fi
  # Exported for the runner, the workers and the validation commands; the environment always wins. Variables that would
  # redirect the runner itself are refused.
  mapfile -t PROJECT_ENV_KEYS < <(jq -r '(.env // {}) | keys[]' <<<"$config")
  for key in "${PROJECT_ENV_KEYS[@]}"; do
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid environment variable name in $PROJECT_CONFIG_SOURCE: $key"
    [[ ! $key =~ $REFUSED_ENV_NAMES ]] \
      || die "environment variable $key in $PROJECT_CONFIG_SOURCE would redirect the runner itself and is not allowed"
    [[ -z ${!key+x} ]] || continue
    value=$(jq -r --arg key "$key" '.env[$key]' <<<"$config")
    export "$key=$value"
  done
  # Display time zone: AGENTIC_DISPLAY_TZ, then the settings, then the system zone (TZ is never set).
  if [[ -z ${AGENTIC_DISPLAY_TZ:-} && -n $PROJECT_TIMEZONE ]]; then export AGENTIC_DISPLAY_TZ=$PROJECT_TIMEZONE; fi
}
load_project_config
# This machine's name in its fleet (see "Fleet" in README.md), or empty: the entry of fleet.json whose id is this
# machine's id.
fleet_self_name() {
  local file=${AGENTIC_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/agentic/fleet.json} id=${AGENTIC_MACHINE_ID:-}
  [[ -f $file ]] || return 0
  [[ -n $id ]] || id=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true)
  [[ -n $id ]] || return 0
  jq -r --arg id "$id" 'first((.machines // {}) | to_entries[] | select(.value.id == $id) | .key) // ""' "$file" 2>/dev/null || true
}
# Where a campaign is and how to open it (campaign status, overview, run and move print it).
# shell_word WORD: WORD as one shell word a person can paste: as it is when plain, single-quoted otherwise.
shell_word() {
  if [[ $1 =~ ^[A-Za-z0-9_./:@%+=,-]+$ ]]; then printf '%s' "$1"; else printf "'%s'" "${1//\'/\'\\\'\'}"; fi
}
# This machine's name: its name in the fleet, else its host name.
machine_name() {
  local name
  name=$(fleet_self_name)
  [[ -n $name ]] || name=$(uname -n | cut -d. -f1)
  printf '%s\n' "$name"
}
# open_command TREE PROVIDER [VIA]: the command that opens PROVIDER's CLI in the campaign worktree TREE. VIA (default
# AGENTIC_OPEN_VIA, which a command routed from another machine of the fleet carries: `ssh -t <this machine>`) runs it
# from where the person asked.
open_command() {
  local inner via=${3-${AGENTIC_OPEN_VIA:-}}
  inner="cd $(shell_word "$1") && ${2:-claude}"
  if [[ -n $via ]]; then printf '%s %s\n' "$via" "$(shell_word "$inner")"; else printf '%s\n' "$inner"; fi
}
# A machine of the fleet that is also one of the executors (same name) never sends work to itself.
if [[ $PROJECT_EXECUTORS != '[]' ]]; then
  PROJECT_EXECUTORS=$(jq -c --arg self "$(fleet_self_name)" 'map(select(.name != $self))' <<<"$PROJECT_EXECUTORS")
fi
# AGENTIC_EXECUTORS=local runs every worker on this machine, whatever the settings declare.
case ${AGENTIC_EXECUTORS:-} in
  '') ;;
  local) PROJECT_EXECUTORS='[]' ;;
  *) die "AGENTIC_EXECUTORS accepts only 'local' (every worker on this machine)" ;;
esac

current_branch() {
  git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || return 1
}

# git_hooked ARGUMENT...: git for a command that runs the project's hooks (commit, rebase, merge, worktree add, switch).
# git hands a hook every descriptor of its caller, and the kit holds its locks on 6 to 9 (launcher.lock and runner.lock
# on 6 and 7, the engine's runner.lock on 8, git.lock or a queue's lock on 9): they are closed for it, so a process a
# hook leaves running (a build server, a daemon) never holds one after its holder ends.
git_hooked() { git "$@" 6>&- 7>&- 8>&- 9>&-; }

campaign_slug_from_branch() {
  local branch=${1:-}
  case "$branch" in
    campaign/*) printf '%s\n' "${branch#campaign/}" ;;
    agentic/*/*) branch=${branch#agentic/}; printf '%s\n' "${branch%%/*}" ;;
    *) return 1 ;;
  esac
}

# Names that a campaign slug can never take: they are the folders (and the file names) the machine's cache keeps next to the
# campaigns' runtimes, which a slug of the same name would overwrite or be mistaken for. The names after `finalizing` are
# reserved ahead of the folders that will use them.
RESERVED_SLUGS=(queue moved finalized finalizing supervisor archive tasks slots fleet-seen main)

reserved_slug() {
  local name
  for name in "${RESERVED_SLUGS[@]}"; do [[ $1 == "$name" ]] && return 0; done
  return 1
}

# The reserved names as a JSON array, for the validators written in jq.
reserved_slugs_json() { printf '%s\n' "${RESERVED_SLUGS[@]}" | jq -R . | jq -sc .; }

validate_slug() {
  [[ $1 =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid campaign slug: $1"
  ! reserved_slug "$1" || die "campaign slug '$1' is reserved (it names a folder of the machine's cache); reserved names: ${RESERVED_SLUGS[*]}"
}

campaign_slug() {
  local slug branch
  branch=$(current_branch) || die 'detached HEAD is not a campaign'
  slug=$(campaign_slug_from_branch "$branch") || die "branch '$branch' is outside campaign/<slug>"
  validate_slug "$slug"
  printf '%s\n' "$slug"
}

repo_id() {
  local identity common
  common=$(git -C "$REPO_ROOT" rev-parse --git-common-dir)
  [[ $common == /* ]] || common="$REPO_ROOT/$common"
  identity=$(realpath -m -- "$common")
  printf '%s' "$identity" | sha256sum | cut -c1-16
}

runtime_base() {
  local base=${AGENTIC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agentic}
  # Git records worktrees by their physical path: a cache reached through a symlink would never match them.
  base=$(realpath -m -- "$base")
  printf '%s/%s\n' "${base%/}" "$(repo_id)"
}

runtime_dir() {
  local slug=${1:-$(campaign_slug)}
  printf '%s/%s\n' "$(runtime_base)" "$slug"
}

ensure_runtime() {
  local directory base
  directory=$(runtime_dir "${1:-$(campaign_slug)}")
  base=$(runtime_base)
  [[ ! -L $base && ! -L $directory ]] || die 'runtime cache path must not be a symlink'
  mkdir -p -- "$directory" "$directory/events" "$directory/logs" "$directory/results" \
    "$directory/prompts" "$directory/state" "$directory/decisions" "$directory/worktrees"
  chmod 700 "$(runtime_base)" "$directory" "$directory"/* 2>/dev/null || true
  printf '%s\n' "$directory"
}

# A task is a campaign of one ticket whose plan (SPEC.md, tickets/T-001.md, validation.json and task.json, written from
# its brief by `campaign _task-plan`) lives in its runtime, <runtime>/plan, instead of campaigns/<slug>/ on its branch:
# its campaign.json says "kind": "task". Everything else, its campaign/<slug> branch included, is a campaign's.
campaign_kind() {
  local file
  file="$(runtime_dir "${1:-$(campaign_slug)}")/campaign.json"
  if [[ -f $file && $(jq -r '.kind // ""' "$file" 2>/dev/null) == task ]]; then printf 'task\n'; else printf 'campaign\n'; fi
}
campaign_is_task() { [[ $(campaign_kind "${1:-}") == task ]]; }

# The campaign's plan folder: campaigns/<slug> on its branch, or a task's <runtime>/plan.
campaign_path() {
  local slug=${1:-$(campaign_slug)}
  if campaign_is_task "$slug"; then
    printf '%s/plan\n' "$(runtime_dir "$slug")"
  else
    printf '%s/campaigns/%s\n' "$REPO_ROOT" "$slug"
  fi
}
tickets_path() { printf '%s/tickets\n' "$(campaign_path "${1:-$(campaign_slug)}")"; }
# The tickets folder of the campaign whose campaign.json is FILE, from any worktree of the repository.
campaign_tickets_dir() {
  if [[ $(jq -r '.kind // ""' "$1" 2>/dev/null) == task ]]; then
    printf '%s/plan/tickets\n' "$(dirname -- "$1")"
  else
    printf '%s/campaigns/%s/tickets\n' "$(jq -r '.worktree' "$1")" "$(jq -r '.slug' "$1")"
  fi
}
# The message of a task's commits: the brief's type(area), feat(task) without one, and its title.
task_commit_message() {
  jq -r '"\(.commit // "feat(task)"): \(.title)"' "$(campaign_path "${1:-}")/task.json"
}

event() {
  local type=$1 message=${2:-} ticket=${3:-} runtime
  runtime=$(ensure_runtime)
  jq -cn --arg time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg type "$type" \
    --arg message "$message" --arg ticket "$ticket" \
    '{time:$time,type:$type,message:$message} + (if $ticket == "" then {} else {ticket:$ticket} end)' \
    >>"$runtime/events/campaign.ndjson"
}

# The desired state of a campaign ("desired" in its campaign.json): running, unless campaign stop said stopped.
desired_state() {
  jq -r '.desired // "running"' "$(runtime_dir "${1:-$(campaign_slug)}")/campaign.json" 2>/dev/null || printf 'running\n'
}

set_desired_state() {
  local file
  file="$(runtime_dir "$1")/campaign.json"
  [[ -f $file ]] || return 0
  jq --arg state "$2" '.desired = $state' "$file" >"$file.tmp" && chmod 600 "$file.tmp" && mv -f -- "$file.tmp" "$file"
}

runner_alive() {
  local runtime pid
  runtime=$(runtime_dir "${1:-$(campaign_slug)}")
  [[ -f "$runtime/runner.lock" ]] || return 1
  flock -n "$runtime/runner.lock" -c true 2>/dev/null && return 1
  [[ -s "$runtime/runner.pid" ]] || return 0
  read -r pid <"$runtime/runner.pid"
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
}

assert_campaign_branch() {
  local branch slug
  branch=$(current_branch) || die 'detached HEAD is not executable as a campaign'
  [[ $branch == campaign/* ]] || die "campaign command requires campaign/<slug>; current branch is '$branch'"
  slug=$(campaign_slug_from_branch "$branch")
  validate_slug "$slug"
}

ticket_json() { python3 "$TICKET_TOOL" get "$(tickets_path)" "$1"; }
ticket_path() { ticket_json "$1" | jq -er '.path'; }

set_ticket_status() {
  local ticket=$1 status=$2 path
  path=$(ticket_path "$ticket")
  python3 "$TICKET_TOOL" set-status "$path" "$ticket" "$status"
}

# keep_task_result SLUG WORKTREE: a task's worker writes its report in .task/RESULT.md, which Git ignores and the
# worktree's removal would lose: it is kept as <runtime>/RESULT.md first.
keep_task_result() {
  local file="$2/.task/RESULT.md"
  [[ -f $file && ! -L $file ]] && campaign_is_task "$1" || return 0
  cp -- "$file" "$(runtime_dir "$1")/RESULT.md"
}

safe_remove_ticket_worktree() {
  local slug=$1 ticket=$2 runtime worktree branch actual_branch
  validate_slug "$slug"
  [[ $ticket =~ ^[A-Z][A-Z0-9]*-[0-9]{3,}$ ]] || die "unsafe ticket id: $ticket"
  runtime=$(runtime_dir "$slug")
  worktree="$runtime/worktrees/$ticket"
  branch="agentic/$slug/$ticket"
  case "$worktree" in "$runtime"/worktrees/*) ;; *) die 'unsafe worktree path' ;; esac
  if git -C "$REPO_ROOT" worktree list --porcelain | grep -Fx "worktree $worktree" >/dev/null; then
    actual_branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [[ $actual_branch == "$branch" ]] || die "refusing to remove worktree owned by '$actual_branch'"
    [[ -z $(git -C "$worktree" status --porcelain=v1) ]] || die "refusing to remove dirty ticket worktree: $ticket"
    keep_task_result "$slug" "$worktree"
    git -C "$REPO_ROOT" worktree remove -- "$worktree"
  fi
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$REPO_ROOT" branch -d -- "$branch" >/dev/null
  fi
}

commit_campaign_status() {
  local ticket=$1 status=$2
  set_ticket_status "$ticket" "$status"
  # A task's plan lives in its runtime: its status is written there and nothing is committed.
  if campaign_is_task; then return 0; fi
  git -C "$REPO_ROOT" add -- "$(ticket_path "$ticket")"
  git_hooked -C "$REPO_ROOT" commit -m "chore(agentic): mark $ticket $status" >/dev/null
}

sanitize_file() {
  local file=$1
  [[ -f $file ]] || return 0
  sed -E -i \
    -e 's/([Aa]uthorization:[[:space:]]*(Bearer|Basic))[[:space:]]+[^[:space:]"}]+/\1 [REDACTED]/g' \
    -e 's/((api[_-]?key|token|password|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]",}]+/\1[REDACTED]/Ig' \
    "$file"
}

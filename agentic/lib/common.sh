#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
IFS=$'\n\t'

die() { printf 'campaign: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command unavailable: $1"; }
for command_name in git jq python3 flock setsid; do require_command "$command_name"; done
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
PROJECT_ENV_KEYS=()
# Remote machines that run workers (a JSON list); AGENTIC_EXECUTORS=local empties it.
PROJECT_EXECUTORS='[]'

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
# are filled in (root "", empty lists) and a trailing slash of root or of a sync path is dropped.
load_executors() {
  local error
  error=$(jq -r '
    def strings: type == "array" and all(.[]; type == "string" and length > 0);
    def fail($i; $message): "executor \($i + 1)\(if (.name | type) == "string" then " (\(.name))" else "" end): \($message)";
    (.executors // []) as $list
    | if ($list | type) != "array" then "executors must be a list"
      else
        ([$list | to_entries[] | .key as $i | .value
          | if type != "object" then "executor \($i + 1): must be an object"
            elif (keys - ["name", "ssh", "workers", "root", "run", "exclude", "rsync_options", "sync_paths", "admit"]) != [] then
              fail($i; "unknown field \((keys - ["name", "ssh", "workers", "root", "run", "exclude", "rsync_options", "sync_paths", "admit"])[0])")
            elif (.name | type) != "string" or (.name | test("^[a-z0-9-]+$") | not) then fail($i; "name must match [a-z0-9-]+")
            elif .name == "local" then fail($i; "the name local is reserved for this machine")
            elif (.ssh | type) != "string" or (.ssh | test("^[^-\\s]\\S*$") | not) then fail($i; "ssh must be an ssh destination or alias")
            elif (.workers | type) != "number" or .workers < 1 or .workers != (.workers | floor) then fail($i; "workers must be a positive integer")
            elif (.root // "" | type) != "string" or (.root // "" | . == "" or startswith("/") | not) then fail($i; "root must be an absolute path or empty")
            elif .run != null and (.run | strings | not) then fail($i; "run must be a list of non-empty strings")
            elif (.run // []) == [] and (.root // "" | sub("/+$"; "")) != "" then
              fail($i; "root needs a run prefix that presents <root>/x at /x; without run the remote paths are the local ones")
            elif .exclude != null and (.exclude | strings | not) then fail($i; "exclude must be a list of non-empty strings")
            elif .rsync_options != null and (.rsync_options | strings | not) then fail($i; "rsync_options must be a list of non-empty strings")
            elif .sync_paths != null and ((.sync_paths | strings | not) or any(.sync_paths[]; startswith("/") | not)) then
              fail($i; "sync_paths must be a list of absolute paths")
            elif .admit != null and (.admit | strings | not) then fail($i; "admit must be a list of non-empty strings")
            else empty end]
         + [$list | map(objects | .name) | group_by(.)[] | select(length > 1) | "executor name \(.[0]) is not unique"])
        | first // empty
      end' <<<"$1") || die "invalid executors in $PROJECT_CONFIG_SOURCE"
  [[ -z $error ]] || die "invalid executors in $PROJECT_CONFIG_SOURCE: $error"
  PROJECT_EXECUTORS=$(jq -c '[(.executors // [])[]
    | .root = (.root // "" | sub("/+$"; "")) | .run = (.run // []) | .exclude = (.exclude // []) | .rsync_options = (.rsync_options // [])
    | .sync_paths = (.sync_paths // [] | map(sub("/+$"; ""))) | .admit = (.admit // [])]' <<<"$1")
}

load_project_config() {
  local key value config
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
  ' <<<"$config" >/dev/null || die "invalid settings in $PROJECT_CONFIG_SOURCE (see project.json.example)"
  load_executors "$config"
  PROJECT_NAME=$(jq -r '.name // ""' <<<"$config")
  PROJECT_TIMEZONE=$(jq -r '.timezone // ""' <<<"$config")
  PROJECT_ARCHIVE_DIR=$(jq -r '.archive_dir // ""' <<<"$config")
  PROJECT_REQUIRED_CHECKS=$(jq -c '.required_checks // []' <<<"$config")
  if [[ $(jq '.instruction_files != null' <<<"$config") == true ]]; then
    mapfile -t PROJECT_INSTRUCTION_FILES < <(jq -r '.instruction_files[]' <<<"$config")
  fi
  # Exported for the runner, the workers and the validation commands; the environment always wins. Variables that would
  # redirect the runner itself are refused.
  mapfile -t PROJECT_ENV_KEYS < <(jq -r '(.env // {}) | keys[]' <<<"$config")
  for key in "${PROJECT_ENV_KEYS[@]}"; do
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid environment variable name in $PROJECT_CONFIG_SOURCE: $key"
    case $key in
      PATH|HOME|IFS|ENV|BASH_ENV|BASHOPTS|SHELLOPTS|PS4|GIT_*|LD_*|PYTHON*)
        die "environment variable $key in $PROJECT_CONFIG_SOURCE would redirect the runner itself and is not allowed" ;;
    esac
    [[ -z ${!key+x} ]] || continue
    value=$(jq -r --arg key "$key" '.env[$key]' <<<"$config")
    export "$key=$value"
  done
  # Display time zone: AGENTIC_DISPLAY_TZ, then the settings, then the system zone (TZ is never set).
  if [[ -z ${AGENTIC_DISPLAY_TZ:-} && -n $PROJECT_TIMEZONE ]]; then export AGENTIC_DISPLAY_TZ=$PROJECT_TIMEZONE; fi
}
load_project_config
# AGENTIC_EXECUTORS=local runs every worker on this machine, whatever the settings declare.
case ${AGENTIC_EXECUTORS:-} in
  '') ;;
  local) PROJECT_EXECUTORS='[]' ;;
  *) die "AGENTIC_EXECUTORS accepts only 'local' (every worker on this machine)" ;;
esac

current_branch() {
  git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || return 1
}

campaign_slug_from_branch() {
  local branch=${1:-}
  case "$branch" in
    campaign/*) printf '%s\n' "${branch#campaign/}" ;;
    agentic/*/*) branch=${branch#agentic/}; printf '%s\n' "${branch%%/*}" ;;
    *) return 1 ;;
  esac
}

validate_slug() {
  [[ $1 =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid campaign slug: $1"
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

campaign_path() { printf '%s/campaigns/%s\n' "$REPO_ROOT" "${1:-$(campaign_slug)}"; }
tickets_path() { printf '%s/tickets\n' "$(campaign_path "${1:-$(campaign_slug)}")"; }

event() {
  local type=$1 message=${2:-} ticket=${3:-} runtime
  runtime=$(ensure_runtime)
  jq -cn --arg time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg type "$type" \
    --arg message "$message" --arg ticket "$ticket" \
    '{time:$time,type:$type,message:$message} + (if $ticket == "" then {} else {ticket:$ticket} end)' \
    >>"$runtime/events/campaign.ndjson"
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
    git -C "$REPO_ROOT" worktree remove -- "$worktree"
  fi
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$REPO_ROOT" branch -d -- "$branch" >/dev/null
  fi
}

commit_campaign_status() {
  local ticket=$1 status=$2
  set_ticket_status "$ticket" "$status"
  git -C "$REPO_ROOT" add -- "$(ticket_path "$ticket")"
  git -C "$REPO_ROOT" commit -m "chore(agentic): mark $ticket $status" >/dev/null
}

sanitize_file() {
  local file=$1
  [[ -f $file ]] || return 0
  sed -E -i \
    -e 's/([Aa]uthorization:[[:space:]]*(Bearer|Basic))[[:space:]]+[^[:space:]"}]+/\1 [REDACTED]/g' \
    -e 's/((api[_-]?key|token|password|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]",}]+/\1[REDACTED]/Ig' \
    "$file"
}

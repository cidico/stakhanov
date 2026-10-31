#!/usr/bin/env bash
# The fleet (see "Fleet" in .agentic/README.md): machines that each hold a clone of the project and reach one another
# over ssh. Sourced by bin/campaign for the commands that use it, after lib/common.sh and lib/remote.sh (whose
# remote_script is the transport); it defines functions and variables and runs nothing.
#
# One file describes the fleet, the same on every member (fleet_file):
#   {"machines": {NAME: {"ssh": DESTINATION, "id": MACHINE_ID}}, "projects": {PROJECT: {"paths": {NAME: PATH}}}}
# A machine finds its own entry by its machine id, and a project is the name of its committed project.json. Code moves
# between the clones through git alone: each clone has the others as remotes named after their machines. No command
# moves a main branch: a clone behind another one is reported, and its owner pulls by hand.

fleet_file() { printf '%s\n' "${AGENTIC_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/agentic/fleet.json}"; }

# The scripts below run on one machine of the fleet, this one (bash -c) or another (remote_script), with the same
# positional arguments (fleet_on).

# This machine's id: systemd's machine id, unless AGENTIC_MACHINE_ID names another.
read -r -d '' FLEET_MACHINE_ID <<'SCRIPT' || true
id=${AGENTIC_MACHINE_ID:-}
[ -n "$id" ] || id=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true)
printf '%s\n' "$id"
SCRIPT

# PATH RELATIVE: what join needs to know of a machine, one item per line: its id, its home, the address it sees the
# caller at, the commands it lacks, the clone's path (PATH, else HOME/RELATIVE), the state there (absent, empty, repo or
# other), the root commits of a repository there; then its fleet file.
read -r -d '' FLEET_PROBE <<'SCRIPT' || true
path=$1 relative=$2
printf '%s\n' "$HOME" "${SSH_CONNECTION%% *}"
missing=''
for command in git jq python3 flock setsid cmp rsync; do
  command -v "$command" >/dev/null 2>&1 || missing="$missing $command"
done
printf '%s\n' "${missing# }"
[ -n "$path" ] || path=$HOME/$relative
printf '%s\n' "$path"
if [ ! -e "$path" ]; then
  printf 'absent\n\n'
elif [ -d "$path" ] && [ -z "$(ls -A "$path")" ]; then
  printf 'empty\n\n'
elif [ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$path" && pwd -P)" ]; then
  printf 'repo\n%s\n' "$(git -C "$path" rev-list --max-parents=0 --all 2>/dev/null | tr '\n' ' ')"
else
  printf 'other\n\n'
fi
file=${AGENTIC_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/agentic/fleet.json}
if [ -f "$file" ]; then cat "$file"; else printf '{}\n'; fi
SCRIPT
FLEET_PROBE="$FLEET_MACHINE_ID"$'\n'"$FLEET_PROBE"

# CONTENT: replaces the machine's fleet file (removes it when CONTENT is empty).
read -r -d '' FLEET_WRITE <<'SCRIPT' || true
set -eu
file=${AGENTIC_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/agentic/fleet.json}
umask 077
mkdir -p "$(dirname "$file")"
if [ -n "$1" ]; then
  printf '%s\n' "$1" >"$file.tmp"
  mv -f "$file.tmp" "$file"
else
  rm -f "$file"
fi
SCRIPT

# REPO [NAME URL]... [-- NAME...]: adds or updates the fleet's remotes NAME of the clone REPO, then removes the ones
# after --. A remote the fleet did not add (it has no remote.<name>.agentic-fleet) is never changed: a name that is
# already another remote fails, after the others are done.
read -r -d '' FLEET_REMOTES <<'SCRIPT' || true
set -eu
repo=$1 status=0
shift
[ -d "$repo" ] || exit 0
ours() { [ "$(git -C "$repo" config --get "remote.$1.agentic-fleet" 2>/dev/null || true)" = true ]; }
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  name=$1 url=$2
  shift 2
  if current=$(git -C "$repo" remote get-url "$name" 2>/dev/null); then
    if ! ours "$name" && [ "$current" != "$url" ]; then
      printf 'the remote %s of %s is %s, not the fleet machine; left as it is\n' "$name" "$repo" "$current" >&2
      status=1
      continue
    fi
    git -C "$repo" remote set-url "$name" "$url"
  else
    git -C "$repo" remote add "$name" "$url"
  fi
  git -C "$repo" config "remote.$name.agentic-fleet" true
done
[ "$#" -eq 0 ] || shift
for name do
  if ours "$name"; then git -C "$repo" remote remove "$name"; fi
done
exit "$status"
SCRIPT

# PATH: an empty repository at PATH whose HEAD is an unborn branch of its own, so the main branch arrives by push like
# any other branch.
read -r -d '' FLEET_CLONE_INIT <<'SCRIPT' || true
set -eu
mkdir -p "$1"
git init -q "$1"
git -C "$1" symbolic-ref HEAD refs/heads/agentic-join
SCRIPT

# PATH BRANCH USER_NAME USER_EMAIL: checks the pushed main branch out. The runner commits in that clone: without an
# identity of its own there, it takes the one of the machine it came from.
read -r -d '' FLEET_CLONE_CHECKOUT <<'SCRIPT' || true
set -eu
path=$1 branch=$2 user_name=$3 user_email=$4
git -C "$path" checkout -q "$branch"
if [ -z "$(git -C "$path" config user.name || true)" ] && [ -n "$user_name" ]; then
  git -C "$path" config user.name "$user_name"
fi
if [ -z "$(git -C "$path" config user.email || true)" ] && [ -n "$user_email" ]; then
  git -C "$path" config user.email "$user_email"
fi
SCRIPT

# REPO REMOTE: the clone REPO reaches the clone behind its remote REMOTE with git over ssh, without a prompt. A host seen
# for the first time is trusted (accept-new): the machines of a fleet trust one another.
read -r -d '' FLEET_REACH <<'SCRIPT' || true
cd "$1" || exit 1
GIT_SSH_COMMAND="${AGENTIC_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new" \
  GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$2" >/dev/null
SCRIPT

# PATH: the campaign overview of the clone at PATH, as JSON. Programs installed for the user (~/.local/bin) are on the
# PATH of every command the fleet runs on a machine, after the system's (so a wrapper of the system still comes first).
read -r -d '' FLEET_OVERVIEW <<'SCRIPT' || true
export PATH="$PATH:$HOME/.local/bin"
cd -- "$1" && exec ./.agentic/bin/campaign overview --json
SCRIPT

# COMMAND...: installs the commands the kit needs with the machine's package manager, as root or through sudo without a
# password. Exit 3 with the command to run on stdout when sudo needs a password; exit 4 without a package manager it
# knows. The proxy variables of the session go along.
read -r -d '' FLEET_PACKAGES <<'SCRIPT' || true
manager=''
for candidate in pacman apt-get dnf zypper; do
  command -v "$candidate" >/dev/null 2>&1 && { manager=$candidate; break; }
done
[ -n "$manager" ] || { printf 'no supported package manager (pacman, apt-get, dnf, zypper)\n'; exit 4; }
packages=''
for command do
  case $command in
    python3) if [ "$manager" = pacman ]; then package=python; else package=python3; fi ;;
    flock|setsid) package=util-linux ;;
    cmp) package=diffutils ;;
    *) package=$command ;;
  esac
  case " $packages " in *" $package "*) ;; *) packages="$packages $package" ;; esac
done
case $manager in
  pacman) install="pacman -S --needed --noconfirm$packages" ;;
  apt-get) install="apt-get update && apt-get install -y$packages" ;;
  dnf) install="dnf install -y$packages" ;;
  zypper) install="zypper --non-interactive install$packages" ;;
esac
proxies=''
for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
  eval "value=\${$name:-}"
  [ -z "$value" ] || proxies="$proxies $name=$value"
done
if [ "$(id -u)" = 0 ]; then
  exec env $proxies sh -c "$install"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  exec sudo -n env $proxies sh -c "$install"
fi
printf 'sudo env%s sh -c %s\n' "$proxies" "'$install'"
exit 3
SCRIPT

# The machine's ssh key (made when it has none), so that the other machines can authorize it: prints the public key.
read -r -d '' FLEET_KEY <<'SCRIPT' || true
set -eu
key=$HOME/.ssh/id_ed25519
if [ ! -f "$key" ]; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C "$(id -un)@$(uname -n)" -f "$key"
fi
cat "$key.pub"
SCRIPT

# PATH PROVIDER MODE: the provider's adapter in the clone at PATH, in MODE (--ready, --install, --login or
# --preflight unattended). AGENTIC_PROVIDER_DIR replaces the clone's adapters, as for the runner.
read -r -d '' FLEET_PROVIDER <<'SCRIPT' || true
export PATH="$PATH:$HOME/.local/bin"
cd -- "$1" || exit 1
adapter=${AGENTIC_PROVIDER_DIR:-./.agentic/providers}/$2/run.sh
shift 2
exec "$adapter" "$@"
SCRIPT

# A campaign's runner lives in the user's systemd when there is one, which stops with the user's last session unless the
# user lingers. Exit 3 with the command to run as root when lingering is off and the user cannot turn it on.
read -r -d '' FLEET_LINGER <<'SCRIPT' || true
command -v loginctl >/dev/null 2>&1 || exit 0
user=$(id -un)
[ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = no ] || exit 0
loginctl enable-linger "$user" >/dev/null 2>&1 && exit 0
printf 'loginctl enable-linger %s\n' "$user"
exit 3
SCRIPT

# PATH COMMAND...: the project's own setup, run in the clone at PATH.
read -r -d '' FLEET_SETUP <<'SCRIPT' || true
export PATH="$PATH:$HOME/.local/bin"
cd -- "$1" || exit 1
shift
exec "$@"
SCRIPT

# PATH [NAME=VALUE...] -- COMMAND ARGUMENT...: `campaign COMMAND ARGUMENT...` in the campaign worktree at PATH, with the
# settings NAME=VALUE.
read -r -d '' FLEET_CAMPAIGN <<'SCRIPT' || true
export PATH="$PATH:$HOME/.local/bin"
cd -- "$1" || exit 1
shift
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do export "$1"; shift; done
[ "$#" -eq 0 ] || shift
exec ./.agentic/bin/campaign "$@"
SCRIPT

# The AGENTIC_* settings that travel with a command to another machine (NAME=VALUE, NUL-separated): the ones of this
# environment, or of the JSON object FILE's .env when given, but those that name this machine's paths or identity.
travelling_settings() {
  local source=${1:-}
  if [[ -n $source ]]; then
    jq -j '.env // {} | to_entries[] | "\(.key)=\(.value)\u0000"' "$source" 2>/dev/null || true
  else
    local name
    while IFS= read -r name; do printf '%s=%s\0' "$name" "${!name}"; done < <(compgen -e | grep '^AGENTIC_')
  fi | while IFS= read -r -d '' assignment; do
    case ${assignment%%=*} in
      AGENTIC_CACHE | AGENTIC_FLEET | AGENTIC_MACHINE_ID | AGENTIC_SSH | AGENTIC_PROVIDER_DIR | AGENTIC_SUPERVISOR | \
        AGENTIC_SUPERVISED | AGENTIC_CAMPAIGN_ROOT | AGENTIC_QUEUE) ;;
      *) printf '%s\0' "$assignment" ;;
    esac
  done
}

# A private folder for the results of one command, removed when the command ends.
fleet_temp=$(mktemp -d)
trap 'rm -rf -- "$fleet_temp"' EXIT

fleet_check() {
  local error
  error=$(jq -r '
    if (.machines | type) != "object" then "machines must be a map of name to machine"
    elif (.projects | type) != "object" then "projects must be a map of name to project"
    else
      ([.machines | to_entries[]
        | if (.key | test("^[a-z0-9-]+$") | not) or .key == "local" then "machine name \(.key) must match [a-z0-9-]+ (local is reserved)"
          elif (.value | type) != "object" then "machine \(.key) must be an object"
          elif (.value.ssh | type) != "string" or (.value.ssh | test("^[^-\\s]\\S*$") | not) then
            "machine \(.key): ssh must be an ssh destination or alias"
          elif (.value.id | type) != "string" or .value.id == "" then "machine \(.key): id must be its machine id"
          else empty end]
       + [.machines | to_entries | group_by(.value.id?)[] | select(length > 1)
          | "machines \(map(.key) | join(" and ")) have the same id"]
       + [.projects | to_entries[]
          | if (.value | type) != "object" or (.value.paths | type) != "object" then "project \(.key): paths must be a map of machine to path"
            elif any(.value.paths[]; type != "string" or (startswith("/") | not)) then "project \(.key): every path must be absolute"
            elif .value.files != null and ((.value.files | type) != "array"
                 or any(.value.files[]; type != "string" or startswith("/") or (split("/") | index("..")) != null)) then
              "project \(.key): files must be a list of paths inside the clone"
            elif .value.setup != null and ((.value.setup | type) != "array" or (.value.setup | length) == 0
                 or any(.value.setup[]; type != "string" or length == 0)) then
              "project \(.key): setup must be a command (a list of non-empty strings)"
            else empty end])
      | first // empty
    end' <<<"$1") || die "invalid fleet in $2"
  [[ -z $error ]] || die "invalid fleet in $2: $error"
}

# fleet_load: FLEET (the file, or an empty fleet), FLEET_ID (this machine's id, possibly empty), FLEET_SELF (this
# machine's name in the fleet, or empty) and FLEET_PROJECT (this project's name, possibly empty).
fleet_load() {
  local file
  file=$(fleet_file)
  FLEET='{"machines":{},"projects":{}}'
  if [[ -f $file ]]; then
    FLEET=$(jq -c '{machines: {}, projects: {}} + .' "$file" 2>/dev/null) || die "invalid JSON in $file"
    fleet_check "$FLEET" "$file"
  fi
  FLEET_ID=$(bash -c "$FLEET_MACHINE_ID")
  FLEET_SELF=$(jq -r --arg id "$FLEET_ID" 'first(.machines | to_entries[] | select(.value.id == $id) | .key) // ""' <<<"$FLEET")
  FLEET_PROJECT=$PROJECT_NAME
}

fleet_valid_name() {
  [[ $1 =~ ^[a-z0-9-]+$ && $1 != local ]] || die "invalid machine name: $1 (it must match [a-z0-9-]+; local is reserved)"
}
fleet_valid_ssh() { [[ $1 =~ ^[^-[:space:]][^[:space:]]*$ ]] || die "invalid ssh destination: $1"; }

# This machine's name when it has none in the fleet: its host name, lower-case, up to the first dot.
fleet_hostname() {
  uname -n | cut -d. -f1 | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

fleet_ssh_of() { jq -r --arg name "$1" '.machines[$name].ssh // ""' <<<"$FLEET"; }

# Every other machine that holds this project: NAME, SSH and PATH, separated by tabs.
fleet_peers() {
  jq -r --arg project "$FLEET_PROJECT" --arg self "$FLEET_SELF" '
    .machines as $machines | (.projects[$project].paths // {}) | to_entries[]
    | select(.key != $self and $machines[.key] != null) | [.key, $machines[.key].ssh, .value] | @tsv' <<<"$FLEET"
}

# fleet_on NAME SCRIPT ARGUMENT...: runs SCRIPT on the machine NAME of the fleet (here when it is this one).
fleet_on() {
  local machine=$1 script=$2 destination
  shift 2
  if [[ $machine == "$FLEET_SELF" ]]; then
    bash -c "$script" fleet "$@"
    return
  fi
  destination=$(fleet_ssh_of "$machine")
  remote_script "$script" "$@"
}

# The end of an error output, on one line, without git's advice after a transport failure.
fleet_reason() {
  { grep -v -e '^fatal: Could not read from remote repository' -e '^Please make sure you have the correct access rights' \
      -e '^and the repository exists' "$1" || true; } | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | tail -c 300
}

# fleet_fetch NAME SSH PATH: the main branch and the campaign branches of NAME's clone, into refs/remotes/NAME/ (pruned).
fleet_fetch() {
  GIT_SSH_COMMAND=$ssh_line GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" fetch --quiet --no-tags --prune --no-write-fetch-head "$2:$3" \
    "+refs/heads/$MAIN_BRANCH:refs/remotes/$1/$MAIN_BRANCH" "+refs/heads/campaign/*:refs/remotes/$1/campaign/*"
}

# fleet_query OVERVIEW NAME SSH PATH: fetches from one machine and, with OVERVIEW true, reads its campaign overview.
# Leaves $fleet_temp/NAME.overview, or $fleet_temp/NAME.error when the machine could not answer.
fleet_query() {
  local want=$1 name=$2 destination=$3 path=$4 out="$fleet_temp/$2"
  fleet_fetch "$name" "$destination" "$path" 2>"$out.error" || return 0
  if [[ $want == true ]] && ! remote_script "$FLEET_OVERVIEW" "$path" >"$out.overview" 2>"$out.error"; then
    rm -f -- "$out.overview"
    return 0
  fi
  rm -f -- "$out.error"
}

# fleet_gather OVERVIEW: fleet_query on every other machine of the project at once.
fleet_gather() {
  local name ssh path
  while IFS=$'\t' read -r name ssh path; do
    fleet_query "$1" "$name" "$ssh" "$path" &
  done < <(fleet_peers)
  wait
}

# fleet_counts NAME: "THERE HERE", the commits that only NAME's main branch (as last fetched) has and that only this
# machine's has.
fleet_counts() {
  git -C "$REPO_ROOT" rev-list --left-right --count "refs/remotes/$1/$MAIN_BRANCH...refs/heads/$MAIN_BRANCH" 2>/dev/null \
    | tr '\t' ' '
}

# fleet_main_warning NAME THERE HERE: the warning a main branch behind NAME's, or diverged from it, deserves. Nothing is
# ever pulled for the user.
fleet_main_warning() {
  local name=$1 there=$2 here=$3
  if ((there > 0 && here == 0)); then
    printf "%s's %s is %d commit(s) ahead of this machine's: pull it by hand with git pull --ff-only %s %s\n" \
      "$name" "$MAIN_BRANCH" "$there" "$name" "$MAIN_BRANCH"
  elif ((there > 0)); then
    printf "%s diverged from %s's (%d commit(s) only there, %d only here): reconcile them by hand\n" \
      "$MAIN_BRANCH" "$name" "$there" "$here"
  fi
}

fleet_seen_file() { printf '%s/fleet-seen.json\n' "$(runtime_base)"; }

# fleet_survey OVERVIEW: this project's fleet as JSON: {project, main_branch, this_machine, machines, warnings}. Every
# machine has name, ssh, path, self and reachable; a reachable peer adds main_branch {only_there, only_here}, an
# unreachable one its error. With OVERVIEW true each machine also has the campaigns and queues of its overview: the last
# ones seen (seen_at) when it does not answer.
fleet_survey() {
  local want=$1 now seen_file seen='{}' self_entry machines name ssh path entry counts there here warning
  local warnings=()
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  seen_file=$(fleet_seen_file)
  [[ ! -f $seen_file ]] || seen=$(jq -c . "$seen_file" 2>/dev/null) || seen='{}'
  fleet_gather "$want"
  self_entry=$(jq -cn --arg name "${FLEET_SELF:-$(fleet_hostname)}" --arg ssh "$(fleet_ssh_of "$FLEET_SELF")" \
    --arg path "$(main_worktree)" '{name: $name, ssh: $ssh, path: $path, self: true, reachable: true}')
  if [[ $want == true ]]; then
    self_entry=$(jq -c --argjson overview "$(cmd_overview --json)" '. + $overview' <<<"$self_entry")
  fi
  machines="[$self_entry]"
  while IFS=$'\t' read -r name ssh path; do
    entry=$(jq -cn --arg name "$name" --arg ssh "$ssh" --arg path "$path" '{name: $name, ssh: $ssh, path: $path, self: false}')
    if [[ -f $fleet_temp/$name.error ]]; then
      entry=$(jq -c --arg error "$(fleet_reason "$fleet_temp/$name.error")" '. + {reachable: false, error: $error}' <<<"$entry")
      if [[ $want == true ]]; then
        entry=$(jq -c --arg name "$name" --argjson seen "$seen" \
          '. + {seen_at: $seen[$name].at, campaigns: ($seen[$name].overview.campaigns // []), queues: ($seen[$name].overview.queues // [])}' <<<"$entry")
      fi
    else
      IFS=' ' read -r there here <<<"$(fleet_counts "$name")"
      entry=$(jq -c --argjson there "${there:-0}" --argjson here "${here:-0}" \
        '. + {reachable: true, main_branch: {only_there: $there, only_here: $here}}' <<<"$entry")
      warning=$(fleet_main_warning "$name" "${there:-0}" "${here:-0}")
      [[ -z $warning ]] || warnings+=("$warning")
      if [[ $want == true ]]; then
        entry=$(jq -c --arg now "$now" --slurpfile overview "$fleet_temp/$name.overview" \
          '. + {seen_at: $now} + $overview[0]' <<<"$entry")
        seen=$(jq -c --arg name "$name" --arg now "$now" --slurpfile overview "$fleet_temp/$name.overview" \
          '.[$name] = {at: $now, overview: $overview[0]}' <<<"$seen")
      fi
    fi
    machines=$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$machines")
  done < <(fleet_peers)
  if [[ $want == true ]]; then
    mkdir -p -- "$(dirname -- "$seen_file")"
    printf '%s\n' "$seen" >"$seen_file.tmp" && mv -f -- "$seen_file.tmp" "$seen_file"
  fi
  jq -n --arg project "$FLEET_PROJECT" --arg main "$MAIN_BRANCH" --arg self "$FLEET_SELF" --argjson machines "$machines" \
    --args '{project: $project, main_branch: $main, this_machine: (if $self == "" then null else $self end),
             machines: $machines, warnings: $ARGS.positional}' "${warnings[@]}"
}

# The local time of a UTC time, as HH:MM (dd/mm), in the display zone.
fleet_local_time() { in_display_tz date -d "$1" '+%H:%M (%d/%m)' 2>/dev/null || printf '%s\n' "$1"; }

# campaign fleet [--json]: the machines of this project's fleet and how their main branches compare with this one.
fleet_list() {
  local json=false report
  [[ ${1:-} == --json ]] && json=true
  fleet_load
  report=$(fleet_survey false)
  if $json; then printf '%s\n' "$report"; return; fi
  if [[ $(jq '.machines | length' <<<"$report") == 1 && -z $FLEET_SELF ]]; then
    note "No fleet holds ${FLEET_PROJECT:-this project}: campaign fleet join NAME --ssh DESTINATION adds a machine."
    return
  fi
  note "Fleet of $FLEET_PROJECT ($([[ -n $FLEET_SELF ]] && printf 'this machine: %s' "$FLEET_SELF" || printf 'this machine is not in it'))"
  jq -r --arg main "$MAIN_BRANCH" '.machines[] | "  \(.name)  \(if .ssh == "" then "" else "\(.ssh):" end)\(.path)  — \(
    if .self then "this machine"
    elif .reachable | not then "unreachable: \(.error)"
    elif .main_branch.only_there == 0 and .main_branch.only_here == 0 then "same \($main)"
    elif .main_branch.only_there == 0 then "its \($main) is \(.main_branch.only_here) commit(s) behind"
    elif .main_branch.only_here == 0 then "its \($main) is \(.main_branch.only_there) commit(s) ahead"
    else "its \($main) diverged (\(.main_branch.only_there) there, \(.main_branch.only_here) here)" end)"' <<<"$report"
  jq -r '.warnings[] | "Warning: \(.)"' <<<"$report"
}

# campaign overview --fleet [--json]: every campaign and queue of this project on every machine of its fleet.
fleet_overview() {
  local json=$1 report count index machine heading
  fleet_load
  report=$(fleet_survey true)
  count=$(jq '.machines | length' <<<"$report")
  for ((index = 0; index < count; index++)); do
    machine=$(jq -r ".machines[$index].seen_at // empty" <<<"$report")
    [[ -z $machine ]] || report=$(jq -c --arg time "$(fleet_local_time "$machine")" ".machines[$index].seen_local_time = \$time" <<<"$report")
  done
  if [[ $json == true ]]; then printf '%s\n' "$report"; return; fi
  for ((index = 0; index < count; index++)); do
    machine=$(jq -c ".machines[$index]" <<<"$report")
    heading=$(jq -r '"== \(.name)\(if .self then " (this machine)" elif .reachable then "" else
      " — unreachable (\(.error))\(if .seen_local_time then "; last seen \(.seen_local_time)" else "; never seen" end)" end)"' <<<"$machine")
    note "$heading"
    if jq -e '.self or .reachable or .seen_at' >/dev/null <<<"$machine"; then print_overview "$machine"; fi
  done
  jq -r '.warnings[] | "Warning: \(.)"' <<<"$report"
}

# Before campaign init SLUG: the slug must be free on every machine of the fleet, and a main branch behind another
# machine's is reported (the campaign starts from this one's). A machine that does not answer is reported too.
fleet_init_check() {
  local slug=$1 name ssh path there here warning
  [[ -f $(fleet_file) ]] || return 0
  fleet_load
  [[ -n $(fleet_peers) ]] || return 0
  fleet_gather false
  while IFS=$'\t' read -r name ssh path; do
    if [[ -f $fleet_temp/$name.error ]]; then
      note "Warning: $name did not answer ($(fleet_reason "$fleet_temp/$name.error")); campaign $slug may already exist there"
      continue
    fi
    git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/$name/campaign/$slug" \
      && die "campaign $slug already exists on $name: pick another slug"
    IFS=' ' read -r there here <<<"$(fleet_counts "$name")"
    warning=$(fleet_main_warning "$name" "${there:-0}" "${here:-0}")
    [[ -z $warning ]] || note "Warning: $warning; the campaign starts from this machine's $MAIN_BRANCH"
  done < <(fleet_peers)
}

# A join in a terminal asks there (sudo's password, a provider's sign-in); elsewhere those become pending items.
fleet_interactive() { [[ -t 0 && -t 1 ]]; }

# fleet_tty SCRIPT ARGUMENT...: runs SCRIPT on $destination with a terminal, for what asks the person something.
fleet_tty() {
  local command
  printf -v command '%q ' bash -c "$1" fleet "${@:2}"
  "${ssh_command[@]}" "${ssh_options[@]}" -t "$destination" "$command"
}

# fleet_install_commands NAME COMMAND...: installs on NAME ($destination) the commands the kit needs that it lacks.
# Returns non-zero, with a pending item, when they could not be installed.
fleet_install_commands() {
  local machine=$1 rc=0 output
  shift
  note "Installing on $machine: $*"
  output=$(remote_script "$FLEET_PACKAGES" "$@" 2>"$fleet_temp/packages.error") || rc=$?
  if ((rc == 3)) && fleet_interactive; then
    note "$machine asks for the password of sudo:"
    rc=0
    "${ssh_command[@]}" "${ssh_options[@]}" -t "$destination" "$output" || rc=$?
  fi
  case $rc in
    0) return 0 ;;
    3) pending+=("install the commands $* on $machine, as root: $output") ;;
    4) pending+=("$machine has no supported package manager: install the commands $* there by hand") ;;
    *) pending+=("installing the commands $* on $machine failed: $(fleet_reason "$fleet_temp/packages.error")") ;;
  esac
  return 1
}

# fleet_project_setup NAME PATH: the project's files and setup (projects.<project>.files and .setup of the fleet file)
# for its clone at PATH on NAME ($destination). A failure is a pending item.
fleet_project_setup() {
  local machine=$1 path=$2 file rc=0
  local -a files setup
  mapfile -t files < <(jq -r --arg project "$FLEET_PROJECT" '.projects[$project].files // [] | .[]' <<<"$FLEET")
  for file in "${files[@]}"; do
    if [[ ! -e $main_tree/$file ]]; then
      pending+=("$file (files of $FLEET_PROJECT in the fleet file) does not exist in this clone, so $machine did not get it")
      continue
    fi
    rsync -a --relative -e "$ssh_line" "$main_tree/./$file" "$destination:$path/" 2>"$fleet_temp/files.error" \
      || pending+=("copying $file to $machine failed: $(fleet_reason "$fleet_temp/files.error")")
  done
  mapfile -t setup < <(jq -r --arg project "$FLEET_PROJECT" '.projects[$project].setup // [] | .[]' <<<"$FLEET")
  ((${#setup[@]} > 0)) || return 0
  note "Running the setup of $FLEET_PROJECT on $machine: ${setup[*]}"
  if fleet_interactive; then
    fleet_tty "$FLEET_SETUP" "$path" "${setup[@]}" || rc=$?
  else
    remote_script "$FLEET_SETUP" "$path" "${setup[@]}" || rc=$?
  fi
  ((rc == 0)) || pending+=("the setup of $FLEET_PROJECT failed on $machine (exit $rc): ${setup[*]}, in $path")
}

# fleet_linger NAME: the user of NAME ($destination) lingers, so a runner outlives the session that started it.
fleet_linger() {
  local machine=$1 rc=0 output
  output=$(remote_script "$FLEET_LINGER" 2>"$fleet_temp/linger.error") || rc=$?
  if ((rc == 3)) && fleet_interactive; then
    note "$machine asks for the password of sudo, so that campaigns outlive the session:"
    rc=0
    "${ssh_command[@]}" "${ssh_options[@]}" -t "$destination" "sudo $output" || rc=$?
  fi
  case $rc in
    0) ;;
    3) pending+=("campaigns on $machine would stop with the session that started them: run there, as root, $output") ;;
    *) pending+=("checking the lingering of $machine's user failed: $(fleet_reason "$fleet_temp/linger.error")") ;;
  esac
}

# The providers this project runs campaigns with: the ones whose run-campaign skill it has.
fleet_project_providers() {
  local provider
  for provider in claude codex grok; do
    [[ ! -d $main_tree/.$provider/skills/run-campaign ]] || printf '%s\n' "$provider"
  done
}

# fleet_ready_providers NAME PATH: each provider of the project ready on NAME ($destination): installed for its user
# when missing, signed in (in a terminal) when not, and its preflight passing. What is left is a pending item.
fleet_ready_providers() {
  local machine=$1 path=$2 provider rc
  while IFS= read -r provider; do
    rc=0
    remote_script "$FLEET_PROVIDER" "$path" "$provider" --ready >/dev/null 2>"$fleet_temp/ready.error" || rc=$?
    if ((rc == 69)); then
      note "Installing $provider on $machine..."
      if remote_script "$FLEET_PROVIDER" "$path" "$provider" --install >"$fleet_temp/install.log" 2>&1; then
        rc=0
        remote_script "$FLEET_PROVIDER" "$path" "$provider" --ready >/dev/null 2>"$fleet_temp/ready.error" || rc=$?
      else
        cp -- "$fleet_temp/install.log" "$fleet_temp/ready.error"
      fi
    fi
    if ((rc == 77)) && fleet_interactive; then
      note "Sign in to $provider on $machine:"
      fleet_tty "$FLEET_PROVIDER" "$path" "$provider" --login || true
      rc=0
      remote_script "$FLEET_PROVIDER" "$path" "$provider" --ready >/dev/null 2>"$fleet_temp/ready.error" || rc=$?
    fi
    case $rc in
      0) ;;
      77) pending+=("sign in to $provider on $machine: ssh -t $destination 'cd $path && .agentic/providers/$provider/run.sh --login'")
          continue ;;
      69) pending+=("$provider is missing on $machine and could not be installed: $(fleet_reason "$fleet_temp/ready.error")")
          continue ;;
      *) pending+=("$provider on $machine: $(fleet_reason "$fleet_temp/ready.error")"); continue ;;
    esac
    if remote_script "$FLEET_PROVIDER" "$path" "$provider" --preflight unattended >/dev/null 2>"$fleet_temp/preflight.error"; then
      note "$provider is ready on $machine."
    else
      pending+=("the preflight of $provider fails on $machine: $(fleet_reason "$fleet_temp/preflight.error")")
    fi
  done < <(fleet_project_providers)
}

# campaign fleet join NAME --ssh DESTINATION [--path PATH] [--as NAME] [--as-ssh DESTINATION]
fleet_join() {
  local name='' dest='' path='' as='' as_ssh='' arg main_tree self relative='' probe dest_fleet merged dest_id
  local dest_path client other root found machine pretty url destination key
  local -a lines pending=() names args
  while (($#)); do
    arg=$1; shift
    case $arg in
      --ssh) (($#)) || die '--ssh requires a destination'; dest=$1; shift ;;
      --path) (($#)) || die '--path requires a folder'; path=$1; shift ;;
      --as) (($#)) || die '--as requires a name'; as=$1; shift ;;
      --as-ssh) (($#)) || die '--as-ssh requires a destination'; as_ssh=$1; shift ;;
      -*) die "unknown fleet join option: $arg" ;;
      *) [[ -z $name ]] || die 'fleet join takes one machine name'; name=$arg ;;
    esac
  done
  [[ -n $name && -n $dest ]] || die 'usage: campaign fleet join NAME --ssh DESTINATION [--path PATH] [--as NAME] [--as-ssh DESTINATION]'
  fleet_valid_name "$name"; fleet_valid_ssh "$dest"
  [[ -z $as ]] || fleet_valid_name "$as"
  [[ -z $as_ssh ]] || fleet_valid_ssh "$as_ssh"
  [[ -z $path || $path == /* ]] || die '--path must be an absolute path'
  fleet_load
  [[ -n $FLEET_PROJECT ]] || die "the fleet knows a project by its name: set \"name\" in .agentic/project.json and commit it on $MAIN_BRANCH"
  [[ -n $FLEET_ID ]] || die 'this machine has no machine id (/etc/machine-id): set AGENTIC_MACHINE_ID'
  main_tree=$(main_worktree)
  [[ -n $main_tree ]] || die "fleet join needs a $MAIN_BRANCH worktree of this project"
  if [[ -n $FLEET_SELF ]]; then
    [[ -z $as || $as == "$FLEET_SELF" ]] || die "this machine is already in the fleet as $FLEET_SELF"
    self=$FLEET_SELF
  else
    self=${as:-$(fleet_hostname)}
    [[ -n $self ]] || die 'cannot name this machine after its host name: pass --as NAME'
    fleet_valid_name "$self"
  fi
  [[ $name != "$self" ]] || die "$name is this machine"
  # The clone goes at the same place under the other home, unless it is outside this home or --path says otherwise.
  if [[ -z $path ]]; then
    case $main_tree in "$HOME"/*) relative=${main_tree#"$HOME"/} ;; *) path=$main_tree ;; esac
  fi

  note "Reaching $name ($dest)..."
  destination=$dest
  probe=$(remote_script "$FLEET_PROBE" "$path" "$relative" 2>"$fleet_temp/probe.error") \
    || die "cannot reach $name at $dest: $(fleet_reason "$fleet_temp/probe.error")"
  mapfile -t lines < <(head -n 7 <<<"$probe")
  dest_fleet=$(tail -n +8 <<<"$probe" | jq -c '{machines: {}, projects: {}} + .' 2>/dev/null) \
    || die "the fleet file on $name is not valid JSON"
  fleet_check "$dest_fleet" "the fleet file on $name"
  dest_id=${lines[0]:-} client=${lines[2]:-} dest_path=${lines[4]:-}
  [[ -n $dest_id ]] || die "$name has no machine id (/etc/machine-id)"
  [[ $dest_id != "$FLEET_ID" ]] || die "$dest is this machine"
  [[ $dest_path == /* ]] || die "$name returned no clone path"
  # The commands the kit needs there; without git there is no clone.
  if [[ -n ${lines[3]:-} ]] && ! fleet_install_commands "$name" ${lines[3]}; then
    [[ " ${lines[3]} " != *' git '* ]] || die "$name lacks git and it could not be installed: ${pending[-1]}"
  fi

  # One fleet out of both files (this machine's entries win), then the two machines in it.
  merged=$(jq -cn --argjson here "$FLEET" --argjson there "$dest_fleet" '$there * $here')
  other=$(jq -r --arg id "$dest_id" --arg name "$name" 'first(.machines | to_entries[] | select(.value.id == $id and .key != $name) | .key) // ""' <<<"$merged")
  [[ -z $other ]] || die "$dest is already in the fleet as $other"
  other=$(jq -r --arg id "$dest_id" --arg name "$name" '.machines[$name].id // $id | select(. != $id)' <<<"$merged")
  [[ -z $other ]] || die "the name $name belongs to another machine of the fleet"
  other=$(jq -r --arg id "$FLEET_ID" --arg self "$self" 'first(.machines | to_entries[] | select(.value.id == $id and .key != $self) | .key) // ""' <<<"$merged")
  [[ -z $other ]] || die "this machine is already in the fleet of $name as $other: pass --as $other"
  other=$(jq -r --arg id "$FLEET_ID" --arg self "$self" '.machines[$self].id // $id | select(. != $id)' <<<"$merged")
  [[ -z $other ]] || die "the name $self belongs to another machine of the fleet: pass --as NAME"
  if [[ -z $as_ssh ]]; then
    as_ssh=$(jq -r --arg self "$self" '.machines[$self].ssh // ""' <<<"$merged")
  fi
  if [[ -z $as_ssh ]]; then
    [[ -n $client && $client != 127.* && $client != *:* ]] \
      || die "$name sees this machine at ${client:-no address}, which other machines cannot use: pass --as-ssh DESTINATION"
    as_ssh="$(id -un)@$client"
  fi
  merged=$(jq -c --arg self "$self" --arg self_ssh "$as_ssh" --arg self_id "$FLEET_ID" --arg self_path "$main_tree" \
    --arg name "$name" --arg dest "$dest" --arg dest_id "$dest_id" --arg dest_path "$dest_path" --arg project "$FLEET_PROJECT" '
    .machines[$self] = ((.machines[$self] // {}) + {ssh: $self_ssh, id: $self_id})
    | .machines[$name] = ((.machines[$name] // {}) + {ssh: $dest, id: $dest_id})
    | .projects[$project].paths[$self] = $self_path | .projects[$project].paths[$name] = $dest_path' <<<"$merged")
  fleet_check "$merged" 'the joined fleet'

  # The code: a new clone gets this machine's main branch; an existing one is left as it is (pulled by hand).
  case ${lines[5]:-} in
    absent | empty)
      note "Cloning $FLEET_PROJECT into $name:$dest_path..."
      remote_script "$FLEET_CLONE_INIT" "$dest_path" 2>"$fleet_temp/clone.error" \
        || die "could not create $dest_path on $name: $(fleet_reason "$fleet_temp/clone.error")"
      GIT_SSH_COMMAND=$ssh_line GIT_TERMINAL_PROMPT=0 git -C "$main_tree" push --quiet --no-verify "$dest:$dest_path" \
        "refs/heads/$MAIN_BRANCH:refs/heads/$MAIN_BRANCH" 2>"$fleet_temp/clone.error" \
        || die "could not push $MAIN_BRANCH to $name: $(fleet_reason "$fleet_temp/clone.error")"
      remote_script "$FLEET_CLONE_CHECKOUT" "$dest_path" "$MAIN_BRANCH" "$(git -C "$main_tree" config user.name || true)" \
        "$(git -C "$main_tree" config user.email || true)" 2>"$fleet_temp/clone.error" \
        || die "could not check $MAIN_BRANCH out on $name: $(fleet_reason "$fleet_temp/clone.error")"
      ;;
    repo)
      found=false
      while IFS= read -r root; do
        [[ " ${lines[6]:-} " == *" $root "* ]] && found=true
      done < <(git -C "$main_tree" rev-list --max-parents=0 "$MAIN_BRANCH")
      $found || die "$dest_path on $name holds another repository: pass --path"
      note "$name already has a clone at $dest_path; its $MAIN_BRANCH is left as it is"
      ;;
    *) die "$dest_path on $name exists and is not a clone of this project: pass --path" ;;
  esac
  FLEET=$merged FLEET_SELF=$self
  fleet_project_setup "$name" "$dest_path"

  # Every machine gets the same fleet file.
  pretty=$(jq . <<<"$FLEET")
  mapfile -t names < <(jq -r '.machines | keys[]' <<<"$FLEET")
  for machine in "${names[@]}"; do
    fleet_on "$machine" "$FLEET_WRITE" "$pretty" 2>"$fleet_temp/write.error" \
      || pending+=("$machine did not receive the fleet file: $(fleet_reason "$fleet_temp/write.error")")
  done

  # Every clone of the project has the others as remotes named after their machines.
  mapfile -t names < <(jq -r --arg project "$FLEET_PROJECT" '.projects[$project].paths | keys[]' <<<"$FLEET")
  for machine in "${names[@]}"; do
    args=("$(jq -r --arg project "$FLEET_PROJECT" --arg m "$machine" '.projects[$project].paths[$m]' <<<"$FLEET")")
    for other in "${names[@]}"; do
      [[ $other != "$machine" ]] || continue
      url="$(fleet_ssh_of "$other"):$(jq -r --arg project "$FLEET_PROJECT" --arg m "$other" '.projects[$project].paths[$m]' <<<"$FLEET")"
      args+=("$other" "$url")
    done
    fleet_on "$machine" "$FLEET_REMOTES" "${args[@]}" 2>"$fleet_temp/remotes.error" \
      || pending+=("the remotes of $machine's clone: $(fleet_reason "$fleet_temp/remotes.error")")
  done

  # The new machine and every other one reach each other's clone (this machine reached it already). When NAME cannot, its
  # key (made when it has none) is in the pending item, to authorize on the other machine.
  for machine in "${names[@]}"; do
    [[ $machine != "$name" ]] || continue
    if ! fleet_on "$name" "$FLEET_REACH" "$dest_path" "$machine" 2>"$fleet_temp/reach.error"; then
      key=$(fleet_on "$name" "$FLEET_KEY" 2>/dev/null) || key='(no key)'
      pending+=("$name cannot reach $machine's clone at $(fleet_ssh_of "$machine") ($(fleet_reason "$fleet_temp/reach.error")); authorize this key of $name there: $key")
    fi
    [[ $machine != "$self" ]] || continue
    fleet_on "$machine" "$FLEET_REACH" \
      "$(jq -r --arg project "$FLEET_PROJECT" --arg m "$machine" '.projects[$project].paths[$m]' <<<"$FLEET")" "$name" \
      2>"$fleet_temp/reach.error" \
      || pending+=("$machine cannot reach $name's clone at $dest (authorize $machine's ssh key there): $(fleet_reason "$fleet_temp/reach.error")")
  done

  # Campaigns keep running there after the session that started them ends.
  destination=$dest
  fleet_linger "$name"
  # The providers of the project, and the kit itself, work there.
  fleet_ready_providers "$name" "$dest_path"
  remote_script "$FLEET_OVERVIEW" "$dest_path" >/dev/null 2>"$fleet_temp/overview.error" \
    || pending+=("the campaign commands fail on $name: $(fleet_reason "$fleet_temp/overview.error")")

  if ((${#pending[@]} == 0)); then
    note "$name joined the fleet of $FLEET_PROJECT ($dest:$dest_path): every command works there."
    return 0
  fi
  note "$name joined the fleet of $FLEET_PROJECT ($dest:$dest_path), with pending items:"
  printf '  - %s\n' "${pending[@]}"
  exit 3
}

# campaign fleet leave NAME: NAME forgets the fleet (its fleet file and the fleet's remotes of its clones) and the other
# machines forget NAME. A machine that does not answer keeps its copy, and is reported.
fleet_leave() {
  local name=${1:-} old pretty machine project path
  local -a names pending=()
  (($# == 1)) || die 'usage: campaign fleet leave NAME'
  fleet_load
  jq -e --arg name "$name" '.machines[$name] != null' <<<"$FLEET" >/dev/null || die "no machine $name in the fleet"
  old=$FLEET
  mapfile -t names < <(jq -r '.machines | keys[]' <<<"$old")
  while IFS=$'\t' read -r project path; do
    fleet_on "$name" "$FLEET_REMOTES" "$path" -- "${names[@]}" 2>"$fleet_temp/leave.error" \
      || pending+=("the remotes of $name's clone of $project: $(fleet_reason "$fleet_temp/leave.error")")
  done < <(jq -r --arg name "$name" '.projects | to_entries[] | select(.value.paths[$name]) | [.key, .value.paths[$name]] | @tsv' <<<"$old")
  fleet_on "$name" "$FLEET_WRITE" '' 2>"$fleet_temp/leave.error" \
    || pending+=("$name kept its fleet file: $(fleet_reason "$fleet_temp/leave.error")")

  FLEET=$(jq -c --arg name "$name" 'del(.machines[$name]) | .projects |= map_values(.paths |= del(.[$name]))' <<<"$old")
  [[ $name != "$FLEET_SELF" ]] || FLEET_SELF=''
  pretty=$(jq . <<<"$FLEET")
  mapfile -t names < <(jq -r '.machines | keys[]' <<<"$FLEET")
  for machine in "${names[@]}"; do
    fleet_on "$machine" "$FLEET_WRITE" "$pretty" 2>"$fleet_temp/leave.error" \
      || pending+=("$machine did not receive the fleet file: $(fleet_reason "$fleet_temp/leave.error")")
  done
  while IFS=$'\t' read -r machine path; do
    fleet_on "$machine" "$FLEET_REMOTES" "$path" -- "$name" 2>"$fleet_temp/leave.error" \
      || pending+=("the remote $name of $machine's clone: $(fleet_reason "$fleet_temp/leave.error")")
  done < <(jq -r '.projects[].paths | to_entries[] | [.key, .value] | @tsv' <<<"$FLEET")

  if ((${#pending[@]} == 0)); then
    note "$name left the fleet."
    return 0
  fi
  note "$name left the fleet, with pending items:"
  printf '  - %s\n' "${pending[@]}"
  exit 3
}

# route_campaign SLUG MACHINE COMMAND ARGUMENT...: `campaign COMMAND ARGUMENT...` in the worktree of campaign SLUG, on
# this machine when it holds it, else on the machine of the fleet that does (MACHINE when given). Does not return.
route_campaign() {
  local slug=$1 machine=$2 command=$3 file tree name destination report found count unreachable rc=0
  local -a settings
  shift 3
  validate_slug "$slug"
  fleet_load
  if [[ -z $machine || $machine == "$FLEET_SELF" ]]; then
    file="$(runtime_dir "$slug")/campaign.json"
    if [[ -f $file ]] && git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$slug"; then
      tree=$(jq -r '.worktree' "$file")
      [[ -d $tree ]] || die "campaign $slug has no worktree here: $tree"
      cd -- "$tree" && exec ./.agentic/bin/campaign "$command" "$@"
    fi
    [[ -z $machine ]] || die "campaign $slug is not on this machine"
  elif ! jq -e --arg machine "$machine" '.machines[$machine] != null' <<<"$FLEET" >/dev/null; then
    die "no machine $machine in the fleet"
  fi
  report=$(fleet_survey true)
  found=$(jq -c --arg slug "$slug" --arg machine "$machine" '[.machines[] | select((.self | not) and .reachable)
    | select($machine == "" or .name == $machine) | . as $m | .campaigns[] | select(.slug == $slug)
    | {name: $m.name, ssh: $m.ssh, worktree}]' <<<"$report")
  count=$(jq 'length' <<<"$found")
  if ((count == 0)); then
    unreachable=$(jq -r '[.machines[] | select(.reachable == false) | .name] | join(", ")' <<<"$report")
    die "no machine of the fleet holds campaign $slug${unreachable:+ (no answer from $unreachable)}"
  fi
  ((count == 1)) || die "campaign $slug is on several machines ($(jq -r 'map(.name) | join(", ")' <<<"$found")): pass --on MACHINE"
  name=$(jq -r '.[0].name' <<<"$found"); destination=$(jq -r '.[0].ssh' <<<"$found"); tree=$(jq -r '.[0].worktree' <<<"$found")
  printf 'campaign %s on %s (%s)\n' "$command" "$name" "$slug" >&2
  mapfile -d '' -t settings < <(travelling_settings)
  remote_script "$FLEET_CAMPAIGN" "$tree" "${settings[@]}" -- "$command" "$@" || rc=$?
  exit "$rc"
}

# finalize_here SLUG MACHINE ARGUMENT...: finalizes campaign SLUG into this machine's main branch: in its worktree when
# it is here, else after moving it here from the machine that holds it (MACHINE when given). Does not return.
finalize_here() {
  local slug=$1 machine=$2 file tree report found destination
  shift 2
  validate_slug "$slug"
  fleet_load
  file="$(runtime_dir "$slug")/campaign.json"
  if [[ ! -f $file ]] || ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/campaign/$slug"; then
    [[ -n $FLEET_SELF ]] || die "campaign $slug is not here, and this machine is not in a fleet"
    report=$(fleet_survey true)
    found=$(jq -c --arg slug "$slug" --arg machine "$machine" '[.machines[] | select((.self | not) and .reachable)
      | select($machine == "" or .name == $machine) | . as $m | .campaigns[] | select(.slug == $slug)
      | {name: $m.name, ssh: $m.ssh, worktree}]' <<<"$report")
    (($(jq 'length' <<<"$found") == 1)) || die "campaign $slug is on no machine of the fleet, or on several (pass --on MACHINE)"
    destination=$(jq -r '.[0].ssh' <<<"$found")
    note "Bringing $slug here from $(jq -r '.[0].name' <<<"$found") to finalize it into this machine's $MAIN_BRANCH..."
    remote_script "$FLEET_CAMPAIGN" "$(jq -r '.[0].worktree' <<<"$found")" -- move --to "$FLEET_SELF" --no-start \
      || die "could not bring $slug here"
  fi
  tree=$(jq -r '.worktree' "$file")
  cd -- "$tree" && exec ./.agentic/bin/campaign finalize "$@"
}

cmd_fleet() {
  local action=${1:-}
  (($#)) && shift
  case $action in
    '' | --json) fleet_list ${action:+"$action"} ;;
    join) fleet_join "$@" ;;
    leave) fleet_leave "$@" ;;
    *) die "unknown fleet action: $action (join, leave, or none to list the fleet)" ;;
  esac
}

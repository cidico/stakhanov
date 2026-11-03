#!/usr/bin/env bash
# What a machine offers a task, for the scheduler and for people (`campaign machine [--fleet] [--json]`): its free
# machine slots (lib/slots.sh), its load, its Claude accounts, what it has been shown to have (the `capabilities` of
# project.json, each one a proof run here) and whether it takes tasks. Sourced by bin/campaign after lib/common.sh,
# lib/slots.sh and lib/overview.sh; it defines functions and variables and runs nothing. --fleet also needs the fleet
# (fleet_lib) for fleet_survey, whose peers run `campaign machine --json` themselves.

# The deadline of every proof and every call to the account hook: AGENTIC_MACHINE_PROBE_SECONDS (default 10).
machine_probe_seconds() {
  local seconds=${AGENTIC_MACHINE_PROBE_SECONDS:-10}
  [[ $seconds =~ ^[1-9][0-9]*$ ]] || die "AGENTIC_MACHINE_PROBE_SECONDS must be a positive whole number of seconds: $seconds"
  printf '%s\n' "$seconds"
}

# machine_slots: {capacity, used, free, holders} of this machine's slots. capacity and free are null without a limit.
machine_slots() {
  local capacity holders
  capacity=$(slot_capacity) || return $?
  holders=$(slot_holders)
  jq -cn --argjson capacity "${capacity:-null}" --argjson holders "$holders" \
    '{capacity: $capacity, used: ($holders | length),
      free: (if $capacity == null then null else ([$capacity - ($holders | length), 0] | max) end), holders: $holders}'
}

# machine_load: {load1, cpus, mem_available_mb}.
machine_load() {
  local load1 cpus key value mem=null
  IFS=' ' read -r load1 _ </proc/loadavg
  cpus=$(nproc)
  while IFS=' ' read -r key value _; do
    [[ $key == MemAvailable: ]] || continue
    mem=$((value / 1024))
    break
  done </proc/meminfo
  jq -cn --argjson load1 "$load1" --argjson cpus "$cpus" --argjson mem "$mem" '{load1: $load1, cpus: $cpus, mem_available_mb: $mem}'
}

# machine_accounts: null without an account hook (AGENTIC_CLAUDE_ACCOUNTS); else what `<hook> account list --json`
# prints when it exits 0 with a JSON list, else {enabled, current} from `account enabled` and `account current`.
machine_accounts() {
  local hook=${AGENTIC_CLAUDE_ACCOUNTS:-} seconds listing current='' enabled=false
  if [[ -z $hook ]]; then
    printf 'null\n'
    return
  fi
  seconds=$(machine_probe_seconds) || return $?
  if command -v "$hook" >/dev/null 2>&1; then
    if listing=$(timeout -k 2 "$seconds" "$hook" account list --json 2>/dev/null </dev/null) \
      && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$listing"; then
      jq -c . <<<"$listing"
      return
    fi
    ! timeout -k 2 "$seconds" "$hook" account enabled >/dev/null 2>&1 </dev/null || enabled=true
    current=$(timeout -k 2 "$seconds" "$hook" account current 2>/dev/null </dev/null | head -n 1) || current=''
  fi
  jq -cn --argjson enabled "$enabled" --arg current "$current" '{enabled: $enabled, current: (if $current == "" then null else $current end)}'
}

# machine_prove ARGV...: runs one proof here, in the main worktree, under the deadline and with no shell. Prints
# {proven, reason}: proven is exit 0; reason is null then, else the first line of the error (or why there was none).
machine_prove() {
  local seconds error rc=0 reason
  seconds=$(machine_probe_seconds) || return $?
  error=$(mktemp)
  (cd -- "$(main_worktree)" 2>/dev/null || true; exec timeout -k 2 "$seconds" "$@" >/dev/null 2>"$error" </dev/null) || rc=$?
  if ((rc == 0)); then
    reason=''
  elif ((rc == 124 || rc == 137)); then
    reason="timed out after ${seconds}s"
  else
    reason=$(grep -m 1 -v '^[[:space:]]*$' "$error" 2>/dev/null | cut -c 1-300 || true)
    [[ -n $reason ]] || reason="exit $rc"
  fi
  rm -f -- "$error"
  jq -cn --argjson proven "$([[ $rc == 0 ]] && printf true || printf false)" --arg reason "$reason" \
    '{proven: $proven, reason: (if $reason == "" then null else $reason end)}'
}

# machine_capabilities: [{name, proven, reason}] for each capability of project.json, in the order of the file.
machine_capabilities() {
  local name result list='[]'
  local -a argv
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    mapfile -d '' -t argv < <(jq -j --arg name "$name" '.[$name][] | ., "\u0000"' <<<"$PROJECT_CAPABILITIES")
    result=$(machine_prove "${argv[@]}")
    list=$(jq -c --arg name "$name" --argjson result "$result" '. + [{name: $name} + $result]' <<<"$list")
  done < <(jq -r 'keys_unsorted[]' <<<"$PROJECT_CAPABILITIES")
  printf '%s\n' "$list"
}

# machine_accepts: machines.<this machine>.accepts of the fleet file; true when it says nothing.
machine_accepts() {
  local self file
  self=$(fleet_self_name)
  file=${AGENTIC_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/agentic/fleet.json}
  if [[ -z $self ]]; then
    printf 'true\n'
    return
  fi
  jq -r --arg self "$self" '.machines[$self].accepts as $accepts
    | if $accepts == null then true elif ($accepts | type) == "boolean" then $accepts else error("not a boolean") end' "$file" 2>/dev/null \
    || die "machines.$self.accepts in $file must be true or false"
}

# machine_read: this machine's whole report as one JSON object. The user's ~/.local/bin is on the PATH of the proofs and
# of the hook, as for every command the fleet runs on a machine.
machine_read() {
  local name at slots load accounts capabilities accepts
  export PATH="$PATH:$HOME/.local/bin"
  # One at a time, and each one's failure (a bad slot count, a bad fleet file) ends the reading: a command substitution
  # does not stop its shell, so nothing may reach jq empty.
  name=$(machine_name) || return $?
  slots=$(machine_slots) || return $?
  load=$(machine_load) || return $?
  accepts=$(machine_accepts) || return $?
  accounts=$(machine_accounts) || return $?
  capabilities=$(machine_capabilities) || return $?
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg name "$name" --arg at "$at" --argjson slots "$slots" --argjson load "$load" --argjson accounts "$accounts" \
    --argjson capabilities "$capabilities" --argjson accepts "$accepts" \
    '{name: $name, at: $at, slots: $slots} + $load + {accounts: $accounts, capabilities: $capabilities, accepts: $accepts}'
}

# machine_print REPORT: the lines of one machine's report (the heading is the caller's).
machine_print() {
  in_display_tz jq -r '
    def yes: if . then "yes" else "no" end;
    (if .slots.capacity == null then "no limit, \(.slots.used) in use" else "\(.slots.free) free of \(.slots.capacity)" end) as $slots
    | "  slots: \($slots)",
      (.slots.holders[] | "    slot \(.slot): \(.kind // "?") \(.label // "") since \(.since // "?")"),
      "  load: \(.load1) on \(.cpus) cpu(s), \(.mem_available_mb) MB of memory available",
      "  accounts: \(if .accounts == null then "no account hook"
        elif (.accounts | type) == "array" then (if length == 0 then "none listed"
          else "\(.accounts | length) listed (\(.accounts | map(.key // .name // "?") | join(", ")))" end)
        else "hook \(if .accounts.enabled then "on" else "off" end), current \(.accounts.current // "none")" end)",
      "  capabilities: \(if (.capabilities | length) == 0 then "none asked for"
        else (.capabilities | map(if .proven then "\(.name) ok" else "\(.name) NOT PROVEN (\(.reason))" end) | join("; ")) end)",
      "  takes tasks: \(.accepts | yes)"' <<<"$1"
}

# machine_heading REPORT: "<name> (read HH:MM (dd/mm))" in the display zone.
machine_heading() {
  in_display_tz jq -r '"\(.name) (read \(.at | sub("\\.[0-9]+"; "") | fromdateiso8601 | localtime | strftime("%H:%M (%d/%m)")))"' <<<"$1"
}

# campaign machine --fleet [--json]: the report of every machine of the project's fleet, over ssh (fleet_survey, under
# fleet.lock and with the cache of the survey). A machine that does not answer has reachable false and its last report
# (seen_at, seen_local_time); one never seen has only its address.
machine_fleet() {
  local json=$1 report count index machine heading time
  fleet_load
  report=$(fleet_survey machine)
  count=$(jq '.machines | length' <<<"$report")
  for ((index = 0; index < count; index++)); do
    time=$(jq -r ".machines[$index].seen_at // empty" <<<"$report")
    [[ -z $time ]] || report=$(jq -c --arg time "$(fleet_local_time "$time")" ".machines[$index].seen_local_time = \$time" <<<"$report")
  done
  if [[ $json == true ]]; then printf '%s\n' "$report"; return; fi
  for ((index = 0; index < count; index++)); do
    machine=$(jq -c ".machines[$index]" <<<"$report")
    if jq -e '.reachable' >/dev/null <<<"$machine"; then
      heading="== $(machine_heading "$machine")$(jq -r 'if .self then " — this machine" else "" end' <<<"$machine")"
    else
      heading=$(jq -r '"== \(.name) — unreachable (\(.error))\(if .seen_local_time then "; last seen \(.seen_local_time)" else "; never seen" end)"' <<<"$machine")
    fi
    note "$heading"
    if jq -e '.slots' >/dev/null 2>&1 <<<"$machine"; then machine_print "$machine"; fi
  done
  jq -r '.warnings[] | "Warning: \(.)"' <<<"$report"
}

# campaign machine [--fleet] [--json]
cmd_machine() {
  local json=false fleet=false arg report
  for arg in "$@"; do
    case $arg in
      --json) json=true ;;
      --fleet) fleet=true ;;
      *) die "unknown machine option: $arg" ;;
    esac
  done
  if $fleet; then
    fleet_lib
    machine_fleet "$json"
    return
  fi
  report=$(machine_read)
  if $json; then printf '%s\n' "$report"; return; fi
  note "Machine $(machine_heading "$report")"
  machine_print "$report"
}

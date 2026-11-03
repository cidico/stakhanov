#!/usr/bin/env bash
# The overview of every campaign and queue in the cache and of the machine's worker rounds, for humans and for the campaign-status skill. Sourced by
# bin/campaign; it defines functions and variables and runs nothing.

# Human-facing times use AGENTIC_DISPLAY_TZ (which project.json "timezone" fills in), else the system zone; events stay
# stored in UTC.
in_display_tz() { if [[ -n ${AGENTIC_DISPLAY_TZ:-} ]]; then TZ=$AGENTIC_DISPLAY_TZ "$@"; else "$@"; fi; }

# Reads NDJSON events and adds local_time ("HH:MM (dd/mm)" in the display timezone) next to the UTC time.
with_local_time() {
  in_display_tz jq -sc 'map(. + (if (.time | type) == "string" then
      {local_time: (.time | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | localtime
        | strftime("%H:%M (%d/%m)"))} else {} end))'
}

# Per-ticket progress for the overview: goal for every ticket; start, elapsed time, current phase
# (from the latest event) and the todo tickets it unblocks for in-progress tickets; reason for blocked ones.
ticket_progress() {
  (cat "$2" 2>/dev/null || true) | with_local_time | jq -c --argjson tickets "$1" '
    def seconds: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    def role: (.message // "" | capture("role=(?<r>[a-z]+)") | .r) // "";
    . as $events | $tickets | . as $all | map(. as $ticket
      | [$events[] | select(.ticket == $ticket.id)] as $mine
      | ([range($mine | length) | select($mine[.].type == "ticket-started")]) as $starts
      | {id, status, risk, depends_on, goal}
      + (if $ticket.status == "in-progress" and ($starts | length) > 0 then
          # Back from a wait for quota, the invocation runs again: the same phase as when it started. A slot taken goes
          # on from the start of the round.
          ($mine[-1] | if .type == "provider-quota-back" then .type = "provider-started"
                       elif .type == "slot-taken" then .type = "ticket-started" else . end) as $last
          | ($last | role) as $role
          | ($mine[$starts[-1]:] | any(.type == "provider-completed" and role == "reviewer")) as $reviewed
          | {executor: ($ticket.executor // "local"),
             started_local_time: $mine[$starts[0]].local_time,
             elapsed_seconds: ((now - ($mine[$starts[0]].time | seconds)) | floor),
             phase: (if ($last.type == "ticket-started") or ($last.type == "provider-started" and $role == "worker")
                       then (if $reviewed then "repairing" else "implementing" end)
                     elif $last.type == "provider-completed" and $role == "worker" then "validating"
                     elif $last.type == "provider-started" and $role == "reviewer" then "reviewing"
                     elif $last.type == "provider-completed" and $role == "reviewer" then "review-done"
                     elif $last.type == "provider-started" and $role == "diagnostician" then "diagnosing"
                     elif $last.type == "recovery-scheduled" or ($last.type == "provider-completed" and $role == "diagnostician")
                       then "recovering"
                     elif $last.type == "integration-conflict" then "resolving-conflict"
                     elif ($last.type | IN("provider-failed", "provider-timeout", "harness-error")) then "provider-error"
                     elif $last.type == "validate-base-started" then "checking-base"
                     elif $last.type == "provider-quota-wait" then "waiting-for-quota"
                     elif $last.type == "waiting-slot" then "waiting-for-slot"
                     else $last.type end),
             phase_note: (if $last.type | IN("provider-quota-wait", "waiting-slot") then $last.message else null end),
             phase_local_time: $last.local_time,
             phase_seconds: ((now - ($last.time | seconds)) | floor),
             unblocks: [$all[] | select(.status == "todo" and any(.depends_on[]; . == $ticket.id))
               | {id, goal, waits_also: [.depends_on[] | select(. != $ticket.id) as $dep
                   | select(any($all[]; .id == $dep and .status != "done")) | $dep]}]}
         else {} end)
      + (if $ticket.status | IN("blocked", "needs-human") then
          {reason: ([$mine[] | select(.type | IN("ticket-blocked", "ticket-needs-human", "integration-conflict", "base-red"))]
                    | last | .message // null)}
         else {} end))'
}

# Worker rounds: the unattended rounds a coordinating session starts outside a campaign runner, each a systemd user
# unit named task-<id>.service whose command is LAUNCHER WORKTREE RUNDIR MODEL EFFORT MINUTES [PROMPT_FILE] (paths
# without spaces). RUNDIR may hold started (ISO time), waiting ("until=<ISO time>" while every account is out) and
# accounts.log (one line per attempt, its account last). Without them the round is still listed, from the unit.
# AGENTIC_SYSTEMCTL replaces systemctl (tests).
worker_rounds() {
  local systemctl=${AGENTIC_SYSTEMCTL:-systemctl} unit argv tree run model effort minutes started repo common
  local waiting attempts account rounds='[]'
  command -v "$systemctl" >/dev/null 2>&1 || { printf '[]\n'; return; }
  while IFS=$' \t' read -r unit _; do
    [[ $unit == task-*.service ]] || continue
    argv=$("$systemctl" --user show -p ExecStart --value "$unit" 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\) ;.*/\1/p' | head -n 1)
    tree='' run='' model='' effort='' minutes=''
    IFS=' ' read -r _ tree run model effort minutes _ <<<"$argv"
    started=''
    [[ -z $run || ! -f $run/started ]] || started=$(date -d "$(head -n 1 "$run/started")" +%s 2>/dev/null) || started=''
    [[ -n $started ]] || started=$(date -d "$("$systemctl" --user show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)" +%s 2>/dev/null) || started=''
    repo=''
    if [[ -n $tree && -d $tree ]]; then
      common=$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=''
      [[ -z $common ]] || repo=$(basename -- "$(dirname -- "$common")")
    fi
    waiting=''; [[ -z $run || ! -f $run/waiting ]] || waiting=$(sed -n 's/^until=//p' "$run/waiting" | head -n 1)
    waiting=$([[ -n $waiting ]] && date -d "$waiting" +%s 2>/dev/null || true)
    attempts=0 account=''
    if [[ -n $run && -f $run/accounts.log ]]; then
      attempts=$(grep -c ' attempt ' "$run/accounts.log" || true)
      account=$(tail -n 1 "$run/accounts.log" | sed -n 's/.* account //p')
      [[ -z $account ]] || { account=$(basename -- "$account"); account=${account#.}; }
    fi
    rounds=$(jq -c --arg id "${unit#task-}" --arg tree "$tree" --arg run "$run" --arg repo "$repo" --arg model "$model" \
      --arg effort "$effort" --arg minutes "$minutes" --arg started "$started" --arg waiting "$waiting" \
      --argjson attempts "${attempts:-0}" --arg account "$account" '
      def local: localtime | strftime("%H:%M (%d/%m)");
      . + [{id: ($id | sub("\\.service$"; "")), repo: (if $repo == "" then null else $repo end),
            worktree: (if $tree == "" then null else $tree end), run_dir: (if $run == "" then null else $run end),
            model: (if $model == "" then null else $model end), effort: (if $effort == "" then null else $effort end),
            deadline_minutes: ($minutes | tonumber? // null), attempts: $attempts,
            account: (if $account == "" then null else $account end)}
           + (if $started == "" then {} else ($started | tonumber) as $at
               | {started_local_time: ($at | local), elapsed_seconds: ((now - $at) | floor)} end)
           + (if $waiting == "" then {phase: "running"}
              else {phase: "waiting-for-quota", waiting_until_local_time: ($waiting | tonumber | local)} end)]' <<<"$rounds")
  done < <("$systemctl" --user list-units --state=active --plain --no-legend 'task-*.service' 2>/dev/null)
  in_display_tz jq -c 'sort_by(.id)' <<<"$rounds"
}

# The human lines of an overview (an object with campaigns and queues).
print_overview() {
  if jq -e '(.campaigns | length) == 0 and (.queues | length) == 0 and ((.moved // []) | length) == 0
            and ((.rounds // []) | length) == 0' >/dev/null <<<"$1"; then
    note 'No campaigns, queues or worker rounds.'
    return
  fi
  jq -r '.campaigns[] | "Campaign \(.slug): runner \(if .runner_active then "active" else "inactive" end)\(if .desired == "stopped" then (if .runner_active then ", stopping" else ", stopped" end) else "" end) — \(.counts | to_entries | map("\(.key)=\(.value)") | join(" "))\(if (.recent_events | length) > 0 then (.recent_events[-1] | " · last event \(.local_time // .time): \(.type)\(if .ticket then " \(.ticket)" else "" end)") else "" end)\(if (.guards // 0) > 0 then " · guards=\(.guards)" else "" end)\(if .worktree then "\n  worktree: \(.worktree)" else "" end)\(if .open then "\n  open: \(.open)" else "" end)"' <<<"$1"
  jq -r '.queues[] | "Queue \(.name): \(.state) — \(.message)"' <<<"$1"
  jq -r '(.moved // [])[] | "Campaign \(.slug): moved to \(.moved_to) (\(.at))"' <<<"$1"
  jq -r '(.rounds // [])[] | "Round \(.id)\(if .repo then " (\(.repo))" else "" end): \(.phase)\(if .waiting_until_local_time then " until \(.waiting_until_local_time)" else "" end)\(if .started_local_time then " · started \(.started_local_time)" else "" end)\(if .model then " · \(.model)" else "" end)\(if .worktree then "\n  worktree: \(.worktree)" else "" end)"' <<<"$1"
}

# One view of every campaign and queue in the cache, for humans and for the campaign-status skill.
cmd_overview() {
  local json=false fleet=false arg base file slug tree runtime tickets active active_ids decisions events campaigns='[]' queues moved
  local machine project provider kind plan_tickets rounds guards
  for arg in "$@"; do
    case $arg in
      --json) json=true ;;
      --fleet) fleet=true ;;
      *) die "unknown overview option: $arg" ;;
    esac
  done
  if $fleet; then
    fleet_lib
    fleet_overview "$json"
    return
  fi
  base=$(runtime_base); machine=$(machine_name); project=$(main_worktree)
  for file in "$base"/*/campaign.json; do
    [[ -f $file ]] || continue
    runtime=$(dirname -- "$file"); slug=$(jq -r '.slug' "$file"); tree=$(jq -r '.worktree' "$file")
    kind=$(jq -r 'if .kind == "task" then "task" else "campaign" end' "$file"); plan_tickets=$(campaign_tickets_dir "$file")
    tickets='[]'
    [[ -d $plan_tickets ]] && tickets=$(python3 "$TICKET_TOOL" list "$plan_tickets" 2>/dev/null || printf '[]')
    active=false; runner_alive "$slug" && active=true
    active_ids=$(for item in "$runtime"/state/*.active; do [[ ! -f $item ]] || basename -- "$item" .active; done | jq -Rsc 'split("\n") | map(select(length > 0))')
    if $active; then
      tickets=$(jq --argjson ids "$active_ids" --argjson executors "$(active_executors "$runtime")" \
        'map(if (.id as $id | $ids | index($id)) != null then .status = "in-progress" | .executor = ($executors[.id] // "local") else . end)' <<<"$tickets")
    fi
    decisions=$( (cat "$runtime"/decisions/*.json 2>/dev/null || true) | jq -sc '.')
    events=$( (tail -n 10 "$runtime/events/campaign.ndjson" 2>/dev/null || true) | with_local_time)
    tickets=$(ticket_progress "$tickets" "$runtime/events/campaign.ndjson")
    provider=$(jq -r '.provider // "claude"' "$runtime/run-config.json" 2>/dev/null || printf 'claude')
    guards=$(guard_findings "$runtime" | jq 'length')
    campaigns=$(jq -c --arg slug "$slug" --arg kind "$kind" --arg tree "$tree" --argjson active "$active" --argjson tickets "$tickets" --argjson guards "$guards" \
      --argjson decisions "$decisions" --argjson events "$events" --arg desired "$(jq -r '.desired // "running"' "$file")" \
      --arg machine "$machine" --arg project "$project" --arg provider "$provider" \
      --arg open "$(open_command "$tree" "$provider")" \
      '. + [{slug:$slug, kind:$kind, machine:$machine, project:$project, worktree:$tree, provider:$provider, open:$open,
             runner_active:$active, desired:$desired, guards:$guards,
             counts:($tickets | group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
             tickets:$tickets, decisions:$decisions, recent_events:$events}]' <<<"$campaigns")
  done
  queues=$( (cat "$base"/queue/*/status.json 2>/dev/null || true) | jq -sc '.')
  moved=$( (cat "$base"/moved/*.json 2>/dev/null || true) | jq -sc '.')
  rounds=$(worker_rounds)
  if $json; then
    jq -n --argjson campaigns "$campaigns" --argjson queues "$queues" --argjson moved "$moved" --argjson rounds "$rounds" \
      '{campaigns:$campaigns, queues:$queues, moved:$moved, rounds:$rounds}'
    return
  fi
  print_overview "$(jq -cn --argjson campaigns "$campaigns" --argjson queues "$queues" --argjson moved "$moved" \
    --argjson rounds "$rounds" '{campaigns:$campaigns, queues:$queues, moved:$moved, rounds:$rounds}')"
}

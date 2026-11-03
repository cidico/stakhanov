#!/usr/bin/env bash
# The guards of the reviewer's findings (see "Guards" in README.md): every finding of a reviewer names the automatic check
# that would have caught it, `guard: {kind, how}`. The runner keeps each accepted finding in guards.ndjson of the campaign's
# runtime (the results of a review are overwritten by the next one), `campaign guards` lists the ones an automatic check
# could have caught, and the overview counts them. Sourced by bin/campaign; it defines functions and variables and runs
# nothing.

# The guard kinds of RESULT.schema.json whose check does not exist yet. reviewer-only is the one no automatic check can be.
GUARD_REVIEWER_ONLY=reviewer-only

# record_review_findings TICKET RESULT: the findings of an accepted reviewer RESULT, appended to the campaign's ledger. A
# line is the finding as written plus the ticket, the ordinal of the ticket's review that made it (`round`: 1 is its first
# review, 2 the one after the repair...), the verdict of that review and, for a task, the task's round.
record_review_findings() {
  local ticket=$1 result=$2 runtime round task_round
  jq -e '(.findings | length) > 0' "$result" >/dev/null 2>&1 || return 0
  runtime=$(ensure_runtime)
  round=$(jq -s --arg ticket "$ticket" '[.[] | select(.ticket == $ticket and .type == "provider-completed"
    and (.message | contains("role=reviewer")))] | length' "$runtime/events/campaign.ndjson" 2>/dev/null) || round=0
  task_round=$(jq -r 'if .kind == "task" then (.round // 1) else "" end' "$runtime/campaign.json" 2>/dev/null) || task_round=''
  jq -c --arg ticket "$ticket" --argjson round "${round:-0}" --arg task_round "$task_round" --arg time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
    .status as $verdict | .findings[]
    | {time: $time, ticket: $ticket, round: $round, verdict: $verdict}
      + (if $task_round == "" then {} else {task_round: ($task_round | tonumber)} end)
      + {severity, path, line, message, reason, fix, guard}' "$result" >>"$runtime/guards.ndjson"
}

# guard_findings RUNTIME: the findings of the ledger of RUNTIME whose guard is not reviewer-only, as a JSON array (empty
# without a ledger). A line without a guard (a ledger from before guards) is not counted.
guard_findings() {
  local ledger="$1/guards.ndjson"
  [[ -f $ledger ]] || { printf '[]\n'; return 0; }
  jq -sc --arg only "$GUARD_REVIEWER_ONLY" '[.[] | select((.guard.kind // $only) != $only)]' "$ledger" 2>/dev/null || printf '[]\n'
}

# campaign guards [--json]: the findings of every campaign and task of this project on this machine that an automatic check
# could have caught: where (campaign or task, ticket, review round, severity), the guard (kind and how) and the message.
# The same scope as `campaign overview`: what the machine's cache holds, not only the campaign of the current branch.
cmd_guards() {
  local json=false arg file runtime slug kind found all='[]' count
  for arg in "$@"; do
    case $arg in
      --json) json=true ;;
      *) die "unknown guards option: $arg" ;;
    esac
  done
  for file in "$(runtime_base)"/*/campaign.json; do
    [[ -f $file ]] || continue
    runtime=$(dirname -- "$file"); slug=$(jq -r '.slug' "$file")
    kind=$(jq -r 'if .kind == "task" then "task" else "campaign" end' "$file")
    found=$(guard_findings "$runtime")
    all=$(jq -c --arg slug "$slug" --arg kind "$kind" --argjson found "$found" \
      '. + [$found[] | {campaign: $slug, kind: $kind} + .]' <<<"$all")
  done
  count=$(jq 'length' <<<"$all")
  if $json; then
    jq -cn --argjson count "$count" --argjson findings "$all" '{count: $count, findings: $findings}'
    return
  fi
  if ((count == 0)); then
    note 'No finding asks for a guard.'
    return
  fi
  note "$count finding(s) an automatic check could have caught:"
  jq -r '.[] | "\(.campaign) (\(.kind)) \(.ticket) round \(.round) [\(.severity)] \(.guard.kind): \(.guard.how)\n  \(.message)"' <<<"$all"
  note "By guard: $(jq -r 'group_by(.guard.kind) | map("\(.[0].guard.kind) \(length)") | join(", ")' <<<"$all")"
}

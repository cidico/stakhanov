#!/usr/bin/env bash
# Loaded by the Bash supervisor after common.sh.
validation_run() {
  local worktree=$1 ticket=$2 phase=$3
  python3 "$AGENTIC_DIR/lib/validation.py" "$worktree" "$(campaign_path)/validation.json" "$(ensure_runtime)/validation" "$ticket" "$phase"

}

validation_final() {
  local worktree=$1 manifest=${2:-$(campaign_path)/validation.json}
  python3 "$AGENTIC_DIR/lib/validation.py" "$worktree" "$manifest" "$(ensure_runtime)/validation" campaign final
}

validation_baseline() {
  local tree=$1 manifest=${2:-$(campaign_path)/validation.json}
  python3 "$AGENTIC_DIR/lib/validation.py" "$tree" "$manifest" "$(ensure_runtime)/validation" campaign baseline
}

# True when the plan declares repository-wide baseline commands.
plan_has_baseline() {
  jq -e '(.baseline // []) | length > 0' "${1:-$(campaign_path)/validation.json}" >/dev/null 2>&1
}

# True when the failed command of a ticket receipt is one of the plan's baseline commands.
failed_command_is_baseline() {
  local receipt=$1 manifest=${2:-$(campaign_path)/validation.json}
  jq -e --slurpfile plan "$manifest" '.failed_command as $failed | ($plan[0].baseline // []) | index([$failed]) != null' "$receipt" >/dev/null 2>&1
}

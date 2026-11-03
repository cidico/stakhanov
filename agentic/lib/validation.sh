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

# validation_base TREE TICKET: the ticket's cheap and component commands, in that order, on TREE (a checkout of the
# ticket's base), stopping at the first that fails. The receipt goes to validation/base/ so that no reader of the ticket's
# own receipts takes a red base for a red ticket. The status is validation.py's: 0 when every command passed.
validation_base() {
  local tree=$1 ticket=$2
  python3 "$AGENTIC_DIR/lib/validation.py" "$tree" "$(campaign_path)/validation.json" "$(ensure_runtime)/validation/base" "$ticket" base
}

# True when the plan declares repository-wide baseline commands.
plan_has_baseline() {
  jq -e '(.baseline // []) | length > 0' "${1:-$(campaign_path)/validation.json}" >/dev/null 2>&1
}

# True when the failed command of a ticket receipt is one of the plan's baseline commands (an argv array, or the
# command of {"command": [...], "timeout_minutes": N}).
failed_command_is_baseline() {
  local receipt=$1 manifest=${2:-$(campaign_path)/validation.json}
  jq -e --slurpfile plan "$manifest" '.failed_command as $failed
    | ($plan[0].baseline // []) | map(if type == "object" then .command else . end) | index([$failed]) != null' \
    "$receipt" >/dev/null 2>&1
}

# validation_environment_failure RECEIPT: prints "<command> (<cause>)" and succeeds when the failure that the FAIL
# receipt records is the environment's, not the code's: the command does not exist (it exited 127, or it could not be
# started at all, and what is missing is a name looked up in the PATH: a script or path of the worktree that does not
# exist is a defect of the code and is repaired), it ran out of time (timedOut), or its output matches one of the environment_failure_patterns of
# project.json (Python regular expressions, searched in its stdout and stderr).
validation_environment_failure() {
  python3 - "$1" "$PROJECT_ENVIRONMENT_FAILURE_PATTERNS" <<'PY'
import json, re, shlex, shutil, sys
from pathlib import Path

path = Path(sys.argv[1])
patterns = json.loads(sys.argv[2])
try:
    receipt = json.loads(path.read_text())
except (OSError, ValueError):
    raise SystemExit(1)
if not isinstance(receipt, dict) or receipt.get('status') != 'FAIL':
    raise SystemExit(1)
failed = receipt.get('failed_command')
evidence = [record for record in receipt.get('evidence') or [] if isinstance(record, dict)]
# The failing record is the last one; a command that could not be started has none (an OSError of validation.py).
record = evidence[-1] if evidence and evidence[-1].get('exitCode') not in (0, None) else None
if not isinstance(failed, list):
    failed = (record or {}).get('command') or []
# As a shell would read it: a brief's command comes back as its brief wrote it.
command = shlex.join(str(part) for part in failed)[:300] or 'unknown command'


def output(record):
    text = [record.get('tail') or '']
    for key in ('stdoutLog', 'stderrLog'):
        name = record.get(key)
        if isinstance(name, str) and name and '/' not in name:
            try:
                text.append((path.parent / 'logs' / name).read_text(errors='replace'))
            except OSError:
                pass
    return '\n'.join(text)


def missing_from_path():
    """True when the command that the argv names is searched in the PATH and is not there. A path (it has a /) that
    does not exist is a file of the worktree that the code should have, which a repair can create."""
    name = str(failed[0]) if failed else ''
    return bool(name) and '/' not in name and shutil.which(name) is None


cause = None
if record is None:
    # The command could not be started: ENOENT. Only a name looked up in the PATH is the environment's.
    if '[Errno 2]' in str(receipt.get('reason') or '') and missing_from_path():
        cause = 'command not found'
elif record.get('exitCode') == 127:
    # A shell's 127 is a command it did not find; "No such file or directory" for a script of the worktree is not.
    if re.search(r'command not found', output(record)) or missing_from_path():
        cause = 'exit 127, command not found'
elif record.get('timedOut') or receipt.get('timedOut'):
    cause = str(record.get('summary') or 'timed out')
else:
    text = output(record)
    cause = next((f'output matches {pattern}' for pattern in patterns if re.search(pattern, text, re.MULTILINE)), None)
if cause is None:
    raise SystemExit(1)
print(f'{command} ({cause})')
PY
}

#!/usr/bin/env python3
"""Execute only versioned validation plans; never execute provider-result text."""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

SECRET_REPLACE = re.compile(
    r"(?i)([Aa]uthorization:\s*(?:Bearer|Basic)\s+)\S+|"
    r"((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s\",}]+|"
    r"(postgres(?:ql)?://)[^\s@]+@"
)

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
    if value.get('status') == 'RUNNING' and path.exists():
        os.replace(path, path.with_suffix(path.suffix + '.previous'))
    os.replace(temp, path)


def argv(value):
    if not isinstance(value, list) or not value or not all(isinstance(x, str) and x and '\0' not in x for x in value):
        raise ValueError('validation commands must be nonempty argv arrays')
    return value


def commands(value):
    if not isinstance(value, list):
        raise ValueError('validation phase must be an array')
    for command in value:
        argv(command)
    return value


def argv_key(command):
    return tuple(command)


def campaign_expensive_commands(plan):
    raw = plan.get('campaign_expensive')
    if raw is None:
        return []
    return commands(raw)


def ticket_requires_campaign_expensive(item):
    flag = item.get('campaign_expensive')
    if flag is None:
        return False
    if flag is not True and flag is not False:
        raise ValueError('ticket campaign_expensive must be a boolean')
    return flag is True


def select_commands(plan, item, phase):
    if phase == 'baseline':
        return list(commands(plan.get('baseline') or []))
    if phase == 'final':
        selected = list(commands(plan.get('final') or []))
        seen = {argv_key(command) for command in selected}
        for command in campaign_expensive_commands(plan):
            key = argv_key(command)
            if key not in seen:
                selected.append(command)
                seen.add(key)
        return selected
    declared = commands(item.get(phase))
    if phase != 'expensive':
        return declared
    campaign = {argv_key(command) for command in campaign_expensive_commands(plan)}
    if not campaign or ticket_requires_campaign_expensive(item):
        return declared
    return [command for command in declared if argv_key(command) not in campaign]


def sanitize_text(text):
    if not text:
        return ''
    return SECRET_REPLACE.sub(
        lambda match: (match.group(1) or match.group(2) or match.group(3) or '') + '[REDACTED]',
        text,
    )


def write_log(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(sanitize_text(text or ''))
    os.chmod(path, 0o600)


def failed_tests(text):
    found = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('(fail) ') or stripped.startswith('not ok '):
            found.append(stripped[:240])
        elif stripped.startswith('FAIL ') and 'tests failed' not in stripped.lower():
            found.append(stripped[:240])
        if len(found) >= 20:
            break
    return found


def plan_read(path):
    if path.is_symlink():
        raise ValueError('validation plan cannot be a symlink')
    plan = json.loads(path.read_text())
    if plan.get('version') != 1 or not isinstance(plan.get('tickets'), dict):
        raise ValueError('invalid validation plan version or tickets')
    commands(plan.get('final'))
    if not commands(plan.get('final')):
        raise ValueError('campaign final validation is required')
    if 'campaign_expensive' in plan:
        commands(plan.get('campaign_expensive'))
    if 'baseline' in plan:
        commands(plan.get('baseline'))
    for key, item in plan['tickets'].items():
        if not isinstance(item, dict):
            raise ValueError(f'{key}: validation entry must be an object')
        commands(item.get('cheap'))
        commands(item.get('component'))
        commands(item.get('expensive'))
        if 'campaign_expensive' in item and item['campaign_expensive'] not in (True, False):
            raise ValueError(f'{key}: campaign_expensive must be a boolean')
    return plan


def command_record(command, exit_code, started, finished, stdout, stderr, stdout_log, stderr_log):
    combined = f'{stdout or ""}\n{stderr or ""}'
    tests = failed_tests(combined)
    duration_ms = max(0, int((finished - started).total_seconds() * 1000))
    summary = f'exit {exit_code}'
    if tests:
        summary = f'exit {exit_code}; {len(tests)} failed test line(s)'
    elif exit_code == 0:
        summary = 'exit 0'
    tail = sanitize_text('\n'.join(combined.splitlines()[-12:]))[:2000]
    return {
        'command': [sanitize_text(part) for part in command],
        'exitCode': exit_code,
        'startedAt': started.replace(tzinfo=datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        'finishedAt': finished.replace(tzinfo=datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        'durationMs': duration_ms,
        'stdoutLog': str(stdout_log),
        'stderrLog': str(stderr_log),
        'summary': summary,
        'failedTests': tests,
        'tail': tail,
    }
class CommandFailed(ValueError):
    def __init__(self, record):
        super().__init__(f"validation command failed (exit {record['exitCode']})")
        self.record = record
def execute(command, tree, logs_dir=None, log_stem=None):
    started = datetime.datetime.now(datetime.timezone.utc)
    result = subprocess.run(argv(command), cwd=tree, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    finished = datetime.datetime.now(datetime.timezone.utc)
    stdout = result.stdout.decode('utf-8', 'replace')
    stderr = result.stderr.decode('utf-8', 'replace')
    stdout_log = stderr_log = None
    if logs_dir is not None and log_stem is not None:
        stdout_log = logs_dir / f'{log_stem}.stdout.log'
        stderr_log = logs_dir / f'{log_stem}.stderr.log'
        write_log(stdout_log, stdout)
        write_log(stderr_log, stderr)
    record = command_record(command, result.returncode, started, finished, stdout, stderr,
                            stdout_log.name if stdout_log else '', stderr_log.name if stderr_log else '')
    if result.returncode:
        raise CommandFailed(record)
    return record


def run(args):
    tree = args.tree.resolve()
    manifest = args.manifest.resolve()
    plan = plan_read(args.manifest)
    runtime = args.runtime.resolve()
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    logs_dir = runtime / 'logs'
    logs_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.phase in ('final', 'baseline'):
        selected = select_commands(plan, None, args.phase)
        item = None
    else:
        item = plan['tickets'].get(args.ticket)
        if item is None:
            raise ValueError('ticket has no trusted validation plan')
        selected = select_commands(plan, item, args.phase)
    if not re.fullmatch(r'(?:campaign|[A-Z][A-Z0-9]*-[0-9]{3,})', args.ticket):
        raise ValueError('invalid validation ticket identifier')
    receipt = runtime / f'{args.ticket}.{args.phase}.json'
    if not selected:
        save(receipt, {'status': 'NOT_REQUIRED', 'manifest': str(manifest)})
        return
    save(receipt, {'status': 'RUNNING', 'manifest': str(manifest)})
    evidence = []
    command = None
    try:
        for index, command in enumerate(selected):
            record = execute(command, tree, logs_dir=args.runtime / 'logs',
                             log_stem=f'{args.ticket}.{args.phase}.{index}')
            evidence.append(record)
    except CommandFailed as exc:
        evidence.append(exc.record)
        save(receipt, {'status': 'FAIL', 'manifest': str(manifest), 'evidence': evidence, 'reason': str(exc), 'failed_command': exc.record['command']})
        raise
    except OSError as exc:
        save(receipt, {'status': 'FAIL', 'manifest': str(manifest), 'evidence': evidence, 'reason': str(exc), 'failed_command': command})
        raise
    save(receipt, {'status': 'PASS', 'manifest': str(manifest), 'evidence': evidence})
    print(f'{args.ticket} {args.phase}: PASS ({len(evidence)} commands)')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('tree', type=Path)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('runtime', type=Path)
    parser.add_argument('ticket')
    parser.add_argument('phase', choices=('cheap', 'component', 'expensive', 'final', 'baseline'))
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f'campaign validation: {exc}', file=sys.stderr)
        return 4
    return 0


if __name__ == '__main__':
    sys.exit(main())

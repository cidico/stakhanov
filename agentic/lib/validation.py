#!/usr/bin/env python3
"""Execute only versioned validation plans; never execute provider-result text."""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

DEFAULT_TIMEOUT_MINUTES = 120
MAX_TIMEOUT_MINUTES = 1440
KILL_GRACE_SECONDS = 10
TIMEOUT_EXIT_CODE = 124

SECRET_REPLACE = re.compile(
    r"(?i)([Aa]uthorization:\s*(?:Bearer|Basic)\s+)\S+|"
    r"((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s\",}]+|"
    r"(postgres(?:ql)?://)[^\s@]+@"
)

def save(path, value, rotate=False):
    """Writes the receipt atomically; rotate keeps the one it replaces as <receipt>.previous."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
    if rotate and path.exists():
        os.replace(path, path.with_suffix(path.suffix + '.previous'))
    os.replace(temp, path)


def argv(value):
    if not isinstance(value, list) or not value or not all(isinstance(x, str) and x and '\0' not in x for x in value):
        raise ValueError('validation commands must be nonempty argv arrays')
    return value


def timeout_minutes_value(value, where):
    """A deadline in minutes: an integer from 1 to MAX_TIMEOUT_MINUTES (a boolean is not one)."""
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_TIMEOUT_MINUTES:
        raise ValueError(f'{where} must be an integer from 1 to {MAX_TIMEOUT_MINUTES} (minutes)')
    return value


def entry_argv(entry):
    """The argv of a plan command, which is an array or {"command": [...], "timeout_minutes": N}."""
    if isinstance(entry, dict):
        extra = sorted(set(entry) - {'command', 'timeout_minutes'})
        if extra:
            raise ValueError(f'validation command object has unknown field(s): {", ".join(map(str, extra))}')
        return argv(entry.get('command'))
    return argv(entry)


def entry_timeout_minutes(entry):
    """The command's own deadline in minutes, or None."""
    if isinstance(entry, dict) and 'timeout_minutes' in entry:
        return timeout_minutes_value(entry['timeout_minutes'], 'validation command timeout_minutes')
    return None


def commands(value):
    if not isinstance(value, list):
        raise ValueError('validation phase must be an array')
    for command in value:
        entry_argv(command)
        entry_timeout_minutes(command)
    return value


def argv_key(command):
    return tuple(entry_argv(command))


def env_text(name):
    value = os.environ.get(name)
    return value.strip() if value and value.strip() else None


def deadline_seconds(entry, plan):
    """The deadline of a command, in seconds. First that applies: AGENTIC_VALIDATION_TIMEOUT_SECONDS (for tests), the
    command's timeout_minutes, the plan's timeout_minutes, AGENTIC_VALIDATION_TIMEOUT_MINUTES, 120 minutes."""
    override = env_text('AGENTIC_VALIDATION_TIMEOUT_SECONDS')
    if override is not None:
        try:
            seconds = float(override)
        except ValueError:
            seconds = 0
        if not seconds > 0 or seconds == float('inf'):
            raise ValueError('AGENTIC_VALIDATION_TIMEOUT_SECONDS must be a positive number of seconds')
        return seconds
    minutes = entry_timeout_minutes(entry)
    if minutes is None and isinstance(plan, dict) and 'timeout_minutes' in plan:
        minutes = timeout_minutes_value(plan['timeout_minutes'], 'validation plan timeout_minutes')
    if minutes is None:
        text = env_text('AGENTIC_VALIDATION_TIMEOUT_MINUTES')
        if text is not None:
            minutes = timeout_minutes_value(int(text) if re.fullmatch(r'[0-9]+', text) else text,
                                            'AGENTIC_VALIDATION_TIMEOUT_MINUTES')
    return (DEFAULT_TIMEOUT_MINUTES if minutes is None else minutes) * 60


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
    if phase == 'base':
        # What proves a ticket cheaply: its cheap and component commands. The expensive ones are never discovery.
        return list(commands(item.get('cheap'))) + list(commands(item.get('component')))
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
    if 'timeout_minutes' in plan:
        timeout_minutes_value(plan['timeout_minutes'], 'validation plan timeout_minutes')
    # Legacy layout (accepted, not produced): without a final list, the campaign_expensive list is the final one.
    if plan.get('final') is None and plan.get('campaign_expensive') is not None:
        plan['final'] = plan['campaign_expensive']
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


def minutes_text(seconds):
    return f'{seconds / 60:g}'


def command_record(command, exit_code, started, finished, stdout, stderr, stdout_log, stderr_log,
                   timeout_seconds=None, timed_out=False):
    combined = f'{stdout or ""}\n{stderr or ""}'
    tests = failed_tests(combined)
    duration_ms = max(0, int((finished - started).total_seconds() * 1000))
    summary = f'exit {exit_code}'
    if timed_out:
        summary = f'timed out after {minutes_text(timeout_seconds)} min'
    elif tests:
        summary = f'exit {exit_code}; {len(tests)} failed test line(s)'
    elif exit_code == 0:
        summary = 'exit 0'
    tail = sanitize_text('\n'.join(combined.splitlines()[-12:]))[:2000]
    record = {
        'command': [sanitize_text(part) for part in entry_argv(command)],
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
    if timeout_seconds is not None:
        record['timeoutSeconds'] = timeout_seconds
        record['timedOut'] = timed_out
    return record


def git_text(tree, *args):
    """Output of a git command in the tree, or None when it fails."""
    result = subprocess.run(['git', '-C', str(tree), *args], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return result.stdout if result.returncode == 0 else None


def tree_state(tree):
    """(commit, dirty): HEAD of the tree, and whether it has tracked changes (or could not be read)."""
    tip = (git_text(tree, 'rev-parse', 'HEAD') or '').strip() or None
    status = git_text(tree, 'status', '--porcelain', '--untracked-files=no')
    return tip, status is None or bool(status.strip())


def reusable_evidence(path, tip, dirty):
    """The passed commands of the receipt at path, when they ran on this very commit and tree: the same tip, no tracked
    change now and none then. Any status counts: a failed or killed run keeps what passed."""
    if not tip or dirty:
        return []
    try:
        old = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    if not isinstance(old, dict) or old.get('tip') != tip or old.get('dirty') or not isinstance(old.get('evidence'), list):
        return []
    return [record for record in old['evidence']
            if isinstance(record, dict) and record.get('exitCode') == 0 and isinstance(record.get('command'), list)]


def take_reusable(available, command):
    """Removes from available and returns the passed record of command (in the form records store it), else None."""
    wanted = [sanitize_text(part) for part in entry_argv(command)]
    for position, record in enumerate(available):
        if record['command'] == wanted:
            return available.pop(position)
    return None


class Receipt:
    """The receipt of one run. Its first write keeps the receipt it replaces as .previous; the later ones do not."""
    def __init__(self, path, manifest, tip=None, dirty=False):
        self.path, self.manifest, self.tip, self.dirty, self.written = path, manifest, tip, dirty, False

    def write(self, status, evidence, **extra):
        value = {'status': status, 'manifest': str(self.manifest)}
        if self.tip is not None or self.dirty:
            value['tip'] = self.tip
            if self.dirty:
                value['dirty'] = True
        value['evidence'] = evidence
        value.update(extra)
        save(self.path, value, rotate=not self.written)
        self.written = True


class CommandFailed(ValueError):
    def __init__(self, record):
        if record.get('timedOut'):
            super().__init__(f"validation command {record['summary']}")
        else:
            super().__init__(f"validation command failed (exit {record['exitCode']})")
        self.record = record


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def terminate_group(process):
    """SIGTERM to the command's process group, SIGKILL for what is left of it KILL_GRACE_SECONDS later."""
    def send(signum):
        try:
            os.killpg(process.pid, signum)
            return True
        except ProcessLookupError:
            return False

    if send(signal.SIGTERM):
        end = time.monotonic() + KILL_GRACE_SECONDS
        while time.monotonic() < end:
            process.poll()
            if not send(0):
                break
            time.sleep(0.1)
        send(signal.SIGKILL)
    process.wait()


def run_group(args, tree, seconds):
    """Runs args in its own process group within seconds: (returncode, stdout, stderr, timed_out). An overdue command
    (and every process of its group) is terminated; an interrupt of this tool terminates it too, then exits."""
    process = subprocess.Popen(args, cwd=tree, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)

    def interrupt(signum, _frame):
        raise Interrupted(signum)

    saved = {}
    try:
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            saved[signum] = signal.signal(signum, interrupt)
    except ValueError:  # not the main thread: no handlers to install
        saved = {}
    try:
        try:
            stdout, stderr = process.communicate(timeout=seconds)
            return process.returncode, stdout, stderr, False
        except subprocess.TimeoutExpired:
            terminate_group(process)
            stdout, stderr = process.communicate()
            return TIMEOUT_EXIT_CODE, stdout, stderr, True
    except Interrupted as error:
        for signum in saved:
            signal.signal(signum, signal.SIG_IGN)
        terminate_group(process)
        raise SystemExit(128 + error.signum)
    finally:
        for signum, handler in saved.items():
            signal.signal(signum, handler)


def execute(command, tree, logs_dir=None, log_stem=None, timeout_seconds=None):
    if timeout_seconds is None:
        timeout_seconds = deadline_seconds(command, {})
    started = datetime.datetime.now(datetime.timezone.utc)
    code, out, err, timed_out = run_group(entry_argv(command), tree, timeout_seconds)
    finished = datetime.datetime.now(datetime.timezone.utc)
    stdout = (out or b'').decode('utf-8', 'replace')
    stderr = (err or b'').decode('utf-8', 'replace')
    stdout_log = stderr_log = None
    if logs_dir is not None and log_stem is not None:
        stdout_log = logs_dir / f'{log_stem}.stdout.log'
        stderr_log = logs_dir / f'{log_stem}.stderr.log'
        write_log(stdout_log, stdout)
        write_log(stderr_log, stderr)
    record = command_record(command, code, started, finished, stdout, stderr,
                            stdout_log.name if stdout_log else '', stderr_log.name if stderr_log else '',
                            timeout_seconds, timed_out)
    if code:
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
    # The final validation is the only long one: it records the commit it validates, saves what passed after every
    # command, and does not run again a command that already passed on this commit and tree.
    final = args.phase == 'final'
    # Every deadline is resolved before anything runs, so a bad one stops the phase with no command started.
    deadlines = [deadline_seconds(command, plan) for command in selected]
    tip, dirty, available = None, False, []
    if final:
        tip, dirty = tree_state(tree)
        available = reusable_evidence(receipt, tip, dirty)
    proof = Receipt(receipt, manifest, tip, dirty)
    evidence = []
    reused = 0
    command = None
    try:
        for index, command in enumerate(selected):
            old = take_reusable(available, command)
            if old:
                evidence.append(dict(old, reused=True))
                reused += 1
                print(f'{args.ticket} {args.phase}: reusing the PASS of {" ".join(old["command"])[:100]} '
                      f'from {old.get("startedAt")} (same commit {tip[:9]})', flush=True)
                continue
            if not proof.written:
                proof.write('RUNNING', evidence)
            record = execute(command, tree, logs_dir=args.runtime / 'logs',
                             log_stem=f'{args.ticket}.{args.phase}.{index}', timeout_seconds=deadlines[index])
            evidence.append(record)
            if final:
                proof.write('RUNNING', evidence)
    except CommandFailed as exc:
        evidence.append(exc.record)
        extra = {'timedOut': True} if exc.record.get('timedOut') else {}
        proof.write('FAIL', evidence, reason=str(exc), failed_command=exc.record['command'], **extra)
        raise
    except OSError as exc:
        proof.write('FAIL', evidence, reason=str(exc), failed_command=entry_argv(command))
        raise
    proof.write('PASS', evidence)
    print(f'{args.ticket} {args.phase}: PASS ({len(evidence)} commands{f", {reused} reused" if reused else ""})')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('tree', type=Path)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('runtime', type=Path)
    parser.add_argument('ticket')
    parser.add_argument('phase', choices=('cheap', 'component', 'expensive', 'final', 'baseline', 'base'))
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f'campaign validation: {exc}', file=sys.stderr)
        return 4
    return 0


if __name__ == '__main__':
    sys.exit(main())

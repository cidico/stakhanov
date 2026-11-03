"""Session mode of the claude provider: the host CLI, the queue and the watch over a hosted subagent. No model, no real
claude: the host is a fake `claude` script (the process name the CLI looks for) and the subagents are transcripts written
by the tests."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from test_campaign import Repo

KIT = Path(__file__).resolve().parents[1]
HOST = KIT / 'bin' / 'session-host'
SESSION = KIT / 'providers' / 'claude' / 'session.py'
sys.path.insert(0, str(KIT / 'providers' / 'claude'))
import session  # noqa: E402

FAKE_CLAUDE = r'''#!/bin/bash
# A stand-in for the claude process: it writes its own session registry entry and then runs, as its children, the commands
# the test drops in its folder (a command is a file cmd.N; its output, error and status come back as out.N, err.N, rc.N).
start=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}')
if [ -z "$FAKE_NO_REGISTRY" ]; then
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  printf '{"pid":%s,"sessionId":"%s","cwd":"/work","procStart":"%s"%s}\n' "$$" "$FAKE_SESSION_ID" "$start" \
    "${FAKE_ENTRYPOINT:+,\"entrypoint\":\"$FAKE_ENTRYPOINT\"}" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
fi
: > "$FAKE_DIR/ready"
while :; do
  for f in "$FAKE_DIR"/cmd.*; do
    [ -e "$f" ] || continue
    n=${f##*.}
    mv "$f" "$FAKE_DIR/run.$n"
    bash "$FAKE_DIR/run.$n" "$n" &
  done
  sleep 0.05
done
'''


class Job:
    def __init__(self, host, number):
        self.host, self.number = host, number

    def finished(self):
        return (self.host.directory / f'rc.{self.number}').exists()

    def result(self, timeout=20):
        deadline = time.time() + timeout
        while not self.finished():
            if time.time() > deadline:
                raise AssertionError('the command did not finish')
            time.sleep(0.05)
        read = lambda name: (self.host.directory / f'{name}.{self.number}').read_text()
        return subprocess.CompletedProcess([], int(read('rc')), read('out'), read('err'))

    def kill(self):
        subprocess.run(['pkill', '-f', f'run.{self.number}'], check=False)


class FakeHost:
    """A long-lived process named claude with its own account and session id; session-host commands run as its children."""

    def __init__(self, case, account='a', session_id='sess-a', registry=True, entrypoint='', env=None):
        self.directory = case.root / f'fake-{account}'
        self.directory.mkdir()
        self.config = case.root / f'.claude-{account}'
        script = self.directory / 'claude'
        script.write_text(FAKE_CLAUDE)
        script.chmod(0o755)
        self.counter = 0
        env = dict(env or case.env, CLAUDE_CONFIG_DIR=str(self.config), FAKE_SESSION_ID=session_id,
                   FAKE_DIR=str(self.directory), FAKE_NO_REGISTRY='' if registry else '1', FAKE_ENTRYPOINT=entrypoint)
        self.process = subprocess.Popen([str(script)], env=env, start_new_session=True)
        case.addCleanup(self.stop)
        deadline = time.time() + 10
        while not (self.directory / 'ready').exists():
            if time.time() > deadline:
                raise AssertionError('the fake claude did not start')
            time.sleep(0.02)

    def stop(self):
        try:
            os.killpg(self.process.pid, 9)
        except ProcessLookupError:
            pass
        self.process.wait()

    def start(self, *command):
        self.counter += 1
        script = self.directory / f'cmd.{self.counter}.tmp'
        script.write_text('cd /\n' + ' '.join(shlex.quote(part) for part in [sys.executable, str(HOST), *command]) +
                          ' > "$FAKE_DIR/out.$1" 2> "$FAKE_DIR/err.$1"\necho $? > "$FAKE_DIR/rc.$1.tmp"\n'
                          'mv "$FAKE_DIR/rc.$1.tmp" "$FAKE_DIR/rc.$1"\n')
        os.rename(script, self.directory / f'cmd.{self.counter}')
        return Job(self, self.counter)

    def call(self, *command, timeout=20):
        return self.start(*command).result(timeout)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='session-mode-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.queue = self.root / 'queue'
        self.env = dict(os.environ, AGENTIC_SESSION_DIR=str(self.queue), AGENTIC_SESSION_HOST_POLL_SECONDS='0.1',
                        PATH='/usr/bin:/bin')
        self.env.pop('CLAUDE_PID', None)
        self.sleepers = []
        self.addCleanup(self.stop_sleepers)

    def stop_sleepers(self):
        for process in self.sleepers:
            process.kill()
            process.wait()

    def sleeper(self):
        process = subprocess.Popen(['sleep', '600'])
        self.sleepers.append(process)
        return process

    def submit(self, identifier='r1', role='worker', model='opus', ticket='TST-001', adapter=None):
        adapter = adapter or self.sleeper()
        prompt = self.root / f'{identifier}.prompt'
        prompt.write_text('combined prompt\n')
        schema = self.root / 'schema.json'
        schema.write_text('{}')
        result = subprocess.run(
            [sys.executable, str(SESSION), 'submit', '--id', identifier, '--project', 'proj', '--ticket', ticket,
             '--role', role, '--model', model, '--effort', 'high',
             '--read-only', 'false' if role == 'worker' else 'true', '--worktree', '/work/tree',
             '--prompt', str(prompt), '--schema', str(schema), '--adapter-pid', str(adapter.pid)],
            env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(result.stdout.strip())

    def hosts(self):
        return {int(path.stem): json.loads(path.read_text()) for path in (self.queue / 'hosts').glob('*.json')}

    # --- register / unregister / status

    def test_register_writes_the_host_and_sweeps_the_dead(self):
        dead = self.queue / 'hosts' / '999999.json'
        dead.parent.mkdir(parents=True)
        dead.write_text(json.dumps({'pid': 999999, 'start': '1'}))
        request = self.submit()
        (request / 'assigned').write_text(json.dumps({'host_pid': 999999, 'host_start': '1', 'agent_id': 'x'}))
        host = FakeHost(self)
        result = host.call('register')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f'registered pid={host.process.pid} session=sess-a account=claude-a hosts=1 requeued=1')
        record = self.hosts()[host.process.pid]
        self.assertEqual(sorted(record), ['account', 'cgroup', 'cwd', 'machine', 'pid', 'session_id', 'since', 'start'])
        self.assertEqual((record['session_id'], record['account'], record['cwd']), ('sess-a', str(host.config), '/work'))
        self.assertEqual(record['start'], session.proc_start(host.process.pid))
        self.assertEqual(record['cgroup'], session.cgroup_of(host.process.pid))
        self.assertFalse(dead.exists())
        self.assertFalse((request / 'assigned').exists(), 'the request of a dead host goes back to pending')

    def test_register_asks_udarnik_to_keep_only_a_terminal_session(self):
        # An app (T3 Code, entrypoint t3-code) restarts the sessions it hosts: udarnik resuming one too would run it twice.
        fake_bin = self.root / 'fake-bin'
        fake_bin.mkdir()
        calls = self.root / 'udarnik-calls'
        udarnik = fake_bin / 'udarnik'
        udarnik.write_text('#!/bin/bash\n[ "$1" = --help ] && { echo "  keep ID | unkeep ID"; exit 0; }\n'
                           f'echo "$*" >> {shlex.quote(str(calls))}\n')
        udarnik.chmod(0o755)
        env = dict(self.env, PATH=f'{fake_bin}:{self.env["PATH"]}')
        terminal = FakeHost(self, account='t', session_id='sess-term', env=env).call('register')
        self.assertEqual(terminal.returncode, 0, terminal.stderr)
        hosted = FakeHost(self, account='h', session_id='sess-t3', entrypoint='t3-code', env=env).call('register')
        self.assertEqual(hosted.returncode, 0, hosted.stderr)
        self.assertIn('not kept by udarnik: the session is hosted by t3-code', hosted.stdout)
        self.assertEqual(calls.read_text().splitlines(), ['keep sess-term'])

    def test_register_without_a_registry_entry_fails(self):
        result = FakeHost(self, registry=False).call('register')
        self.assertEqual(result.returncode, 1)
        self.assertIn('no session registry entry', result.stderr)
        self.assertEqual(self.hosts(), {})

    def test_commands_need_a_registered_host(self):
        result = FakeHost(self).call('wait')
        self.assertEqual(result.returncode, 1)
        self.assertIn('not registered as a host', result.stderr)

    def test_unregister_removes_the_host(self):
        host = FakeHost(self)
        host.call('register')
        self.assertEqual(len(self.hosts()), 1)
        result = host.call('unregister')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), f'unregistered pid={host.process.pid}')
        self.assertEqual(self.hosts(), {})

    def test_status_lists_hosts_and_requests(self):
        host = FakeHost(self)
        host.call('register')
        self.submit('r1')
        lines = host.call('status').stdout.splitlines()
        self.assertEqual(lines[0], 'hosts=1 requests=1')
        self.assertRegex(lines[1], r'^host pid=\d+ alive=yes session=sess-a account=claude-a machine=\S+ age=\d+s$')
        self.assertRegex(lines[2], r'^request r1 pending age=\d+s role=worker ticket=TST-001 project=proj attempt=1$')

    # --- wait

    def test_wait_prints_new_and_cancel_items(self):
        host = FakeHost(self)
        host.call('register')
        request = self.submit('r-new')
        self.assertEqual(host.call('wait').stdout.splitlines(), ['new r-new'])
        self.assertEqual(host.call('claim', 'r-new', 'agent-abc123').stdout.strip(), 'claimed r-new abc123')
        (request / 'cancel').write_text('{"reason":"idle"}')
        self.assertEqual(host.call('wait').stdout.splitlines(), ['cancel r-new abc123'])
        self.assertEqual(host.call('cancelled', 'r-new').returncode, 0)
        self.assertTrue((request / 'cancelled').exists())

    def test_wait_blocks_until_work_arrives_and_ends_when_unregistered(self):
        host = FakeHost(self)
        host.call('register')
        waiting = host.start('wait')
        time.sleep(0.5)
        self.assertFalse(waiting.finished(), 'wait blocks while there is nothing to do')
        self.submit('late')
        self.assertEqual(waiting.result().stdout.splitlines(), ['new late'])
        self.assertEqual(host.call('claim', 'late', 'x1').returncode, 0)
        stopping = host.start('wait')
        time.sleep(0.3)
        for path in (self.queue / 'hosts').glob('*.json'):
            path.unlink()
        self.assertEqual(stopping.result().stdout.strip(), 'stopped')

    def test_wait_offers_a_request_whose_host_died_and_not_one_whose_adapter_died(self):
        host = FakeHost(self)
        host.call('register')
        adapter = self.sleeper()
        request = self.submit('orphan', adapter=adapter)
        adapter.kill()
        adapter.wait()
        self.assertEqual(host.call('status').stdout.splitlines()[-1].split()[2], 'abandoned')
        waiting = host.start('wait')
        time.sleep(0.5)
        self.assertFalse(waiting.finished(), 'an abandoned request is no work')
        self.submit('taken-over')
        (self.queue / 'requests' / 'taken-over' / 'assigned').write_text(
            json.dumps({'host_pid': 999999, 'host_start': '1', 'agent_id': 'gone'}))
        self.assertEqual(waiting.result().stdout.splitlines(), ['new taken-over'])
        self.assertTrue((request / 'request.json').exists())

    def test_wait_asks_a_host_to_stop_the_agent_of_a_vanished_adapter(self):
        host = FakeHost(self)
        host.call('register')
        adapter = self.sleeper()
        self.submit('gone', adapter=adapter)
        host.call('claim', 'gone', 'ag9')
        adapter.kill()
        adapter.wait()
        self.assertEqual(host.call('wait').stdout.splitlines(), ['cancel gone ag9'])

    def test_requests_of_a_limited_account_are_not_offered_to_it(self):
        first, second = FakeHost(self, 'a', 'sess-a'), FakeHost(self, 'b', 'sess-b')
        first.call('register')
        second.call('register')
        request = self.submit('limited')
        (request / 'limited').write_text(str(first.config) + '\n')
        waiting = first.start('wait')
        self.assertEqual(second.call('wait').stdout.splitlines(), ['new limited'])
        time.sleep(0.3)
        self.assertFalse(waiting.finished())
        self.assertEqual(first.call('brief', 'limited').returncode, 3)

    # --- brief / claim

    def test_brief_fields_per_role(self):
        host = FakeHost(self)
        host.call('register')
        expected = {
            'worker': ('campaign-worker', 'opus', 'with the Write tool'),
            'reviewer': ('campaign-reviewer', 'sonnet', 'with Bash'),
            'diagnostician': ('campaign-diagnostician', 'haiku', 'with Bash'),
        }
        models = {'worker': 'opus', 'reviewer': 'claude-sonnet-5-5[1m]', 'diagnostician': 'claude-haiku-4-5'}
        for role, (agent_type, alias, writer) in expected.items():
            request = self.submit(f'r-{role}', role=role, model=models[role], ticket='DCA 001 extra long ticket name')
            result = host.call('brief', f'r-{role}')
            self.assertEqual(result.returncode, 0, result.stderr)
            brief = json.loads(result.stdout)
            self.assertEqual(sorted(brief), ['description', 'effort', 'model', 'prompt', 'run_in_background', 'subagent_type'])
            self.assertEqual((brief['subagent_type'], brief['model'], brief['effort']), (agent_type, alias, 'high'))
            self.assertIs(brief['run_in_background'], True)
            self.assertLessEqual(len(brief['description'].split()), 5)
            self.assertTrue(brief['description'].startswith(role))
            stored = json.loads((request / 'request.json').read_text())
            for needle in (stored['prompt'], stored['result'], stored['schema'], str(request / 'done'), '/work/tree',
                           f'done r-{role}', 'no human', 'run_in_background', writer):
                self.assertIn(needle, brief['prompt'])
            self.assertNotIn('previous attempt', brief['prompt'])
            self.assertTrue((request / 'reserved').exists())

    def test_brief_prepends_the_redispatch_note_after_an_assignment(self):
        host = FakeHost(self)
        host.call('register')
        request = self.submit('again')
        self.assertEqual(host.call('claim', 'again', 'a1').returncode, 0)
        self.assertFalse((request / 'reserved').exists())
        (request / 'assigned').unlink()
        brief = json.loads(host.call('brief', 'again').stdout)
        self.assertTrue(brief['prompt'].startswith('A previous attempt of this role was interrupted. Any uncommitted change '
                                                   'in the worktree is its partial, unverified work'))

    def test_brief_is_exclusive_between_hosts(self):
        first, second = FakeHost(self, 'a', 'sess-a'), FakeHost(self, 'b', 'sess-b')
        first.call('register')
        second.call('register')
        self.submit('contested')
        self.assertEqual(first.call('brief', 'contested').returncode, 0)
        self.assertEqual(first.call('brief', 'contested').returncode, 0)
        lost = second.call('brief', 'contested')
        self.assertEqual(lost.returncode, 3)
        self.assertIn('reserved by another host', lost.stderr)

    def test_brief_of_an_unknown_model_or_missing_request_fails(self):
        host = FakeHost(self)
        host.call('register')
        self.submit('odd', model='gpt-9')
        self.assertEqual(host.call('brief', 'odd').returncode, 1)
        self.assertEqual(host.call('brief', 'nothing').returncode, 3)

    def test_claim_stores_the_transcript_or_its_pattern(self):
        host = FakeHost(self)
        host.call('register')
        request = self.submit('c1')
        host.call('claim', 'c1', 'aaa')
        assigned = json.loads((request / 'assigned').read_text())
        self.assertEqual(sorted(assigned), ['account', 'agent_id', 'at', 'host_pid', 'host_start', 'session_id', 'transcript'])
        self.assertEqual(assigned['transcript'], f'{host.config}/projects/*/sess-a/subagents/agent-aaa.jsonl')
        transcript = host.config / 'projects' / '-work' / 'sess-a' / 'subagents' / 'agent-bbb.jsonl'
        transcript.parent.mkdir(parents=True)
        transcript.write_text('')
        host.call('claim', 'c1', 'bbb')
        self.assertEqual(json.loads((request / 'assigned').read_text())['transcript'], str(transcript))

    # --- the request and the watch (session.py)

    def test_submit_files_the_whole_request_at_once(self):
        request = self.submit('whole', role='reviewer', model='claude-opus-4-1')
        stored = json.loads((request / 'request.json').read_text())
        for field in ('id', 'project', 'ticket', 'role', 'model', 'effort', 'read_only', 'worktree', 'prompt', 'result',
                      'schema', 'created', 'attempt'):
            self.assertIn(field, stored)
        self.assertEqual((stored['id'], stored['role'], stored['model'], stored['read_only'], stored['attempt']),
                         ('whole', 'reviewer', 'claude-opus-4-1', True, 1))
        self.assertEqual(Path(stored['prompt']).read_text(), 'combined prompt\n')
        self.assertEqual(stored['result'], str(request / 'result.json'))
        self.assertEqual([path.name for path in (self.queue / 'requests').iterdir()], ['whole'])
        second = self.submit('whole-2', role='reviewer')
        self.assertEqual(json.loads((second / 'request.json').read_text())['attempt'], 2)

    def assign(self, request, transcript, pid=None, start=None, at=None):
        process = self.sleeper() if pid is None else None
        pid = pid if pid is not None else process.pid
        (request / 'assigned').write_text(json.dumps(
            {'host_pid': pid, 'host_start': start or session.proc_start(pid), 'session_id': 'sess-a', 'account': '/acct/a',
             'agent_id': 'ag1', 'transcript': str(transcript), 'at': at or time.time()}))
        return pid

    def inspect(self, request, idle=600, extra=()):
        result = subprocess.run([sys.executable, str(SESSION), 'inspect', str(request), str(self.root / 'state.json'),
                                 str(idle), *extra], env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    @staticmethod
    def assistant(text=None, tool=None, stop='end_turn', **extra):
        content = []
        if text is not None:
            content.append({'type': 'text', 'text': text})
        if tool:
            content.append({'type': 'tool_use', 'id': tool[0], 'name': tool[1], 'input': tool[2]})
        entry = {'type': 'assistant', 'uuid': f'u-{time.monotonic_ns()}', 'timestamp': '2026-11-02T10:00:00.000Z',
                 'message': {'id': 'm1', 'role': 'assistant', 'model': 'claude-opus-4-1', 'stop_reason': stop,
                             'content': content, 'usage': {'input_tokens': 3, 'output_tokens': 5,
                                                           'cache_read_input_tokens': 7, 'cache_creation_input_tokens': 11}}}
        entry.update(extra)
        return json.dumps(entry)

    def test_inspect_verdicts(self):
        request = self.submit('v1')
        transcript = self.root / 'agent.jsonl'
        self.assertEqual(self.inspect(request)['verdict'], 'unassigned')
        self.assign(request, transcript, pid=999999, start='1')
        self.assertEqual(self.inspect(request)['verdict'], 'host-dead')
        self.assign(request, transcript)
        old = time.time() - 7200
        transcript.write_text(self.assistant(tool=('t1', 'Read', {'file_path': '/x'}), stop='tool_use') + '\n')
        self.assertEqual(self.inspect(request)['verdict'], 'working')
        os.utime(transcript, (old, old))
        (request / 'assigned').unlink()
        self.assign(request, transcript, at=old)
        self.assertEqual(self.inspect(request)['verdict'], 'idle')
        transcript.write_text(self.assistant(text='done v1') + '\n')
        verdict = self.inspect(request)
        self.assertEqual(verdict['verdict'], 'finished')
        limit = {'isApiErrorMessage': True, 'error': 'rate_limit', 'message': {
            'role': 'assistant', 'stop_reason': 'stop_sequence', 'model': '<synthetic>',
            'content': [{'type': 'text', 'text': "You've hit your 5-hour limit"}]}}
        transcript.write_text(self.assistant(text='working') + '\n' + json.dumps(dict(type='assistant', uuid='lim-1', **limit)) + '\n')
        verdict = self.inspect(request)
        self.assertEqual((verdict['verdict'], verdict['limit_id'], verdict['account']), ('limit', 'lim-1', '/acct/a'))
        self.assertIn('5-hour limit', verdict['limit_text'])
        self.assertEqual(self.inspect(request, extra=['--ack-limit', 'lim-1'])['verdict'], 'finished')

    def test_a_limit_is_recognised_by_its_text_alone(self):
        request = self.submit('v2')
        transcript = self.root / 'agent.jsonl'
        self.assign(request, transcript)
        entry = {'type': 'assistant', 'uuid': 'l2', 'isApiErrorMessage': True, 'error': 'unknown',
                 'message': {'role': 'assistant', 'stop_reason': 'stop_sequence', 'content': 'Claude usage limit reached|1700000000'}}
        transcript.write_text(json.dumps(entry) + '\n')
        self.assertEqual(self.inspect(request)['verdict'], 'limit')
        entry['error'] = 'server_error'
        entry['message']['content'] = 'API Error: Connection lost'
        transcript.write_text(json.dumps(entry) + '\n')
        self.assertEqual(self.inspect(request)['verdict'], 'finished')

    def test_a_pending_bash_call_counts_while_its_processes_work(self):
        request = self.submit('busy')
        transcript = self.root / 'agent.jsonl'
        command = 'while :; do sleep 0.05; done # token-4711'
        transcript.write_text(self.assistant(tool=('b1', 'Bash', {'command': command}), stop='tool_use') + '\n')
        old = time.time() - 7200
        os.utime(transcript, (old, old))
        self.assign(request, transcript)
        worker = subprocess.Popen(['nice', '-n', '19', 'bash', '-c', f"eval '{command}' < /dev/null"])
        self.addCleanup(lambda: (worker.kill(), worker.wait()))
        time.sleep(0.3)
        self.assertEqual(self.inspect(request, idle=2)['verdict'], 'working')   # first sample: the baseline
        time.sleep(2.2)
        self.assertEqual(self.inspect(request, idle=2)['verdict'], 'working', 'CPU moved: not idle')
        worker.kill()
        worker.wait()
        self.assertEqual(self.inspect(request, idle=2)['verdict'], 'working')   # activity seen just now
        time.sleep(2.2)
        self.assertEqual(self.inspect(request, idle=2)['verdict'], 'idle')

    def test_usage_sums_each_message_once(self):
        request = self.submit('u1')
        transcript = self.root / 'agent.jsonl'
        self.assign(request, transcript)
        first = self.assistant(text='a')
        second = json.loads(self.assistant(tool=('t', 'Read', {}), stop='tool_use'))
        second['message']['id'] = 'm2'
        second['timestamp'] = '2026-11-02T10:00:30.000Z'
        transcript.write_text(first + '\n' + first + '\n' + json.dumps(second) + '\n')
        out = self.root / 'usage.json'
        subprocess.run([sys.executable, str(SESSION), 'usage', str(request), str(out)], env=self.env, check=True)
        usage = json.loads(out.read_text())
        self.assertEqual(usage, {'provider': 'claude', 'model': 'claude-opus-4-1', 'cost_usd': None, 'input_tokens': 6,
                                 'output_tokens': 10, 'cache_read_tokens': 14, 'cache_creation_tokens': 22, 'num_turns': 2,
                                 'duration_ms': 30000})

    def test_the_timeout_of_a_session_role_is_the_session_maximum(self):
        def timeout(provider, role='worker', **env):
            script = f'die() {{ echo "$*" >&2; exit 1; }}; source {KIT}/lib/provider.sh; provider_timeout_seconds {role} {provider}'
            return subprocess.run(['bash', '-c', script], env=dict(self.env, **env), text=True, capture_output=True)
        for role in ('worker', 'reviewer', 'diagnostician'):
            self.assertEqual(timeout('claude', role, AGENTIC_CLAUDE_MODE='session').stdout.strip(), '604800')
        self.assertEqual(timeout('claude', AGENTIC_CLAUDE_MODE='session', AGENTIC_SESSION_MAX_SECONDS='86400').stdout.strip(), '86400')
        self.assertEqual(timeout('claude', AGENTIC_CLAUDE_MODE='print').stdout.strip(), '3600')
        self.assertEqual(timeout('claude').stdout.strip(), '3600')
        self.assertEqual(timeout('codex', AGENTIC_CLAUDE_MODE='session').stdout.strip(), '3600')
        self.assertNotEqual(timeout('claude', AGENTIC_CLAUDE_MODE='session', AGENTIC_SESSION_MAX_SECONDS='0').returncode, 0)


class RunnerPreflightTests(unittest.TestCase):
    def test_a_run_waits_for_a_host_session_through_the_project_environment(self):
        # The mode comes from project.json env, like in a real project; with no host the runner refuses to start and the
        # queue keeps retrying later.
        queue = tempfile.TemporaryDirectory(prefix='session-queue-')
        self.addCleanup(queue.cleanup)
        repo = Repo(settings={'env': {'AGENTIC_CLAUDE_MODE': 'session', 'AGENTIC_SESSION_DIR': queue.name}})
        self.addCleanup(repo.close)
        repo.init_campaign()
        result = repo.command('run', '--provider', 'claude', '--mode', 'unattended', cwd=repo.worktree, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no live campaign host session on this machine; open one with /campaign-host', result.stderr)
        self.assertIn('provider adapter preflight failed', result.stderr)


if __name__ == '__main__':
    unittest.main()

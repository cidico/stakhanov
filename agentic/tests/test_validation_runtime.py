"""Focused executable validation regressions; no model or service calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

TOOL = Path(__file__).resolve().parents[1] / 'lib/validation.py'

class RuntimeValidationTests(unittest.TestCase):
    def test_scoped_execution_repair_and_sanitized_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = root / 'validation.json'
            runtime = root / 'receipts'
            item = {'cheap': [['sh', '-c', 'echo "(fail) case"; echo password=canary >&2; test -f repaired']],
                    'component': [], 'expensive': [['touch', 'ticket-proof'], ['touch', 'campaign-proof']]}
            plan = {'version': 1, 'tickets': {'TST-001': item}, 'final': [['true']],
                    'campaign_expensive': [['touch', 'campaign-proof']]}
            manifest.write_text(json.dumps(plan))
            def run(phase, ticket='TST-001'):
                return subprocess.run(['python3', str(TOOL), str(root), str(manifest), str(runtime), ticket, phase],
                                      capture_output=True, text=True)
            result = run('cheap')
            self.assertNotEqual(result.returncode, 0)
            proof = json.loads((runtime / 'TST-001.cheap.json').read_text())
            self.assertEqual(proof['status'], 'FAIL')
            self.assertNotIn('canary', json.dumps(proof))
            record = proof['evidence'][0]
            self.assertEqual(record['exitCode'], 1)
            self.assertGreaterEqual(record['durationMs'], 0)
            self.assertTrue(record['failedTests'])
            self.assertNotIn('canary', (runtime / 'logs' / record['stderrLog']).read_text())
            (root / 'repaired').touch()
            self.assertEqual(run('cheap').returncode, 0)
            self.assertEqual(run('component').returncode, 0)
            self.assertEqual(run('expensive').returncode, 0)
            self.assertTrue((root / 'ticket-proof').exists())
            self.assertFalse((root / 'campaign-proof').exists())
            self.assertEqual(run('final', 'campaign').returncode, 0)
            self.assertTrue((root / 'campaign-proof').exists())

    def test_invalid_command_is_never_executed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = root / 'validation.json'
            manifest.write_text(json.dumps({'version': 1, 'tickets': {'TST-001':
                {'cheap': ['touch unwanted'], 'component': [], 'expensive': []}}, 'final': [['true']]}))
            result = subprocess.run(['python3', str(TOOL), str(root), str(manifest), str(root / 'runtime'),
                                     'TST-001', 'cheap'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'unwanted').exists())


class FinalReuseTests(unittest.TestCase):
    """The final validation does not run again a command that passed on the same commit and tree."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tree = self.root / 'tree'
        self.tree.mkdir()
        self.runtime = self.root / 'receipts'
        self.manifest = self.root / 'validation.json'
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'agentic@example.test')
        self.git('config', 'user.name', 'Agentic Test')
        (self.tree / 'tracked.txt').write_text('seed\n')
        self.git('add', 'tracked.txt')
        self.git('commit', '-q', '-m', 'seed')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.tree), *args], capture_output=True, text=True, check=True).stdout.strip()

    def step(self, name, condition='true'):
        return ['sh', '-c', f'echo {name} >> {self.root}/{name}.count; {condition}']

    def runs(self, name):
        path = self.root / f'{name}.count'
        return len(path.read_text().splitlines()) if path.exists() else 0

    def run_phase(self, final, phase='final', ticket='campaign', baseline=None):
        plan = {'version': 1, 'final': final, 'tickets': {'TST-001': {'cheap': final, 'component': [], 'expensive': []}}}
        if baseline is not None:
            plan['baseline'] = baseline
        self.manifest.write_text(json.dumps(plan))
        return subprocess.run(['python3', str(TOOL), str(self.tree), str(self.manifest), str(self.runtime), ticket, phase],
                              capture_output=True, text=True)

    def receipt(self, name='campaign.final.json'):
        return json.loads((self.runtime / name).read_text())

    def failing_run(self, gate):
        """One passed command, then one that fails until the gate file exists."""
        plan = [self.step('one'), self.step('two', f'test -f {gate}')]
        self.assertNotEqual(self.run_phase(plan).returncode, 0)
        return plan

    def test_the_final_receipt_records_the_tip_and_is_saved_after_every_command(self):
        during = self.root / 'during.json'
        result = self.run_phase([self.step('one'), ['cp', str(self.runtime / 'campaign.final.json'), str(during)]])
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = json.loads(during.read_text())
        self.assertEqual((seen['status'], len(seen['evidence']), seen['tip']), ('RUNNING', 1, self.git('rev-parse', 'HEAD')))
        done = self.receipt()
        self.assertEqual((done['status'], done['tip'], len(done['evidence'])), ('PASS', self.git('rev-parse', 'HEAD'), 2))
        self.assertFalse((self.runtime / 'campaign.final.json.previous').exists())
        self.assertIn('campaign final: PASS (2 commands)', result.stdout)

    def test_the_same_commit_reuses_the_passed_commands_and_runs_the_failed_one_again(self):
        gate = self.root / 'gate'
        plan = self.failing_run(gate)
        failed = self.receipt()
        self.assertEqual(failed['status'], 'FAIL')
        gate.touch()
        result = self.run_phase(plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runs('one'), self.runs('two')), (1, 2))
        tip = self.git('rev-parse', 'HEAD')
        command = ' '.join(failed['evidence'][0]['command'])
        self.assertIn(f'campaign final: reusing the PASS of {command} from {failed["evidence"][0]["startedAt"]} '
                      f'(same commit {tip[:9]})\n', result.stdout)
        self.assertIn('campaign final: PASS (2 commands, 1 reused)', result.stdout)
        done = self.receipt()
        self.assertEqual([record.get('reused', False) for record in done['evidence']], [True, False])
        self.assertEqual(done['evidence'][0]['startedAt'], failed['evidence'][0]['startedAt'])
        self.assertEqual(done['evidence'][0]['durationMs'], failed['evidence'][0]['durationMs'])
        # Rotation happens once per run: the receipt the run replaced, not one of its own progressive saves.
        self.assertEqual(self.receipt('campaign.final.json.previous')['status'], 'FAIL')

    def test_the_reuse_line_cuts_a_long_command_to_one_hundred_characters(self):
        gate = self.root / 'gate'
        long = ['sh', '-c', f'echo one >> {self.root}/one.count; # ' + 'x' * 150]
        plan = [long, self.step('two', f'test -f {gate}')]
        self.assertNotEqual(self.run_phase(plan).returncode, 0)
        gate.touch()
        result = self.run_phase(plan)
        line = next(line for line in result.stdout.splitlines() if 'reusing the PASS of' in line)
        shown = line.split('reusing the PASS of ', 1)[1].split(' from ', 1)[0]
        self.assertEqual(shown, ' '.join(long)[:100])
        self.assertEqual(len(shown), 100)

    def test_a_killed_run_keeps_what_passed(self):
        gate = self.root / 'gate'
        plan = [self.step('one'), self.step('two'), self.step('three', f'[ -f {gate} ] || kill -9 $PPID')]
        self.assertNotEqual(self.run_phase(plan).returncode, 0)
        killed = self.receipt()
        self.assertEqual((killed['status'], len(killed['evidence'])), ('RUNNING', 2))
        gate.touch()
        result = self.run_phase(plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runs('one'), self.runs('two'), self.runs('three')), (1, 1, 2))
        self.assertIn('campaign final: PASS (3 commands, 2 reused)', result.stdout)

    def test_another_commit_reuses_nothing(self):
        gate = self.root / 'gate'
        plan = self.failing_run(gate)
        gate.touch()
        (self.tree / 'tracked.txt').write_text('changed\n')
        self.git('commit', '-q', '-am', 'next')
        result = self.run_phase(plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runs('one'), self.runs('two')), (2, 2))
        self.assertNotIn('reusing', result.stdout)

    def test_a_tracked_change_reuses_nothing_and_its_evidence_is_never_reused_later(self):
        gate = self.root / 'gate'
        (self.tree / 'tracked.txt').write_text('edited\n')
        plan = self.failing_run(gate)
        self.assertTrue(self.receipt()['dirty'])
        # Same commit and a dirty tree again: nothing is reused.
        self.assertNotEqual(self.run_phase(plan).returncode, 0)
        self.assertEqual(self.runs('one'), 2)
        # The tree is clean again, but what passed ran on a tree that was not: nothing is reused either.
        (self.tree / 'tracked.txt').write_text('seed\n')
        gate.touch()
        result = self.run_phase(plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.runs('one'), 3)
        self.assertNotIn('reusing', result.stdout)

    def test_an_untracked_file_does_not_stop_the_reuse(self):
        gate = self.root / 'gate'
        plan = self.failing_run(gate)
        (self.tree / 'scratch.txt').write_text('untracked\n')
        gate.touch()
        self.assertEqual(self.run_phase(plan).returncode, 0)
        self.assertEqual(self.runs('one'), 1)

    def test_a_receipt_without_a_tip_reuses_nothing(self):
        gate = self.root / 'gate'
        plan = self.failing_run(gate)
        value = self.receipt()
        del value['tip']
        (self.runtime / 'campaign.final.json').write_text(json.dumps(value))
        gate.touch()
        self.assertEqual(self.run_phase(plan).returncode, 0)
        self.assertEqual(self.runs('one'), 2)

    def test_ticket_phases_and_the_baseline_never_reuse_and_record_no_tip(self):
        plan = [self.step('one')]
        for phase, ticket, name in (('cheap', 'TST-001', 'TST-001.cheap.json'), ('baseline', 'campaign', 'campaign.baseline.json')):
            self.assertEqual(self.run_phase(plan, phase, ticket, baseline=plan).returncode, 0)
            self.assertEqual(self.run_phase(plan, phase, ticket, baseline=plan).returncode, 0)
            self.assertNotIn('tip', self.receipt(name))
            self.assertNotIn('reused', json.dumps(self.receipt(name)))
        self.assertEqual(self.runs('one'), 4)


class DeadlineTests(unittest.TestCase):
    """Every validation command has a deadline; an overdue one is killed with its whole process group."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / 'receipts'
        self.manifest = self.root / 'validation.json'

    def run_plan(self, commands, plan=None, env=None, phase='cheap'):
        value = {'version': 1, 'final': [['true']],
                 'tickets': {'TST-001': {'cheap': commands, 'component': [], 'expensive': []}}}
        value.update(plan or {})
        self.manifest.write_text(json.dumps(value))
        environment = {key: v for key, v in os.environ.items() if not key.startswith('AGENTIC_VALIDATION_')}
        environment.update(env or {})
        return subprocess.run(['python3', str(TOOL), str(self.root), str(self.manifest), str(self.runtime),
                               'TST-001', phase], capture_output=True, text=True, env=environment)

    def receipt(self):
        return json.loads((self.runtime / 'TST-001.cheap.json').read_text())

    def alive(self, pid_file):
        try:
            os.kill(int(pid_file.read_text()), 0)
            return True
        except ProcessLookupError:
            return False

    def wait_gone(self, pid_file):
        end = time.monotonic() + 5
        while self.alive(pid_file) and time.monotonic() < end:
            time.sleep(0.05)
        return not self.alive(pid_file)

    def test_a_command_that_sleeps_past_the_deadline_fails_with_a_timeout_record(self):
        started = time.monotonic()
        result = self.run_plan([['sleep', '60']], env={'AGENTIC_VALIDATION_TIMEOUT_SECONDS': '1'})
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(result.returncode, 4)
        proof = self.receipt()
        record = proof['evidence'][0]
        self.assertEqual((proof['status'], proof['timedOut']), ('FAIL', True))
        self.assertEqual((record['exitCode'], record['timedOut'], record['timeoutSeconds']), (124, True, 1))
        self.assertGreaterEqual(record['durationMs'], 900)
        self.assertLess(record['durationMs'], 20000)
        self.assertRegex(record['summary'], r'^timed out after [0-9.]+ min$')
        self.assertIn('timed out after', proof['reason'])
        self.assertEqual(proof['failed_command'], ['sleep', '60'])

    def test_a_deadline_in_minutes_is_reported_as_minutes(self):
        script = 'import sys; sys.path.insert(0, %r); import validation; ' % str(TOOL.parent) + \
                 'print(validation.minutes_text(7200))'
        out = subprocess.run(['python3', '-I', '-c', script], capture_output=True, text=True).stdout
        self.assertEqual(out.strip(), '120')

    def test_a_command_that_ignores_sigterm_dies_at_sigkill(self):
        pid_file = self.root / 'stubborn.pid'
        script = f'trap "" TERM; echo $$ > {pid_file}; while :; do sleep 1; done'
        started = time.monotonic()
        result = self.run_plan([['bash', '-c', script]], env={'AGENTIC_VALIDATION_TIMEOUT_SECONDS': '1'})
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 4)
        self.assertGreaterEqual(elapsed, 10)  # the grace between SIGTERM and SIGKILL
        self.assertTrue(self.wait_gone(pid_file))
        self.assertEqual(self.receipt()['evidence'][0]['exitCode'], 124)

    def test_a_background_grandchild_dies_with_the_group(self):
        pid_file = self.root / 'grandchild.pid'
        script = f'(sleep 300 & echo $! > {pid_file}; wait) & wait'
        result = self.run_plan([['bash', '-c', script]], env={'AGENTIC_VALIDATION_TIMEOUT_SECONDS': '1'})
        self.assertEqual(result.returncode, 4)
        self.assertTrue(pid_file.exists())
        self.assertTrue(self.wait_gone(pid_file))
        self.assertTrue(self.receipt()['evidence'][0]['timedOut'])

    def test_a_grandchild_holding_the_pipes_cannot_outlive_the_deadline(self):
        pid_file = self.root / 'holder.pid'
        script = f'sleep 300 & echo $! > {pid_file}'  # the shell exits at once, the sleeper keeps stdout open
        started = time.monotonic()
        result = self.run_plan([['bash', '-c', script]], env={'AGENTIC_VALIDATION_TIMEOUT_SECONDS': '1'})
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(result.returncode, 4)
        self.assertTrue(self.wait_gone(pid_file))

    def test_the_precedence_of_the_sources(self):
        def seconds(entry, plan=None, **env):
            return self.deadline(entry, plan or {}, env)
        self.assertEqual(seconds(['true']), 120 * 60)
        self.assertEqual(seconds(['true'], AGENTIC_VALIDATION_TIMEOUT_MINUTES='7'), 7 * 60)
        self.assertEqual(seconds(['true'], {'timeout_minutes': 5}, AGENTIC_VALIDATION_TIMEOUT_MINUTES='7'), 5 * 60)
        self.assertEqual(seconds({'command': ['true'], 'timeout_minutes': 3}, {'timeout_minutes': 5},
                                 AGENTIC_VALIDATION_TIMEOUT_MINUTES='7'), 3 * 60)
        self.assertEqual(seconds({'command': ['true']}, {'timeout_minutes': 5}), 5 * 60)
        self.assertEqual(seconds({'command': ['true'], 'timeout_minutes': 3}, {'timeout_minutes': 5},
                                 AGENTIC_VALIDATION_TIMEOUT_MINUTES='7', AGENTIC_VALIDATION_TIMEOUT_SECONDS='2'), 2)

    def deadline(self, entry, plan, env):
        script = ('import json, sys; sys.path.insert(0, %r); import validation; ' % str(TOOL.parent) +
                  'print(validation.deadline_seconds(json.loads(sys.argv[1]), json.loads(sys.argv[2])))')
        environment = {key: v for key, v in os.environ.items() if not key.startswith('AGENTIC_VALIDATION_')}
        environment.update(env)
        out = subprocess.run(['python3', '-I', '-c', script, json.dumps(entry), json.dumps(plan)],
                             capture_output=True, text=True, env=environment, check=True).stdout
        return float(out)

    def test_the_precedence_holds_in_a_real_run(self):
        # The command's own 1 minute beats the plan's; the seconds override beats both and ends the run quickly.
        result = self.run_plan([{'command': ['sleep', '60'], 'timeout_minutes': 1}], {'timeout_minutes': 2},
                               env={'AGENTIC_VALIDATION_TIMEOUT_SECONDS': '1'})
        self.assertEqual(result.returncode, 4)
        self.assertEqual(self.receipt()['evidence'][0]['timeoutSeconds'], 1)
        result = self.run_plan([{'command': ['true'], 'timeout_minutes': 3}], {'timeout_minutes': 2})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.receipt()['evidence'][0]['timeoutSeconds'], 180)

    def test_the_old_list_form_is_intact(self):
        result = self.run_plan([['sh', '-c', 'echo fine']], {'final': [['true']]})
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.receipt()['evidence'][0]
        self.assertEqual((record['command'], record['exitCode'], record['timedOut']), (['sh', '-c', 'echo fine'], 0, False))
        self.assertEqual(record['timeoutSeconds'], 7200)
        self.assertEqual(record['summary'], 'exit 0')
        # A command that fails on its own keeps its exit code and message.
        result = self.run_plan([['sh', '-c', 'exit 3']])
        self.assertEqual(result.returncode, 4)
        self.assertIn('validation command failed (exit 3)', result.stderr)
        self.assertNotIn('timedOut', self.receipt())

    def test_the_object_form_runs_and_an_unknown_field_is_refused(self):
        result = self.run_plan([{'command': ['sh', '-c', 'echo ok']}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.receipt()['evidence'][0]['command'], ['sh', '-c', 'echo ok'])
        result = self.run_plan([{'command': ['touch', 'unwanted'], 'shell': True}])
        self.assertEqual(result.returncode, 4)
        self.assertIn('unknown field', result.stderr)
        self.assertFalse((self.root / 'unwanted').exists())

    def test_a_bad_timeout_is_refused_before_any_command_runs(self):
        cases = [({'timeout_minutes': '5'}, None), ({'timeout_minutes': 0}, None), ({'timeout_minutes': 1441}, None),
                 ({'timeout_minutes': 1.5}, None), ({'timeout_minutes': True}, None),
                 ({}, {'command': ['touch', 'unwanted'], 'timeout_minutes': '5'}),
                 ({}, {'command': ['touch', 'unwanted'], 'timeout_minutes': -1})]
        for plan, entry in cases:
            with self.subTest(plan=plan, entry=entry):
                result = self.run_plan([entry or ['touch', 'unwanted']], plan)
                self.assertEqual(result.returncode, 4)
                self.assertIn('timeout_minutes must be an integer from 1 to 1440', result.stderr)
                self.assertFalse((self.root / 'unwanted').exists())
        result = self.run_plan([['touch', 'unwanted']], {'timeout_minutes': 1440})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_bad_environment_deadline_is_refused_before_any_command_runs(self):
        for name, value in (('AGENTIC_VALIDATION_TIMEOUT_MINUTES', 'soon'), ('AGENTIC_VALIDATION_TIMEOUT_MINUTES', '0'),
                            ('AGENTIC_VALIDATION_TIMEOUT_SECONDS', 'soon'), ('AGENTIC_VALIDATION_TIMEOUT_SECONDS', '-1')):
            with self.subTest(name=name, value=value):
                result = self.run_plan([['touch', 'unwanted']], env={name: value})
                self.assertEqual(result.returncode, 4)
                self.assertIn(name, result.stderr)
                self.assertFalse((self.root / 'unwanted').exists())

    def test_the_timeout_keeps_what_the_command_printed_and_the_final_receipt_shows_it(self):
        result = self.run_plan([['sh', '-c', 'echo before; sleep 60']], phase='final',
                               env={'AGENTIC_VALIDATION_TIMEOUT_SECONDS': '1'},
                               plan={'final': [['sh', '-c', 'echo before; sleep 60']]})
        self.assertEqual(result.returncode, 4)
        proof = json.loads((self.runtime / 'TST-001.final.json').read_text())
        record = proof['evidence'][0]
        self.assertEqual((proof['status'], record['timedOut'], record['exitCode']), ('FAIL', True, 124))
        self.assertIn('before', (self.runtime / 'logs' / record['stdoutLog']).read_text())


if __name__ == '__main__':
    unittest.main()

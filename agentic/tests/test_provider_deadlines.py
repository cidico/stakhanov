"""Bounded real subprocess proof with local adapters; no model or product tests."""
import json
from pathlib import Path
import subprocess
import time
import unittest

from test_campaign import Repo, ticket


class ProviderDeadlineTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.repo.init_campaign()

    def tearDown(self):
        self.repo.close()

    def hang(self, role, stubborn=False):
        adapter = Path(self.repo.env['AGENTIC_PROVIDER_DIR']) / 'mock/run.sh'
        extra = '''
            if [ "$role" = "$HANG_ROLE" ] && [ "$ticket" = TST-001 ]; then
              printf 'invoked\\n' >> "$DEADLINE_PROOF/invocations"
              if [ "$role" = worker ]; then printf 'partial work\\n' > "$worktree/partial.txt"; fi
              bash -c 'if [ "$STUBBORN" = 1 ]; then trap "" TERM; fi; echo "$BASHPID" > "$DEADLINE_PROOF/child.pid"; exec sleep 120' &
              wait
            fi
        '''
        adapter.write_text(adapter.read_text().replace('status=PASS\n', extra + '\nstatus=PASS\n', 1))
        proof = Path(self.repo.cache.name) / 'deadline-proof'
        proof.mkdir()
        self.repo.env.update(HANG_ROLE=role, DEADLINE_PROOF=str(proof),
                             STUBBORN='1' if stubborn else '0',
                             **{f'AGENTIC_{role.upper()}_TIMEOUT_SECONDS': '1'})
        return proof

    def run_campaign(self):
        return subprocess.run([str(self.repo.binary(self.repo.worktree)), 'run', '--provider', 'mock', '--mode', 'interactive'],
                              cwd=self.repo.worktree, env=self.repo.env, text=True,
                              capture_output=True, timeout=25)

    def assert_child_stopped(self, proof):
        pid = int((proof / 'child.pid').read_text())
        stat = Path(f'/proc/{pid}/stat')
        if stat.exists():
            self.assertEqual(stat.read_text().split(') ', 1)[1].split()[0], 'Z')

    def test_worker_timeout_preserves_partial_work_without_retry_or_foreign_kill(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        proof = self.hang('worker')
        unrelated = subprocess.Popen(['sleep', '120'])
        try:
            started = time.monotonic()
            result = self.run_campaign()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(time.monotonic() - started, 18)
            self.assertIsNone(unrelated.poll())
            self.assert_child_stopped(proof)
        finally:
            unrelated.terminate()
            unrelated.wait()
        self.assertEqual((proof / 'invocations').read_text().splitlines(), ['invoked'])
        worktree = self.repo.worktree.parent / 'TST-001'
        self.assertEqual((worktree / 'partial.txt').read_text(), 'partial work\n')
        state = json.loads(self.repo.command('status', '--json', cwd=self.repo.worktree).stdout)
        self.assertEqual(state['tickets'][0]['status'], 'todo')
        self.assertEqual(state['decisions'], [])
        self.assertIn('provider-timeout', result.stdout)
        self.assertIn('no automatic retry', result.stdout)

    def test_reviewer_timeout_kills_stubborn_child_and_independent_ticket_completes(self):
        self.repo.configure([ticket(collision=('one',)), ticket('TST-002', collision=('two',))])
        self.repo.mock_provider()
        proof = self.hang('reviewer', stubborn=True)
        result = self.run_campaign()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_child_stopped(proof)
        self.assertEqual((proof / 'invocations').read_text().splitlines(), ['invoked'])
        state = json.loads(self.repo.command('status', '--json', cwd=self.repo.worktree).stdout)
        self.assertEqual({x['id']: x['status'] for x in state['tickets']},
                         {'TST-001': 'todo', 'TST-002': 'done'})
        self.assertEqual(state['decisions'], [])
        self.assertTrue((self.repo.worktree.parent / 'TST-001/product-TST-001.txt').exists())
        self.assertFalse((self.repo.worktree / 'product-TST-001.txt').exists())
        self.assertTrue((self.repo.worktree / 'product-TST-002.txt').exists())
        self.assertIn('role=reviewer', result.stdout)
        self.assertIn('provider-timeout', result.stdout)

    def test_zero_deadline_is_rejected_before_worktree_creation(self):
        self.repo.configure([ticket()])
        self.repo.mock_provider()
        self.repo.env['AGENTIC_REVIEWER_TIMEOUT_SECONDS'] = '0'
        result = self.run_campaign()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid reviewer timeout', result.stderr)
        self.assertFalse((self.repo.worktree.parent / 'TST-001').exists())


if __name__ == '__main__':
    unittest.main()

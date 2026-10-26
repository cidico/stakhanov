"""Recover a proposed validation change only after the coordinator adopts it."""
import json
from pathlib import Path
import unittest
import subprocess
import time
from test_campaign import Repo, ticket, CAMPAIGN

class PlanRecoveryTests(unittest.TestCase):
    def review_state(self, repo, worker):
        source = CAMPAIGN.read_text()
        helper = source.split("review_worktree_state() {", 1)[1].split("\nreview_ticket() {", 1)[0]
        script = "review_worktree_state() {" + helper + '\nREPO_ROOT=$1\ncampaign_slug() { printf harness-sample; }\nreview_worktree_state "$2"\n'
        return subprocess.run(["bash", "-c", script, "review-state", str(repo.worktree), str(worker)],
                              check=True, capture_output=True, text=True).stdout

    def test_review_allows_only_coordinator_adopted_plan_updates(self):
        repo = Repo()
        try:
            repo.init_campaign(); repo.configure([ticket()])
            runtime = next(Path(repo.cache.name).rglob('campaign.json')).parent
            worker = runtime / 'worktrees/TST-001'
            repo.git('worktree', 'add', '-b', 'agentic/harness-sample/TST-001', str(worker), 'campaign/harness-sample')
            before = self.review_state(repo, worker)
            relative = Path('campaigns/harness-sample/validation.json')
            plan = json.loads((repo.worktree / relative).read_text())
            plan['tickets']['TST-001']['cheap'].append(['test', '-f', 'README.md'])
            approved = json.dumps(plan)
            (repo.worktree / relative).write_text(approved)
            (worker / relative).write_text(approved)
            self.assertEqual(before, self.review_state(repo, worker))
            (worker / relative).write_text(approved + 'unauthorized')
            self.assertNotEqual(before, self.review_state(repo, worker))
        finally:
            repo.close()

    def test_review_still_detects_product_edits_with_approved_plan(self):
        repo = Repo()
        try:
            repo.init_campaign(); repo.configure([ticket()])
            runtime = next(Path(repo.cache.name).rglob('campaign.json')).parent
            worker = runtime / 'worktrees/TST-001'
            repo.git('worktree', 'add', '-b', 'agentic/harness-sample/TST-001', str(worker), 'campaign/harness-sample')
            before = self.review_state(repo, worker)
            (worker / 'README.md').write_text('unapproved product edit\n')
            self.assertNotEqual(before, self.review_state(repo, worker))
        finally:
            repo.close()

    def test_recovery_uses_coordinator_reviewed_plan(self):
        repo = Repo()
        try:
            repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
            runtime = next(Path(repo.cache.name).rglob('campaign.json')).parent
            worker = runtime / 'worktrees/TST-001'
            repo.git('worktree', 'add', '-b', 'agentic/harness-sample/TST-001', str(worker), 'campaign/harness-sample')
            relative = Path('campaigns/harness-sample/validation.json')
            plan = json.loads((worker / relative).read_text())
            plan['tickets']['TST-001']['cheap'].append(['test', '-f', 'product-TST-001.txt'])
            proposed = json.dumps(plan)
            (worker / relative).write_text(proposed)
            (worker / 'product-TST-001.txt').write_text('preserved implementation\n')
            (repo.worktree / relative).write_text(proposed)
            repo.git('add', str(relative), cwd=repo.worktree)
            repo.git('commit', '-m', 'review validation commands', cwd=repo.worktree)
            repo.command('run', '--provider', 'mock', cwd=repo.worktree)
            state = json.loads(repo.command('status', '--json', cwd=repo.worktree).stdout)
            self.assertEqual(state['tickets'][0]['status'], 'done')
            self.assertEqual((repo.worktree / 'product-TST-001.txt').read_text(), 'preserved implementation\n')
        finally:
            repo.close()

    def test_recover_already_queued_ticket_preserves_delta_and_succeeds(self):
        repo = Repo()
        try:
            repo.init_campaign(); repo.configure([ticket()]); repo.mock_provider()
            runtime = next(Path(repo.cache.name).rglob('campaign.json')).parent
            worker = runtime / 'worktrees/TST-001'
            repo.git('worktree', 'add', '-b', 'agentic/harness-sample/TST-001', str(worker), 'campaign/harness-sample')
            (worker / 'product-TST-001.txt').write_text('preserved integration repair\n')
            for _ in range(2):
                repo.command('recover', 'TST-001', cwd=repo.worktree)
            repo.command('run', '--provider', 'mock', cwd=repo.worktree)
            state = json.loads(repo.command('status', '--json', cwd=repo.worktree).stdout)
            self.assertEqual('done', state['tickets'][0]['status'])
            self.assertEqual('preserved integration repair\n', (repo.worktree / 'product-TST-001.txt').read_text())
        finally:
            repo.close()

    def test_explicit_recovery_retries_same_engine_failure_without_restarting_supervisor(self):
        self.exercise_same_engine_recovery(recovery_succeeds=True)

    def test_unsuccessful_explicit_recovery_does_not_loop_automatically(self):
        self.exercise_same_engine_recovery(recovery_succeeds=False)

    def exercise_same_engine_recovery(self, recovery_succeeds):
        repo = Repo()
        try:
            repo.init_campaign()
            repo.configure([ticket(collision=("one",)), ticket('TST-002', collision=("two",))])
            repo.mock_provider()
            runtime = next(Path(repo.cache.name).rglob('campaign.json')).parent
            recovery_ready = runtime / 'recovery-ready'
            release_other = runtime / 'release-other'
            repo.env.update(MOCK_RECOVERY_READY=str(recovery_ready), MOCK_RELEASE_OTHER=str(release_other),
                            MOCK_RECOVERY_FAIL_AGAIN="0" if recovery_succeeds else "1")
            adapter = Path(repo.cache.name) / 'mock-providers/mock/run.sh'
            script = adapter.read_text()
            script = script.replace('status=PASS\n', 'if [ "$role" = worker ] && [ "$ticket" = TST-001 ]; then printf preserved > "$worktree/product-TST-001.txt"; fi\nif [ "$ticket" = TST-001 ] && { [ ! -f "$MOCK_RECOVERY_READY" ] || [ "$MOCK_RECOVERY_FAIL_AGAIN" = 1 ]; }; then exit 70; fi\nif [ "$role" = worker ] && [ "$ticket" = TST-002 ]; then\n  while [ ! -f "$MOCK_RELEASE_OTHER" ]; do sleep 0.05; done\nfi\nstatus=PASS\n', 1)
            adapter.write_text(script)
            repo.command('run', '--provider', 'mock', '--mode', 'unattended', cwd=repo.worktree)
            events = runtime / 'events/campaign.ndjson'
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                observed = [json.loads(line) for line in events.read_text().splitlines()]
                if any(e['type'] == 'harness-error' and e.get('ticket') == 'TST-001' for e in observed):
                    break
                time.sleep(0.05)
            self.assertTrue(any(e['type'] == 'harness-error' and e.get('ticket') == 'TST-001' for e in observed))
            recovery_ready.touch()
            repo.command('recover', 'TST-001', cwd=repo.worktree)
            release_other.touch()
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                state = json.loads(repo.command('status', '--json', cwd=repo.worktree).stdout)
                if not state['runner']['active']:
                    break
                time.sleep(0.1)
            self.assertFalse(state['runner']['active'])
            self.assertEqual(recovery_succeeds, all(t['status'] == 'done' for t in state['tickets']), state['tickets'])
            observed = [json.loads(line) for line in events.read_text().splitlines()]
            self.assertEqual(2, sum(e['type'] == 'ticket-started' and e.get('ticket') == 'TST-001' for e in observed))
            self.assertEqual(1, sum(e['type'] == 'runner-started' for e in observed))
            if recovery_succeeds:
                self.assertEqual("preserved", (repo.worktree / "product-TST-001.txt").read_text())
        finally:
            if 'release_other' in locals():
                release_other.touch()
            repo.close()

    def test_recover_idle_ticket_while_another_worker_remains_active(self):
        repo = Repo()
        try:
            repo.init_campaign(); repo.configure([ticket(), ticket('TST-002', status='blocked')]); repo.mock_provider()
            runtime = next(Path(repo.cache.name).rglob('campaign.json')).parent
            worker = runtime / 'worktrees/TST-002'
            repo.git('worktree', 'add', '-b', 'agentic/harness-sample/TST-002', str(worker), 'campaign/harness-sample')
            (worker / 'product-TST-002.txt').write_text('preserved recovery\n')
            repo.env.update(MOCK_TRACK_DIR=str(runtime / 'tracking'), MOCK_SLEEP='2')
            repo.command('run', '--provider', 'mock', '--mode', 'unattended', cwd=repo.worktree)
            repo.command('recover', 'TST-002', cwd=repo.worktree)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                state = json.loads(repo.command('status', '--json', cwd=repo.worktree).stdout)
                if not state['runner']['active']:
                    break
                time.sleep(0.1)
            self.assertFalse(state['runner']['active'])
            self.assertTrue(all(t['status'] == 'done' for t in state['tickets']))
            self.assertEqual((repo.worktree / 'product-TST-002.txt').read_text(), 'preserved recovery\n')
        finally:
            repo.close()


if __name__ == '__main__':
    unittest.main()

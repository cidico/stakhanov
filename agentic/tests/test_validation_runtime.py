"""Focused executable validation regressions; no model or service calls."""
import json
from pathlib import Path
import subprocess
import tempfile
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

if __name__ == '__main__':
    unittest.main()

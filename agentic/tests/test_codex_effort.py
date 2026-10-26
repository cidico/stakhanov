"""Exercise real adapter argv construction with a local CLI stub; no model calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class EffortTests(unittest.TestCase):
    def test_campaign_policy_overrides_inherited_medium_and_preserves_model(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(ROOT, root / '.agentic', ignore=shutil.ignore_patterns('tests', '__pycache__'))
            policy_dir = root / 'campaigns/effort-sample'
            policy_dir.mkdir(parents=True)
            policy = Path(temp) / 'codex-effort.json'
            policy.write_text(json.dumps({
                'version': 1, 'allowed_efforts': ['low', 'high'],
                'roles': {'coordinator': 'high', 'worker': 'high', 'reviewer': 'high', 'diagnostician': 'high'},
                'record_process_events': True, 'bounded_connection_retries': True}))
            shutil.copyfile(policy, policy_dir / policy.name)
            subprocess.run(['git', 'init', '-q', '-b', 'campaign/effort-sample', str(root)], check=True)
            binary = root / 'bin'
            binary.mkdir()
            stub = binary / 'codex'
            stub.write_text('#!/usr/bin/env python3\nimport json,os,sys\njson.dump(sys.argv[1:],open(os.environ["CAPTURE"],"w"))\nprint(json.dumps({"type":"local.stub"}))\nsys.exit(19)\n')
            stub.chmod(0o755)
            prompt = root / 'prompt'
            prompt.write_text('Local argument probe only.')
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                       CAPTURE=str(root / 'argv.json'), AGENTIC_CODEX_MODEL='preserved-model',
                       AGENTIC_CODEX_EFFORT='medium', AGENTIC_CODEX_WORKER_EFFORT='medium',
                       AGENTIC_CODEX_REVIEWER_EFFORT='medium', AGENTIC_CODEX_DIAGNOSTICIAN_EFFORT='medium')
            adapter = root / '.agentic/providers/codex/run.sh'
            def invoke(role):
                result = subprocess.run([str(adapter), role, str(root), str(prompt),
                                         str(root / 'result'), str(root / 'events')], env=env, capture_output=True)
                self.assertEqual(result.returncode, 19, result.stderr)
                return json.loads((root / 'argv.json').read_text())
            for role in ('worker', 'reviewer', 'diagnostician'):
                args = invoke(role)
                self.assertIn('model_reasoning_effort="high"', args)
                self.assertLess(args.index('--config'), args.index('exec'))
                self.assertEqual(args[args.index('--model') + 1], 'preserved-model')
                self.assertNotIn('model_reasoning_effort="medium"', args)
                self.assertIn('unbounded_connection_retries', args)
                self.assertEqual(args[args.index('unbounded_connection_retries') - 1], '--disable')
                captured = list(root.glob('events.' + role + '.*.codex.ndjson'))
                self.assertEqual(len(captured), 1)
                self.assertEqual(json.loads(captured[0].read_text()), {'type': 'local.stub'})
                self.assertEqual(captured[0].stat().st_mode & 0o777, 0o600)
            subprocess.run(['git', '-C', str(root), 'symbolic-ref', 'HEAD',
                            'refs/heads/agentic/effort-sample/TST-001'], check=True)
            self.assertIn('model_reasoning_effort="high"', invoke('worker'))
            subprocess.run(['git', '-C', str(root), 'symbolic-ref', 'HEAD',
                            'refs/heads/campaign/unrelated'], check=True)
            before = set(root.glob('events.*.codex.ndjson'))
            unrelated_args = invoke('worker')
            self.assertIn('model_reasoning_effort="medium"', unrelated_args)
            self.assertNotIn('unbounded_connection_retries', unrelated_args)
            self.assertEqual(set(root.glob('events.*.codex.ndjson')), before)
            subprocess.run(['git', '-C', str(root), 'symbolic-ref', 'HEAD',
                            'refs/heads/campaign/effort-sample'], check=True)
            data = json.loads(policy.read_text())
            data['roles']['worker'] = 'medium'
            (policy_dir / policy.name).write_text(json.dumps(data))
            (root / 'argv.json').unlink()
            result = subprocess.run([str(adapter), 'worker', str(root), str(prompt),
                                     str(root / 'result'), str(root / 'events')], env=env, capture_output=True)
            self.assertEqual(result.returncode, 64)
            self.assertFalse((root / 'argv.json').exists())
            data = json.loads(policy.read_text())
            data['bounded_connection_retries'] = 'true'
            (policy_dir / policy.name).write_text(json.dumps(data))
            result = subprocess.run([str(adapter), 'worker', str(root), str(prompt),
                                     str(root / 'result'), str(root / 'events')], env=env, capture_output=True)
            self.assertEqual(result.returncode, 64)
            self.assertFalse((root / 'argv.json').exists())

if __name__ == '__main__':
    unittest.main()

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / 'distribution/public/.github/workflows/publish-server.yml'
if not WORKFLOW.exists():
    WORKFLOW = ROOT / '.github/workflows/publish-server.yml'


class ServerPublicationRetryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='server-publication-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.release = self.root / 'release'
        self.release.mkdir()
        self.assets = {'server.tgz': 'verified library', 'server-starter.tar.gz': 'verified starter',
                       'release-evidence.json': '{}', 'starter-test-receipt.json': '{}'}
        for name in list(self.assets):
            if name.endswith(('.tgz', '.tar.gz')):
                digest = hashlib.sha256(self.assets[name].encode()).hexdigest()
                self.assets[name + '.sha256'] = f'{digest}  {name}\n'
        for name, value in self.assets.items():
            (self.release / name).write_text(value)
        self.state = self.root / 'remote.json'
        self.state.write_text(json.dumps({'draft': True, 'assets': {}}))
        binary = self.root / 'bin'
        binary.mkdir()
        command = binary / 'gh'
        command.write_text('#!/usr/bin/env python3\n' + textwrap.dedent('''
            import json, os, sys
            from pathlib import Path
            state_file = Path(os.environ['MOCK_RELEASE_STATE'])
            state = json.loads(state_file.read_text())
            args = sys.argv[1:]
            action = args[1]
            if action == 'view':
                if '--json' in args:
                    print('\\n'.join(state['assets']))
            elif action == 'download':
                name = args[args.index('--pattern') + 1]
                directory = Path(args[args.index('--dir') + 1])
                (directory / name).write_text(state['assets'][name])
            elif action == 'upload':
                file = Path(args[3])
                assert file.name not in state['assets'], 'must never overwrite assets'
                state['assets'][file.name] = file.read_text()
            elif action == 'edit':
                assert '--draft=false' in args and '--latest=false' in args
                assert len(state['assets']) == 6, 'publish only when all assets exist'
                state['draft'] = False
            else:
                raise AssertionError(action)
            state_file.write_text(json.dumps(state))
        '''))
        command.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                        MOCK_RELEASE_STATE=str(self.state), RELEASE_TAG='server-v0.1.0-alpha.2')
        content = WORKFLOW.read_text()
        section = content.split('      - name: Create release with the verified archive\n', 1)[1]
        body = section.split('        run: |\n', 1)[1]
        lines = []
        for line in body.splitlines():
            if line.strip() and not line.startswith('          '):
                break
            lines.append(line)
        self.script = textwrap.dedent('\n'.join(lines))

    def run_publish(self):
        return subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', self.script],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_partial_upload_is_completed_before_publication(self):
        self.state.write_text(json.dumps({'draft': True, 'assets': {'server.tgz': self.assets['server.tgz']}}))
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(state, {'draft': False, 'assets': self.assets})

    def test_different_existing_asset_blocks_all_uploads(self):
        original = {'draft': True, 'assets': {'starter-test-receipt.json': 'different'}}
        self.state.write_text(json.dumps(original))
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text()), original)

    def test_complete_release_retries_without_overwriting(self):
        original = {'draft': False, 'assets': self.assets}
        self.state.write_text(json.dumps(original))
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), original)


if __name__ == '__main__':
    unittest.main()

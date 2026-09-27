"""Verify real managed commands from non-default paths, including shell quoting."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HookInstallTests(unittest.TestCase):
    def test_실제_설치_경로를_모든_에이전트에_안전하게_등록한다(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "custom data $literal's directory"
            install.mkdir()
            for name in ('install.sh', 'codex-hooks.toml'):
                shutil.copy2(ROOT / 'hooks' / name, install / name)
            (install / 'agent-event-hook.sh').write_text('#!/bin/sh\nprintf "%s" "$1" > "$HOOK_CALL_RESULT"\n')
            (install / 'agent-event-hook.sh').chmod(0o755)
            environment = {'HOME': temporary, 'PATH': os.environ['PATH']}
            for _ in range(2):
                subprocess.run(['bash', str(install / 'install.sh'), '--claude', '--codex', '--devin'],
                               env=environment, capture_output=True, check=True, timeout=20)
            codex = tomllib.loads((root / '.codex/config.toml').read_text())
            commands = []
            for groups in codex['hooks'].values():
                for group in groups:
                    commands.extend((hook['command'], 'codex') for hook in group['hooks'])
            claude = json.loads((root / '.claude/settings.json').read_text())
            devin = json.loads((root / '.config/devin/config.json').read_text())
            for config, source in ((claude, 'claude-code'), (devin, 'devin')):
                for groups in config['hooks'].values():
                    for group in groups:
                        commands.extend((hook['command'], source) for hook in group['hooks'])
            self.assertGreater(len(commands), 10)
            for command, source in commands:
                self.assertIn('custom data', command)
                result = root / 'called'
                subprocess.run(['sh', '-c', command], env={**environment, 'HOOK_CALL_RESULT': str(result)},
                               check=True, capture_output=True, timeout=10)
                self.assertEqual(result.read_text(), source)
            for groups in codex['hooks'].values():
                for group in groups:
                    self.assertEqual(len(group['hooks']), 1)

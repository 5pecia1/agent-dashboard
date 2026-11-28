"""Exercise real hook registration against a rendered server alpha.10 installation."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / 'hooks/install.sh'
LEGACY = (ROOT / 'scripts/tests/fixtures/codex-alpha10.toml').read_bytes()
STATE = b'[features]\r\nhooks = true\r\n\r\n[hooks.state."existing-id"]\r\ntrusted_hash = "test-value"\r\n'
HERDR = {'hooks': [{'type': 'command', 'command': 'herdr hook codex', 'timeout': 5}]}
USER = {'matcher': 'custom', 'hooks': [{'type': 'command', 'command': '/opt/custom/agent-event-hook.sh codex'}]}
OLD = {'hooks': [{'type': 'command', 'command': '/previous/home/.local/share/my-dashboard/hooks/agent-event-hook.sh codex'}]}
SOURCE = {'future': [1, 2], 'hooks': {'Stop': [HERDR, OLD, USER], 'FutureEvent': [USER]}}


class CodexRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.layer = self.home / 'codex layer'
        self.layer.mkdir()
        self.toml = self.layer / 'config.toml'
        self.hooks = self.layer / 'hooks.json'
        self.env = {'PATH': os.environ['PATH'], 'HOME': str(self.home), 'CODEX_HOME': str(self.layer)}

    def install(self, *args):
        return subprocess.run(['bash', str(INSTALL), *(args or ['--codex'])], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def successful(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clean_layer_uses_only_json_and_all_eight_groups(self):
        self.successful()
        self.assertFalse(self.toml.exists())
        registered = json.loads(self.hooks.read_bytes())['hooks']
        self.assertEqual(set(registered), {'SessionStart', 'UserPromptSubmit', 'PermissionRequest',
            'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'})
        self.assertEqual(sum(map(len, registered.values())), 8)
        self.assertEqual([group['matcher'] for group in registered['PreToolUse']],
                         ['request_user_input', 'request_user_input_async'])

    def test_merge_retains_order_and_trust_and_reinstalls_without_writes(self):
        self.toml.write_bytes(STATE + LEGACY)
        self.hooks.write_text(json.dumps(SOURCE))
        self.env.update(CODEX_HOME=str(self.home / 'ignored'), MY_DASHBOARD_CODEX_CONFIG=str(self.toml))
        self.successful()
        self.assertFalse((self.home / 'ignored').exists())
        self.assertEqual(self.toml.read_bytes(), STATE + b'\n\n')
        self.assertEqual(set(tomllib.loads(self.toml.read_text())['hooks']), {'state'})
        registered = json.loads(self.hooks.read_bytes())
        self.assertEqual(registered['future'], SOURCE['future'])
        self.assertEqual(registered['hooks']['FutureEvent'], [USER])
        stop = registered['hooks']['Stop']
        self.assertEqual(len(stop), 3)
        self.assertEqual((stop[0], stop[2]), (HERDR, USER))
        self.assertEqual(shlex.split(stop[1]['hooks'][0]['command']), [str(ROOT / 'hooks/agent-event-hook.sh'), 'codex'])
        self.assertEqual([p.read_bytes() for p in self.layer.glob('config.toml.bak.*')], [STATE + LEGACY])
        previous = {p: p.stat().st_mtime_ns for p in self.layer.iterdir()}
        self.successful()
        self.assertEqual(previous, {p: p.stat().st_mtime_ns for p in self.layer.iterdir()})

    def test_conflicts_are_rejected_before_agent_configuration_changes(self):
        existing = json.dumps(SOURCE).encode()
        cases = [
            (STATE + LEGACY + b'[[hooks.Stop]]\n', existing),
            (STATE + LEGACY.replace(b'type = "command"', b'type = "changed"', 1), existing),
            (STATE + LEGACY + b'# END my-dashboard hooks\n', existing),
            (STATE + LEGACY, b'{"hooks":{},"hooks":{}}'),
            (STATE + LEGACY, b'{invalid'),
            (STATE + LEGACY, b'[]'),
            (STATE + LEGACY, json.dumps({'hooks': {'Stop': [OLD, OLD]}}).encode()),
            (STATE + LEGACY, json.dumps({'hooks': {'Stop': [dict(OLD, timeout=2)]}}).encode()),
        ]
        for toml, hooks in cases:
            with self.subTest(toml_len=len(toml), json_len=len(hooks)):
                self.toml.write_bytes(toml)
                self.hooks.write_bytes(hooks)
                result = self.install('--claude', '--codex')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.toml.read_bytes(), toml)
                self.assertEqual(self.hooks.read_bytes(), hooks)
                self.assertFalse((self.home / '.claude/settings.json').exists())
                self.assertEqual(set(self.layer.iterdir()), {self.toml, self.hooks})

    def test_failure_and_interruption_before_toml_replace_can_retry(self):
        injection = self.home / 'fault'
        injection.mkdir()
        (injection / 'sitecustomize.py').write_text("""
import os
original = os.replace
def replace(src, dst):
    if os.fspath(dst) == os.environ.get('TEST_FAIL_TOML'):
        if os.environ['TEST_FAILURE'] == 'exit':
            os._exit(75)
        raise PermissionError('injected write failure')
    return original(src, dst)
os.replace = replace
""")
        for mode in ('error', 'exit'):
            with self.subTest(mode=mode):
                self.toml.write_bytes(STATE + LEGACY)
                self.hooks.write_text(json.dumps(SOURCE))
                self.env.update(PYTHONPATH=str(injection), TEST_FAIL_TOML=str(self.toml.resolve()), TEST_FAILURE=mode)
                result = self.install()
                del self.env['TEST_FAIL_TOML']
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.toml.read_bytes(), STATE + LEGACY)
                if mode == 'error':
                    self.assertEqual(json.loads(self.hooks.read_text()), SOURCE)
                else:
                    self.assertEqual(len(json.loads(self.hooks.read_text())['hooks']), 8)
                self.successful()
                self.assertEqual(set(tomllib.loads(self.toml.read_text())['hooks']), {'state'})
                self.assertEqual(len(json.loads(self.hooks.read_text())['hooks']['Stop']), 3)

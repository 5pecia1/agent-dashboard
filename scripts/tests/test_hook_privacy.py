"""Inspect actual hook HTTP payloads and offline queues with synthetic secrets."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
CANARY = 'private-content-canary-8094'


class HookPrivacyTests(unittest.TestCase):
    def run_hook(self, name, include=None, aliases=False, offline=False, backlog=False):
        received = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200)
                self.end_headers()

        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as httpd:
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            try:
                with tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    state = directory / 'state'
                    state.mkdir()
                    if backlog:
                        (state / 'spool.ndjson').write_text(json.dumps({
                            'session_id': 'previous', 'message': CANARY, 'raw': CANARY,
                            'project': '/workspace/example', 'host': 'old-host'}) + '\n')
                    environment = {
                        'PATH': os.environ['PATH'], 'HOME': temporary,
                        'MY_DASHBOARD_ENV': str(directory / 'missing-env'),
                        'MY_DASHBOARD_URL': 'http://127.0.0.1:1' if offline else f'http://127.0.0.1:{httpd.server_port}',
                        'MY_DASHBOARD_TOKEN': 'fixture-ingest',
                        'MY_DASHBOARD_STATE_DIR': str(state),
                    }
                    if include is not None:
                        environment['MY_DASHBOARD_INCLUDE_CONTENT'] = str(include)
                    if aliases:
                        environment.update(MY_DASHBOARD_PROJECT_LABEL='public-project',
                                           MY_DASHBOARD_HOST_LABEL='public-host')
                    payload = {'session_id': 'privacy', 'hook_event_name': 'UserPromptSubmit',
                               'cwd': '/workspace/example', 'prompt': CANARY,
                               'tool_input': {'command': CANARY}}
                    args = ['bash', str(ROOT / 'hooks' / name)]
                    if name == 'agent-event-hook.sh':
                        args.append('devin')
                        payload.update(prompt_id='p1', tool_use_id='t1', tool_name='exec')
                    elif name == 'codex-notify.sh':
                        args.append(json.dumps({'thread-id': 'privacy', 'type': 'agent-turn-complete',
                                                'cwd': '/workspace/example', 'last-assistant-message': CANARY}))
                    else:
                        args.extend(['privacy', 'working', CANARY])
                    result = subprocess.run(args, input=json.dumps(payload), env=environment,
                                            cwd=temporary, text=True, capture_output=True, timeout=10)
                    spool = (state / 'spool.ndjson').read_text() if (state / 'spool.ndjson').exists() else ''
            finally:
                httpd.shutdown()
                thread.join()
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        return received, spool

    def test_기본값은_원문과_메시지를_보내지_않는다(self):
        for name in ('agent-event-hook.sh', 'codex-notify.sh', 'send-generic.sh'):
            with self.subTest(name=name):
                payloads, _ = self.run_hook(name)
                self.assertEqual(len(payloads), 1)
                self.assertNotIn(CANARY, json.dumps(payloads))
                self.assertNotIn('raw', payloads[0])
                self.assertIsNone(payloads[0]['message'])
                if name == 'agent-event-hook.sh':
                    self.assertEqual(payloads[0]['prompt_id'], 'p1')

    def test_명시적_선택이면_상세_내용을_보낸다(self):
        for name in ('agent-event-hook.sh', 'codex-notify.sh', 'send-generic.sh'):
            with self.subTest(name=name):
                payloads, _ = self.run_hook(name, include=1)
                self.assertIn(CANARY, json.dumps(payloads))

    def test_기본_오프라인_스풀에도_상세_내용이_없다(self):
        for name in ('agent-event-hook.sh', 'codex-notify.sh', 'send-generic.sh'):
            with self.subTest(name=name):
                _, spool = self.run_hook(name, offline=True)
                self.assertTrue(spool)
                self.assertNotIn(CANARY, spool)

    def test_과거_스풀도_현재_비공개_설정으로_전송한다(self):
        payloads, _ = self.run_hook('agent-event-hook.sh', backlog=True)
        self.assertEqual(len(payloads), 2)
        self.assertNotIn(CANARY, json.dumps(payloads))

    def test_프로젝트와_호스트_별칭을_적용한다(self):
        payloads, _ = self.run_hook('agent-event-hook.sh', aliases=True)
        self.assertEqual(payloads[0]['project'], 'public-project')
        self.assertEqual(payloads[0]['host'], 'public-host')

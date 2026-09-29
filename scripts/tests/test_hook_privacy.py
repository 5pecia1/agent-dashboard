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
# agy 질문 도구 PreToolUse. 질문 문장·선택지·경로에 비밀 표식을 심는다.
ANTIGRAVITY_QUESTION = {
    'conversationId': 'privacy-antigravity', 'workspacePaths': ['/workspace/example'],
    'transcriptPath': f'/tmp/{CANARY}.jsonl', 'stepIdx': 2,
    'toolCall': {'name': 'ask_question',
                 'args': {'questions': [{'question': CANARY, 'options': [CANARY]}]}},
}


class HookPrivacyTests(unittest.TestCase):
    def run_hook(self, name, include=None, aliases=False, offline=False, backlog=False, antigravity=None):
        """antigravity=(event, payload)면 agent-event-hook.sh를 agy처럼 부른다. stdout은 self.last_stdout."""
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
                    if antigravity is not None:
                        event, payload = antigravity
                        args.extend(['antigravity', event])
                    elif name == 'agent-event-hook.sh':
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
        self.last_stdout = result.stdout
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

    # agy는 hook stdout을 JSON 응답으로 읽는다 - stdout에는 응답 한 줄 말고 아무것도 없어야 한다.
    def test_antigravity_stdout은_응답뿐이고_기본값은_원문을_보내지_않는다(self):
        payloads, _ = self.run_hook('agent-event-hook.sh', antigravity=('PreToolUse', ANTIGRAVITY_QUESTION))
        self.assertEqual(self.last_stdout, '{"decision":"ask"}\n')
        self.assertEqual(len(payloads), 1)
        self.assertEqual(payloads[0]['event'], 'UserInputRequest')
        self.assertEqual(payloads[0]['session_id'], 'privacy-antigravity')
        self.assertIsNone(payloads[0]['message'])
        self.assertNotIn('raw', payloads[0])
        self.assertNotIn(CANARY, json.dumps(payloads))

    def test_antigravity_명시적_선택이면_질문_문장을_보낸다(self):
        payloads, _ = self.run_hook('agent-event-hook.sh', include=1,
                                    antigravity=('PreToolUse', ANTIGRAVITY_QUESTION))
        self.assertEqual(self.last_stdout, '{"decision":"ask"}\n')
        self.assertEqual(payloads[0]['message'], CANARY)

    def test_antigravity_오프라인_스풀에도_원문이_없다(self):
        stop = {'conversationId': 'privacy-antigravity', 'workspacePaths': ['/workspace/example'],
                'transcriptPath': f'/tmp/{CANARY}.jsonl', 'fullyIdle': True, 'error': CANARY}
        payloads, spool = self.run_hook('agent-event-hook.sh', offline=True, antigravity=('Stop', stop))
        self.assertEqual(self.last_stdout, '{"decision":""}\n')
        self.assertEqual(payloads, [])
        self.assertIn('"event":"Stop"', spool)
        self.assertNotIn(CANARY, spool)

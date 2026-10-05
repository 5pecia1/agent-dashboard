import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOOKS = ROOT / 'hooks'

spec = importlib.util.spec_from_file_location('herdr_context', HOOKS / 'herdr-context.py')
herdr_context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(herdr_context)

AGENTS = {
    'claude-code': ('claude', 'herdr:claude'),
    'codex': ('codex', 'herdr:codex'),
    'devin': ('devin', 'herdr:devin'),
    'grok': ('grok', 'herdr:grok'),
    'antigravity': ('agy', 'herdr:antigravity_cli'),
}


class FakeHerdr:
    def __init__(self, reply):
        self._reply = reply
        self.requests = []
        self._dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self._dir.name, 'herdr.sock')
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen(5)
        self._listener.settimeout(0.1)
        self._stopped = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stopped.is_set():
            try:
                conn, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                conn.settimeout(5)
                data = b''
                while b'\n' not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                self.requests.append(data)
                reply = self._reply
                if callable(reply):
                    try:
                        request = json.loads(data.split(b'\n', 1)[0]) if data else None
                    except ValueError:
                        request = None
                    reply = reply(request)
                if reply == 'hang':
                    time.sleep(1.0)
                elif reply:
                    conn.sendall(reply)
            except OSError:
                pass
            finally:
                conn.close()

    @property
    def count(self):
        return len(self.requests)

    def close(self):
        self._stopped.set()
        self._listener.close()
        self._thread.join(timeout=2)
        self._dir.cleanup()


def pane_for(source, session_id, **fields):
    agent, reporter = AGENTS[source]
    pane = {
        'agent': agent,
        'agent_session': {'agent': agent, 'source': reporter, 'kind': 'id', 'value': session_id},
        'title': None,
        'label': None,
        'terminal_title_stripped': None,
        'pane_id': 'moved-pane-42',
    }
    pane.update(fields)
    return pane


def pane_reply(pane, request_id=herdr_context.REQUEST_ID):
    return (json.dumps(
        {'id': request_id, 'result': {'type': 'pane_current', 'pane': pane}},
        ensure_ascii=False) + '\n').encode()


def herdr_env(socket_path='', pane_id='pane-7', **extra):
    env = {
        'MY_DASHBOARD_INCLUDE_CONTENT': '1',
        'HERDR_ENV': '1',
        'HERDR_SOCKET_PATH': socket_path,
        'HERDR_PANE_ID': pane_id,
    }
    env.update(extra)
    return env


def dead_port():
    probe = socket.socket()
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


class HerdrHelperTests(unittest.TestCase):
    def test_AGENTS_매핑은_기대한_다섯_소스의_리터럴과_같다(self):
        self.assertEqual(herdr_context.AGENTS, AGENTS)

    def test_모든_지원_소스의_네이티브_세션이_일치하면_제목을_돌려준다(self):
        for source in AGENTS:
            with self.subTest(source=source):
                pane = pane_for(source, 'sess-1', title=' 작업  A ')
                self.assertEqual(herdr_context.title_from_pane(pane, source, 'sess-1'), '작업 A')

    def test_제목_우선순위는_title_label_terminal_title_stripped_순이다(self):
        pane = pane_for('codex', 's1', title='T', label='L', terminal_title_stripped='X')
        self.assertEqual(herdr_context.title_from_pane(pane, 'codex', 's1'), 'T')
        pane = pane_for('codex', 's1', title=None, label='L', terminal_title_stripped='X')
        self.assertEqual(herdr_context.title_from_pane(pane, 'codex', 's1'), 'L')
        pane = pane_for('codex', 's1', title=None, label=None, terminal_title_stripped='X')
        self.assertEqual(herdr_context.title_from_pane(pane, 'codex', 's1'), 'X')
        pane = pane_for('codex', 's1', title='   ', label='L')
        self.assertEqual(herdr_context.title_from_pane(pane, 'codex', 's1'), 'L')
        self.assertIsNone(herdr_context.title_from_pane(pane_for('codex', 's1'), 'codex', 's1'))

    def test_정체성이_하나라도_다르면_제목을_주지_않는다(self):
        good = pane_for('claude-code', 'sess-1', title='작업')
        cases = {
            'pane agent 다름': dict(good, agent='codex'),
            'session agent 다름': dict(good, agent_session={'agent': 'codex', 'source': 'herdr:claude', 'kind': 'id', 'value': 'sess-1'}),
            'reporter 다름': dict(good, agent_session={'agent': 'claude', 'source': 'herdr:other', 'kind': 'id', 'value': 'sess-1'}),
            'kind가 path': dict(good, agent_session={'agent': 'claude', 'source': 'herdr:claude', 'kind': 'path', 'value': '/repo/demo'}),
            'session id 다름': dict(good, agent_session={'agent': 'claude', 'source': 'herdr:claude', 'kind': 'id', 'value': 'other'}),
            'agent_session 없음': dict(good, agent_session=None),
            'agent_session이 dict 아님': dict(good, agent_session='x'),
        }
        for name, pane in cases.items():
            with self.subTest(name=name):
                self.assertIsNone(herdr_context.title_from_pane(pane, 'claude-code', 'sess-1'))
        for name, pane, source, session_id in [
            ('pane이 dict 아님', 'nope', 'claude-code', 'sess-1'),
            ('알 수 없는 source', good, 'generic', 'sess-1'),
        ]:
            with self.subTest(name=name):
                self.assertIsNone(herdr_context.title_from_pane(pane, source, session_id))
        for name, session_id in [('session_id unknown', 'unknown'), ('session_id 빈 문자열', ''), ('session_id None', None)]:
            with self.subTest(name=name):
                self.assertIsNone(herdr_context.title_from_pane(good, 'claude-code', session_id))

    def test_제목_정규화_공백_제어문자_한글_120코드포인트(self):
        n = herdr_context.normalize_title
        self.assertEqual(n('  a\n b \t c  '), 'a b c')
        self.assertEqual(n('알림\x07그룹 제목'), '알림그룹 제목')
        self.assertEqual(n('한글 제목'), '한글 제목')
        self.assertEqual(n('\U00010400' * 121), '\U00010400' * 120)
        self.assertIsNone(n('   '))
        self.assertIsNone(n(123))
        self.assertIsNone(n(None))

    def test_lookup_title_성공_요청과_응답_계약(self):
        fake = FakeHerdr(lambda _req: pane_reply(pane_for('devin', 'sess-9', title='Devin 작업')))
        try:
            env = herdr_env(socket_path=fake.path)
            self.assertEqual(herdr_context.lookup_title('devin', 'sess-9', env), 'Devin 작업')
            self.assertEqual(fake.count, 1)
            request = json.loads(fake.requests[0].split(b'\n', 1)[0])
            self.assertEqual(request, {
                'id': 'my-dashboard-title',
                'method': 'pane.current',
                'params': {'caller_pane_id': 'pane-7'},
            })
        finally:
            fake.close()

    def test_lookup_title_게이트가_꺼져_있으면_소켓에_절대_닿지_않는다(self):
        fake = FakeHerdr(pane_reply(pane_for('codex', 's1', title='t')))
        try:
            gated = [
                herdr_env(socket_path=fake.path, MY_DASHBOARD_INCLUDE_CONTENT='0'),
                herdr_env(socket_path=fake.path, HERDR_ENV='0'),
                {k: v for k, v in herdr_env(socket_path=fake.path).items() if k != 'HERDR_SOCKET_PATH'},
                {k: v for k, v in herdr_env(socket_path=fake.path).items() if k != 'HERDR_PANE_ID'},
            ]
            for env in gated:
                self.assertIsNone(herdr_context.lookup_title('codex', 's1', env))
            self.assertIsNone(herdr_context.lookup_title('generic', 's1', herdr_env(socket_path=fake.path)))
            self.assertIsNone(herdr_context.lookup_title('codex', 'unknown', herdr_env(socket_path=fake.path)))
            self.assertEqual(fake.count, 0)
        finally:
            fake.close()

    def test_lookup_title_이상_응답은_전부_None(self):
        pane = pane_for('codex', 's1', title='t')
        replies = {
            '다른 id': pane_reply(pane, request_id='someone-else'),
            'dict 아님': b'["x"]\n',
            'result type 다름': (json.dumps({'id': herdr_context.REQUEST_ID, 'result': {'type': 'other'}}) + '\n').encode(),
            '잘못된 JSON': b'{oops\n',
            '개행 없이 끊김': json.dumps({'id': herdr_context.REQUEST_ID, 'result': {'type': 'pane_current', 'pane': pane}}).encode(),
            '즉시 끊김': None,
            '64KB 초과': b'x' * (herdr_context.MAX_RESPONSE_BYTES + 1000),
        }
        for name, reply in replies.items():
            with self.subTest(name=name):
                fake = FakeHerdr(reply)
                try:
                    self.assertIsNone(herdr_context.lookup_title('codex', 's1', herdr_env(socket_path=fake.path)))
                finally:
                    fake.close()

    def test_lookup_title_응답이_멈추면_시간_예산_안에_None으로_돌아온다(self):
        fake = FakeHerdr('hang')
        try:
            start = time.monotonic()
            result = herdr_context.lookup_title('codex', 's1', herdr_env(socket_path=fake.path))
            elapsed = time.monotonic() - start
            self.assertIsNone(result)
            self.assertLess(elapsed, 1.0)
        finally:
            fake.close()

    def test_없는_소켓_경로도_None이다(self):
        self.assertIsNone(herdr_context.lookup_title('codex', 's1', herdr_env(socket_path='/nonexistent/herdr.sock')))


def _http_server():
    received = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200)
            self.end_headers()

    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd, thread, received


def _base_env(directory, port):
    return {
        'PATH': os.environ['PATH'],
        'HOME': str(directory),
        'MY_DASHBOARD_ENV': str(directory / 'missing-env'),
        'MY_DASHBOARD_URL': f'http://127.0.0.1:{port}',
        'MY_DASHBOARD_TOKEN': 'fixture-ingest',
        'MY_DASHBOARD_STATE_DIR': str(directory / 'state'),
    }


class HookHerdrTests(unittest.TestCase):
    def run_hook(self, name, args=(), stdin=None, env=None, cwd=None, state_dir=None, timeout=10):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)
        state = state_dir or (directory / 'state')
        state.mkdir(exist_ok=True)
        httpd, thread, received = _http_server()
        self.addCleanup(lambda: (httpd.shutdown(), thread.join(), httpd.server_close()))
        environment = _base_env(directory, httpd.server_port)
        environment['MY_DASHBOARD_STATE_DIR'] = str(state)
        environment.update(env or {})
        result = subprocess.run(
            ['bash', str(cwd or (HOOKS / name)), *args],
            input=stdin, env=environment, cwd=directory, text=True,
            capture_output=True, timeout=timeout)
        spool = (state / 'spool.ndjson').read_text() if (state / 'spool.ndjson').exists() else ''
        self.assertEqual(result.returncode, 0)
        return received, spool, result, state

    def claude_stdin(self, session_id='sess-1', event='UserPromptSubmit', **extra):
        payload = {'session_id': session_id, 'hook_event_name': event, 'cwd': '/repo/demo'}
        payload.update(extra)
        return json.dumps(payload)

    def test_지원하는_모든_소스가_Herdr_제목을_이벤트에_실어_보낸다(self):
        cases = {
            'claude-code': (['claude-code'], self.claude_stdin('s-claude'), {}),
            'codex': (['codex'], self.claude_stdin('s-codex'), {}),
            'devin': (['devin'], self.claude_stdin('s-devin'), {}),
            'grok': (['claude-code'], json.dumps({'sessionId': 's-grok', 'hook_event_name': 'UserPromptSubmit', 'cwd': '/repo/demo'}), {'GROK_HOOK_EVENT': 'UserPromptSubmit'}),
            'antigravity': (['antigravity', 'PreInvocation'],
                            json.dumps({'conversationId': 's-agy', 'workspacePaths': ['/repo/demo'],
                                        'invocationNum': 0, 'initialNumSteps': 3}), {}),
        }
        for source, (args, stdin, extra) in cases.items():
            with self.subTest(source=source):
                session_id = f's-{source.split("-")[0]}' if source != 'antigravity' else 's-agy'
                fake = FakeHerdr(lambda _r, s=source, i=session_id: pane_reply(pane_for(s, i, title='작업 A')))
                try:
                    env = herdr_env(socket_path=fake.path, **extra)
                    received, _spool, result, _state = self.run_hook('agent-event-hook.sh', args=args, stdin=stdin, env=env)
                    self.assertEqual(fake.count, 1)
                    self.assertEqual(len(received), 1)
                    self.assertEqual(received[0]['display_title'], '작업 A')
                    self.assertEqual(received[0]['source'], source)
                    self.assertEqual(received[0]['session_id'], session_id)
                    self.assertEqual(received[0]['event'], 'UserPromptSubmit')
                finally:
                    fake.close()

    def test_codex_notify_fallback도_제목을_실어_보낸다(self):
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('codex', 'thread-9', title='notify 작업')))
        try:
            notify = json.dumps({'thread-id': 'thread-9', 'type': 'agent-turn-complete', 'cwd': '/repo/demo'})
            received, _spool, _result, _state = self.run_hook(
                'codex-notify.sh', args=[notify], env=herdr_env(socket_path=fake.path))
            self.assertEqual(fake.count, 1)
            self.assertEqual(received[0]['display_title'], 'notify 작업')
            self.assertEqual(received[0]['source'], 'codex')
            self.assertEqual(received[0]['session_id'], 'thread-9')
        finally:
            fake.close()

    def test_env_파일의_opt_in도_제목을_실어_보낸다(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)
        env_file = directory / 'env'
        env_file.write_text('MY_DASHBOARD_INCLUDE_CONTENT=1\n')
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('claude-code', 'sess-1', title='파일 opt-in 작업')))
        try:
            env = herdr_env(socket_path=fake.path, MY_DASHBOARD_ENV=str(env_file))
            env.pop('MY_DASHBOARD_INCLUDE_CONTENT')
            received, _spool, _result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(), env=env)
            self.assertEqual(fake.count, 1)
            self.assertEqual(received[0]['display_title'], '파일 opt-in 작업')
        finally:
            fake.close()

    def test_pane_정체성이_다르면_제목만_빠지고_원래_이벤트는_그대로다(self):
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('claude-code', 'someone-else', title='남의 작업')))
        try:
            received, _spool, _result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'],
                stdin=self.claude_stdin('sess-1', prompt='원래 프롬프트'),
                env=herdr_env(socket_path=fake.path))
            self.assertEqual(fake.count, 1)
            self.assertEqual(len(received), 1)
            self.assertNotIn('display_title', received[0])
            self.assertEqual(received[0]['message'], '원래 프롬프트')
            self.assertEqual(received[0]['project'], '/repo/demo')
            self.assertEqual(received[0]['source'], 'claude-code')
        finally:
            fake.close()

    def test_콘텐츠_opt_in이_없으면_Herdr를_조회하지_않고_제목도_없다(self):
        fake = FakeHerdr(pane_reply(pane_for('claude-code', 'sess-1', title='작업 A')))
        try:
            received, _spool, _result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(),
                env={'HERDR_ENV': '1', 'HERDR_SOCKET_PATH': fake.path, 'HERDR_PANE_ID': 'pane-7'})
            self.assertEqual(fake.count, 0)
            self.assertNotIn('display_title', received[0])
            self.assertIsNone(received[0]['message'])
        finally:
            fake.close()

    def test_HERDR_ENV가_없으면_조회하지_않는다(self):
        fake = FakeHerdr(pane_reply(pane_for('claude-code', 'sess-1', title='작업 A')))
        try:
            received, _spool, _result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(),
                env={'MY_DASHBOARD_INCLUDE_CONTENT': '1',
                     'HERDR_SOCKET_PATH': fake.path, 'HERDR_PANE_ID': 'pane-7'})
            self.assertEqual(fake.count, 0)
            self.assertNotIn('display_title', received[0])
        finally:
            fake.close()

    def test_Herdr가_죽어_있어도_원래_이벤트는_그대로_간다(self):
        received, _spool, _result, _state = self.run_hook(
            'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(),
            env=herdr_env(socket_path='/nonexistent/herdr.sock'))
        self.assertEqual(len(received), 1)
        self.assertNotIn('display_title', received[0])
        self.assertEqual(received[0]['event'], 'UserPromptSubmit')

    def test_헬퍼_파일이_없어도_원래_이벤트는_그대로_간다(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)
        lonely = directory / 'agent-event-hook.sh'
        shutil.copy(HOOKS / 'agent-event-hook.sh', lonely)
        received, _spool, _result, _state = self.run_hook(
            'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(),
            env=herdr_env(socket_path='/nonexistent.sock'), cwd=lonely)
        self.assertEqual(len(received), 1)
        self.assertNotIn('display_title', received[0])

    def test_python3가_없어도_원래_이벤트는_그대로_간다(self):
        if shutil.which('jq') is None or shutil.which('curl') is None:
            self.skipTest('jq/curl이 없으면 이 테스트는 훅 자체를 돌릴 수 없다')
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)
        fakebin = directory / 'bin'
        fakebin.mkdir()
        for cmd in ('bash', 'jq', 'curl', 'cat', 'date', 'hostname', 'mkdir', 'stat', 'tail',
                    'head', 'wc', 'tr', 'mv', 'rm', 'sleep', 'ps', 'iconv', 'dirname', 'find', 'sed', 'awk'):
            found = shutil.which(cmd)
            if found:
                os.symlink(found, fakebin / cmd)
        fake = FakeHerdr(pane_reply(pane_for('claude-code', 'sess-1', title='작업 A')))
        try:
            env = herdr_env(socket_path=fake.path)
            env['PATH'] = str(fakebin)
            received, _spool, result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(), env=env)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(fake.count, 0)
            self.assertEqual(len(received), 1)
            self.assertNotIn('display_title', received[0])
        finally:
            fake.close()

    def test_Herdr_응답이_멈춰도_훅은_exit0이고_이벤트를_보낸다(self):
        fake = FakeHerdr('hang')
        try:
            start = time.monotonic()
            received, _spool, result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(),
                env=herdr_env(socket_path=fake.path))
            elapsed = time.monotonic() - start
            self.assertEqual(result.returncode, 0)
            self.assertLess(elapsed, 5.0)
            self.assertEqual(len(received), 1)
            self.assertNotIn('display_title', received[0])
        finally:
            fake.close()

    def test_하트비트가_스로틀되면_Herdr를_조회하지_않는다(self):
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('claude-code', 'sess-hb', title='작업 A')))
        try:
            directory = Path(tempfile.mkdtemp())
            self.addCleanup(shutil.rmtree, directory, True)
            state = directory / 'state'
            state.mkdir()
            env = herdr_env(socket_path=fake.path)
            stdin = self.claude_stdin('sess-hb', event='PostToolUse')
            received1, _s, _r, _ = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=stdin, env=env, state_dir=state)
            received2, _s, _r, _ = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=stdin, env=env, state_dir=state)
            self.assertEqual(len(received1), 1)
            self.assertEqual(len(received2), 0)
            self.assertEqual(fake.count, 1)
        finally:
            fake.close()

    def test_antigravity에서_버려지는_이벤트는_Herdr를_조회하지_않고_stdout도_그대로다(self):
        fake = FakeHerdr(pane_reply(pane_for('antigravity', 's-agy', title='작업 A')))
        try:
            stdin = json.dumps({'conversationId': 's-agy', 'workspacePaths': ['/repo/demo'],
                                'toolCall': {'name': 'run_command', 'args': {}}})
            received, _spool, result, _state = self.run_hook(
                'agent-event-hook.sh', args=['antigravity', 'PreToolUse'], stdin=stdin,
                env=herdr_env(socket_path=fake.path))
            self.assertEqual(result.stdout, '{"decision":"ask"}\n')
            self.assertEqual(fake.count, 0)
            self.assertEqual(len(received), 0)
        finally:
            fake.close()

    def test_antigravity_stdout은_제목을_실어_보낼_때도_응답_한_줄뿐이다(self):
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('antigravity', 's-agy', title='작업 A')))
        try:
            stdin = json.dumps({'conversationId': 's-agy', 'workspacePaths': ['/repo/demo'],
                                'invocationNum': 0, 'initialNumSteps': 3})
            received, _spool, result, _state = self.run_hook(
                'agent-event-hook.sh', args=['antigravity', 'PreInvocation'], stdin=stdin,
                env=herdr_env(socket_path=fake.path))
            self.assertEqual(result.stdout, '{}\n')
            self.assertEqual(received[0]['display_title'], '작업 A')
        finally:
            fake.close()

    def test_밀린_스풀의_제목은_캡처된_그_시점_값이_유지된다(self):
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('claude-code', 'sess-1', title='새 이름')))
        try:
            directory = Path(tempfile.mkdtemp())
            self.addCleanup(shutil.rmtree, directory, True)
            state = directory / 'state'
            state.mkdir()
            backlog = {'protocol_version': 1, 'source': 'claude-code', 'session_id': 'sess-1',
                       'project': '/repo/demo', 'event': 'UserPromptSubmit', 'host': 'old-host',
                       'event_id': 'old-1', 'occurred_at': 1, 'message': 'old msg',
                       'display_title': '캡처된 옛 제목', 'raw': '{"x":1}'}
            (state / 'spool.ndjson').write_text(json.dumps(backlog, ensure_ascii=False) + '\n')
            received, _spool, _result, _state = self.run_hook(
                'agent-event-hook.sh', args=['claude-code'], stdin=self.claude_stdin(),
                env=herdr_env(socket_path=fake.path), state_dir=state)
            self.assertEqual(len(received), 2)
            self.assertEqual(received[0]['display_title'], '캡처된 옛 제목')
            self.assertEqual(received[1]['display_title'], '새 이름')
        finally:
            fake.close()

    def test_opt_out이면_밀린_스풀의_제목과_원문도_벗겨_낸다(self):
        cases = {
            'agent-event-hook.sh': (['claude-code'], self.claude_stdin(), 'claude-code', 'sess-1'),
            'codex-notify.sh': ([json.dumps({'thread-id': 'thread-9', 'type': 'agent-turn-complete', 'cwd': '/repo/demo'})],
                                None, 'codex', 'thread-9'),
            'send-generic.sh': (['gen-1', 'working', 'hello'], None, 'generic', 'gen-1'),
        }
        for name, (args, stdin, source, session_id) in cases.items():
            with self.subTest(hook=name):
                fake = FakeHerdr(pane_reply(pane_for('codex', session_id, title='작업 A')))
                try:
                    directory = Path(tempfile.mkdtemp())
                    self.addCleanup(shutil.rmtree, directory, True)
                    state = directory / 'state'
                    state.mkdir()
                    backlog = {'protocol_version': 1, 'source': source, 'session_id': session_id,
                               'project': '/repo/demo', 'event': 'UserPromptSubmit', 'host': 'old-host',
                               'event_id': 'old-1', 'occurred_at': 1,
                               'message': 'private-msg', 'display_title': 'private-title', 'raw': '{"secret":1}'}
                    (state / 'spool.ndjson').write_text(json.dumps(backlog) + '\n')
                    received, _spool, _result, _state = self.run_hook(
                        name, args=args, stdin=stdin,
                        env={'HERDR_ENV': '1', 'HERDR_SOCKET_PATH': fake.path, 'HERDR_PANE_ID': 'pane-7'},
                        state_dir=state)
                    self.assertEqual(fake.count, 0)
                    self.assertGreaterEqual(len(received), 1)
                    for payload in received:
                        self.assertNotIn('display_title', payload)
                        self.assertNotIn('raw', payload)
                        self.assertIsNone(payload['message'])
                finally:
                    fake.close()

    def test_opt_out에서_전송_실패로_쌓이는_스풀도_제목과_원문이_없다(self):
        fake = FakeHerdr(pane_reply(pane_for('claude-code', 'sess-1', title='작업 A')))
        try:
            directory = Path(tempfile.mkdtemp())
            self.addCleanup(shutil.rmtree, directory, True)
            state = directory / 'state'
            state.mkdir()
            environment = _base_env(directory, dead_port())
            environment['MY_DASHBOARD_STATE_DIR'] = str(state)
            environment.update({
                'HERDR_ENV': '1', 'HERDR_SOCKET_PATH': fake.path, 'HERDR_PANE_ID': 'pane-7',
            })
            result = subprocess.run(
                ['bash', str(HOOKS / 'agent-event-hook.sh'), 'claude-code'],
                input=self.claude_stdin(prompt='private prompt'), env=environment,
                cwd=directory, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            lines = [json.loads(line) for line in (state / 'spool.ndjson').read_text().splitlines() if line.strip()]
            self.assertEqual(len(lines), 1)
            self.assertNotIn('display_title', lines[0])
            self.assertNotIn('raw', lines[0])
            self.assertIsNone(lines[0]['message'])
            self.assertEqual(fake.count, 0)
        finally:
            fake.close()

    def test_generic은_스스로_제목을_조회하지_않는다(self):
        fake = FakeHerdr(pane_reply(pane_for('codex', 'gen-1', title='작업 A')))
        try:
            received, _spool, result, _state = self.run_hook(
                'send-generic.sh', args=['gen-1', 'working', 'hello'],
                env=herdr_env(socket_path=fake.path))
            self.assertEqual(result.returncode, 0)
            self.assertEqual(fake.count, 0)
            self.assertEqual(len(received), 1)
            self.assertNotIn('display_title', received[0])
            self.assertEqual(received[0]['state'], 'working')
        finally:
            fake.close()


    def grok_stop_stdin(self, session_id='s-grok', **extra):
        payload = {
            'hookEventName': 'stop',
            'hook_event_name': 'Stop',
            'sessionId': session_id,
            'session_id': session_id,
            'cwd': '/repo/demo',
        }
        payload.update(extra)
        return json.dumps(payload)

    def run_grok_stop(self, stdin, env):
        return self.run_hook(
            'agent-event-hook.sh', args=['claude-code'], stdin=stdin,
            env={'GROK_HOOK_EVENT': 'Stop', **env})

    def test_grok의_Stop_본문은_마지막_어시스턴트_메시지다(self):
        received, _spool, _result, _state = self.run_grok_stop(
            self.grok_stop_stdin(lastAssistantMessage='DASHBOARD_HERDR_QA_OK'),
            {'MY_DASHBOARD_INCLUDE_CONTENT': '1'})
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0]['source'], 'grok')
        self.assertEqual(received[0]['event'], 'Stop')
        self.assertEqual(received[0]['message'], 'DASHBOARD_HERDR_QA_OK')

    def test_grok의_camel_본문은_opt_out이면_지워진다(self):
        received, _spool, _result, _state = self.run_grok_stop(
            self.grok_stop_stdin(lastAssistantMessage='DASHBOARD_HERDR_QA_OK'), {})
        self.assertEqual(len(received), 1)
        self.assertIsNone(received[0]['message'])

    def test_grok의_camel_본문과_Herdr_제목은_같이_온다(self):
        fake = FakeHerdr(lambda _r: pane_reply(pane_for('grok', 's-grok', title='작업 A')))
        try:
            received, _spool, _result, _state = self.run_grok_stop(
                self.grok_stop_stdin(lastAssistantMessage='본문'),
                herdr_env(socket_path=fake.path))
            self.assertEqual(received[0]['display_title'], '작업 A')
            self.assertEqual(received[0]['message'], '본문')
        finally:
            fake.close()

    def test_snake_필드가_둘_다_있으면_snake가_이긴다(self):
        received, _spool, _result, _state = self.run_grok_stop(
            self.grok_stop_stdin(last_assistant_message='snake 본문',
                                 lastAssistantMessage='camel 본문'),
            {'MY_DASHBOARD_INCLUDE_CONTENT': '1'})
        self.assertEqual(received[0]['message'], 'snake 본문')

    def test_claude_code는_grok_전용_camel_필드를_읽지_않는다(self):
        received, _spool, _result, _state = self.run_hook(
            'agent-event-hook.sh', args=['claude-code'],
            stdin=self.claude_stdin(lastAssistantMessage='camel 본문'),
            env={'MY_DASHBOARD_INCLUDE_CONTENT': '1'})
        self.assertEqual(len(received), 1)
        self.assertIsNone(received[0]['message'])

    def test_grok의_camel_본문도_300자에서_자른다(self):
        received, _spool, _result, _state = self.run_grok_stop(
            self.grok_stop_stdin(lastAssistantMessage='가' * 350),
            {'MY_DASHBOARD_INCLUDE_CONTENT': '1'})
        self.assertEqual(received[0]['message'], '가' * 300)


if __name__ == '__main__':
    unittest.main()

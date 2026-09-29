"""Run real hooks against a local capture server to verify spool lock portability and cleanup."""
import http.server
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOOKS = ('agent-event-hook.sh', 'codex-notify.sh', 'send-generic.sh')

# 실제 stat 대신 PATH 앞에 두는 가짜 stat. mtime은 파이썬으로 읽는다(macOS에는 GNU stat이 없다).
# GNU: `-f`는 --file-system이라 파일시스템 정보를 stdout 여러 줄에 찍고 실패하고, `-c %Y`만 mtime을 준다.
# 그 여러 줄이 산술식에 들어가 stale 락이 영영 안 지워졌던 것이 원래 버그다.
# BSD: `-f %m`만 mtime을 주고 `-c`는 사용법 오류로 끝난다.
FAKE_STAT = '''#!/bin/sh
mtime() {{ {python} -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }}
case "{flavor}:$1" in
  gnu:-f)
    printf '  File: "%s"\\n    ID: 8d9d1a8b3f7e2c11 Namelen: 255     Type: overlayfs\\n' "$2"
    printf 'Block size: 4096\\n'
    exit 1 ;;
  gnu:-c) mtime "$3" ;;
  bsd:-f) mtime "$3" ;;
  bsd:-c) echo "stat: illegal option -- c" >&2; exit 1 ;;
  *) exit 1 ;;
esac
'''


class Capture:
    """수신한 payload를 모으는 로컬 서버. stall_first면 첫 요청을 받은 뒤 응답을 오래 붙잡는다."""

    def __init__(self, stall_first=False):
        self.received = []
        self.first_request = threading.Event()
        self.release = threading.Event()
        capture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                capture.received.append(body)
                if stall_first and not capture.first_request.is_set():
                    capture.first_request.set()
                    capture.release.wait(10)
                self.send_response(200)
                self.end_headers()

        self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.release.set()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()

    @property
    def url(self):
        return f'http://127.0.0.1:{self.httpd.server_port}'


class HookLockTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.state = self.directory / 'state'
        self.state.mkdir()
        self.spool = self.state / 'spool.ndjson'
        self.lock = self.state / 'spool.lock'

    def fake_stat_path(self, flavor):
        """가짜 stat을 담은 디렉터리를 PATH 맨 앞에 붙인 값을 돌려준다."""
        bin_dir = self.directory / f'bin-{flavor}'
        bin_dir.mkdir(exist_ok=True)
        script = bin_dir / 'stat'
        script.unlink(missing_ok=True)
        script.write_text(FAKE_STAT.format(python=sys.executable, flavor=flavor))
        script.chmod(script.stat().st_mode | stat.S_IEXEC)
        return f'{bin_dir}{os.pathsep}{os.environ["PATH"]}'

    def seed_spool(self):
        self.spool.write_text(json.dumps({
            'session_id': 'previous', 'event': 'UserPromptSubmit', 'source': 'generic', 'state': 'working',
            'project': '/workspace/example', 'host': 'old-host', 'protocol_version': 1,
            'event_id': 'previous-1-a', 'occurred_at': 1}) + '\n')

    def make_lock(self, age_seconds):
        # 앞선 하위 테스트가 실패해 락을 남겨도 다음 케이스가 영향받지 않게 비우고 시작한다.
        if self.lock.exists():
            self.lock.rmdir()
        self.lock.mkdir()
        past = time.time() - age_seconds
        os.utime(self.lock, (past, past))

    def command(self, name):
        args = ['bash', str(ROOT / 'hooks' / name)]
        payload = {'session_id': 'current', 'hook_event_name': 'UserPromptSubmit', 'cwd': '/workspace/example'}
        if name == 'codex-notify.sh':
            args.append(json.dumps({'thread-id': 'current', 'type': 'agent-turn-complete',
                                    'cwd': '/workspace/example'}))
        elif name == 'send-generic.sh':
            args.extend(['current', 'working'])
        return args, json.dumps(payload)

    def environment(self, url, path=None):
        return {'PATH': path or os.environ['PATH'], 'HOME': str(self.directory),
                'MY_DASHBOARD_ENV': str(self.directory / 'missing-env'),
                'MY_DASHBOARD_URL': url, 'MY_DASHBOARD_TOKEN': 'fixture-ingest',
                'MY_DASHBOARD_STATE_DIR': str(self.state)}

    def run_hook(self, name, path=None):
        with Capture() as capture:
            args, stdin = self.command(name)
            result = subprocess.run(args, input=stdin, env=self.environment(capture.url, path),
                                    cwd=self.directory, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0)
        return [body['session_id'] for body in capture.received], result

    def test_오래된_락은_GNU와_BSD_stat_모두에서_지우고_스풀을_재전송한다(self):
        for flavor in ('gnu', 'bsd'):
            for name in HOOKS:
                with self.subTest(flavor=flavor, name=name):
                    self.seed_spool()
                    self.make_lock(age_seconds=120)
                    delivered, result = self.run_hook(name, self.fake_stat_path(flavor))
                    self.assertNotIn('syntax error', result.stderr)
                    self.assertEqual(sorted(delivered), ['current', 'previous'])
                    self.assertEqual(self.spool.read_text().strip(), '')
                    self.assertFalse(self.lock.exists())

    def test_다른_프로세스가_방금_잡은_락은_지우지_않는다(self):
        for name in HOOKS:
            with self.subTest(name=name):
                self.seed_spool()
                self.make_lock(age_seconds=0)
                delivered, _ = self.run_hook(name)
                # 락을 못 잡으면 스풀 정리를 건너뛰지만 이번 이벤트는 그래도 보낸다.
                self.assertEqual(delivered, ['current'])
                self.assertTrue(self.lock.is_dir())
                self.assertIn('previous', self.spool.read_text())
                self.lock.rmdir()

    def test_락을_쥔_채_TERM을_받으면_락을_풀고_0으로_끝난다(self):
        for name in HOOKS:
            with self.subTest(name=name):
                self.seed_spool()
                # 스풀 재전송의 첫 curl을 서버가 붙잡는 동안 락은 확실히 이 프로세스가 쥐고 있다.
                with Capture(stall_first=True) as capture:
                    args, stdin = self.command(name)
                    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, cwd=self.directory, text=True,
                                               env=self.environment(capture.url))
                    process.stdin.write(stdin)
                    process.stdin.close()
                    try:
                        self.assertTrue(capture.first_request.wait(10))
                        self.assertTrue(self.lock.is_dir())
                        process.send_signal(signal.SIGTERM)
                        self.assertEqual(process.wait(timeout=15), 0)
                    finally:
                        capture.release.set()
                        if process.poll() is None:
                            process.kill()
                        process.wait()
                        process.stdout.close()
                        process.stderr.close()
                self.assertFalse(self.lock.exists())
                self.spool.unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main()

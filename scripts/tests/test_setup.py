"""Exercise the downloaded installer with isolated settings and an HTTP fixture."""
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
INGEST = 'fixture-ingest-token'


class InstallerTests(unittest.TestCase):
    def run_installer(self, status=204, existing=False, dry_run=False):
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requests.append((self.path, self.headers.get('Authorization')))
                if self.path == '/dashboard/auth/ingest-check':
                    self.send_response(status)
                    self.end_headers()
                elif self.path.startswith('/hooks/files/'):
                    # Installer registration behavior has separate real-install tests.
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'#!/usr/bin/env bash\nexit 0\n')
                else:
                    self.send_response(404)
                    self.end_headers()

        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as httpd:
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            try:
                with tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    origin = f'http://127.0.0.1:{httpd.server_port}'
                    script = directory / 'setup.sh'
                    script.write_text((ROOT / 'hooks/setup.sh').read_text().replace(
                        '__MY_DASHBOARD_ORIGIN__', origin))
                    config = directory / '.config/my-dashboard/env'
                    original = f'MY_DASHBOARD_URL={origin}\nMY_DASHBOARD_TOKEN={INGEST}\n# retained\n'
                    if existing:
                        config.parent.mkdir(parents=True)
                        config.write_text(original)
                    environment = {'PATH': os.environ['PATH'], 'HOME': temporary,
                                   'XDG_DATA_HOME': str(directory / 'data'),
                                   'MY_DASHBOARD_TOKEN': INGEST}
                    result = subprocess.run(['bash', str(script), *(['--dry-run'] if dry_run else [])],
                                            env=environment, text=True, capture_output=True, timeout=20)
                    config_text = config.read_text() if config.exists() else None
            finally:
                httpd.shutdown()
                thread.join()
        self.assertNotIn(INGEST, result.stdout + result.stderr)
        return result, requests, config_text, original

    def test_새_설정은_수집_토큰을_비변경_API로_검증한다(self):
        result, requests, _, _ = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(('/dashboard/auth/ingest-check', f'Bearer {INGEST}'), requests)
        self.assertNotIn('/dashboard/sessions', [path for path, _ in requests])
        self.assertIn('수집 토큰 검증 완료', result.stderr)

    def test_기존_설정을_보존하면서_다시_검증한다(self):
        result, requests, config, original = self.run_installer(existing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, original)
        self.assertIn(('/dashboard/auth/ingest-check', f'Bearer {INGEST}'), requests)

    def test_잘못된_토큰은_성공으로_표시하지_않는다(self):
        result, _, _, _ = self.run_installer(status=401)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('인증 실패', result.stderr)

    def test_403은_구서버와_잘못된_권한을_단정하지_않는다(self):
        result, _, _, _ = self.run_installer(status=403)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('서버·설치기 버전', result.stderr)

    def test_미지원_서버는_검증되지_않았음을_알린다(self):
        result, _, _, _ = self.run_installer(status=404)
        self.assertEqual(result.returncode, 0)
        self.assertIn('아직 확인되지 않았습니다', result.stderr)
        self.assertNotIn('수집 토큰 검증 완료', result.stderr)

    def test_미리보기는_네트워크와_설정을_변경하지_않는다(self):
        result, requests, config, _ = self.run_installer(dry_run=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(requests, [])
        self.assertIsNone(config)

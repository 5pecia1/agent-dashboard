"""Exercise the downloaded installer with isolated settings and an HTTP fixture."""
import http.server
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
INGEST = 'fixture-ingest-token'
# 실제 install.sh 대신 내려주는 스텁: 넘겨받은 인자를 자기 옆 파일에 한 줄씩 남긴다.
INSTALL_STUB = b'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$(dirname "$0")/install-args"\n'
# PATH 맨 앞에 두는 mv: 진짜 mv를 부르기 직전에 원본의 권한을 `<대상 파일 이름> <모드>`로 기록한다.
MV_SPY = """#!/usr/bin/env python3
import os, shutil, stat, sys
args = [arg for arg in sys.argv[1:] if not arg.startswith('-')]
with open(os.environ['MV_SPY_LOG'], 'a') as log:
    log.write(f'{os.path.basename(args[-1])} {stat.S_IMODE(os.stat(args[0]).st_mode):o}\\n')
here = os.path.dirname(os.path.abspath(__file__))
path = os.pathsep.join(p for p in os.environ['PATH'].split(os.pathsep) if p != here)
os.execv(shutil.which('mv', path=path), ['mv', *sys.argv[1:]])
"""


def setup_file_list(name):
    """The file names setup.sh installs under EXECUTABLE_FILES / NON_EXECUTABLE_FILES."""
    match = re.search(rf'^{name}="([^"]*)"', (ROOT / 'hooks/setup.sh').read_text(), re.MULTILINE)
    return set(match.group(1).split())


EXECUTABLE_HOOKS = setup_file_list('EXECUTABLE_FILES')
PLAIN_HOOKS = setup_file_list('NON_EXECUTABLE_FILES')


def hook_file_modes(hooks_dir):
    """Permission bits of the hook files already in place (the .download temp files don't count)."""
    if hooks_dir is None or not hooks_dir.is_dir():
        return {}
    return {path.name: stat.S_IMODE(path.stat().st_mode) for path in hooks_dir.iterdir()
            if path.is_file() and not path.name.endswith('.download')}


class InstallerTests(unittest.TestCase):
    def run_installer(self, status=204, existing=False, dry_run=False, runs=1, spy_mv=False):
        requests = []
        # 설치기 스텁이 받은 인자. 설치기를 실행하지 않았으면(미리보기) None.
        self.install_args = None
        # 서버가 훅 파일 요청을 받을 때마다 엿본 "이미 제자리에 놓인 훅 파일들의 권한"과, 끝난 뒤의 권한.
        self.modes_seen = []
        self.final_modes = {}
        # spy_mv일 때 mv가 받은 (대상 파일 이름, 원본 권한 8진수 문자열).
        self.mv_calls = []
        hooks_dir = {}  # 임시 폴더가 정해지면 채운다
        case = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requests.append((self.path, self.headers.get('Authorization')))
                if self.path.startswith('/hooks/files/'):
                    # curl은 이 응답을 기다리는 중이라 setup.sh는 멈춰 있다 - 앞서 받은 파일은 이미 제자리다.
                    case.modes_seen.append(hook_file_modes(hooks_dir.get('path')))
                if self.path == '/dashboard/auth/ingest-check':
                    self.send_response(status)
                    self.end_headers()
                elif self.path == '/hooks/files/install.sh':
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(INSTALL_STUB)
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
                    hooks_dir['path'] = directory / 'data/my-dashboard/hooks'
                    if spy_mv:
                        spy = directory / 'spy-bin'
                        spy.mkdir()
                        (spy / 'mv').write_text(MV_SPY)
                        (spy / 'mv').chmod(0o755)
                        environment['PATH'] = f'{spy}{os.pathsep}{environment["PATH"]}'
                        environment['MV_SPY_LOG'] = str(directory / 'mv.log')
                    logs = []
                    for index in range(runs):  # 두 번 이상이면 앞선 실행이 남긴 훅 위에 덮어쓰는 업데이트다
                        result = subprocess.run(['bash', str(script), *(['--dry-run'] if dry_run else [])],
                                                env=environment, text=True, capture_output=True, timeout=20)
                        logs.append(result.stdout + result.stderr)
                        if index < runs - 1:  # 마지막 앞의 실행은 성공해야 다음 실행이 업데이트가 된다
                            self.assertEqual(result.returncode, 0, result.stderr)
                    config_text = config.read_text() if config.exists() else None
                    args_file = hooks_dir['path'] / 'install-args'
                    if args_file.exists():
                        self.install_args = args_file.read_text().splitlines()
                    self.final_modes = hook_file_modes(hooks_dir['path'])
                    if spy_mv:
                        self.mv_calls = [line.split() for line in (directory / 'mv.log').read_text().splitlines()]
            finally:
                httpd.shutdown()
                thread.join()
        self.assertNotIn(INGEST, ''.join(logs))
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

    def test_설치기에_네_에이전트_대상을_모두_넘긴다(self):
        result, _, _, _ = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.install_args, ['--claude', '--codex', '--devin', '--antigravity'])

    def test_기존_설정이_있어도_설치기에_네_에이전트_대상을_넘긴다(self):
        result, _, _, _ = self.run_installer(existing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.install_args, ['--claude', '--codex', '--devin', '--antigravity'])

    def test_미리보기는_설치기에_넘길_대상을_보여주고_실행하지_않는다(self):
        result, _, _, _ = self.run_installer(dry_run=True)
        self.assertIn('install.sh --claude --codex --devin --antigravity', result.stderr)
        self.assertIsNone(self.install_args)

    def test_실행_파일은_제자리에_놓이는_순간부터_실행_권한이_있다(self):
        # 다운로드가 끝나기까지 hook은 계속 실행된다. 옮긴 뒤에 chmod하면 그 사이의 hook이 실행 불가 상태가
        # 돼서(claude·codex·devin은 exit 126, antigravity는 조용히 폴백 응답) 이벤트가 사라진다.
        self.assertTrue(EXECUTABLE_HOOKS and PLAIN_HOOKS, 'setup.sh에서 파일 목록을 읽지 못했다')
        for runs, label in ((1, '처음 설치'), (2, '업데이트')):
            with self.subTest(label):
                result, _, _, _ = self.run_installer(runs=runs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreaterEqual(len(self.modes_seen), len(EXECUTABLE_HOOKS | PLAIN_HOOKS) * runs)
                for seen in self.modes_seen:
                    for name in EXECUTABLE_HOOKS & set(seen):
                        self.assertTrue(seen[name] & 0o100, f'{name}이 실행 권한 없이 제자리에 놓였다(모드 {seen[name]:o})')
                for name in EXECUTABLE_HOOKS:
                    self.assertTrue(self.final_modes[name] & 0o100, name)
                for name in PLAIN_HOOKS:
                    self.assertFalse(self.final_modes[name] & 0o111, f'{name}에는 실행 권한을 주지 않는다')

    def test_실행_파일은_실행_권한을_받은_채로_옮겨진다(self):
        # 위 테스트는 파일 사이의 틈만 본다. 파일 하나를 옮기는 그 순간에도 원본(.download)이 이미
        # 실행 가능해야 제자리 파일이 실행 불가 상태로 놓이는 순간이 아예 없다(옮긴 직후 chmod하는
        # 순서도 이 순간을 만든다).
        result, _, _, _ = self.run_installer(spy_mv=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        moved = dict(self.mv_calls)
        self.assertEqual(set(moved), EXECUTABLE_HOOKS | PLAIN_HOOKS)
        for name in EXECUTABLE_HOOKS:
            self.assertTrue(int(moved[name], 8) & 0o100, f'{name}을 실행 권한 없이 옮겼다(모드 {moved[name]})')
        for name in PLAIN_HOOKS:
            self.assertFalse(int(moved[name], 8) & 0o111, f'{name}에는 실행 권한을 주지 않는다(모드 {moved[name]})')

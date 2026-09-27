"""Exercise the piped public installer against immutable local release fixtures.

Curl is the only network seam: production API/download URLs remain hardcoded.
No test changes HOME, the real app, credentials, or Cloudflare resources.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'distribution/public/install.sh'
if not SCRIPT.exists():  # Copybara public layout.
    SCRIPT = ROOT / 'install.sh'
API = 'https://api.github.com/repos/5pecia1/agent-dashboard/releases'
DOWNLOAD = 'https://github.com/5pecia1/agent-dashboard/releases/download'
BUNDLE_ID = 'io.github.5pecia1.mydashboard'


class ReleaseInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='release-installer-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin = self.directory / 'bin'
        self.bin.mkdir()
        self.urls = {}
        self.releases = []
        self.environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                                INSTALL_FIXTURE=str(self.directory), INSTALL_SYSTEM='Linux')
        self.executable('curl', '''import json, os, pathlib, shutil, sys
d = pathlib.Path(os.environ['INSTALL_FIXTURE'])
args = sys.argv[1:]; url = args[-1]
with (d / 'requests').open('a') as f: f.write(url + '\\n')
source = json.loads((d / 'urls.json').read_text()).get(url)
if not source: sys.exit(22)
shutil.copyfile(source, args[args.index('--output') + 1])
''')
        self.executable('uname', '''import os, platform, sys
print(os.environ['INSTALL_SYSTEM'] if sys.argv[1] == '-s' else platform.machine())
''')
        # Hide real installed apps from fixture identity checks while retaining
        # native macOS plutil for downloaded fixture JSON and Info.plist.
        if sys.platform == 'darwin':
            self.executable('plutil', '''import os, pathlib, subprocess, sys
path = pathlib.Path(sys.argv[-1])
if str(path).startswith(('/Applications/', str(pathlib.Path.home() / 'Applications') + '/')):
    sys.exit(1)
sys.exit(subprocess.call(['/usr/bin/plutil', *sys.argv[1:]]))
''')

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f'#!{sys.executable}\n' + body)
        path.chmod(0o755)

    def register(self, url, data):
        path = self.directory / ('response-' + str(len(self.urls)))
        path.write_bytes(data if isinstance(data, bytes) else json.dumps(data).encode())
        self.urls[url] = str(path)
        return path

    def release(self, tag, assets, prerelease=False):
        metadata = dict(tag_name=tag, draft=False, prerelease=prerelease,
                        assets=[{'name': name} for name in assets])
        self.releases.append(metadata)
        self.register(API + '/tags/' + tag, metadata)
        for name, data in assets.items():
            self.register(f'{DOWNLOAD}/{tag}/{name}', data)
        return metadata

    def starter(self, version='1.2.3', *, bad_hash=False, invalid=False, missing_package=False,
                unsafe_name=None, symlink=False, prerelease=False):
        tag = 'server-v' + version
        package = b'tested server package fixture'
        package_name = 'vendor/agent-dashboard-server-' + version + '.tgz'
        manifest = dict(schema=1, product='Agent Dashboard', tag=tag,
                        server_version=version, source_commit='a' * 40,
                        package_file=package_name, package_sha256=hashlib.sha256(package).hexdigest())
        if missing_package:
            del manifest['package_sha256']
        files = {
            'starter-manifest.json': json.dumps(manifest).encode(),
            'package.json': json.dumps({'dependencies': {'server': 'file:' + package_name}}).encode(),
            'package-lock.json': b'{}', 'wrangler.jsonc': b'{}', 'README.md': b'Run npm ci.',
        }
        if not missing_package:
            files[package_name] = package
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for name, content in files.items():
                item = tarfile.TarInfo('agent-dashboard-server/' + name)
                item.size = len(content)
                item.mode = 0o644
                archive.addfile(item, io.BytesIO(content))
            if unsafe_name:
                item = tarfile.TarInfo(unsafe_name)
                item.size = 1
                archive.addfile(item, io.BytesIO(b'x'))
            if symlink:
                item = tarfile.TarInfo('agent-dashboard-server/escape')
                item.type = tarfile.SYMTYPE
                item.linkname = '../../outside'
                archive.addfile(item)
        payload = b'not a tar archive' if invalid else stream.getvalue()
        filename = 'agent-dashboard-server-' + version + '-starter.tar.gz'
        digest = '0' * 64 if bad_hash else hashlib.sha256(payload).hexdigest()
        self.release(tag, {filename: payload, filename + '.sha256': f'{digest}  {filename}\n'.encode()}, prerelease)
        return tag

    def app(self, version='1.2.3', *, bad_hash=False, invalid=False, unsafe_link=False):
        tag = 'v' + version
        info = dict(CFBundleIdentifier=BUNDLE_ID, CFBundleShortVersionString=version,
                    CFBundleExecutable='my_dashboard')
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, content, mode in [
                ('Agent Dashboard.app/Contents/Info.plist', plistlib.dumps(info), 0o644),
                ('Agent Dashboard.app/Contents/MacOS/my_dashboard', b'#!/bin/sh\nexit 0\n', 0o755),
            ]:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(entry, content)
            if unsafe_link:
                entry = zipfile.ZipInfo('Agent Dashboard.app/Contents/escape')
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, '../../../outside')
        payload = b'not a zip archive' if invalid else stream.getvalue()
        arch = os.uname().machine
        filename = f'agent-dashboard-{tag}-macos-{arch}.zip'
        digest = '0' * 64 if bad_hash else hashlib.sha256(payload).hexdigest()
        receipt = dict(schema=1, product='Agent Dashboard', tag=tag, version=version,
                       source_commit='a' * 40, artifacts=[dict(platform='macos', arch=arch,
                       signing='unsigned', file=filename, sha256=digest)])
        self.release(tag, {filename: payload, 'release.json': json.dumps(receipt).encode(),
                          'SHA256SUMS': f'{digest}  {filename}\n'.encode()})
        return tag

    def run_installer(self, *args, system='Linux', extra_env=None):
        self.register(API + '?per_page=100&page=1', self.releases)
        (self.directory / 'urls.json').write_text(json.dumps(self.urls))
        environment = dict(self.environment, INSTALL_SYSTEM=system, **(extra_env or {}))
        result = subprocess.run(['bash', '-s', '--', *args], input=SCRIPT.read_text(), text=True,
                                capture_output=True, env=environment, cwd=self.directory,
                                start_new_session=True, timeout=60)
        return result

    def requests(self):
        path = self.directory / 'requests'
        return path.read_text().splitlines() if path.exists() else []

    def assertFailure(self, result, message, destination=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        if destination:
            self.assertFalse(destination.exists())

    def test_piped_help_requires_no_runtime(self):
        result = self.run_installer('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--version', result.stdout)
        self.assertEqual(self.requests(), [])

    def test_latest_filters_other_product_and_preview_then_resolves_once(self):
        self.release('v99.0.0', {})
        self.starter('2.0.0-alpha.1', prerelease=True)
        self.starter('1.2.3')
        target = self.directory / 'project'
        result = self.run_installer('server', '--dry-run', '--dir', str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected server release: server-v1.2.3', result.stderr)
        self.assertFalse(target.exists())
        self.assertEqual(sum('/tags/' in url for url in self.requests()), 1)

    def test_prerelease_is_opt_in_and_exact_prerelease_does_not_need_flag(self):
        self.starter('2.0.0-alpha.1', prerelease=True)
        self.starter('1.2.3')
        for args in [('--prerelease',), ('--version', '2.0.0-alpha.1')]:
            result = self.run_installer('server', '--dry-run', *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Selected server release: server-v2.0.0-alpha.1', result.stderr)

    def test_missing_exact_version_never_falls_back(self):
        self.starter()
        result = self.run_installer('server', '--version', '9.9.9')
        self.assertFailure(result, 'Download failed')
        self.assertEqual(self.requests(), [API + '/tags/server-v9.9.9'])

    def test_no_stable_server_explains_prerelease(self):
        self.starter('1.0.0-alpha.1', prerelease=True)
        self.assertFailure(self.run_installer('server'), 'use --prerelease')

    def test_bad_hash_and_invalid_archive_fail_without_installing(self):
        for version, options, message in [
            ('1.0.0', {'bad_hash': True}, 'SHA256 mismatch'),
            ('1.0.1', {'invalid': True}, 'Invalid server archive'),
            ('1.0.2', {'unsafe_name': '../escape'}, 'Unsafe server archive path'),
            ('1.0.3', {'symlink': True}, 'Unsafe server archive entry'),
            ('1.0.4', {'missing_package': True}, 'Server package SHA256 is missing'),
        ]:
            self.starter(version, **options)
            target = self.directory / version
            result = self.run_installer('server', '--version', version, '--dir', str(target))
            self.assertFailure(result, message, target)
        self.assertFalse((self.directory / 'escape').exists())

    def test_server_install_is_movable_and_never_overwrites(self):
        self.starter()
        target = self.directory / 'project'
        result = self.run_installer('server', '--dir', str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        moved = self.directory / 'moved-project'
        target.rename(moved)
        dependency = json.loads((moved / 'package.json').read_text())['dependencies']['server']
        self.assertTrue((moved / dependency.removeprefix('file:')).is_file())
        marker = moved / 'personal-config'
        marker.write_text('keep this')
        result = self.run_installer('server', '--dir', str(moved))
        self.assertFailure(result, 'Destination exists')
        self.assertEqual(marker.read_text(), 'keep this')

    def test_busy_lock_preserves_destination(self):
        self.starter()
        target = self.directory / 'project'
        lock = Path(str(target) + '.install-lock')
        lock.mkdir()
        result = self.run_installer('server', '--dir', str(target))
        self.assertFailure(result, 'Another installation may be running', target)
        self.assertTrue(lock.is_dir())

    def test_hooks_requires_clean_https_origin_and_does_not_print_credentials(self):
        result = self.run_installer('hooks', '--server-url', 'https://private-secret@example.com')
        self.assertFailure(result, 'must be an HTTPS origin')
        self.assertNotIn('private-secret', result.stderr)
        self.assertEqual(self.requests(), [])

    def test_hooks_delegates_server_script_without_pipe_stdin_or_token_logging(self):
        script = b'#!/bin/bash\n[ -z "$(cat)" ] || exit 3\n[ "$MY_DASHBOARD_TOKEN" = fixture-secret ] || exit 4\nprintf "hooks installed\\n"\n'
        self.register('https://example.com/setup.sh', script)
        result = self.run_installer('hooks', '--server-url', 'https://example.com/',
                                    extra_env={'MY_DASHBOARD_TOKEN': 'fixture-secret'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('fixture-secret', result.stdout + result.stderr)
        self.assertEqual(self.requests(), ['https://example.com/setup.sh'])

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS bundle extraction')
    def test_app_rejects_corruption_and_escaping_links_before_mutation(self):
        for version, options, message in [
            ('1.0.0', {'bad_hash': True}, 'SHA256 mismatch'),
            ('1.0.1', {'invalid': True}, 'Invalid app ZIP archive'),
            ('1.0.2', {'unsafe_link': True}, 'Unsafe app symlink'),
        ]:
            self.app(version, **options)
            target = self.directory / ('apps-' + version)
            result = self.run_installer('--version', version, '--dir', str(target), system='Darwin')
            self.assertFailure(result, message, target)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS bundle extraction')
    def test_app_replace_is_explicit_and_canonicalizes_destination(self):
        self.app('1.2.3')
        target = self.directory / 'apps'
        result = self.run_installer('--dir', str(target), system='Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = target / 'Agent Dashboard.app'
        marker = installed / 'previous-installation'
        marker.write_text('keep in backup')
        result = self.run_installer('--dir', 'apps/', system='Darwin')
        self.assertFailure(result, 'rerun with --replace')
        self.assertTrue(marker.exists())
        result = self.run_installer('--dir', './apps/', '--replace', system='Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed.is_dir())
        backups = list(target.glob('Agent Dashboard.app.backup-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / marker.name).read_text(), 'keep in backup')

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS bundle extraction')
    def test_app_rename_failure_restores_previous_app_and_cleans_lock(self):
        self.app()
        target = self.directory / 'apps'
        result = self.run_installer('--dir', str(target), system='Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = target / 'Agent Dashboard.app/previous-installation'
        marker.write_text('restore this')
        real_mv = shutil.which('mv')
        self.executable('mv', f'''import os, subprocess, sys
if '/.agent-dashboard-app.' in sys.argv[1]: sys.exit(9)
sys.exit(subprocess.call([{real_mv!r}, *sys.argv[1:]]))
''')
        result = self.run_installer('--dir', str(target), '--replace', system='Darwin')
        self.assertFailure(result, 'previous installation restored')
        self.assertEqual(marker.read_text(), 'restore this')
        self.assertFalse((target / '.agent-dashboard.install-lock').exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS bundle extraction')
    def test_interrupted_app_replacement_restores_previous_app(self):
        self.app()
        target = self.directory / 'apps'
        result = self.run_installer('--dir', str(target), system='Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = target / 'Agent Dashboard.app/previous-installation'
        marker.write_text('restore after interruption')
        real_mv = shutil.which('mv')
        self.executable('mv', f'''import os, signal, subprocess, sys
if '/.agent-dashboard-app.' in sys.argv[1]:
    os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(9)
sys.exit(subprocess.call([{real_mv!r}, *sys.argv[1:]]))
''')
        result = self.run_installer('--dir', str(target), '--replace', system='Darwin')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), 'restore after interruption')
        self.assertFalse((target / '.agent-dashboard.install-lock').exists())


if __name__ == '__main__':
    unittest.main()

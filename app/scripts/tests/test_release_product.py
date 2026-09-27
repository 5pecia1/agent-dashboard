import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_product as release

VERSION = '0.1.2'
TAG = f'v{VERSION}'
COMMIT = 'a' * 40


class ProductReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'app'
        self.web = self.root / 'build/web'
        self.web.mkdir(parents=True)
        (self.app / 'flutter_app').mkdir(parents=True)
        (self.app / 'Cargo.toml').write_text(f'[workspace.package]\nversion = "{VERSION}"\n')
        (self.app / 'flutter_app/pubspec.yaml').write_text(
            f'version: {VERSION}+1\nmsix_config:\n  msix_version: {VERSION}.0\n')
        files = {
            'index.html': '<base href="/"><title>Agent Dashboard</title>',
            'flutter_bootstrap.js': 'bootstrap();',
            'main.dart.js': 'app();',
            'manifest.json': json.dumps({'name': 'Agent Dashboard'}),
            'version.json': json.dumps({'version': VERSION}),
            'pkg/my_dashboard.js': 'loadWasm();',
            'pkg/my_dashboard_bg.wasm': 'wasm fixture',
            '_headers': '/release-manifest.json\n  Cache-Control: no-store\n',
        }
        for name, content in files.items():
            destination = self.web / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)

    def package(self, output='packaged'):
        args = argparse.Namespace(platform='web', source=self.web, tag=TAG,
                                  commit=COMMIT, output=self.root / output, arch=None)
        receipt = release.package(args, root=self.app)
        return args.output / receipt['artifact']['file'], receipt

    def verify(self, archive, digest=None, commit=COMMIT):
        return release.verify_web(argparse.Namespace(
            archive=archive, sha256=digest or release.sha256(archive), tag=TAG,
            commit=commit, output=self.root / 'deployed'))

    def test_패키지의_검증된_파일을_그대로_배포하고_공개_버전과_커밋을_기록한다(self):
        before = {path.relative_to(self.web): path.read_bytes()
                  for path in self.web.rglob('*') if path.is_file()}
        archive, receipt = self.package()
        self.assertEqual(archive.name, f'agent-dashboard-{TAG}-web.tar.gz')
        embedded = self.verify(archive)
        self.assertEqual(embedded['source_commit'], COMMIT)
        self.assertEqual(embedded['version'], VERSION)
        self.assertEqual(receipt['artifact']['sha256'], hashlib.sha256(archive.read_bytes()).hexdigest())
        for name, content in before.items():
            self.assertEqual((self.root / 'deployed' / name).read_bytes(), content)
            self.assertEqual((self.web / name).read_bytes(), content)
        self.assertFalse((self.web / release.WEB_METADATA).exists())
        rebuilt_archive, _ = self.package('packaged-again')
        self.assertEqual(archive.read_bytes(), rebuilt_archive.read_bytes())

    def test_프로젝트와_빌드와_태그의_버전이_다르면_발행하지_않는다(self):
        (self.app / 'Cargo.toml').write_text('[workspace.package]\nversion = "9.9.9"\n')
        with self.assertRaisesRegex(ValueError, 'versions differ'):
            self.package()
        (self.app / 'Cargo.toml').write_text(f'[workspace.package]\nversion = "{VERSION}"\n')
        (self.web / 'version.json').write_text('{"version":"9.9.9"}')
        with self.assertRaisesRegex(ValueError, 'built web version'):
            self.package()
        self.assertFalse(list((self.root / 'packaged').glob('*.tar.gz')))

    def test_다운로드_중_변경되거나_다른_커밋으로_빌드된_웹은_배포하지_않는다(self):
        archive, receipt = self.package()
        with self.assertRaisesRegex(ValueError, 'metadata differs'):
            self.verify(archive, commit='b' * 40)
        archive.write_bytes(archive.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            self.verify(archive, digest=receipt['artifact']['sha256'])
        self.assertFalse((self.root / 'deployed').exists())

    def test_상위_경로와_링크와_중복_경로가_있는_아카이브를_거부한다(self):
        for kind in ('traversal', 'absolute', 'symlink', 'hardlink', 'duplicate', 'dot'):
            with self.subTest(kind=kind):
                archive = self.root / f'{kind}.tar.gz'
                with tarfile.open(archive, 'w:gz') as stream:
                    name = {'traversal': '../escaped', 'absolute': '/escaped',
                            'dot': '.'}.get(kind, 'index.html')
                    member = tarfile.TarInfo(name)
                    if kind in {'symlink', 'hardlink'}:
                        member.type = tarfile.SYMTYPE if kind == 'symlink' else tarfile.LNKTYPE
                        member.linkname = '../escaped'
                        stream.addfile(member)
                    else:
                        member.size = 1
                        stream.addfile(member, io.BytesIO(b'x'))
                        if kind == 'duplicate':
                            stream.addfile(member, io.BytesIO(b'y'))
                with self.assertRaises(ValueError):
                    self.verify(archive)
                self.assertFalse((self.root / 'deployed').exists())
                self.assertFalse((self.root / 'escaped').exists())

    def test_개인_환경파일과_키와_심볼릭_링크는_웹에_포함하지_않는다(self):
        for name in ('.env.production', 'private.pem', 'credentials.json', 'linked.js'):
            with self.subTest(name=name):
                forbidden = self.web / name
                if name == 'linked.js':
                    forbidden.symlink_to(self.web / 'main.dart.js')
                else:
                    forbidden.write_text('not a real secret')
                with self.assertRaises(ValueError):
                    self.package()
                forbidden.unlink()

    def test_Pages_파일_제한을_넘으면_배포_전에_실패한다(self):
        with (self.web / 'too-large.wasm').open('wb') as stream:
            stream.truncate(release.MAX_FILE_BYTES + 1)
        with self.assertRaisesRegex(ValueError, '25 MiB'):
            self.package()

    def test_두_플랫폼의_원본_산출물을_합치고_변조된_다운로드를_거부한다(self):
        archive, web_receipt = self.package('download/web')
        mac_dir = self.root / 'download/macos'
        mac_dir.mkdir(parents=True)
        mac_archive = mac_dir / f'agent-dashboard-{TAG}-macos-arm64.zip'
        mac_archive.write_bytes(b'opaque native artifact')
        mac_receipt = dict(release.metadata(TAG, COMMIT), artifact={
            'platform': 'macos', 'file': mac_archive.name, 'arch': 'arm64',
            'sha256': release.sha256(mac_archive), 'size_bytes': mac_archive.stat().st_size,
            'signing': 'ad-hoc', 'notarization': 'not-verified'})
        (mac_dir / 'macos-arm64.artifact.json').write_text(json.dumps(mac_receipt))
        args = argparse.Namespace(input=self.root / 'download', output=self.root / 'release',
                                  tag=TAG, commit=COMMIT)
        combined = release.combine(args)
        self.assertEqual(combined['source_commit'], COMMIT)
        self.assertEqual(len(combined['artifacts']), 2)
        self.assertEqual((args.output / archive.name).read_bytes(), archive.read_bytes())
        self.assertEqual((args.output / mac_archive.name).read_bytes(), mac_archive.read_bytes())
        sums = (args.output / 'SHA256SUMS').read_text()
        self.assertIn(f"{web_receipt['artifact']['sha256']}  {archive.name}\n", sums)
        mac_archive.write_bytes(b'changed download')
        args.output = self.root / 'rejected-release'
        with self.assertRaisesRegex(ValueError, 'differs from its receipt'):
            release.combine(args)
        self.assertFalse(args.output.exists())

    def test_플랫폼_누락과_출처_혼합은_릴리스로_합치지_않는다(self):
        _, receipt = self.package('download/web')
        args = argparse.Namespace(input=self.root / 'download', output=self.root / 'release',
                                  tag=TAG, commit=COMMIT)
        with self.assertRaisesRegex(ValueError, 'both web and macOS'):
            release.combine(args)
        receipt['source_commit'] = 'b' * 40
        (self.root / 'download/web/web.artifact.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'different release version or source commit'):
            release.combine(args)
        self.assertFalse(args.output.exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'requires native macOS packaging tools')
    def test_macOS_번들의_서명을_검사하고_제품명과_실행권한과_링크를_보존한다(self):
        bundle = self.root / 'my_dashboard.app'
        contents = bundle / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        binary = contents / 'MacOS/my_dashboard'
        subprocess.run(['cc', '-x', 'c', '-', '-o', str(binary)],
                       input='int main(void) { return 0; }', text=True, check=True,
                       capture_output=True)
        info = {'CFBundleShortVersionString': VERSION, 'CFBundleName': release.PRODUCT,
                'CFBundleDisplayName': release.PRODUCT, 'CFBundleIdentifier': 'test.agent-dashboard',
                'CFBundleExecutable': 'my_dashboard', 'CFBundlePackageType': 'APPL'}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        resources = contents / 'Resources'
        resources.mkdir()
        (resources / 'fixture.txt').write_text('retained resource')
        (resources / 'current.txt').symlink_to('fixture.txt')
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)],
                       check=True, capture_output=True)
        args = argparse.Namespace(platform='macos', source=bundle, tag=TAG,
                                  commit=COMMIT, output=self.root / 'native', arch=platform.machine())
        receipt = release.package(args, root=self.app)
        artifact = receipt['artifact']
        self.assertEqual(artifact['signing'], 'ad-hoc')
        self.assertEqual(artifact['notarization'], 'not-verified')
        self.assertIn(platform.machine(), artifact['architectures'])
        with zipfile.ZipFile(args.output / artifact['file']) as archive:
            executable = archive.getinfo('Agent Dashboard.app/Contents/MacOS/my_dashboard')
            self.assertTrue((executable.external_attr >> 16) & 0o111)
            self.assertEqual(archive.read('Agent Dashboard.app/Contents/Resources/current.txt'),
                             b'fixture.txt')
        self.assertTrue(binary.exists())


if __name__ == '__main__':
    unittest.main()

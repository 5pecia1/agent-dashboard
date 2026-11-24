import base64
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_distribution as signing
import sparkle_release as sparkle


class SparkleReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.pages = self.root / 'pages'
        self.pages.mkdir()
        self.assets = {}
        self.releases = []

    def stable(self, tag, build, prerelease=False, draft=False):
        name = f'agent-dashboard-{tag}-macos-universal.zip'
        source = self.root / tag
        source.mkdir()
        key = base64.b64encode(b'p' * 32).decode()
        signature = base64.b64encode(b's' * 64).decode()
        info = dict(CFBundleIdentifier=sparkle.BUNDLE_ID, CFBundleDisplayName=sparkle.PRODUCT,
                    CFBundleShortVersionString=tag[1:], CFBundleVersion=str(build),
                    SUFeedURL=sparkle.PUBLIC_FEED, SUPublicEDKey=key)
        archive = source / name
        with zipfile.ZipFile(archive, 'w') as out:
            out.writestr(f'{sparkle.PRODUCT}.app/Contents/Info.plist', plistlib.dumps(info))
        size = archive.stat().st_size
        rss = ET.Element('rss', version='2.0')
        channel = ET.SubElement(rss, 'channel')
        ET.SubElement(channel, 'link').text = sparkle.PUBLIC_FEED
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, sparkle.S + 'version').text = str(build)
        ET.SubElement(item, sparkle.S + 'shortVersionString').text = tag[1:]
        ET.SubElement(item, 'enclosure', {'url': f'https://github.com/{sparkle.REPO}/releases/download/{tag}/{name}',
                                         'length': str(size), sparkle.S + 'edSignature': signature})
        feed = ET.tostring(rss)
        (source / 'appcast.xml').write_bytes(feed)
        artifact = dict(platform='macos', arch='universal', bundle_id=sparkle.BUNDLE_ID, file=name, sha256=sparkle.digest(archive), size_bytes=size,
                        notarization='stapled', signing='developer-id', build=str(build), sparkle_ed_signature=signature)
        (source / 'release.json').write_text(json.dumps(dict(tag=tag, artifacts=[artifact])))
        self.assets[tag] = source
        self.releases.append(dict(tag_name=tag, prerelease=prerelease, draft=draft, assets=[
            dict(name='appcast.xml', size=len(feed)), dict(name=name, size=size)]))
        return feed

    def stage(self, live=None):
        def download(tag, name, destination):
            return self.assets[tag] / name
        with (patch.object(sparkle, 'gh_download', side_effect=download),
              patch.object(sparkle.subprocess, 'check_output', return_value=json.dumps([self.releases])),
              patch.object(sparkle, 'verify_ed') as verify, patch.object(sparkle, 'live_feed', return_value=live)):
            sparkle.stage_pages(self.pages)
            return verify

    def test_웹_롤백시에도_가장_높은_정식_맥_빌드의_피드를_보존한다(self):
        self.stable('v0.1.11', 12)
        expected = self.stable('v0.1.12', 13)
        self.stable('v0.1.13-beta', 14, prerelease=True)
        self.stable('v0.2.0', 15, draft=True)
        verify = self.stage(expected)
        self.assertEqual((self.pages / 'appcast.xml').read_bytes(), expected)
        self.assertEqual(verify.call_args.args[0].parent.name, 'v0.1.12')

    def test_현재_맥_버전을_낮추거나_운영_피드를_삭제하지_않는다(self):
        self.stable('v0.1.11', 12)
        newer = self.stable('v0.1.12', 13)
        self.releases.pop()
        with self.assertRaisesRegex(ValueError, 'older or different'):
            self.stage(newer)
        self.releases.clear()
        with self.assertRaisesRegex(ValueError, 'live update feed'):
            self.stage(newer)
        self.assertFalse((self.pages / 'appcast.xml').exists())

    def test_올라간_ZIP_바이트와_피드의_URL이_영수증에_묶인다(self):
        good = self.stable('v0.1.12', 13)
        source = self.assets['v0.1.12']
        feed = source / 'appcast.xml'
        feed.write_bytes(good.replace(b'/releases/download/v0.1.12/', b'/releases/latest/'))
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.stage()
        feed.write_bytes(good)
        archive = next(source.glob('*.zip'))
        archive.write_bytes(archive.read_bytes()[::-1])
        with self.assertRaisesRegex(ValueError, 'verified release receipt'):
            self.stage()
        self.assertFalse((self.pages / 'appcast.xml').exists())

    def test_플랫폼_검증기가_Ed25519_원본과_변조를_구분한다(self):
        # RFC 8032 section 7.1, TEST 2. All values are public test vectors.
        key = bytes.fromhex('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c')
        sig = bytes.fromhex('92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
                            '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00')
        file = self.root / 'signed'
        file.write_bytes(b'\x72')
        sparkle.verify_ed(file, base64.b64encode(key).decode(), base64.b64encode(sig).decode())
        file.write_bytes(b'\x73')
        with self.assertRaisesRegex(ValueError, 'does not verify'):
            sparkle.verify_ed(file, base64.b64encode(key).decode(), base64.b64encode(sig).decode())

    def test_Sparkle_도우미만_핀_버전과_권한이_일치할_때_서명한다(self):
        framework = self.root / 'Contents/Frameworks/Sparkle.framework/Versions/B'
        (framework / 'Resources').mkdir(parents=True)
        (framework / 'Resources/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.sparkle-project.Sparkle', 'CFBundleShortVersionString': '2.10.1'}))
        helper = framework / 'Updater.app'
        (helper / 'Contents').mkdir(parents=True)
        info = helper / 'Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.sparkle-project.Sparkle.Updater',
                                        'CFBundleExecutable': 'Updater'}))
        with patch.object(signing.subprocess, 'check_output', return_value=plistlib.dumps({})):
            signing.check_embedded_targets(self.root, [helper])
        with patch.object(signing.subprocess, 'check_output', return_value=plistlib.dumps({'com.apple.security.get-task-allow': True})):
            with self.assertRaisesRegex(ValueError, 'unreviewed entitlements'):
                signing.check_embedded_targets(self.root, [helper])
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'example.unexpected', 'CFBundleExecutable': 'Updater'}))
        with self.assertRaisesRegex(ValueError, 'unexpected Sparkle'):
            signing.check_embedded_targets(self.root, [helper])
        foreign = self.root / 'Contents/Mystery.app'
        foreign.mkdir()
        with self.assertRaisesRegex(ValueError, 'configure explicit'):
            signing.check_embedded_targets(self.root, [foreign])


if __name__ == '__main__':
    unittest.main()

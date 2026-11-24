import argparse
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_distribution as distribution


class MacDistributionTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / 'source.app'
        contents = self.source / 'Contents'
        contents.mkdir(parents=True)
        self.bundle_id = 'com.example.dashboard'
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': self.bundle_id}))
        self.framework = contents / 'Frameworks' / 'Embedded.framework'
        self.framework.mkdir(parents=True)
        self.binary = self.framework / 'Embedded'
        self.binary.write_bytes(bytes.fromhex('cffaedfe'))
        self.entitlements = self.root / 'Release.entitlements'
        self.entitlements.write_bytes(plistlib.dumps({}))
        self.args = argparse.Namespace(source_commit='b' * 40, bundle_id=self.bundle_id, team_id='ABC1234567',
                                      identity='a' * 40, keychain=None, notary_profile='fixture',
                                      source=self.source, output=self.root / 'Signed.app',
                                      entitlements=self.entitlements)
        self.commands = []

    def run_tool(self, *command):
        self.commands.append(command)
        if command[0] == 'ditto' and command[1] != '-c':
            shutil.copytree(command[1], command[2], symlinks=True)

    def submit(self, status):
        response = json.dumps({'status': status, 'id': 'fixture-id'})
        with (patch.object(distribution, 'run', side_effect=self.run_tool),
              patch.object(distribution, 'verify_signature'),
              patch.object(distribution, 'verify') as verify,
              patch.object(distribution.subprocess, 'check_output', return_value=response)):
            distribution.sign(self.args)
            return verify

    def test_승인된_응답만_스테이플하고_검증한_번들을_내보낸다(self):
        verify = self.submit('Accepted')
        self.assertTrue(self.args.output.is_dir())
        signed_info = plistlib.loads((self.args.output / 'Contents/Info.plist').read_bytes())
        self.assertEqual(signed_info[distribution.SOURCE_COMMIT_KEY], self.args.source_commit)
        self.assertNotIn(distribution.SOURCE_COMMIT_KEY,
                         plistlib.loads((self.source / 'Contents/Info.plist').read_bytes()))
        self.assertTrue(self.binary.is_file())
        signed = [command for command in self.commands if command[0] == 'codesign']
        self.assertEqual([c[-1].name for c in signed], ['Embedded', 'Embedded.framework', 'Signed.app'])
        self.assertTrue(all('--timestamp' in c and 'runtime' in c for c in signed))
        self.assertFalse(any('--entitlements' in c for c in signed[:-1]))
        self.assertIn(self.entitlements, signed[-1])
        self.assertTrue(any(c[:3] == ('xcrun', 'stapler', 'staple') for c in self.commands))
        verify.assert_called_once()

    def test_공증이_거절되면_출력없이_종료한다(self):
        with self.assertRaisesRegex(ValueError, 'Invalid.*fixture-id'):
            self.submit('Invalid')
        self.assertFalse(self.args.output.exists())
        self.assertFalse(any(c[:2] == ('xcrun', 'stapler') for c in self.commands))

    def test_앱_밖을_가리키는_링크와_다른_ID를_거부한다(self):
        (self.framework / 'escape').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'symlink outside app'):
            distribution.nested_code(self.source)
        self.args.bundle_id += '.other'
        with self.assertRaisesRegex(ValueError, 'unexpected bundle ID'):
            distribution.sign(self.args)
        self.assertFalse(self.args.output.exists())


if __name__ == '__main__':
    unittest.main()

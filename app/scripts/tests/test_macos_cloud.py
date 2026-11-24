import argparse
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_cloud as cloud


@unittest.skipIf(sys.platform == 'win32', 'Xcode archives use POSIX locks')
class CloudNotaryTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.archive = self.root / 'Dashboard.xcarchive'
        self.app = self.archive / 'Products/Applications/Runner.app'
        self.identifier = 'com.example.dashboard'
        self.commit = 'a' * 40
        self.team = 'ABCDE12345'
        self.uuid = str(uuid.uuid4()).upper()
        self.write_app(self.app)
        self.meta = {'ApplicationProperties': {'ApplicationPath': 'Applications/Runner.app'}}
        self.write_record()
        self.args = argparse.Namespace(archive=self.archive, output=self.root / 'Finished.app',
                                       bundle_id=self.identifier, team_id=self.team,
                                       source_commit=self.commit, submit=False)

    def write_app(self, path):
        contents = path / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleIdentifier': self.identifier, cloud.SOURCE_COMMIT_KEY: self.commit}))

    def write_record(self):
        (self.archive / 'Info.plist').write_bytes(plistlib.dumps(self.meta))

    def submitted(self, status):
        self.meta['Distributions'] = [{'destination': 'upload', 'uploadDestination': 'Developer ID',
                                      'uploadEvent': {'state': 'success'}, 'teamID': self.team,
                                      'processingEvent': {'state': 'processing'}, 'identifier': self.uuid}]
        self.write_record()
        folder = self.archive / 'Submissions' / self.uuid
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'notarization-log.json').write_text(json.dumps(
            {'jobId': self.uuid, 'status': status, 'statusCode': 0 if status == 'Accepted' else 4000}))

    def download(self, *command):
        self.assertEqual(command[:2], ('xcodebuild', '-exportNotarizedApp'))
        self.write_app(command[-1] / 'Runner.app')

    def test_접수된_아카이브는_submit을_반복해도_기존_결과만_다운로드한다(self):
        self.submitted('Accepted')
        self.args.submit = True
        with patch.object(cloud, 'run', side_effect=self.download) as runner, patch.object(cloud, 'verify') as verify:
            cloud.cloud_release(self.args)
        runner.assert_called_once()
        verify.assert_called_once()
        self.assertTrue(self.args.output.is_dir())

    def test_업로드와_공증_승인을_구분하고_거절된_결과는_내보내지_않는다(self):
        self.submitted('Invalid')
        with patch.object(cloud, 'run', side_effect=self.download), patch.object(cloud, 'verify') as verify:
            with self.assertRaisesRegex(ValueError, 'not accepted'):
                cloud.cloud_release(self.args)
        verify.assert_not_called()
        self.assertFalse(self.args.output.exists())

    def test_기본_재개_명령은_최초_업로드를_시작하지_않는다(self):
        with patch.object(cloud, 'run') as runner, self.assertRaisesRegex(ValueError, 'use --submit'):
            cloud.cloud_release(self.args)
        runner.assert_not_called()

    def test_다른_팀과_다른_커밋의_아카이브는_애플에_전송하지_않는다(self):
        self.submitted('Accepted')
        self.args.submit = True
        for field, value in [('team_id', 'OTHER12345'), ('source_commit', 'b' * 40)]:
            with self.subTest(field=field), patch.object(cloud, 'run') as runner:
                args = argparse.Namespace(**dict(vars(self.args), **{field: value}))
                with self.assertRaises(ValueError):
                    cloud.cloud_release(args)
                runner.assert_not_called()


if __name__ == '__main__':
    unittest.main()

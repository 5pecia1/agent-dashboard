import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
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
                                       source_commit=self.commit, submit=False, api_key_env=False, wait_seconds=0)

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

    def test_API_키는_업로드와_다운로드_때만_제한된_임시파일로_전달한다(self):
        self.args.api_key_env = True
        self.args.submit = True
        self.args.wait_seconds = 45
        private_key = '-----BEGIN PRIVATE KEY-----\nfixture-only\n-----END PRIVATE KEY-----'
        env = dict(ASC_PRIVATE_KEY=private_key, ASC_KEY_ID='FIXTURE123', ASC_ISSUER_ID=str(uuid.uuid4()))
        key_files = []

        def xcode(*cmd):
            key = Path(cmd[cmd.index('-authenticationKeyPath') + 1])
            self.assertEqual(key.read_text().strip(), private_key)
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('ASC_PRIVATE_KEY', os.environ)
            self.assertNotIn(private_key, list(map(str, cmd)))
            key_files.append(key)
            if cmd[1] == '-exportArchive':
                self.submitted('Accepted')
            else:
                self.assertEqual(cmd[1], '-exportNotarizedApp')
                self.write_app(cmd[cmd.index('-exportPath') + 1] / 'Runner.app')

        def status(command, **opts):
            self.assertEqual(command[3], self.uuid)
            self.assertEqual(Path(command[command.index('--key') + 1]), key_files[0])
            if command[2] == 'wait':
                self.assertEqual(command[command.index('--timeout') + 1], '45s')
                self.assertLessEqual(opts['timeout'], 75)
            return subprocess.CompletedProcess(command, 0, json.dumps({'id': self.uuid, 'status': 'Accepted'}))

        with (patch.dict(os.environ, env), patch.object(cloud, 'run', side_effect=xcode),
              patch.object(cloud.subprocess, 'run', side_effect=status) as poll, patch.object(cloud, 'verify') as verify):
            cloud.cloud_release(self.args)
        self.assertEqual(poll.call_count, 2)
        verify.assert_called_once()
        self.assertEqual(key_files[0], key_files[1])
        self.assertFalse(key_files[0].exists())
        self.assertTrue(self.args.output.exists())

    def test_팀_API_키_누락이나_잘못된_키가_있으면_로컬_계정으로_진행하지_않는다(self):
        self.args.api_key_env = True
        for pem in ('', 'invalid-file-content'):
            with self.subTest(pem=pem), patch.dict(os.environ, {
                'ASC_PRIVATE_KEY': pem, 'ASC_KEY_ID': 'FIXTURE123', 'ASC_ISSUER_ID': self.uuid,
            }), patch.object(cloud, 'run') as runner, self.assertRaisesRegex(ValueError, 'ASC_PRIVATE_KEY'):
                cloud.cloud_release(self.args)
            runner.assert_not_called()

    def test_대기중_거절_다른_접수번호는_즉시_중단하고_재접수하지_않는다(self):
        for status, uid in [('In Progress', self.uuid), ('Invalid', self.uuid), ('Accepted', str(uuid.uuid4()))]:
            with self.subTest(status=status), patch.object(cloud.subprocess, 'run', return_value=
                    subprocess.CompletedProcess([], 0, json.dumps({'id': uid, 'status': status}))) as query:
                with self.assertRaises(ValueError):
                    cloud.wait_for_notary(self.uuid, [], 0)
                query.assert_called_once()
                self.assertEqual(query.call_args.args[0][2], 'info')

    def test_공증_대기_기한이_지나면_현재_아카이브를_재사용한다(self):
        with (patch.object(cloud.subprocess, 'run', side_effect=subprocess.TimeoutExpired('notarytool', 31)) as query,
              self.assertRaisesRegex(ValueError, 'resume with the same archive')):
            cloud.wait_for_notary(self.uuid, [], 1)
        query.assert_called_once()

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

    def test_애플이_승인한_접수라도_내보낸_앱_서명이_다르면_배포하지_않는다(self):
        self.submitted('Accepted')
        with (patch.object(cloud, 'run', side_effect=self.download),
              patch.object(cloud, 'verify', side_effect=ValueError('unexpected bundle signature')) as gatekeeper,
              self.assertRaisesRegex(ValueError, 'unexpected bundle signature')):
            cloud.cloud_release(self.args)
        self.assertEqual(gatekeeper.call_args.args[1:], (self.identifier, self.team))
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

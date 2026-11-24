import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_ci_signing as ci


class CiSigningTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.enterContext(patch.object(Path, 'home', return_value=self.root))
        self.uuid = str(uuid.uuid4()).upper()
        self.team = 'ABC1234567'
        self.args = argparse.Namespace(team_id=self.team, bundle_id='org.example.personal', source_commit='a' * 40,
                                       archive=self.root / 'App.xcarchive', output=self.root / 'Personal.app',
                                       notary_receipt=self.root / 'receipts/apple.json', wait_seconds=30,
                                       submission_id=None)
        self.source = self.args.archive / 'Products/Applications/Source.app'
        self.plist = plistlib.dumps({'CFBundleIdentifier': self.args.bundle_id, ci.SOURCE_COMMIT_KEY: self.args.source_commit})
        (self.source / 'Contents').mkdir(parents=True)
        (self.source / 'Contents/Info.plist').write_bytes(self.plist)
        (self.args.archive / 'Info.plist').write_bytes(plistlib.dumps({
            'ApplicationProperties': {'ApplicationPath': 'Applications/Source.app'}}))
        self.state = self.args.archive / 'DashboardNotarization'
        self.state.mkdir()
        self.upload = self.state / 'unique-notary-filename.zip'
        with zipfile.ZipFile(self.upload, 'w') as archive:
            archive.writestr('Source.app/Contents/Info.plist', self.plist)
        self.digest = ci.sha256(self.upload)
        self.build = dict(team=self.team, bundle_id=self.args.bundle_id, source_commit=self.args.source_commit,
                          zip=self.upload.name, sha256=self.digest)
        (self.state / 'build.json').write_text(json.dumps(self.build))
        self.receipt = dict(status='Accepted', statusCode=0, jobId=self.uuid, sha256=self.digest)
        self.auth_env = dict(ASC_KEY_ID='FIXTURE123', ASC_ISSUER_ID=str(uuid.uuid4()),
                             ASC_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----')

    def tools(self, *command):
        if command[1:3] == ('notarytool', 'log'):
            Path(command[4]).write_text(json.dumps(self.receipt))
        elif command[:3] == ('ditto', '-x', '-k'):
            app = Path(command[-1]) / self.source.name
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(self.plist)
        elif command[:3] != ('xcrun', 'stapler', 'staple'):
            self.fail(f'unexpected tool: {command[:3]}')

    @unittest.skipIf(sys.platform == 'win32', 'macOS keychain coordination uses POSIX locks')
    def test_가져오기_실패_시_암호를_출력하지_않고_해당_키체인만_삭제한다(self):
        secret = 'synthetic-import-password'
        calls = []
        def security(command, **_options):
            calls.append(command[1])
            if command[1] == 'create-keychain':
                Path(command[-1]).touch()
            if command[1] == 'import':
                self.assertIn(secret, command)
                raise subprocess.TimeoutExpired(command, timeout=1)
            return subprocess.CompletedProcess(command, 0, stdout=b'', stderr=secret.encode())
        with patch.object(ci.subprocess, 'run', side_effect=security), self.assertRaises(ValueError) as error:
            with ci.signing_identity(base64.b64encode(b'test').decode(), secret, self.team):
                self.fail('invalid import returned an identity')
        self.assertNotIn(secret, str(error.exception))
        self.assertEqual(calls, ['create-keychain', 'list-keychains', 'list-keychains', 'unlock-keychain', 'import', 'delete-keychain'])

    @unittest.skipIf(sys.platform == 'win32', 'macOS keychain coordination uses POSIX locks')
    def test_동시에_추가하거나_제거한_키체인과_원래_검색_순서를_보존한다(self):
        first = (self.root / 'first.keychain-db').resolve()
        second = (self.root / 'second.keychain-db').resolve()
        original = [str(self.root / 'User Login.keychain-db'), str(self.root / 'other.keychain-db')]
        external = str(self.root / 'another application.keychain-db')
        visible = list(original)

        def security(operation, *args):
            if operation == 'create-keychain':
                args[-1].touch()
            elif operation == 'delete-keychain':
                visible.remove(str(args[-1]))
            elif operation == 'list-keychains' and '-s' not in args:
                return shlex.join(visible).encode()
            elif operation == 'list-keychains':
                visible[:] = [str(item) for item in args[args.index('-s') + 1:]]
            else:
                self.fail(operation)
            return b''

        with patch.object(ci, 'keychain_command', side_effect=security):
            with ci.listed_keychain(first, 'fixture'):
                self.assertEqual(visible, [*original, str(first)])
                with ci.listed_keychain(second, 'fixture'):
                    self.assertEqual(visible, [*original, str(first), str(second)])
                    visible.remove(original[0])
                    visible.insert(0, external)
                self.assertEqual(visible, [external, original[1], str(first)])
            self.assertEqual(visible, [external, original[1]])

    @unittest.skipIf(sys.platform == 'win32', 'macOS keychain coordination uses POSIX locks')
    def test_다른_팀의_서명_인증서는_거부한다(self):
        def security(operation, *args):
            if operation == 'create-keychain':
                Path(args[-1]).touch()
            if operation == 'find-identity':
                return f' 1) {"B"*40} "Developer ID Application: Other (ZZZ1234567)"\n'.encode()
            return b''
        with patch.object(ci, 'keychain_command', side_effect=security), self.assertRaisesRegex(ValueError, 'expected team'):
            with ci.signing_identity(base64.b64encode(b'test').decode(), 'test-only', self.team):
                self.fail('different team accepted')

    @unittest.skipIf(sys.platform == 'win32', 'macOS signing uses POSIX archive locks')
    def test_대기_실패_이후에는_같은_ZIP과_접수번호로_재개한다(self):
        with (patch.dict(os.environ, dict(self.auth_env), clear=True),
              patch.object(ci.subprocess, 'check_output', return_value=json.dumps({'id': self.uuid})) as submit,
              patch.object(ci, 'wait_for_notary', side_effect=ValueError('pending')),
              self.assertRaisesRegex(ValueError, 'pending')):
            ci.sign_ci(self.args)
        submit.assert_called_once()
        self.assertEqual(json.loads((self.state / 'submission.json').read_bytes())['id'], self.uuid)
        self.assertFalse(self.args.output.exists())
        with (patch.dict(os.environ, dict(self.auth_env), clear=True),
              patch.object(ci.subprocess, 'check_output') as submit_again,
              patch.object(ci, 'wait_for_notary'), patch.object(ci, 'run', side_effect=self.tools),
              patch.object(ci, 'verify') as verify):
            ci.sign_ci(self.args)
        submit_again.assert_not_called()
        verify.assert_called_once()
        self.assertTrue(self.args.output.is_dir())
        self.assertEqual(self.args.notary_receipt.read_bytes(), json.dumps(self.receipt).encode())

    def test_승인된_다른_ZIP이나_접수번호로는_배포할_수_없다(self):
        for field, value in [('status', 'Invalid'), ('statusCode', 1), ('sha256', '0' * 64), ('jobId', str(uuid.uuid4()))]:
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'exact submitted ZIP'):
                ci.accepted_receipt(json.dumps(dict(self.receipt, **{field: value})), self.uuid, self.digest)

    def test_업로드_도중_끊겼으면_자동으로_다시_올리지_않는다(self):
        (self.state / 'upload-started').touch()
        with patch.object(ci.subprocess, 'check_output', return_value='{"history": []}') as history, self.assertRaisesRegex(ValueError, 'recorded ID'):
            ci.submission_id(self.state, self.upload, [], None)
        self.assertEqual(history.call_args.args[0][2], 'history')
        self.assertEqual(ci.submission_id(self.state, self.upload, [], self.uuid), self.uuid)
        self.assertEqual(json.loads((self.state / 'submission.json').read_bytes())['id'], self.uuid)

    def test_접수번호_저장전에_끊기면_고유_ZIP_이름으로_애플_이력을_조회한다(self):
        (self.state / 'upload-started').touch()
        previous = {'history': [{'name': 'another.zip', 'id': str(uuid.uuid4())},
                                {'name': self.upload.name, 'id': self.uuid.lower()}]}
        with patch.object(ci.subprocess, 'check_output', return_value=json.dumps(previous)) as query:
            self.assertEqual(ci.submission_id(self.state, self.upload, [], None), self.uuid)
        self.assertEqual(query.call_args.args[0][2], 'history')


if __name__ == '__main__':
    unittest.main()

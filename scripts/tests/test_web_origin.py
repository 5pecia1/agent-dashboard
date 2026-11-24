import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import check_web_origin as origin


class WebOriginTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.sha = 'a' * 40
        self.tag = 'v1.0.0'
        self.file = self.directory / 'agent-dashboard-v1.0.0-web.tar.gz'
        self.file.write_bytes(b'fixture web archive')
        self.pins = self.directory / 'pins.json'
        self.pins.write_text(json.dumps({self.tag:{'commit':self.sha,'sha256':hashlib.sha256(self.file.read_bytes()).hexdigest()}}))

    def test_historical_release_is_bound_to_both_the_digest_and_commit(self):
        with patch.object(origin,'PINS',self.pins), patch.object(origin.subprocess,'run') as gh:
            origin.verify(self.file,self.tag,self.sha)
            with self.assertRaisesRegex(ValueError,'historical'):
                origin.verify(self.file,self.tag,'b' * 40)
            self.file.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'historical'):
                origin.verify(self.file,self.tag,self.sha)
            gh.assert_not_called()

    def test_new_release_requires_trusted_workflow_tag_and_source_commit(self):
        self.pins.write_text('{}')
        with patch.object(origin,'PINS',self.pins), patch.object(origin.subprocess,'run') as gh:
            origin.verify(self.file,self.tag,self.sha)
            args = gh.call_args.args[0]
            self.assertTrue(gh.call_args.kwargs['check'])
            self.assertEqual(args[args.index('--repo')+1],origin.REPO)
            self.assertEqual(args[args.index('--signer-workflow')+1],origin.WORKFLOW)
            self.assertEqual(args[args.index('--source-digest')+1],self.sha)
            self.assertEqual(args[args.index('--source-ref')+1],'refs/tags/'+self.tag)
            self.assertIn('--deny-self-hosted-runners',args)
            gh.side_effect = subprocess.CalledProcessError(1,'gh')
            with self.assertRaises(subprocess.CalledProcessError):
                origin.verify(self.file,self.tag,self.sha)
            self.assertEqual(gh.call_count,2)


if __name__ == '__main__':
    unittest.main()

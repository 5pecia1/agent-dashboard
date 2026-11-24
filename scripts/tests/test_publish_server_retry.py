"""Both release workflows share the verified draft-to-published transaction."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publish_verified_release as release


class PublicationRetryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.dir = self.root / 'release'
        self.dir.mkdir()
        self.assets = {'server.tgz': b'verified library', 'starter.tar.gz': b'verified starter'}
        for name, data in self.assets.items():
            (self.dir / name).write_bytes(data)
        self.args = argparse.Namespace(directory=self.dir, tag='server-v0.1.0-alpha.2',
                                      commit='a' * 40, notes=self.root/'notes', title='Server', latest='false',
                                      prerelease=True)
        self.remote = dict(draft=True, assets={})
        self.args.notes.write_text('Release notes')
        self.visibility_delay = 0
        self.inventory_delay = 0
        self.calls = []
        self.resolved = self.args.commit

    def gh(self, *args):
        self.calls.append(args)
        if args[0] == 'api':
            if args[1] == 'graphql':
                obj = {'databaseId': 123} if self.remote is not None else None
                if obj and self.visibility_delay > 0:
                    self.visibility_delay -= 1
                    obj = None
                return json.dumps({'data':{'repository':{'release':obj}}})
            if '--method' in args:
                method = args[args.index('--method') + 1]
                if method == 'POST':
                    self.assertIn('draft=true', args)
                    self.assertIsNone(self.remote)
                    self.remote = dict(draft=True, assets={})
                    return json.dumps(dict(id=123, tag_name=self.args.tag, draft=True))
                self.assertEqual(method, 'PATCH')
                self.assertIn('draft=false', args)
                self.assertIn('repos/example/project/releases/123', args)
                self.assertEqual(self.remote['assets'], self.assets)
                self.assertTrue(self.remote['draft'])
                self.remote['draft'] = False
                return '{}'
            if '--paginate' in args:
                self.assertIn('/releases/123/assets', args[-1])
                if len(self.remote['assets']) == len(self.assets) and self.inventory_delay:
                    self.inventory_delay -= 1
                    return '[[]]'
                return json.dumps([[dict(name=n, state='uploaded', digest='sha256:'+hashlib.sha256(v).hexdigest())
                                    for n,v in self.remote['assets'].items()]])
            if '/commits/' in args[1]:
                return self.resolved
            self.assertTrue(args[1].endswith('/releases/123'))
            return json.dumps(dict(id=123, tag_name=self.args.tag, draft=self.remote['draft']))
        self.assertEqual(args[:2], ('release','upload'))
        name = Path(args[-1]).name
        self.assertTrue(self.remote['draft'])
        self.assertNotIn(name,self.remote['assets'])
        self.assertNotIn('--clobber',args)
        self.remote['assets'][name] = (self.dir/name).read_bytes()
        return ''

    def publish(self):
        with patch.dict(os.environ, {'GH_REPO':'example/project'}), patch.object(release, 'gh', side_effect=self.gh):
            release.publish(self.args)

    def test_new_release_has_all_assets_before_publication(self):
        self.remote = None
        self.publish()
        self.assertFalse(self.remote['draft'])

    def test_new_draft_and_last_uploaded_asset_can_take_time_to_be_visible(self):
        self.remote = None
        self.visibility_delay = 2
        self.inventory_delay = 2
        with patch.object(release.time, 'sleep') as wait:
            self.publish()
        self.assertEqual(wait.call_count, 4)
        self.assertEqual(sum('POST' in args for args in self.calls), 1)
        self.assertEqual(sum('PATCH' in args for args in self.calls), 1)
        self.assertEqual(sum(args[:2] == ('release','upload') for args in self.calls), len(self.assets))
        self.assertFalse(self.remote['draft'])

    def test_partial_upload_is_completed_before_publication(self):
        self.remote['assets']['server.tgz'] = self.assets['server.tgz']
        self.publish()
        self.assertFalse(self.remote['draft'])
        self.assertEqual(sum(a[:2] == ('release','upload') for a in self.calls),1)

    def test_different_existing_asset_blocks_all_uploads(self):
        self.remote['assets']['starter.tar.gz'] = b'different'
        with self.assertRaisesRegex(ValueError,'bytes differ'):
            self.publish()
        self.assertFalse(any(a[0]=='release' for a in self.calls))

    def test_complete_release_retries_without_overwriting(self):
        self.remote = dict(draft=False, assets=dict(self.assets))
        self.publish()
        self.assertFalse(any(a[0]=='release' for a in self.calls))

    def test_missing_published_asset_never_receives_an_upload(self):
        self.remote = dict(draft=False, assets={})
        with self.assertRaisesRegex(ValueError,'published release has missing'):
            self.publish()
        self.assertFalse(any(a[0]=='release' for a in self.calls))

    def test_moved_tag_is_rejected_before_publication(self):
        self.resolved = 'b' * 40
        with self.assertRaisesRegex(ValueError,'tag differs'):
            self.publish()
        self.assertFalse(any(a[0]=='release' for a in self.calls))


if __name__ == '__main__':
    unittest.main()

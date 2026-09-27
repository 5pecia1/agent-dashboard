import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/pages_deployment.py'
if not SCRIPT.is_file():
    SCRIPT = ROOT / 'distribution/public/scripts/pages_deployment.py'
SPEC = importlib.util.spec_from_file_location('pages_deployment', SCRIPT)
pages = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pages)

ORIGIN = 'https://example.pages.dev'
COMMIT = 'a' * 40
TOKEN = 'synthetic-test-token'


def manifest(tag='v0.1.1', commit=COMMIT):
    return {'schema': 1, 'product': 'Agent Dashboard', 'platform': 'web',
            'tag': tag, 'version': tag[1:], 'source_commit': commit}


def deployment(status='success', stage='deploy'):
    return {'environment': 'production', 'latest_stage': {'name': stage, 'status': status}}


def response(value):
    return io.BytesIO(json.dumps(value).encode())


def project_response(branch='main'):
    return response({'success': True, 'result': {'production_branch': branch}})


class PagesDeploymentTests(unittest.TestCase):
    def check(self, **kwargs):
        options = {'origin': ORIGIN, 'account': 'account', 'project': 'project',
                   'token': TOKEN, 'tag': 'v0.1.1'}
        options.update(kwargs)
        return pages.check_before_deploy(**options)

    def test_checked_page_size_follows_history_and_does_not_send_token_to_site(self):
        urls = []

        def cloudflare(request, timeout):
            url = urllib.parse.urlsplit(request.full_url)
            urls.append(url)
            if url.hostname == 'api.cloudflare.com':
                self.assertEqual(request.get_header('Authorization'), 'Bearer ' + TOKEN)
                if url.path.endswith('/projects/project'):
                    return project_response()
                query = urllib.parse.parse_qs(url.query)
                # The live API returned HTTP 400/code 8000024 for the old size 100.
                if query.get('per_page') != ['20']:
                    raise urllib.error.HTTPError(request.full_url, 400, 'Bad Request', {},
                        response({'success': False, 'errors': [
                            {'code': 8000024, 'message': 'Invalid list options'}]}))
                self.assertEqual(query.get('env'), ['production'])
                self.assertEqual(request.get_header('Authorization'), 'Bearer ' + TOKEN)
                self.assertIn('AgentDashboard', request.get_header('User-agent'))
                if query['page'] == ['1']:
                    return response({'success': True, 'result': [deployment('failure')] * 20,
                                     'result_info': {'total_pages': 2}})
                self.assertEqual(query['page'], ['2'])
                return response({'success': True, 'result': [deployment()],
                                 'result_info': {'total_pages': 2}})
            self.assertEqual(url.hostname, 'example.pages.dev')
            self.assertIsNone(request.get_header('Authorization'))
            return response(manifest())

        with patch.object(pages.urllib.request, 'urlopen', side_effect=cloudflare):
            self.assertEqual(self.check(token='  ' + TOKEN + '\n'), 'v0.1.1')
        self.assertEqual(len(urls), 4)

    def test_page_history_without_counts_keeps_searching_full_pages(self):
        values = [project_response(), response({'success': True, 'result': [deployment('failure')] * 20}),
                  response({'success': True, 'result': [deployment()]}), response(manifest())]
        with patch.object(pages.urllib.request, 'urlopen', side_effect=values) as get:
            self.assertEqual(self.check(), 'v0.1.1')
            self.assertEqual(get.call_count, 4)

    def test_first_deployment_does_not_require_existing_manifest(self):
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[project_response(), response(
                {'success': True, 'result': []})]) as get:
            self.assertIsNone(self.check())
            self.assertEqual(get.call_count, 2)

    def test_preview_checks_access_without_inspecting_production_manifest(self):
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[project_response(), response(
                {'success': True, 'result': [deployment()]})]) as get:
            self.assertIsNone(self.check(tag='v0.2.0-alpha.1'))
            self.assertEqual(get.call_count, 2)
        error = urllib.error.HTTPError('https://api.cloudflare.com/', 403, 'Forbidden', {}, io.BytesIO(b''))
        with patch.object(pages.urllib.request, 'urlopen', side_effect=error):
            with self.assertRaisesRegex(pages.DeploymentError, 'HTTP 403'):
                self.check(tag='v0.2.0-alpha.1')

    def test_successful_build_does_not_count_as_a_deployed_release(self):
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[project_response(), response(
                {'success': True, 'result': [deployment(stage='build')]})]) as get:
            self.assertIsNone(self.check())
            self.assertEqual(get.call_count, 2)

    def test_production_branch_mismatch_blocks_stable_and_preview(self):
        for tag in ('v0.1.1', 'v0.2.0-alpha.1'):
            for branch in ('master', 'release-v0-2-0-alpha-1', None):
                with self.subTest(tag=tag, branch=branch), patch.object(
                        pages.urllib.request, 'urlopen', return_value=project_response(branch)) as get:
                    with self.assertRaisesRegex(pages.DeploymentError, 'production branch to main'):
                        self.check(tag=tag)
                    self.assertEqual(get.call_count, 1)

    def test_unverifiable_project_settings_block_deployment(self):
        for data in ([], {'success': False}, {'success': True, 'result': []}):
            with self.subTest(data=data), patch.object(
                    pages.urllib.request, 'urlopen', return_value=response(data)):
                with self.assertRaisesRegex(pages.DeploymentError, 'project settings'):
                    self.check()

    def test_cloudflare_error_reports_real_error_but_redacts_secret(self):
        body = {'success': False, 'errors': [
            {'code': 8000024, 'message': 'Invalid list options: ' + TOKEN}]}
        error = urllib.error.HTTPError('https://api.cloudflare.com/', 400, 'Bad Request', {}, response(body))
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[project_response(), error]):
            with self.assertRaises(pages.DeploymentError) as raised:
                self.check()
        message = str(raised.exception)
        self.assertIn('HTTP 400', message)
        self.assertIn('8000024: Invalid list options', message)
        self.assertIn('[REDACTED]', message)
        self.assertNotIn(TOKEN, message)

    def test_opaque_error_body_is_never_logged(self):
        error = urllib.error.HTTPError('https://api.cloudflare.com/', 403, 'Forbidden', {},
                                       io.BytesIO(('secret dump ' + TOKEN).encode()))
        with patch.object(pages.urllib.request, 'urlopen', side_effect=error):
            with self.assertRaisesRegex(pages.DeploymentError, 'HTTP 403') as raised:
                self.check()
        self.assertNotIn('secret dump', str(raised.exception))
        self.assertNotIn(TOKEN, str(raised.exception))

    def test_invalid_tokens_rejected_before_network(self):
        for token in ('', '  ', 'Bearer ' + TOKEN, 'bad token', 'bad\ntoken'):
            with self.subTest(token=token), patch.object(pages.urllib.request, 'urlopen') as get:
                with self.assertRaises(pages.DeploymentError):
                    self.check(token=token)
                get.assert_not_called()

    def test_history_failures_do_not_allow_deployment(self):
        for data in ([], {'success': False, 'result': []},
                     {'success': True, 'result': 'invalid'},
                     {'success': True, 'result': [None]},
                     {'success': True, 'result': [deployment('failure')],
                      'result_info': {'total_pages': '2'}}):
            with self.subTest(data=data), patch.object(pages.urllib.request, 'urlopen', side_effect=[
                    project_response(), response(data)]):
                with self.assertRaises(pages.DeploymentError):
                    self.check()

    def test_missing_or_malformed_production_manifest_blocks_even_rollback(self):
        invalid = [[], {}, manifest('v0.2.0') | {'source_commit': ''},
                   manifest() | {'product': 'other'}, manifest() | {'version': '9.0.0'},
                   manifest() | {'tag': 1}, manifest() | {'source_commit': 42}]
        for value in invalid:
            with self.subTest(value=value), patch.object(pages.urllib.request, 'urlopen', side_effect=[
                    project_response(), response({'success': True, 'result': [deployment()]}), response(value)]):
                with self.assertRaisesRegex(pages.DeploymentError, 'metadata is invalid'):
                    self.check(allow_rollback=True)
        missing = urllib.error.HTTPError(ORIGIN, 404, 'Not Found', {}, io.BytesIO(b''))
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[
                project_response(), response({'success': True, 'result': [deployment()]}), missing]):
            with self.assertRaisesRegex(pages.DeploymentError, 'manifest returned HTTP 404'):
                self.check(allow_rollback=True)

    def test_rollbacks_require_explicit_true_and_compare_numbers(self):
        for allow in (False, 'false', 'true', True):
            with self.subTest(allow=allow), patch.object(pages.urllib.request, 'urlopen', side_effect=[
                    project_response(), response({'success': True, 'result': [deployment()]}), response(manifest('v0.10.0'))]):
                if allow is True:
                    self.assertEqual(self.check(tag='v0.9.0', allow_rollback=allow), 'v0.10.0')
                else:
                    with self.assertRaisesRegex(pages.DeploymentError, 'explicit allow_rollback'):
                        self.check(tag='v0.9.0', allow_rollback=allow)

    def test_unbounded_history_fails_closed(self):
        def never_ending(request, **kwargs):
            if request.full_url.endswith('/projects/project'):
                return project_response()
            return response({'success': True, 'result': [deployment('failure')] * 20})
        with patch.object(pages.urllib.request, 'urlopen', side_effect=never_ending) as get:
            with self.assertRaisesRegex(pages.DeploymentError, 'lookup limit'):
                self.check()
            self.assertEqual(get.call_count, 51)

    def test_confirm_retries_transient_failures_and_stale_manifest(self):
        transient = urllib.error.URLError('temporary failure')
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[
                transient, response(manifest(commit='b' * 40)), response(manifest())]) as get, \
                patch.object(pages.time, 'sleep') as sleep:
            self.assertEqual(pages.confirm_deployment(ORIGIN, 'v0.1.1', COMMIT), manifest())
            self.assertEqual(sleep.call_count, 2)
            self.assertTrue(all(call.kwargs['timeout'] == 20 for call in get.call_args_list))

    def test_confirm_never_accepts_wrong_product_or_commit(self):
        with patch.object(pages.urllib.request, 'urlopen', side_effect=[
                response(manifest() | {'product': 'other'}),
                response(manifest(commit='b' * 40))]), patch.object(pages.time, 'sleep') as sleep:
            with self.assertRaisesRegex(pages.DeploymentError, 'expected release manifest'):
                pages.confirm_deployment(ORIGIN, 'v0.1.1', COMMIT, attempts=2)
            self.assertEqual(sleep.call_count, 1)


if __name__ == '__main__':
    unittest.main()

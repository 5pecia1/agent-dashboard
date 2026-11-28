"""Exercise real helper processes, curl requests and shell event spooling."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'hooks/device-auth.py'
spec = importlib.util.spec_from_file_location('hook_device_auth', HELPER)
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


class DeviceConnectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name)
        self.refreshes = 0
        self.received = []
        self.available = True
        self.revoked = False
        self.access = 'mdi_' + 'a' * 64
        self.refresh = 'b' * 64
        case = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, status, value=None):
                self.send_response(status)
                self.end_headers()
                if value is not None:
                    self.wfile.write(json.dumps(value).encode())

            def do_GET(self):
                if self.path.startswith('/hooks/files/'):
                    name = self.path.rsplit('/', 1)[-1]
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write((ROOT / 'hooks' / name).read_bytes())
                    return
                if case.revoked or self.headers.get('Authorization') != 'Bearer ' + case.access:
                    return self.reply(401, {'error':'unauthorized'})
                self.reply(204)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if not case.available:
                    return self.reply(503, {'error':'unavailable'})
                if self.path.endswith('/device'):
                    return self.reply(200, {'device_code':'e'*64, 'user_code':'AAAA-BBBB',
                        'verification_uri':'https://account.example.test/approve',
                        'verification_uri_complete':'https://account.example.test/approve#user_code=AAAA-BBBB',
                        'expires_in':60, 'interval':1})
                if self.path.endswith('/token'):
                    return self.reply(200, {'scope':auth.SCOPE, 'token_type':'Bearer',
                        'access_token':case.access, 'refresh_token':case.refresh, 'expires_in':604800})
                if self.path.endswith('/refresh'):
                    if case.revoked or body['refresh_token'] != case.refresh:
                        return self.reply(400, {'error':'invalid_grant'})
                    case.refreshes += 1
                    case.access = 'mdi_' + 'c' * 64
                    case.refresh = 'd' * 64
                    return self.reply(200, {'scope':auth.SCOPE, 'token_type':'Bearer',
                                           'access_token':case.access, 'refresh_token':case.refresh, 'expires_in':604800})
                if case.revoked or self.headers.get('Authorization') != 'Bearer ' + case.access:
                    return self.reply(401, {'error':'unauthorized'})
                case.received.append(body)
                self.reply(200, {'status':'ok'})

        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.server = f'http://127.0.0.1:{self.http.server_port}'
        self.environment = dict(os.environ, HOME=str(self.home), MY_DASHBOARD_URL=self.server,
                                MY_DASHBOARD_AUTH='device', MY_DASHBOARD_INCLUDE_CONTENT='1')
        for name in ('MY_DASHBOARD_ENV','MY_DASHBOARD_STATE_DIR','MY_DASHBOARD_TOKEN','CODEX_HOME','MY_DASHBOARD_CODEX_CONFIG'):
            self.environment.pop(name, None)
        self.connection = auth.DeviceAuth(self.server, self.home / '.config/my-dashboard',
                                         self.home / '.local/state/my-dashboard')
        self.connection.save({'scope':auth.SCOPE, 'token_type':'Bearer', 'access_token':self.access,
                              'refresh_token':self.refresh, 'expires_in':604800})

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
        self.directory.cleanup()

    def helper(self, command, payload=None):
        return subprocess.run([sys.executable, str(HELPER), command, '--server', self.server],
                              input=json.dumps(payload) if payload is not None else None,
                              text=True, capture_output=True, env=self.environment, timeout=8)

    def event(self, event_id):
        environment = dict(self.environment, MY_DASHBOARD_EVENT_ID=event_id)
        result = subprocess.run(['bash', str(ROOT / 'hooks/send-generic.sh'), 'fixture-session', 'done', 'hello'],
                                env=environment, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_concurrent_expiry_rotates_once_and_delivers_every_payload(self):
        value = self.connection.record()
        value['expires'] = time.time() - 1
        auth.write_json(self.connection.path, value)
        processes = [subprocess.Popen([sys.executable, str(HELPER), 'send', '--server', self.server],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, env=self.environment) for _ in range(4)]
        for number, process in enumerate(processes):
            process.stdin.write(json.dumps({'event_id':str(number)}))
            process.stdin.close()
            process.stdin = None
        for process in processes:
            output, errors = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output.strip(), '200')
            self.assertNotIn(self.access, output + errors)
        self.assertEqual(self.refreshes, 1)
        self.assertEqual({event['event_id'] for event in self.received}, {'0','1','2','3'})
        self.assertEqual(self.connection.path.stat().st_mode & 0o777, 0o600)

    def test_offline_event_survives_and_replays_before_the_next_event(self):
        self.available = False
        self.event('offline-event')
        spool = self.connection.state / 'spool.ndjson'
        self.assertEqual(json.loads(spool.read_text())['event_id'], 'offline-event')
        self.available = True
        self.event('online-event')
        self.assertEqual([event['event_id'] for event in self.received], ['offline-event','online-event'])
        self.assertEqual(spool.read_text(), '')
        status = auth.read_json(self.connection.state / 'collection-status.json')
        self.assertGreater(status['last_sent_at'], 0)

    def test_missing_and_revoked_credentials_keep_events_and_report_reconnection(self):
        self.revoked = True
        self.event('revoked-event')
        status = auth.read_json(self.connection.state / 'collection-status.json')
        self.assertEqual(status['state'], 'login_required')
        self.assertNotIn('last_sent_at', status)
        self.connection.path.unlink()
        self.event('missing-event')
        lines = (self.connection.state / 'spool.ndjson').read_text().splitlines()
        self.assertEqual([json.loads(line)['event_id'] for line in lines], ['revoked-event','missing-event'])
        self.assertEqual(self.received, [])

    def test_successful_auth_check_does_not_erase_delivery_failure(self):
        self.connection.observe('rejected', time.time())
        result = self.helper('check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        status = auth.read_json(self.connection.state / 'collection-status.json')
        self.assertEqual(status['auth_state'], 'connected')
        self.assertEqual(status['state'], 'rejected')
        self.assertNotIn('last_sent_at', status)

    def test_credentials_cannot_be_sent_to_a_different_server(self):
        other = auth.DeviceAuth('http://127.0.0.1:1', self.connection.config, self.connection.state)
        with self.assertRaisesRegex(auth.ConnectionError, 'invalid_credentials'):
            other.credential(time.monotonic() + 1)

    def test_downloaded_setup_connects_an_existing_tokenless_env_and_is_idempotent(self):
        self.connection.path.unlink()
        settings = self.connection.config / 'env'
        settings.write_text('# keep my comment\nMY_DASHBOARD_INCLUDE_CONTENT=1\n')
        script = self.home / 'setup.sh'
        script.write_text((ROOT / 'hooks/setup.sh').read_text().replace('__MY_DASHBOARD_ORIGIN__', self.server))
        environment = dict(self.environment, XDG_DATA_HOME=str(self.home / '.local/share'))
        for key in ('MY_DASHBOARD_AUTH','MY_DASHBOARD_URL'):
            environment.pop(key, None)
        def install():
            result = subprocess.run(['bash', str(script), '--device-auth', '--include-content'],
                                    env=environment, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn(self.access, result.stdout + result.stderr)
            return result
        first = install()
        self.assertIn('approval_required', first.stdout)
        original = settings.read_bytes()
        second = install()
        self.assertNotIn('approval_required', second.stdout)
        self.assertEqual(settings.read_bytes(), original)
        self.assertEqual(original.count(b'MY_DASHBOARD_INCLUDE_CONTENT=1'), 1)
        self.assertIn(b'# keep my comment', original)
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.home / '.local/share/my-dashboard/hooks/transport.sh').is_file())
        self.assertIn('agent-event-hook.sh', (self.home / '.codex/hooks.json').read_text())

    def test_downloaded_setup_rejects_codex_conflict_before_changing_an_installation(self):
        hook = self.home / '.local/share/my-dashboard/hooks/install.sh'
        hook.parent.mkdir(parents=True)
        hook.write_text('old installed script')
        config = self.home / '.codex/config.toml'
        config.parent.mkdir()
        config.write_text('[[hooks.Stop]]\n')
        settings = self.connection.config / 'env'
        settings.write_text('# existing settings\n')
        script = (ROOT / 'hooks/setup.sh').read_text().replace('__MY_DASHBOARD_ORIGIN__', self.server)
        result = subprocess.run(['bash', '-s', '--', '--device-auth'], input=script, env=dict(
            self.environment, XDG_DATA_HOME=str(self.home / '.local/share')), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('move custom Codex TOML hook events', result.stderr)
        self.assertEqual(settings.read_text(), '# existing settings\n')
        self.assertEqual(hook.read_text(), 'old installed script')
        self.assertEqual(set(hook.parent.iterdir()), {hook})
        self.assertFalse((config.parent / 'hooks.json').exists())

    def test_status_recognizes_codex_json_and_legacy_toml_at_configured_paths(self):
        layer = self.home / 'codex layer'
        layer.mkdir()
        config = layer / 'config.toml'
        hooks = layer / 'hooks.json'
        self.environment['MY_DASHBOARD_CODEX_CONFIG'] = str(config)
        marker = 'agent-event-hook.sh'
        def status():
            return json.loads(self.helper('status').stdout)['state']
        config.write_text(f'[hooks.state."{marker}"]\ntrusted_hash = "fixture"\n')
        hooks.write_text(json.dumps({'note': marker, 'hooks': {}}))
        self.assertEqual(status(), 'missing_hooks')
        hooks.write_text(json.dumps({'hooks': {'Stop': [{'hooks': [
            {'type': 'command', 'command': f'/example/{marker} codex'}]}]}}))
        self.assertEqual(status(), 'missing_hooks')  # another integration's namesake script
        script = self.home / '.local/share/my-dashboard/hooks' / marker
        hooks.write_text(json.dumps({'hooks': {'Stop': [{'hooks': [
            {'type': 'command', 'command': f'{script} codex'}]}]}}))
        self.assertNotEqual(status(), 'missing_hooks')
        hooks.unlink()
        legacy = (ROOT / 'scripts/tests/fixtures/codex-alpha10.toml').read_text()
        config.write_text(legacy.replace('/previous/home', str(self.home)))
        self.assertNotEqual(status(), 'missing_hooks')

    def test_status_failure_cannot_turn_an_accepted_event_into_a_retry(self):
        with auth.lock(self.connection.state / 'collection-status.lock', time.monotonic() + 1):
            result = self.helper('send', {'event_id':'accepted'})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '200')
        self.assertEqual(self.received, [{'event_id':'accepted'}])

    def test_http_unavailable_remains_distinct_from_connection_failure(self):
        self.available = False
        result = self.helper('send', {'event_id':'unavailable'})
        self.assertEqual(result.stdout.strip(), '503')
        self.assertEqual(result.returncode, 1)

    def test_malformed_credentials_fail_with_a_structured_error(self):
        self.connection.path.write_text('[]')
        result = self.helper('check')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['error'], 'invalid_credentials')
        self.assertNotIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()

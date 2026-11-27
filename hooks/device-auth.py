#!/usr/bin/env python3
"""Browser-approved hook credentials and bounded event delivery (stdlib only)."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

SCOPE = 'dashboard:ingest'
AUTH_PATH = '/dashboard/ingest-auth'


class ConnectionError(Exception):
    def __init__(self, code, status=0):
        self.code = code
        self.status = status
        super().__init__(code)


def origin(value):
    parsed = urlsplit(value)
    if (parsed.scheme not in ('https', 'http') or not parsed.hostname or
            parsed.username or parsed.password or parsed.query or parsed.fragment or
            parsed.path not in ('', '/') or
            (parsed.scheme == 'http' and parsed.hostname not in ('127.0.0.1', 'localhost', '::1'))):
        raise ConnectionError('invalid_server')
    return value.rstrip('/')


def read_json(path):
    try:
        with path.open() as stream:
            value = json.load(stream)
            if not isinstance(value, dict):
                raise ConnectionError('invalid_credentials')
            return value
    except FileNotFoundError:
        return None


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=path.name + '.')
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def lock(path, deadline):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ConnectionError('busy')
                time.sleep(0.02)
        yield
    finally:
        os.close(descriptor)


def request(server, path, method, deadline, body=None, token=None):
    """Keep credentials off the process command line and never follow redirects."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ConnectionError('network')
    config = ['silent', 'show-error', 'user-agent = "AgentDashboard-Hooks/1"']
    if token:
        if not re.fullmatch(r'[A-Za-z0-9._~+/=-]+', token):
            raise ConnectionError('invalid_credentials')
        config.append('header = "Authorization: Bearer ' + token + '"')
    command = ['curl', '--disable', '--config', '-', '--max-time', str(remaining), '--request', method,
               '--write-out', '\n%{http_code}', '--url', server + path]
    if body is not None:
        # curl config input carries both headers and body, without temp secret files.
        payload = json.dumps(body, ensure_ascii=True, separators=(',', ':'))
        config.extend(['header = "Content-Type: application/json"',
                       'data-binary = ' + json.dumps(payload)])
    try:
        result = subprocess.run(command, input='\n'.join(config) + '\n', text=True,
                                capture_output=True, timeout=remaining + 0.2)
    except subprocess.TimeoutExpired:
        raise ConnectionError('network') from None
    if result.returncode:
        raise ConnectionError('network')
    content, _, code = result.stdout.rpartition('\n')
    if len(content) > 16384 or not code.isdigit():
        raise ConnectionError('invalid_response')
    status = int(code)
    if status == 429:
        raise ConnectionError('rate_limited', status)
    if status >= 500:
        raise ConnectionError('unavailable', status)
    if 300 <= status < 400:
        raise ConnectionError('invalid_response')
    try:
        value = json.loads(content) if content else {}
    except ValueError:
        raise ConnectionError('invalid_response') from None
    if not isinstance(value, dict):
        raise ConnectionError('invalid_response')
    return status, value


class DeviceAuth:
    def __init__(self, server, config_dir=None, state_dir=None):
        self.server = origin(server)
        self.config = Path(config_dir or Path.home() / '.config/my-dashboard')
        self.state = Path(state_dir or os.environ.get('MY_DASHBOARD_STATE_DIR') or
                          Path.home() / '.local/state/my-dashboard')
        self.path = self.config / 'ingest-auth.json'
        self.lock_path = self.config / 'ingest-auth.lock'

    def record(self):
        value = read_json(self.path)
        if value is None:
            raise ConnectionError('login_required')
        if (value.get('origin') != self.server or value.get('scope') != SCOPE or
                not re.fullmatch(r'mdi_[a-f0-9]{64}', str(value.get('access', ''))) or
                not re.fullmatch(r'[a-f0-9]{64}', str(value.get('refresh', ''))) or
                not isinstance(value.get('expires'), (int, float))):
            raise ConnectionError('invalid_credentials')
        if self.path.stat().st_mode & 0o077:
            raise ConnectionError('private_storage_required')
        return value

    def save(self, response):
        if (response.get('scope') != SCOPE or response.get('token_type') != 'Bearer' or
                not re.fullmatch(r'mdi_[a-f0-9]{64}', str(response.get('access_token', ''))) or
                not re.fullmatch(r'[a-f0-9]{64}', str(response.get('refresh_token', ''))) or
                type(response.get('expires_in')) is not int or
                not 0 < response['expires_in'] <= 31 * 86400):
            raise ConnectionError('invalid_response')
        value = dict(origin=self.server, scope=SCOPE, access=response['access_token'],
                     refresh=response['refresh_token'], expires=time.time() + response['expires_in'])
        write_json(self.path, value)
        return value

    def credential(self, deadline, rejected=None):
        with lock(self.lock_path, deadline):
            value = self.record()
            if value['expires'] > time.time() + 30 and value['access'] != rejected:
                return value['access']
            status, response = request(self.server, AUTH_PATH + '/refresh', 'POST', deadline,
                                       {'scope': SCOPE, 'refresh_token': value['refresh']})
            if status in (400, 401, 403):
                raise ConnectionError('login_required', 401)
            if status != 200:
                raise ConnectionError('invalid_response')
            return self.save(response)['access']

    def authenticated(self, path, method, deadline, body=None):
        token = self.credential(deadline)
        status, response = request(self.server, path, method, deadline, body, token)
        if status == 401:
            token = self.credential(deadline, rejected=token)
            status, response = request(self.server, path, method, deadline, body, token)
        if status in (401, 403):
            raise ConnectionError('login_required', status)
        if not 200 <= status < 300:
            raise ConnectionError('rejected', status)
        return status, response

    def observe(self, state, started, sent=False, checking=False):
        record = dict(origin=self.server, state=state, attempted_at=started)
        path = self.state / 'collection-status.json'
        with lock(self.state / 'collection-status.lock', time.monotonic() + 0.1):
            previous = read_json(path) or {}
            if previous.get('origin') == self.server:
                for key in ('last_sent_at', 'last_checked_at', 'auth_state'):
                    if key in previous:
                        record[key] = previous[key]
                if previous.get('attempted_at', 0) > started:
                    return
                if checking:
                    record['state'] = previous.get('state', state)
                    if state == 'connected' and record['state'] in ('login_required', 'disconnected', 'invalid_credentials'):
                        record['state'] = 'waiting_event'
            if checking:
                record['auth_state'] = state
                record['last_checked_at'] = time.time()
            if sent:
                record['auth_state'] = 'connected'
                record['last_sent_at'] = time.time()
            write_json(path, record)

    def check(self):
        self.authenticated('/dashboard/auth/ingest-check', 'GET', time.monotonic() + 5)

    def login(self):
        try:
            self.check()
            return False
        except ConnectionError as error:
            if error.code not in ('login_required', 'invalid_credentials', 'private_storage_required'):
                raise
        # Hold the credential lock through approval so two installers cannot replace
        # one another's grant or leave an untracked active grant after cancellation.
        with lock(self.lock_path, time.monotonic() + 0.3):
            status, challenge = request(self.server, AUTH_PATH + '/device', 'POST',
                                        time.monotonic() + 12, {'scope': SCOPE})
            if status != 200:
                raise ConnectionError('login_unsupported')
            code = challenge.get('user_code', '')
            page = challenge.get('verification_uri', '')
            parsed = urlsplit(page)
            if (not re.fullmatch(r'[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}', code) or
                    parsed.scheme != 'https' or not parsed.hostname or parsed.username or
                    parsed.password or parsed.fragment or parsed.query or
                    challenge.get('verification_uri_complete') != page + '#user_code=' + code or
                    not re.fullmatch(r'[a-f0-9]{64}', str(challenge.get('device_code', ''))) or
                    type(challenge.get('expires_in')) is not int or not 0 < challenge['expires_in'] <= 1200 or
                    type(challenge.get('interval')) is not int or not 0 < challenge['interval'] <= 120):
                raise ConnectionError('invalid_response')
            print(json.dumps(dict(status='approval_required', user_code=code,
                                  verification_uri=challenge['verification_uri_complete'])), flush=True)
            expires = time.monotonic() + challenge['expires_in']
            interval = challenge['interval']
            while time.monotonic() + interval < expires:
                time.sleep(interval)
                try:
                    status, response = request(self.server, AUTH_PATH + '/token', 'POST',
                                               min(expires, time.monotonic() + 12),
                                               {'scope': SCOPE, 'device_code': challenge['device_code']})
                except ConnectionError as error:
                    if error.code not in ('network', 'rate_limited', 'unavailable'):
                        raise
                    interval = min(60, interval + 5)
                    continue
                if status == 200:
                    self.save(response)
                    return True
                if response.get('error') != 'authorization_pending':
                    raise ConnectionError('approval_failed')
            raise ConnectionError('approval_expired')

    def disconnect(self):
        write_json(self.state / 'collection-disabled', {'disabled': True})
        with lock(self.lock_path, time.monotonic() + 5):
            value = self.record()
            status, response = request(self.server, AUTH_PATH + '/token', 'DELETE',
                                       time.monotonic() + 5, {'scope': SCOPE, 'refresh_token': value['refresh']})
            if status != 200 and response.get('error') != 'invalid_grant':
                raise ConnectionError('revoke_failed')
            self.path.unlink()

    def status(self):
        configuration = self.config / 'env'
        values = ['', '', '']
        if configuration.exists():
            result = subprocess.run(['bash', '-c',
                '. "$1" >/dev/null 2>&1; printf "%s\\0%s\\0%s" "${MY_DASHBOARD_URL:-}" "${MY_DASHBOARD_AUTH:-}" "${MY_DASHBOARD_TOKEN:+present}"',
                'dashboard-status', str(configuration)], capture_output=True, timeout=2)
            if result.returncode:
                raise ConnectionError('invalid_credentials')
            values = result.stdout.decode().split('\0')
        server, mode, legacy = values
        value = read_json(self.state / 'collection-status.json') or {}
        if value.get('origin') != self.server:
            value = {}
        state = value.get('auth_state', 'connected')
        if state == 'connected':
            state = value.get('state', 'waiting_event')
        if (self.state / 'collection-disabled').exists():
            state = 'disconnected'
        elif server.rstrip('/') != self.server:
            state = 'login_required'
        elif mode != 'device':
            state = 'legacy' if legacy else 'login_required'
        else:
            try:
                self.record()
            except ConnectionError as error:
                state = error.code
        spool = self.state / 'spool.ndjson'
        queued = 0
        if spool.exists():
            with spool.open('rb') as stream:
                queued = sum(bool(line.strip()) for line in stream)
        if state == 'connected' and not value.get('last_sent_at'):
            state = 'waiting_event'
        registrations = [Path.home() / name for name in (
            '.claude/settings.json', '.codex/config.toml', '.config/devin/config.json',
            '.gemini/config/hooks.json', '.config/opencode/plugins/my-dashboard.js')]
        registered = False
        for path in registrations:
            if path.exists():
                text = '\n'.join(line for line in path.read_text().splitlines()
                                 if not line.lstrip().startswith(('#', '//')))
                if any(name in text for name in ('agent-event-hook.sh', 'codex-notify.sh', 'opencode-plugin.mjs')):
                    registered = True
                    break
        if not registered and state != 'disconnected':
            state = 'missing_hooks'
        return {'state': state, 'last_sent_at': value.get('last_sent_at'), 'queued': queued,
                'device': mode == 'device' and self.path.exists()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['login', 'check', 'send', 'disconnect', 'status'])
    parser.add_argument('--server', required=True)
    args = parser.parse_args()
    started = time.time()
    connection = DeviceAuth(args.server)
    http_status = 0
    try:
        if args.command == 'status':
            print(json.dumps(connection.status()))
            return 0
        if args.command == 'send':
            payload = json.load(sys.stdin)
            http_status, _ = connection.authenticated('/dashboard/events', 'POST', time.monotonic() + 1.8, payload)
            try:
                connection.observe('connected', started, sent=True)
            except (ConnectionError, OSError, ValueError):
                pass  # The server's acknowledgement determines whether to retry.
            print(http_status)
        elif args.command == 'login':
            if connection.login():
                connection.check()
            (connection.state / 'collection-disabled').unlink(missing_ok=True)
            connection.observe('connected', started, checking=True)
            print('{"status":"authorized"}', flush=True)
        elif args.command == 'check':
            connection.check()
            connection.observe('connected', started, checking=True)
            print('{"status":"authorized"}')
        else:
            connection.disconnect()
            connection.observe('disconnected', started, checking=True)
            print('{"status":"disconnected"}')
    except (ConnectionError, OSError, ValueError) as error:
        code = error.code if isinstance(error, ConnectionError) else 'local_error'
        if args.command != 'status':
            try:
                connection.observe(code, started, checking=args.command != 'send')
            except (ConnectionError, OSError, ValueError):
                pass  # Delivery still fails and the shell keeps the event in its spool.
        if args.command == 'send':
            print(f'{error.status:03d}' if isinstance(error, ConnectionError) else '000')
        else:
            print(json.dumps({'status': 'error', 'error': code}), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

"""Exercise the deployed worker in one browser profile with isolated fixture accounts."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socket
import threading
import urllib.request


@contextmanager
def fixture_server(public_base):
    # Use the worker and shell bytes emitted by the real build. All fixture
    # identities and requests remain on the loopback server.
    files = {}
    for name in ('my_dashboard_service_worker.js', 'index.html', 'manifest.json', 'flutter_bootstrap.js'):
        with urllib.request.urlopen(public_base + name, timeout=15) as source:
            files[name] = source.read()
    assert b'const BUILD = null;' not in files['my_dashboard_service_worker.js'], 'web shell missing build stamp'

    class Handler(BaseHTTPRequestHandler):
        policy = 'public, max-age=600'
        personalized = False
        offline = False

        def do_GET(self):
            # Chromium's page-level offline emulation can leave the service
            # worker online. Also break its origin connection for this phase.
            if Handler.offline:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            path = self.path.removeprefix('/dashboard-app/')
            if path.startswith('my_dashboard_service_worker.js?'):
                path = 'my_dashboard_service_worker.js'
            if path == 'client.html':
                data, media = b'<!doctype html><title>Shared browser fixture</title>', 'text/html'
            elif path in files or path == '':
                name = path or 'index.html'
                data = files[name]
                media = 'text/html' if name.endswith('.html') else 'application/json' if name.endswith('.json') else 'text/javascript'
                if name == 'manifest.json' and self.headers.get('Authorization'):
                    data = b'fixture authorized asset'
                elif name == 'manifest.json' and Handler.personalized:
                    data = ('fixture static response ' + self.headers.get('Cookie', '')).encode()
            else:
                account = self.headers.get('Authorization') or self.headers.get('Cookie', 'anonymous')
                data, media = ('fixture response ' + account).encode(), 'text/plain'
            self.send_response(200)
            self.send_header('Content-Type', media)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', Handler.policy if path == 'manifest.json' else 'public, max-age=600')
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/dashboard-app/', Handler
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def verify_shared_profile(browser, public_base):
    with fixture_server(public_base.rstrip('/') + '/') as (base, handler):
        context = browser.new_context()
        try:
            page = context.new_page()
            page.goto(base + 'client.html')
            # Both prior dashboard scopes use the older unscoped naming scheme.
            page.evaluate("""async () => {
              document.cookie = 'fixture_account=alpha; path=/';
              for (const [cache, bootstrap] of [
                ['sol-app-shell-511', 'flutter_bootstrap.js'],
                ['sol-app-shell-512', '/another-app/flutter_bootstrap.js'],
                ['unrelated-browser-cache', '/unrelated.js']
              ]) {
                const old = await caches.open(cache);
                await old.put(bootstrap, new Response('old static entry'));
                await old.put(new URL('records.json', bootstrap.startsWith('/') ? location.origin + bootstrap : location.href), new Response('old entry'));
              }
              await navigator.serviceWorker.register('my_dashboard_service_worker.js?v=smoke');
              await navigator.serviceWorker.ready;
            }""")
            page.wait_for_function('() => !!navigator.serviceWorker.controller')
            names = page.evaluate('() => caches.keys()')
            assert 'sol-app-shell-511' not in names, 'previous dashboard data cache survived activation'
            assert 'sol-app-shell-512' in names and 'unrelated-browser-cache' in names
            own = [name for name in names if name.startswith('agent-dashboard-shell-v2:')]
            assert len(own) == 1

            def read(path, headers=None):
                return page.evaluate("""async ({path, headers}) =>
                  (await fetch(path, {headers})).text()""", {'path': path, 'headers': headers or {}})

            def keys():
                return page.evaluate('async name => (await (await caches.open(name)).keys()).map(r => r.url)', own[0])

            endpoint = 'dashboard/sync'
            for account in ('alpha', 'bravo'):
                page.evaluate('s => { document.cookie = "fixture_account=" + s + "; path=/"; }', account)
                assert read(endpoint, {'Authorization': 'Bearer ' + account}) == 'fixture response Bearer ' + account
                assert read(endpoint) == 'fixture response fixture_account=' + account
                assert read('assets/not-in-the-build.json') == 'fixture response fixture_account=' + account
                assert read('records.json?fixture=' + account) == 'fixture response fixture_account=' + account
            assert all('dashboard/sync' not in url and 'not-in-the-build' not in url and '?' not in url for url in keys())
            assert read('manifest.json', {'Authorization': 'Bearer scoped-fixture'}) == 'fixture authorized asset'
            document = context.new_page()
            document.goto(base + endpoint)
            assert document.locator('body').inner_text() == 'fixture response fixture_account=bravo'
            assert 'fixture response' not in page.evaluate(
                'async key => (await (await caches.open(key)).match("index.html")).text()', own[0])

            read('manifest.json')
            assert base + 'manifest.json' in keys()
            for policy in ('public, no-store', 'private, max-age=60'):
                handler.policy = policy
                read('manifest.json')
                assert base + 'manifest.json' not in keys(), 'disallowed response remained cached'
                handler.policy = 'public, max-age=600'
                read('manifest.json')
                assert base + 'manifest.json' in keys()
            handler.personalized = True
            for account in ('alpha', 'bravo'):
                page.evaluate('s => { document.cookie = "fixture_account=" + s + "; path=/"; }', account)
                assert read('manifest.json') == 'fixture static response fixture_account=' + account
                assert base + 'manifest.json' not in keys(), 'personalized bytes were cached'
            handler.personalized = False

            handler.offline = True
            context.set_offline(True)
            result = page.evaluate("""async path => {
              try { await fetch(path, {headers: {Authorization: 'Bearer bravo'}}); return 'served'; }
              catch (_) { return 'unavailable'; }
            }""", endpoint)
            assert result == 'unavailable', 'offline API request used a stored response'
            from playwright.sync_api import Error
            try:
                document.goto(base + endpoint, timeout=10000)
            except Error:
                pass
            else:
                raise AssertionError('offline API navigation returned a shell or account response')
            assert 'Agent Dashboard' in read('index.html'), 'the build-verified shell must remain readable offline'
        finally:
            context.close()

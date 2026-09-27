#!/usr/bin/env python3
"""Check that the push service worker coexists with the app shell one, and that it displays what the server sends.

The central `tools/device-app/web_smoke.py` already proves the app boots and
survives an offline reload. This script proves the two claims that FCM web push
adds on top, without any Firebase credential:

  1. Coexistence. Registering `web/push_sw.js` under its own scope leaves the
     app shell worker as the page's controller, keeps the registration count at
     exactly two, and does not break the offline reload contract.
  2. Display. The very bytes we ship in `web/push_sw.js` turn one FCM data-only
     envelope into exactly one `showNotification`, replace by session tag, and
     route a click to an open window (or open one when there is none).
  3. The permission gate. The vendored Firebase SDK loads same-origin and
     reports this browser as supported, and `requestFcmToken` still stops at
     `permission-required` - which is the proof that nothing on this path can
     raise a permission prompt on its own. Only the settings button may.

The second check runs the file's real source in a sandbox with a fake `self`
(the file is written to touch globals only through `self.` for this reason).
A push event cannot be delivered to a worker without a push service, and the
banner itself needs a human's eyes - that part stays a morning item.

Run with: uv run --with playwright python app/scripts/web_push_smoke.py URL
 --browser /path/to/chrome --output /tmp/web-push-evidence
"""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

# These three must match lib/src/platform/web_push.dart. They are repeated as
# literals on purpose: this script is the check that the Dart constants and the
# files in web/ actually agree in a real browser.
PUSH_SW_URL = 'push_sw.js'
PUSH_SW_SCOPE = 'push-scope/'
PUSH_BRIDGE_URL = 'push_token_bridge.js'
APP_SHELL_SW = 'my_dashboard_service_worker.js'

# flutter_bootstrap.js logs this when the app shell worker fails to become the
# controller before Flutter loads. It is a warning, not an error, so nothing
# else would fail - which is exactly why we look for it by hand.
CONTROL_WARNING = 'did not take control'

# One FCM data-only envelope, shaped like contracts/dashboard-protocol.v1.json
# push.data_keys. Values are all strings, as FCM requires.
ENVELOPE = {
    'from': '1234567890',
    'fcmMessageId': 'test-message-id',
    'data': {
        'transition_id': '42',
        'session_key': 'claude_code:s1',
        'state': 'waiting_input',
        'source': 'claude_code',
        'project': '/Users/example/dev/x',
        'host': 'demo-mac',
        'title': 'claude_code:s1',
        'body': '입력을 기다리는 중',
        'link': '/?session=claude_code%3As1',
    },
}

# Runs push_sw.js against a fake `self` and reports every call it made.
HARNESS = """
async ({source, envelope, windowCount}) => {
  const calls = [];
  const listeners = {};
  const pending = [];
  const self = {
    addEventListener: (type, handler) => { listeners[type] = handler; },
    skipWaiting: () => calls.push({kind: 'skipWaiting'}),
    registration: {
      showNotification: (title, options) => {
        calls.push({kind: 'showNotification', title, options});
        return Promise.resolve();
      },
    },
    clients: {
      matchAll: (options) => {
        calls.push({kind: 'matchAll', options});
        const windows = [];
        for (let i = 0; i < windowCount; i += 1) {
          windows.push({focus: () => { calls.push({kind: 'focus', index: i}); return Promise.resolve(); }});
        }
        return Promise.resolve(windows);
      },
      openWindow: (url) => { calls.push({kind: 'openWindow', url}); return Promise.resolve(null); },
    },
    BroadcastChannel: function (name) {
      calls.push({kind: 'channel', name});
      this.postMessage = (message) => calls.push({kind: 'postMessage', message});
      this.close = () => calls.push({kind: 'channelClose'});
    },
  };
  // `new Function` and not eval: the worker source gets exactly one binding,
  // `self`, so any global it reaches for by another name would throw here.
  new Function('self', source)(self);

  const collect = (promise) => { pending.push(promise); };
  listeners.push({data: {json: () => envelope}, waitUntil: collect});
  listeners.push({data: {json: () => envelope}, waitUntil: collect});
  await Promise.all(pending.splice(0));

  const shown = calls.filter((call) => call.kind === 'showNotification');
  const clicked = shown.length ? shown[0].options.data : {};
  listeners.notificationclick({
    notification: {data: clicked, close: () => calls.push({kind: 'close'})},
    waitUntil: collect,
  });
  await Promise.all(pending.splice(0));
  return {calls, listeners: Object.keys(listeners).sort()};
}
"""


# Loads the vendored SDK the way lib/src/platform/web_push_web.dart does, then
# asks for a token twice: once with no credentials, once with fake but complete
# ones. Neither call may reach `getToken()`, so neither can prompt.
BRIDGE_PROBE = """
async ({module, scope}) => {
  await new Promise((resolve, reject) => {
    const tag = document.createElement('script');
    tag.type = 'module';
    tag.src = module;
    tag.addEventListener('load', resolve);
    tag.addEventListener('error', () => reject(new Error('module load failed')));
    document.head.appendChild(tag);
  });
  const bridge = globalThis.solAppPushBridge;
  if (!bridge) return {loaded: false};
  const registration = await navigator.serviceWorker.getRegistration(scope);
  return {
    loaded: true,
    permission: Notification.permission,
    half_configured: await bridge.requestFcmToken('{}', '', registration),
    configured: await bridge.requestFcmToken(
      '{"apiKey":"fake","projectId":"fake","appId":"1:1:web:1","messagingSenderId":"1"}',
      'BFakeVapidPublicKey',
      registration,
    ),
  };
}
"""


def boot(page, greeting):
    """Wait until Flutter has painted and the app shell worker controls the page."""
    page.locator('flt-semantics-placeholder').evaluate('(element) => element.click()')
    page.get_by_text(greeting, exact=True).first.wait_for()
    controller = page.evaluate('() => navigator.serviceWorker.controller?.scriptURL ?? null')
    assert controller and APP_SHELL_SW in controller, f'app shell worker is not controlling: {controller}'
    return controller


def scopes(page):
    return sorted(page.evaluate('async () => (await navigator.serviceWorker.getRegistrations()).map((r) => r.scope)'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('--greeting', default='Setup', help='text the booted app renders (semantics tree)')
    parser.add_argument('--browser')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    origin = args.url.rstrip('/') + '/'

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=args.browser, headless=True)
        context = browser.new_context(viewport={'width': 900, 'height': 700})
        page = context.new_page()
        errors, warnings = [], []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('console', lambda message: warnings.append(message.text) if CONTROL_WARNING in message.text else None)

        page.goto(args.url)
        controller = boot(page, args.greeting)
        assert scopes(page) == [origin], f'expected only the app shell registration before the probe: {scopes(page)}'

        # The app registers this from lib/src/platform/web_push_web.dart once the
        # server hands it credentials. With no server configured we register it
        # here the same way, so the coexistence claim is testable with zero
        # credentials.
        page.evaluate(
            'async ({url, scope}) => { const r = await navigator.serviceWorker.register(url, {scope}); await navigator.serviceWorker.ready; return r.scope; }',
            {'url': PUSH_SW_URL, 'scope': PUSH_SW_SCOPE},
        )
        page.wait_for_function(
            'async () => (await navigator.serviceWorker.getRegistrations()).length === 2',
        )
        registered = scopes(page)
        assert registered == [origin, origin + PUSH_SW_SCOPE], f'unexpected registrations: {registered}'
        assert page.evaluate('() => navigator.serviceWorker.controller?.scriptURL ?? null') == controller, (
            'the push worker took the page over; it must never control a document'
        )
        page.screenshot(path=str(args.output / 'online.png'))

        source = page.evaluate('async (url) => (await fetch(url)).text()', PUSH_SW_URL)
        # The file's own comments name both bans, so compare against code only.
        code = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('//'))
        assert 'importScripts' not in code, 'push_sw.js must stay a pure worker'
        assert "'fetch'" not in code, 'push_sw.js must never intercept fetches'
        assert 'caches' not in code, 'push_sw.js must hold no caching logic'
        with_window = page.evaluate(HARNESS, {'source': source, 'envelope': ENVELOPE, 'windowCount': 1})
        without_window = page.evaluate(HARNESS, {'source': source, 'envelope': ENVELOPE, 'windowCount': 0})

        shown = [call for call in with_window['calls'] if call['kind'] == 'showNotification']
        assert len(shown) == 2, f'one push must show exactly one notification: {len(shown)} for 2 pushes'
        title, options = shown[0]['title'], shown[0]['options']
        assert title == ENVELOPE['data']['title'], title
        assert options['body'] == ENVELOPE['data']['body'], options
        assert options['tag'] == ENVELOPE['data']['session_key'], options
        assert options['renotify'] is True, options
        assert options['data'] == {
            'link': ENVELOPE['data']['link'],
            'transition_id': ENVELOPE['data']['transition_id'],
            'session_key': ENVELOPE['data']['session_key'],
        }, options
        assert shown[1]['options']['tag'] == options['tag'], 'the second push must replace the first by tag'

        posted = [call for call in with_window['calls'] if call['kind'] == 'postMessage']
        assert len(posted) == 1 and posted[0]['message']['refresh'] is True, posted
        assert posted[0]['message']['link'] == ENVELOPE['data']['link'], posted
        assert any(call['kind'] == 'channel' and call['name'] == 'dashboard' for call in with_window['calls'])
        assert any(call['kind'] == 'focus' for call in with_window['calls']), 'an open window must be focused'
        assert not any(call['kind'] == 'openWindow' for call in with_window['calls']), 'do not open a second window'

        opened = [call for call in without_window['calls'] if call['kind'] == 'openWindow']
        assert len(opened) == 1 and opened[0]['url'] == ENVELOPE['data']['link'], opened
        assert not any(call['kind'] == 'postMessage' for call in without_window['calls']), 'nobody to talk to'

        # The SDK is vendored under web/vendor/. If the one rewritten import
        # specifier were wrong, or COEP blocked the module, this is where it
        # shows: the module would not load, or isSupported() would be false.
        bridge = page.evaluate(BRIDGE_PROBE, {'module': PUSH_BRIDGE_URL, 'scope': PUSH_SW_SCOPE})
        assert bridge['loaded'], 'push_token_bridge.js did not load as a module'
        assert bridge['permission'] == 'default', f'this probe assumes a fresh profile: {bridge}'
        assert bridge['half_configured']['status'] == 'unsupported', bridge['half_configured']
        assert bridge['configured']['status'] == 'permission-required', (
            f'getToken() must not be reached without permission: {bridge["configured"]}'
        )

        # The offline contract has to survive the second registration.
        context.set_offline(True)
        page.reload()
        boot(page, args.greeting)
        assert scopes(page) == registered, f'registrations changed offline: {scopes(page)}'
        page.screenshot(path=str(args.output / 'offline.png'))
        context.set_offline(False)

        assert not errors, errors
        assert not warnings, warnings
        result = {
            'url': args.url,
            'controller': controller,
            'registrations': registered,
            'push_sw_pure': True,
            'notifications_per_push': 1,
            'click_with_window': 'focus+broadcast',
            'click_without_window': 'openWindow',
            'offline_reload': True,
            'firebase_sdk_same_origin': True,
            'permission_gate': bridge['configured']['status'],
            'page_errors': errors,
            'control_warnings': warnings,
        }
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))
        browser.close()


if __name__ == '__main__':
    main()

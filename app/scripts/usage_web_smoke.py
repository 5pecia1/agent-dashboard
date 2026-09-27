#!/usr/bin/env python3
"""Exercise the built public app with browser-local, synthetic integration data.

uv run --with playwright python app/scripts/usage_web_smoke.py \
  --url http://127.0.0.1:8798 --output /tmp/agent-dashboard-usage-qa
"""
import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

CONFIG_KEY = 'my-dashboard.config.v1'
FIXTURE_HOSTS = {'dashboard.example.test', 'teamclaude.example.test', 'devin.example.test'}


def enable_semantics(page):
    placeholder = page.locator('flt-semantics-placeholder')
    placeholder.wait_for(timeout=60000)
    placeholder.evaluate('(element) => element.click()')


def capture(page, output, name):
    text = page.locator('body').aria_snapshot()
    assert '???' not in text, text
    page.screenshot(path=str(output / f'{name}.png'), full_page=True)
    (output / f'{name}.txt').write_text(text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--browser', default='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=args.browser, headless=True)
        context = browser.new_context(viewport={'width': 1200, 'height': 1000}, locale='en-US')
        page = context.new_page()
        errors, requests = [], []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('request', lambda request: requests.append(request.url))
        page.goto(args.url)
        enable_semantics(page)
        page.get_by_role('button', name=re.compile('^TeamClaude ')).wait_for(timeout=60000)
        page.get_by_role('button', name=re.compile('^Devin ')).wait_for(timeout=60000)
        page.wait_for_load_state('networkidle')
        assert all(field.input_value() == '' for field in page.get_by_role('textbox').all())
        assert not any(urlsplit(url).hostname in FIXTURE_HOSTS or '/teamclaude/' in url or 'SeatManagementService' in url for url in requests)
        assert page.title() == 'Agent Dashboard'
        capture(page, args.output, 'setup')

        # Saving the dashboard settings must not remove unknown future settings.
        old = {'future_integration': {'api_key': 'fixture-only'}, 'cursor': 41}
        raw = json.dumps(old, indent=2)
        page.evaluate('(raw) => localStorage.setItem("my-dashboard.config.v1", raw)', raw)
        page.reload()
        enable_semantics(page)
        page.locator('input[type=password]').fill('fixture-client')
        page.get_by_role('button', name='Save', exact=True).click()
        page.wait_for_function('localStorage.getItem("my-dashboard.config.v1.before-extensions") !== null')
        saved = json.loads(page.evaluate(f'localStorage.getItem("{CONFIG_KEY}")'))
        assert saved['future_integration'] == old['future_integration'] and saved['cursor'] == 41
        assert page.evaluate('localStorage.getItem("my-dashboard.config.v1.before-extensions")') == raw

        def mock_api(route):
            request = route.request
            parsed = urlsplit(request.url)
            if parsed.hostname == 'teamclaude.example.test':
                assert request.headers.get('x-api-key') == 'fixture-team'
                body = {'accounts': [{'name': 'Demo Claude', 'provider': 'anthropic', 'quota': {'unified5h': 0.3, 'unified7d': 0.65, 'unified7dFable': 0.4}}, {'name': 'Demo Codex', 'provider': 'codex', 'quota': {'planType': 'pro', 'unified7d': 0.34}}]} if parsed.path.endswith('/status') else {'accounts': [{'name': 'Demo Claude', 'tier': {'weight': 20, 'rateLimitTier': 'default_claude_max_20x'}}]}
            elif parsed.hostname == 'devin.example.test':
                assert request.post_data_json['metadata']['api_key'] == 'fixture-devin'
                body = {'userStatus': {'planStatus': {'planInfo': {'planName': 'Max', 'billingStrategy': 'BILLING_STRATEGY_QUOTA', 'hideDailyQuota': True}, 'dailyQuotaRemainingPercent': 100, 'weeklyQuotaRemainingPercent': 48, 'overageBalanceMicros': '7462105'}}}
            elif parsed.path.endswith('/sync'):
                body = {'protocol_version': 1, 'reset': True, 'cursor': 1, 'server_time': 1789545600000, 'ui_lang': 'en', 'sessions': [], 'transitions': []}
            else:
                body = {}
            route.fulfill(status=200, content_type='application/json', body=json.dumps(body), headers={'Access-Control-Allow-Origin': '*'})

        context.route(re.compile(r'https://(?:dashboard|teamclaude|devin)\.example\.test/'), mock_api)
        config = {
            'server_url': 'https://dashboard.example.test',
            'client_token': 'fixture-client',
            'teamclaude': {'url': 'https://teamclaude.example.test', 'api_key': 'fixture-team'},
            'devin': {'url': 'https://devin.example.test', 'api_key': 'fixture-devin'},
        }
        page.evaluate('(config) => localStorage.setItem("my-dashboard.config.v1", JSON.stringify(config))', config)
        page.reload()
        enable_semantics(page)
        page.get_by_role('group', name=re.compile('TeamClaude')).first.wait_for(timeout=60000)
        page.get_by_role('progressbar', name=re.compile('Devin')).first.wait_for(timeout=60000)
        text = capture(page, args.output, 'usage')
        assert 'Codex' in text and 'TeamClaude' in text and 'Devin' in text, text
        page.set_viewport_size({'width': 390, 'height': 1000})
        page.wait_for_timeout(300)
        capture(page, args.output, 'usage-narrow')
        assert not errors, errors
        assert FIXTURE_HOSTS <= {urlsplit(url).hostname for url in requests}
        context.close()
        browser.close()
    print('Public app: empty first boot, preserved settings, and configured TeamClaude/Devin panels passed.')


if __name__ == '__main__':
    main()

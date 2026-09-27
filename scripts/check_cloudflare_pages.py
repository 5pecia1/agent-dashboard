#!/usr/bin/env python3
"""Read-only Pages credential/query diagnostic. Never print credentials or headers."""
import json
import os
import urllib.error
import urllib.parse
import urllib.request


def main():
    raw_token = os.environ.get('CLOUDFLARE_API_TOKEN', '')
    token = raw_token.strip()
    if not token:
        raise SystemExit('CLOUDFLARE_API_TOKEN is missing')
    if any(character.isspace() for character in token):
        raise SystemExit('The token contains internal whitespace. Save only the token value, without a Bearer prefix.')
    account = urllib.parse.quote(os.environ['CLOUDFLARE_ACCOUNT_ID'], safe='')
    project = urllib.parse.quote(os.environ['CLOUDFLARE_PAGES_PROJECT'], safe='')
    base = f'https://api.cloudflare.com/client/v4/accounts/{account}/pages/projects/{project}'
    print(json.dumps({'trimmed_surrounding_whitespace': raw_token != token}))
    for label, suffix in [('project', ''), ('deployments-default', '/deployments?env=production'),
                          ('deployments-100', '/deployments?env=production&per_page=100&page=1'),
                          ('deployments-20', '/deployments?env=production&per_page=20&page=1')]:
        request = urllib.request.Request(base + suffix, headers={
            'Authorization': 'Bearer ' + token, 'User-Agent': 'AgentDashboard-Pages-Diagnostic/1'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.load(response)
                print(json.dumps({'check': label, 'http_status': response.status,
                                  'success': body.get('success'),
                                  'result_count': len(body['result']) if isinstance(body.get('result'), list) else None}))
        except urllib.error.HTTPError as error:
            try:
                payload = json.loads(error.read(16384))
            except (ValueError, OSError):
                payload = {}
            errors = []
            for item in payload.get('errors', []):
                message = str(item.get('message', ''))
                for secret in sorted({raw_token, token}, key=len, reverse=True):
                    if secret:
                        message = message.replace(secret, '[REDACTED]')
                errors.append({'code': item.get('code'), 'message': message[:500]})
            print(json.dumps({'check': label, 'http_status': error.code, 'errors': errors}))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check and confirm Agent Dashboard Pages deployments without exposing credentials."""
import argparse
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request


class DeploymentError(RuntimeError):
    pass


def normalized_token(raw_token):
    token = raw_token.strip()
    if not token:
        raise DeploymentError('CLOUDFLARE_API_TOKEN is missing')
    if token.lower().startswith('bearer ') or any(character.isspace() for character in token):
        raise DeploymentError('Save only the API token value, without a Bearer prefix or internal whitespace')
    return token


def _origin(value):
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment):
        raise DeploymentError('CLOUDFLARE_PAGES_URL must be the HTTPS production origin')
    return value.rstrip('/')


def _redact(value, secrets):
    text = str(value)
    for secret in sorted(set(secrets), key=len, reverse=True):
        if secret:
            text = text.replace(secret, '[REDACTED]')
    return text[:500]


def _get_json(url, token=None, raw_token=None, timeout=30):
    headers = {'User-Agent': 'AgentDashboard-Pages-Deployment/1'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        details = []
        if token:
            try:
                payload = json.loads(error.read(16384))
            except (ValueError, OSError):
                payload = None
            if isinstance(payload, dict) and isinstance(payload.get('errors'), list):
                for item in payload['errors'][:5]:
                    if isinstance(item, dict):
                        details.append(_redact(
                            f"{item.get('code', 'unknown')}: {item.get('message', '')}",
                            (token, raw_token or '')))
        service = 'Cloudflare Pages API' if token else 'Production release manifest'
        suffix = '; ' + '; '.join(details) if details else ''
        raise DeploymentError(f'{service} returned HTTP {error.code}{suffix}') from None
    except (OSError, ValueError):
        service = 'Cloudflare Pages API' if token else 'Production release manifest'
        raise DeploymentError(f'{service} could not be read as JSON') from None


def _stable_tag(tag):
    return isinstance(tag, str) and re.fullmatch(r'v\d+\.\d+\.\d+', tag) is not None


def _validate_manifest(manifest):
    tag = manifest.get('tag') if isinstance(manifest, dict) else None
    if (not isinstance(manifest, dict) or manifest.get('schema') != 1
            or manifest.get('product') != 'Agent Dashboard' or manifest.get('platform') != 'web'
            or not _stable_tag(tag) or manifest.get('version') != tag[1:]
            or not isinstance(manifest.get('source_commit'), str)
            or not re.fullmatch(r'[0-9a-f]{40}', manifest['source_commit'])):
        raise DeploymentError('Production metadata is invalid; inspect the existing deployment before replacing it')
    return manifest


def check_before_deploy(origin, account, project, token, tag, allow_rollback=False):
    origin = _origin(origin)
    if not isinstance(tag, str) or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', tag):
        raise DeploymentError('The release tag must be vMAJOR.MINOR.PATCH with an optional prerelease suffix')
    prerelease = not _stable_tag(tag)
    raw_token = token
    token = normalized_token(raw_token)
    if not account or not project:
        raise DeploymentError('CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_PAGES_PROJECT are required')
    account = urllib.parse.quote(account, safe='')
    project = urllib.parse.quote(project, safe='')
    project_endpoint = f'https://api.cloudflare.com/client/v4/accounts/{account}/pages/projects/{project}'
    details = _get_json(project_endpoint, token, raw_token)
    if (not isinstance(details, dict) or details.get('success') is not True
            or not isinstance(details.get('result'), dict)):
        raise DeploymentError('Cannot verify Cloudflare Pages project settings')
    if details['result'].get('production_branch') != 'main':
        raise DeploymentError('Set the Cloudflare Pages production branch to main before deploying')
    endpoint = project_endpoint + '/deployments'
    deployed = False
    for page in range(1, 51):
        # Pages rejected per_page=100 with code 8000024; 20 is verified against this API.
        data = _get_json(endpoint + f'?env=production&per_page=20&page={page}', token, raw_token)
        if not isinstance(data, dict) or data.get('success') is not True or not isinstance(data.get('result'), list):
            raise DeploymentError('Cannot verify Cloudflare production deployment history')
        rows = data['result']
        if any(not isinstance(item, dict) or not isinstance(item.get('latest_stage'), dict) for item in rows):
            raise DeploymentError('Cloudflare returned invalid production deployment history')
        if prerelease:
            # Preview releases still verify API access but cannot replace production.
            return None
        if any(item.get('environment') == 'production'
               and item['latest_stage'].get('name') == 'deploy'
               and item['latest_stage'].get('status') == 'success' for item in rows):
            deployed = True
            break
        if not rows:
            break
        info = data.get('result_info') or {}
        if not isinstance(info, dict):
            raise DeploymentError('Cloudflare returned invalid production pagination metadata')
        pages = info.get('total_pages')
        if pages is not None:
            if not isinstance(pages, int) or isinstance(pages, bool) or pages < page:
                raise DeploymentError('Cloudflare returned invalid production pagination metadata')
            if page == pages:
                break
        elif len(rows) < 20:
            break
    else:
        raise DeploymentError('Production history exceeded the lookup limit; inspect the project before deploying')
    if not deployed:
        return None
    manifest = _validate_manifest(_get_json(origin + '/release-manifest.json?check=' + str(time.time_ns())))
    current = manifest['tag']
    number = lambda value: tuple(map(int, value[1:].split('.')))
    if number(current) > number(tag) and allow_rollback is not True:
        raise DeploymentError(f'Production is already {current}; an older release needs an explicit allow_rollback dispatch')
    return current


def confirm_deployment(origin, tag, commit, attempts=24, delay=5):
    origin = _origin(origin)
    if not _stable_tag(tag) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise DeploymentError('Expected release tag or source commit is invalid')
    for attempt in range(attempts):
        try:
            query = urllib.parse.urlencode({'commit': commit, 'check': time.time_ns()})
            manifest = _validate_manifest(_get_json(origin + '/release-manifest.json?' + query, timeout=20))
            if manifest['tag'] == tag and manifest['source_commit'] == commit:
                return manifest
        except DeploymentError:
            pass
        if attempt + 1 < attempts:
            time.sleep(delay)
    raise DeploymentError('Production did not serve the expected release manifest; inspect the Pages deployment')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'confirm'))
    command = parser.parse_args().command
    try:
        origin = os.environ['CLOUDFLARE_PAGES_URL']
        tag = os.environ['RELEASE_TAG']
        if command == 'check':
            current = check_before_deploy(origin, os.environ['CLOUDFLARE_ACCOUNT_ID'],
                os.environ['CLOUDFLARE_PAGES_PROJECT'], os.environ.get('CLOUDFLARE_API_TOKEN', ''),
                tag, os.environ.get('ALLOW_ROLLBACK', 'false') == 'true')
            if _stable_tag(tag):
                print(f'Production deployment check passed (current release: {current or "none"})')
            else:
                print('Preview deployment check passed; Cloudflare Pages API access verified')
        else:
            commit = os.environ['SOURCE_COMMIT']
            confirm_deployment(origin, tag, commit)
            message = f'Deployed [{tag}]({_origin(origin)}) from `{commit}`.\n'
            if os.environ.get('GITHUB_STEP_SUMMARY'):
                with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
                    summary.write(message)
            print(message.strip())
    except KeyError as error:
        raise SystemExit(f'Required environment variable is missing: {error.args[0]}') from None
    except DeploymentError as error:
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()

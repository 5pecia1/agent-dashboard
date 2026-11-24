#!/usr/bin/env python3
"""Sign a built macOS app, notarize it and emit a verified, stapled copy."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


MACHO_MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
PUBLIC_BUNDLE_ID = 'io.github.5pecia1.mydashboard'
SOURCE_COMMIT_KEY = 'DashboardSourceCommit'


def run(*command):
    subprocess.run(command, check=True)


def app_identifier(app):
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise ValueError(f'expected a built .app directory: {app}')
    plist = app / 'Contents/Info.plist'
    if not plist.resolve().is_relative_to(app.resolve()):
        raise ValueError('Info.plist points outside the application bundle')
    with plist.open('rb') as stream:
        return plistlib.load(stream)['CFBundleIdentifier']


def requirement(bundle_id, team):
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise ValueError('expected a reverse-domain bundle identifier')
    if not re.fullmatch(r'[A-Z0-9]{10}', team or ''):
        raise ValueError('expected the ten-character Developer ID signing team')
    return (f'identifier "{bundle_id}" and anchor apple generic and certificate leaf[subject.OU] = "{team}" '
            'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
            'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')


def verify_signature(app, bundle_id, team):
    designated = requirement(bundle_id, team)
    if app_identifier(app) != bundle_id:
        raise ValueError('unexpected macOS application identifier')
    run('codesign', '--verify', '--deep', '--strict', '--all-architectures', app)
    run('codesign', '--verify', '--strict', '--all-architectures', '-R=' + designated, app)
    detail = subprocess.check_output(['codesign', '--display', '--verbose=4', app],
                                     stderr=subprocess.STDOUT, text=True)
    if not re.search(r'flags=0x[0-9a-f]+\([^)]*\bruntime\b', detail) or not re.search(r'^Timestamp=.+', detail, re.M):
        raise ValueError('distribution signature must have a hardened runtime and secure timestamp')


def verify(app, bundle_id, team):
    verify_signature(app, bundle_id, team)
    run('xcrun', 'stapler', 'validate', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)


def nested_code(app):
    """Return inner code before enclosing bundles, skipping framework symlinks."""
    items = []
    for path in app.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError(f'symlink outside app: {path.relative_to(app)}')
        elif path.is_dir() and path.suffix in {'.framework', '.appex', '.xpc', '.app', '.plugin', '.bundle'}:
            if path.suffix in {'.bundle', '.plugin'}:
                info = path / 'Contents/Info.plist'
                if not info.is_file() or not plistlib.loads(info.read_bytes()).get('CFBundleExecutable'):
                    continue
            items.append(path)
        elif path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    items.append(path)
    return sorted(items, key=lambda p: (-len(p.parts), str(p)))


def preflight(args):
    requirement(args.bundle_id, args.team_id)
    if not re.fullmatch(r'[A-Fa-f0-9]{40}', args.identity):
        raise ValueError('pass the SHA-1 fingerprint of the Developer ID Application identity')
    keychains = [args.keychain] if args.keychain else []
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning',
                                          *keychains], text=True)
    if not any(args.identity.upper() in line.upper() and '"Developer ID Application: ' in line
               and line.rstrip().endswith(f'({args.team_id})"') for line in identities.splitlines()):
        raise ValueError('no matching Developer ID Application identity and private key in the selected keychain')
    for tool in ('notarytool', 'stapler'):
        run('xcrun', '--find', tool)
    keychain = ['--keychain', args.keychain] if args.keychain else []
    subprocess.run(['xcrun', 'notarytool', 'history', '--keychain-profile', args.notary_profile,
                    *keychain, '--output-format', 'json'], check=True, stdout=subprocess.DEVNULL)
    print('Signing identity and notary credentials are available.')


def sign(args):
    requirement(args.bundle_id, args.team_id)
    if not re.fullmatch(r'[A-Fa-f0-9]{40}', args.identity):
        raise ValueError('pass the SHA-1 fingerprint of the Developer ID Application identity')
    if app_identifier(args.source) != args.bundle_id:
        raise ValueError('source application has an unexpected bundle ID')
    if args.output.suffix != '.app' or args.output.exists() or args.output.is_symlink():
        raise ValueError('--output must be a new .app path')
    if args.source.resolve() in args.output.resolve().parents:
        raise ValueError('destination must be outside the source application')
    if args.entitlements:
        entitlements = plistlib.loads(args.entitlements.read_bytes())
        if entitlements.get('com.apple.security.get-task-allow'):
            raise ValueError('development debugging entitlement in a release build')
    keychain = ['--keychain', args.keychain] if args.keychain else []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.notarize-', dir=args.output.parent) as tmp:
        bundle = Path(tmp) / args.output.name
        run('ditto', args.source, bundle)
        nested = nested_code(bundle)
        if args.source_commit:
            if not re.fullmatch(r'[0-9a-f]{40}', args.source_commit):
                raise ValueError('expected a full source Git commit SHA')
            plist = bundle / 'Contents/Info.plist'
            info = plistlib.loads(plist.read_bytes())
            if info.get(SOURCE_COMMIT_KEY, args.source_commit) != args.source_commit:
                raise ValueError('built application records a different source commit')
            info[SOURCE_COMMIT_KEY] = args.source_commit
            plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        options = ['codesign', '--force', '--sign', args.identity, '--timestamp', '--options', 'runtime', *keychain]
        for item in nested:
            # Individual Mach-O code and Flutter/plugin frameworks need no extra privileges.
            # Signed app extensions and services can require their own entitlement sets.
            if item.is_dir() and item.suffix in {'.app', '.appex', '.xpc'}:
                raise ValueError(f'configure explicit entitlements for embedded target {item.name}')
            run(*options, item)
        root_entitlements = ['--entitlements', args.entitlements] if args.entitlements else []
        run(*options, *root_entitlements, bundle)
        verify_signature(bundle, args.bundle_id, args.team_id)
        upload = Path(tmp) / 'submission.zip'
        run('ditto', '-c', '-k', '--keepParent', bundle, upload)
        response = subprocess.check_output([
            'xcrun', 'notarytool', 'submit', upload, '--keychain-profile', args.notary_profile,
            *keychain, '--wait', '--output-format', 'json'], text=True)
        result = json.loads(response)
        if result.get('status') != 'Accepted':
            raise ValueError(f"notarization {result.get('status')} for submission {result.get('id')}")
        print(f"Apple accepted notarization submission {result.get('id')}", flush=True)
        run('xcrun', 'stapler', 'staple', bundle)
        verify(bundle, args.bundle_id, args.team_id)
        bundle.rename(args.output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for command in ('preflight', 'sign', 'verify'):
        sub = commands.add_parser(command)
        sub.add_argument('--bundle-id', required=True)
        sub.add_argument('--team-id', required=True)
        if command == 'verify':
            sub.add_argument('--app', type=Path, required=True)
        else:
            sub.add_argument('--identity', required=True)
            sub.add_argument('--notary-profile', required=True)
            sub.add_argument('--keychain')
            if command == 'sign':
                sub.add_argument('--source', type=Path, required=True)
                sub.add_argument('--source-commit', help='record this source SHA in the signed Info.plist')
                sub.add_argument('--output', type=Path, required=True)
                sub.add_argument('--entitlements', type=Path)
    for command in ('archive', 'cloud'):
        sub = commands.add_parser(command)
        sub.add_argument('--archive', type=Path, required=True)
        sub.add_argument('--bundle-id', required=True)
        sub.add_argument('--source-commit', required=True)
        if command == 'archive':
            sub.add_argument('--project', type=Path, required=True, help='Flutter app root')
        else:
            sub.add_argument('--output', type=Path, required=True)
            sub.add_argument('--team-id', required=True)
            sub.add_argument('--api-key-env', action='store_true',
                             help='authenticate with ASC_KEY_ID, ASC_ISSUER_ID and the raw multiline ASC_PRIVATE_KEY')
            sub.add_argument('--wait-seconds', type=int, default=0,
                             help='poll an API-key submission for at most this many seconds before export')
            sub.add_argument('--submit', action='store_true', help='upload this archive if it has never been submitted')
    args = parser.parse_args()
    try:
        if args.action in ('archive', 'cloud'):
            from macos_cloud import archive_host, cloud_release
            if args.action == 'archive':
                archive_host(args)
            else:
                cloud_release(args)
        elif args.action == 'verify':
            verify(args.app, args.bundle_id, args.team_id)
        elif args.action == 'preflight':
            preflight(args)
        else:
            sign(args)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()

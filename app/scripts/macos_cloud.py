"""Archive a Flutter host and use Xcode's signed-in Developer ID distribution team."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid

from macos_distribution import SOURCE_COMMIT_KEY, app_identifier, requirement, run, verify


def archived_app(archive):
    if archive.is_symlink() or not archive.is_dir() or archive.suffix != '.xcarchive':
        raise ValueError('expected a saved .xcarchive')
    info = plistlib.loads((archive / 'Info.plist').read_bytes())
    products = (archive / 'Products').resolve()
    app = (products / info['ApplicationProperties']['ApplicationPath']).resolve()
    if not app.is_relative_to(products):
        raise ValueError('archive application path escapes Products')
    return app


def verify_commit(commit):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('expected a full Git source commit SHA')


def archive_host(args):
    verify_commit(args.source_commit)
    project = args.project.resolve()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'],
                                    cwd=project, text=True)
    if head != args.source_commit or dirty or (project / 'pubspec_overrides.yaml').exists():
        raise ValueError('archive requires a clean checkout at the specified Git commit and locked dependencies')
    if args.archive.suffix != '.xcarchive' or args.archive.exists() or args.archive.is_symlink():
        raise ValueError('choose a new .xcarchive path; keep the archive for notarization')
    args.archive.parent.mkdir(parents=True, exist_ok=True)
    (project / 'build/macos/SourcePackages').mkdir(parents=True, exist_ok=True)
    subprocess.run(['flutter', 'pub', 'get', '--enforce-lockfile'], cwd=project, check=True)
    subprocess.run(['flutter', 'build', 'macos', '--config-only', '--release',
                    '--target', 'lib/main.dart', '--no-pub'], cwd=project, check=True)
    with tempfile.TemporaryDirectory(prefix='.archive-', dir=args.archive.parent) as temp:
        scratch = Path(temp).resolve()
        staging = scratch / args.archive.name
        run('xcodebuild', '-workspace', project / 'macos/Runner.xcworkspace', '-scheme', 'Runner',
            '-configuration', 'Release', '-destination', 'generic/platform=macOS',
            '-derivedDataPath', scratch / 'derived',
            '-clonedSourcePackagesDirPath', project / 'build/macos/SourcePackages',
            '-archivePath', staging, 'archive', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual',
            'ENABLE_HARDENED_RUNTIME=YES', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO')
        app = archived_app(staging)
        if app_identifier(app) != args.bundle_id:
            raise ValueError('archive contains the wrong bundle ID')
        plist = app / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info[SOURCE_COMMIT_KEY] = args.source_commit
        plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        # Preserve the archive's entitlement set after stamping its source. Xcode signs for distribution.
        run('codesign', '--force', '--sign', '-', '--options', 'runtime',
            '--preserve-metadata=identifier,entitlements', app)
        run('codesign', '--verify', '--deep', '--strict', '--all-architectures', app)
        staging.rename(args.archive)


def uploaded_submission(archive, team):
    info = plistlib.loads((archive / 'Info.plist').read_bytes())
    submitted = [d for d in info.get('Distributions', [])
                 if d.get('destination') == 'upload' and d.get('uploadDestination') == 'Developer ID'
                 and d.get('uploadEvent', {}).get('state') == 'success']
    if not submitted:
        return None
    if len(submitted) != 1 or submitted[0].get('teamID') != team:
        raise ValueError('archive has multiple submissions or belongs to another Developer ID team')
    return str(uuid.UUID(submitted[0]['identifier'])).upper()


@contextmanager
def api_key_arguments(enabled):
    """Supply Xcode and notarytool credentials without inheriting the PEM into child tools."""
    pem = os.environ.pop('ASC_PRIVATE_KEY', None)
    if not enabled:
        yield [], []
        return
    key_id = os.environ.get('ASC_KEY_ID', '')
    issuer = os.environ.get('ASC_ISSUER_ID', '')
    if not (pem and key_id and issuer):
        raise ValueError('--api-key-env requires ASC_KEY_ID, ASC_ISSUER_ID and the multiline ASC_PRIVATE_KEY')
    if not re.fullmatch(r'[A-Za-z0-9]+', key_id):
        raise ValueError('invalid App Store Connect key ID')
    try:
        uuid.UUID(issuer)
    except ValueError:
        raise ValueError('invalid App Store Connect team key issuer ID') from None
    pem = pem.strip().replace('\r\n', '\n')
    if not (pem.startswith('-----BEGIN PRIVATE KEY-----\n') and pem.endswith('\n-----END PRIVATE KEY-----')):
        raise ValueError('ASC_PRIVATE_KEY must contain the original multiline .p8 PEM')
    # The key lives outside the archive and the release output. Apple only receives its file path.
    with tempfile.TemporaryDirectory(prefix='dashboard-api-key-') as temp:
        path = Path(temp).resolve() / 'AuthKey.p8'
        with os.fdopen(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as key_file:
            key_file.write(pem + '\n')
        yield (['-authenticationKeyPath', str(path), '-authenticationKeyID', key_id,
                '-authenticationKeyIssuerID', issuer],
               ['--key', str(path), '--key-id', key_id, '--issuer', issuer])


def wait_for_notary(submission, auth, seconds):
    """Poll the existing submission through Apple's tool. Never initiate a new upload here."""
    try:
        if seconds:
            # wait also exits nonzero on timeouts. Read info once for a definitive status in either case.
            subprocess.run(['xcrun', 'notarytool', 'wait', submission, *auth, '--timeout', f'{seconds}s',
                            '--output-format', 'json'], stdout=subprocess.DEVNULL, timeout=seconds + 30)
        response = subprocess.run(['xcrun', 'notarytool', 'info', submission, *auth, '--output-format', 'json'],
                                  stdout=subprocess.PIPE, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise ValueError(f'timed out checking submission {submission}; resume with the same archive') from None
    if response.returncode:
        raise ValueError(f'notarytool info could not confirm submission {submission}; resume with the same archive')
    result = json.loads(response.stdout)
    if str(result.get('id', '')).upper() != submission:
        raise ValueError('notary service returned a different submission ID')
    if result.get('status') != 'Accepted':
        raise ValueError(f'Apple has not accepted submission {submission}: {result.get("status")}')


def cloud_release(args):
    import fcntl  # Only Xcode hosts use this command.

    if args.wait_seconds < 0 or (args.wait_seconds and not args.api_key_env):
        raise ValueError('--wait-seconds requires --api-key-env and a nonnegative time limit')
    verify_commit(args.source_commit)
    requirement(args.bundle_id, args.team_id)
    archive = args.archive.resolve()
    app = archived_app(archive)
    if (app_identifier(app) != args.bundle_id
            or plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get(SOURCE_COMMIT_KEY) != args.source_commit):
        raise ValueError('archive bundle ID or source commit differs from the requested release')
    if (args.output.suffix != '.app' or args.output.is_symlink() or args.output.exists()
            or args.output.resolve().is_relative_to(archive)):
        raise ValueError('--output must be a new .app path outside the archive')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    lock = os.open(archive, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with (api_key_arguments(args.api_key_env) as (xcode_auth, notary_auth),
              tempfile.TemporaryDirectory(prefix='.xcode-notary-', dir=args.output.parent) as temp):
            scratch = Path(temp).resolve()
            submission = uploaded_submission(archive, args.team_id)
            if not submission:
                if not args.submit:
                    raise ValueError('archive has no Developer ID submission; use --submit to upload it')
                if any((archive / 'Submissions').glob('*')):
                    raise ValueError('archive contains a submission without a successful upload record; inspect it in Xcode')
                options = scratch / 'ExportOptions.plist'
                options.write_bytes(plistlib.dumps({'method': 'developer-id', 'destination': 'upload',
                                                    'signingStyle': 'automatic', 'teamID': args.team_id}))
                run('xcodebuild', '-exportArchive', '-allowProvisioningUpdates', '-archivePath', archive,
                    '-exportOptionsPlist', options, '-exportPath', scratch / 'upload', *xcode_auth)
                submission = uploaded_submission(archive, args.team_id)
                if not submission:
                    raise ValueError('Xcode reported no completed Developer ID upload; inspect the saved archive')
            print(f'Using Apple submission {submission}. To resume, use this archive without --submit.', flush=True)
            if notary_auth:
                wait_for_notary(submission, notary_auth, args.wait_seconds)
            destination = scratch / 'accepted'
            run('xcodebuild', '-exportNotarizedApp', '-archivePath', archive, '-exportPath', destination, *xcode_auth)
            log = archive / 'Submissions' / submission / 'notarization-log.json'
            receipt = json.loads(log.read_bytes())
            if (str(receipt.get('jobId')).upper() != submission or receipt.get('status') != 'Accepted'
                    or receipt.get('statusCode') != 0):
                raise ValueError(f'Apple has not accepted submission {submission}; inspect {log}')
            apps = list(destination.glob('*.app'))
            if len(apps) != 1:
                raise ValueError('Xcode did not return one notarized app')
            exported = apps[0]
            if plistlib.loads((exported / 'Contents/Info.plist').read_bytes()).get(SOURCE_COMMIT_KEY) != args.source_commit:
                raise ValueError('downloaded app differs from the archived source commit')
            # Xcode staples the accepted app during export. Check the actual ticket before delivery.
            verify(exported, args.bundle_id, args.team_id)
            exported.rename(args.output)
    finally:
        os.close(lock)

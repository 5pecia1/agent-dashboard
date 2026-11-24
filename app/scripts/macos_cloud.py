"""Archive a Flutter host and use Xcode's signed-in Developer ID distribution team."""
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


def cloud_release(args):
    import fcntl  # Only Xcode hosts use this command.

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
        with tempfile.TemporaryDirectory(prefix='.xcode-notary-', dir=args.output.parent) as temp:
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
                    '-exportOptionsPlist', options, '-exportPath', scratch / 'upload')
                submission = uploaded_submission(archive, args.team_id)
                if not submission:
                    raise ValueError('Xcode reported no completed Developer ID upload; inspect the saved archive')
            print(f'Using Apple submission {submission}. To resume, use this archive without --submit.', flush=True)
            destination = scratch / 'accepted'
            run('xcodebuild', '-exportNotarizedApp', '-archivePath', archive, '-exportPath', destination)
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

"""Sign with an isolated CI keychain; notarize with a team App Store Connect API key."""
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import stat
import subprocess
import tempfile
import uuid
import zipfile

from macos_cloud import api_key_arguments, archived_app, verify_commit, wait_for_notary
from macos_distribution import SOURCE_COMMIT_KEY, app_identifier, requirement, run, sign_copy, verify
from release_product import safe_path, sha256


def keychain_command(operation, *arguments):
    # security(1) takes passwords in argv. Never log either argv, tool output or an exception containing argv.
    try:
        result = subprocess.run(['security', operation, *arguments], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        raise ValueError(f'CI keychain: security {operation} did not finish') from None
    if result.returncode:
        raise ValueError(f'CI keychain: security {operation} failed with exit {result.returncode}')
    return result.stdout


@contextmanager
def keychain_search_lock():
    import fcntl

    # security list-keychains -s replaces the user list. Serialize this helper's
    # additions and deletions across archives so one release cannot undo another.
    cache = Path.home() / 'Library/Caches/agent-dashboard-signing'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (cache / 'search-list.lock').open('ab') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


@contextmanager
def listed_keychain(chain, password):
    try:
        with keychain_search_lock():
            keychain_command('create-keychain', '-p', password, chain)
            # codesign --keychain selects the identity only. It still finds the
            # Developer ID intermediate via the user's regular search list.
            current = shlex.split(keychain_command('list-keychains', '-d', 'user').decode())
            if not any(Path(item).resolve() == chain for item in current):
                keychain_command('list-keychains', '-d', 'user', '-s', *current, chain)
        yield
    finally:
        if chain.exists():
            with keychain_search_lock():
                # security deletes this entry from the live list; other keys
                # added or removed while the signing job ran keep their state.
                keychain_command('delete-keychain', chain)


@contextmanager
def signing_identity(encoded, password, team):
    if not encoded or not password:
        raise ValueError('initial signing requires CI_SIGNING_P12 and CI_SIGNING_P12_PASSWORD')
    try:
        certificate = base64.b64decode(''.join(encoded.split()), validate=True)
    except ValueError:
        raise ValueError('CI_SIGNING_P12 must be base64-encoded PKCS#12') from None
    with tempfile.TemporaryDirectory(prefix='dashboard-keychain-') as temp:
        scratch = Path(temp).resolve()
        chain = scratch / 'signing.keychain-db'
        p12 = scratch / 'signer.p12'
        with os.fdopen(os.open(p12, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'wb') as stream:
            stream.write(certificate)
        secret = secrets.token_hex(32)
        with listed_keychain(chain, secret):
            keychain_command('unlock-keychain', '-p', secret, chain)
            keychain_command('import', p12, '-k', chain, '-f', 'pkcs12', '-x', '-P', password, '-T', '/usr/bin/codesign')
            p12.unlink()
            keychain_command('set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', secret, chain)
            listing = keychain_command('find-identity', '-v', '-p', 'codesigning', chain).decode()
            identities = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"Developer ID Application: [^"]+ \('
                                    + re.escape(team) + r'\)"\s*$', listing, re.M)
            if len(identities) != 1:
                raise ValueError('PKCS#12 must contain one usable Developer ID Application identity for the expected team')
            yield identities[0], ['--keychain', str(chain)]



def write_record(path, data):
    """Publish complete receipt bytes, including when a process restarts after an interrupted write."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_submission(state, source, binding, encoded, password):
    # Publish the signed ZIP and its hash together. Re-signing would change the timestamp and CDHash.
    with tempfile.TemporaryDirectory(prefix='.ci-sign-', dir=state.parent) as temp:
        scratch = Path(temp).resolve()
        stage = scratch / 'state'
        stage.mkdir()
        entitlements = subprocess.check_output(['codesign', '--display', '--entitlements', '-', '--xml', source],
                                              stderr=subprocess.DEVNULL)
        entitlements_path = None
        if entitlements:
            if plistlib.loads(entitlements).get('com.apple.security.get-task-allow'):
                raise ValueError('development debugging entitlement in CI archive')
            entitlements_path = scratch / 'release.entitlements'
            entitlements_path.write_bytes(entitlements)
        with signing_identity(encoded, password, binding['team']) as (identity, keychain):
            bundle = scratch / source.name
            sign_copy(source, bundle, binding['bundle_id'], binding['team'], identity, keychain, entitlements_path,
                      binding['source_commit'])
        upload = stage / f'{binding["bundle_id"]}-{uuid.uuid4()}.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', bundle, upload)
        record = dict(binding, zip=upload.name, sha256=sha256(upload))
        (stage / 'build.json').write_text(json.dumps(record))
        stage.rename(state)


def submission_id(state, upload, auth, recovery):
    record = state / 'submission.json'
    if record.exists():
        current = str(uuid.UUID(json.loads(record.read_bytes())['id'])).upper()
        if recovery and recovery != current:
            raise ValueError('recovery ID differs from the saved Apple submission')
        return current
    intent = state / 'upload-started'
    if recovery:
        if not intent.is_file():
            raise ValueError('no interrupted submission to recover on this archive')
        current = recovery
    elif intent.exists():
        history = json.loads(subprocess.check_output(['xcrun', 'notarytool', 'history', *auth,
                                                       '--output-format', 'json'], text=True))
        matches = [item['id'] for item in history['history'] if item.get('name') == upload.name]
        if len(matches) != 1:
            raise ValueError(f'previous upload has no recorded ID; match {upload.name} in notarytool history '
                             'and retry with --submission-id')
        current = str(uuid.UUID(matches[0])).upper()
    else:
        intent.touch(exist_ok=False)
        response = subprocess.check_output(['xcrun', 'notarytool', 'submit', upload, *auth, '--no-wait',
                                            '--output-format', 'json'], text=True)
        current = str(uuid.UUID(json.loads(response)['id'])).upper()
    write_record(record, json.dumps({'id': current}).encode())
    return current


def accepted_receipt(data, identifier, digest):
    record = json.loads(data)
    if (str(record.get('jobId', '')).upper() != identifier
            or record.get('status') != 'Accepted' or record.get('statusCode') != 0
            or str(record.get('sha256', '')).lower() != digest):
        raise ValueError('Apple receipt does not accept the exact submitted ZIP and submission ID')


def finish(state, source, args, auth):
    record = json.loads((state / 'build.json').read_bytes())
    if any(record.get(key) != value for key, value in {
            'bundle_id': args.bundle_id, 'source_commit': args.source_commit, 'team': args.team_id}.items()):
        raise ValueError('saved signing state belongs to another source, app or team')
    filename = record['zip']
    if Path(filename).name != filename or not filename.endswith('.zip'):
        raise ValueError('invalid saved notary ZIP name')
    upload = state / filename
    if upload.is_symlink() or sha256(upload) != record['sha256']:
        raise ValueError('saved signed ZIP differs from the original submission')
    recovery = str(uuid.UUID(args.submission_id)).upper() if args.submission_id else None
    identifier = submission_id(state, upload, auth, recovery)
    print(f'Apple submission {identifier}. Keep the archive to resume this request.', flush=True)
    wait_for_notary(identifier, auth, args.wait_seconds)
    with tempfile.TemporaryDirectory(prefix='.notarized-', dir=args.output.parent) as temp:
        scratch = Path(temp)
        log = scratch / 'notarization-log.json'
        run('xcrun', 'notarytool', 'log', identifier, log, *auth)
        receipt = log.read_bytes()
        accepted_receipt(receipt, identifier, record['sha256'])
        if args.notary_receipt.exists() and args.notary_receipt.read_bytes() != receipt:
            raise ValueError('existing output receipt belongs to another submission')
        with zipfile.ZipFile(upload) as zipped:
            for entry in zipped.infolist():
                if safe_path(entry.filename.rstrip('/')).parts[0] not in {source.name, '__MACOSX'}:
                    raise ValueError('unexpected entry in saved submission')
                if stat.S_ISLNK(entry.external_attr >> 16):
                    safe_path(zipped.read(entry).decode())
        run('ditto', '-x', '-k', upload, scratch)
        app = scratch / source.name
        if plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get(SOURCE_COMMIT_KEY) != args.source_commit:
            raise ValueError('signed app source commit differs from the release')
        run('xcrun', 'stapler', 'staple', app)
        verify(app, args.bundle_id, args.team_id)
        write_record(args.notary_receipt, receipt)
        app.rename(args.output)


def sign_ci(args):
    import fcntl

    # Remove credential data before any subprocess starts, including git, codesign and security.
    encoded = os.environ.pop('CI_SIGNING_P12', None)
    password = os.environ.pop('CI_SIGNING_P12_PASSWORD', None)
    with api_key_arguments(True) as (_, auth):
        requirement(args.bundle_id, args.team_id)
        verify_commit(args.source_commit)
        if args.wait_seconds < 0:
            raise ValueError('--wait-seconds must be nonnegative')
        archive = args.archive.resolve()
        source = archived_app(archive)
        if (app_identifier(source) != args.bundle_id or
                plistlib.loads((source / 'Contents/Info.plist').read_bytes()).get(SOURCE_COMMIT_KEY) != args.source_commit):
            raise ValueError('archive bundle ID or source commit differs from the requested release')
        if (args.output.suffix != '.app' or args.output.is_symlink() or args.output.exists()
                or args.output.resolve().is_relative_to(archive) or args.notary_receipt.is_symlink()
                or args.notary_receipt.resolve().is_relative_to(archive)
                or args.notary_receipt.resolve().is_relative_to(args.output.resolve())):
            raise ValueError('choose a new .app and a separate output receipt outside the archive')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        lock = os.open(archive, os.O_RDONLY)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = archive / 'DashboardNotarization'
            if state.is_symlink():
                raise ValueError('invalid signing state directory')
            if not state.exists():
                prepare_submission(state, source, dict(team=args.team_id, bundle_id=args.bundle_id,
                                   source_commit=args.source_commit), encoded, password)
            finish(state, source, args, auth)
        finally:
            os.close(lock)

#!/usr/bin/env python3
"""Package built Agent Dashboard apps and verify the exact web release for Pages."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from version_check import check

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = 'Agent Dashboard'
SCHEMA = 1
WEB_METADATA = 'release-manifest.json'
MAX_FILE_BYTES = 25 * 1024 * 1024  # Cloudflare Pages' per-asset limit.
MAX_FILES = 20_000  # Pages Free project limit.
MAX_WEB_BYTES = 512 * 1024 * 1024  # Bound extraction before writing to disk.
WEB_REQUIRED = ('index.html', 'flutter_bootstrap.js', 'main.dart.js',
                'manifest.json', 'version.json')
PRIVATE_SUFFIXES = {'.pem', '.key', '.p12', '.pfx'}
MACHO_MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
MACOS_ARCHITECTURES = {'arm64', 'x86_64'}


def metadata(tag, commit):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('expected a full source Git commit SHA')
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', tag):
        raise ValueError('expected an app version tag such as v0.1.0')
    return {'schema': SCHEMA, 'product': PRODUCT, 'version': tag[1:],
            'tag': tag, 'source_commit': commit}


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def safe_path(name):
    path = PurePosixPath(name)
    if (not name or not path.parts or name != path.as_posix() or path.is_absolute()
            or any(part in {'', '.', '..'} for part in path.parts) or '\\' in name):
        raise ValueError(f'unsafe archive path: {name}')
    return path


def web_files(source, version):
    if not source.is_dir() or source.is_symlink():
        raise ValueError('web source must be a built directory')
    paths = sorted(source.rglob('*'))
    if any(path.is_symlink() or not (path.is_file() or path.is_dir()) for path in paths):
        raise ValueError('web assets must be regular files, without symlinks')
    files = {path.relative_to(source).as_posix(): path for path in paths if path.is_file()}
    for name, path in files.items():
        safe_path(name)
        if (any(part.startswith('.env') for part in path.relative_to(source).parts)
                or path.suffix.lower() in PRIVATE_SUFFIXES
                or path.name.lower() in {'credentials.json', 'config.local.json'}):
            raise ValueError(f'private configuration file in web assets: {name}')
        if path.stat().st_size > MAX_FILE_BYTES:
            raise ValueError(f'asset exceeds the Pages 25 MiB limit: {name}')
    if len(files) > MAX_FILES or sum(path.stat().st_size for path in files.values()) > MAX_WEB_BYTES:
        raise ValueError('web assets exceed the release size or file-count budget')
    if any(name not in files or not files[name].stat().st_size for name in WEB_REQUIRED):
        raise ValueError('web build is incomplete')
    if not any(name.startswith('pkg/') and name.endswith('_bg.wasm') for name in files):
        raise ValueError('Rust WASM asset is missing')
    if not any(name.startswith('pkg/') and name.endswith('.js') for name in files):
        raise ValueError('Rust WASM JavaScript loader is missing')
    index = files['index.html'].read_text()
    if '<title>Agent Dashboard</title>' not in index or '<base href="/">' not in index:
        raise ValueError('web build must use the public product title and root base URL')
    if json.loads(files['manifest.json'].read_text()).get('name') != PRODUCT:
        raise ValueError('web manifest product name differs')
    if json.loads(files['version.json'].read_text()).get('version') != version:
        raise ValueError('built web version differs from the release tag')
    return files


def package_web(source, destination, release):
    files = web_files(source, release['version'])
    # Metadata belongs to the archive; leave the already-built source untouched.
    payloads = {name: path for name, path in files.items() if name != WEB_METADATA}
    payloads[WEB_METADATA] = json_bytes(dict(release, platform='web'))
    total = sum(len(value) if isinstance(value, bytes) else value.stat().st_size
                for value in payloads.values())
    if len(payloads) > MAX_FILES or total > MAX_WEB_BYTES:
        raise ValueError('release metadata exceeds the web archive size or file-count budget')
    with destination.open('wb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name, payload in sorted(payloads.items()):
                    content = payload if isinstance(payload, bytes) else payload.read_bytes()
                    member = tarfile.TarInfo(name)
                    member.size = len(content)
                    member.mode = 0o644
                    archive.addfile(member, io.BytesIO(content))


def package_macos(source, destination, release, arch):
    if source.suffix != '.app' or not source.is_dir() or source.is_symlink():
        raise ValueError('macOS source must be an existing .app bundle')
    with (source / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleShortVersionString') != release['version']:
        raise ValueError('built macOS version differs from the release tag')
    if any(info.get(key) != PRODUCT for key in ('CFBundleName', 'CFBundleDisplayName')):
        raise ValueError('macOS bundle must use the public product name')
    executable = info.get('CFBundleExecutable', '')
    if not executable or Path(executable).name != executable:
        raise ValueError('invalid macOS executable name')
    binary = source / 'Contents/MacOS' / executable
    architectures = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
    for path in source.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO_MAGIC:
                continue
        architectures &= set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split())
    required = MACOS_ARCHITECTURES if arch == 'universal' else {arch}
    if not required <= architectures:
        raise ValueError(f'macOS bundle architectures {sorted(architectures)} do not support {arch}')
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(source)],
                               capture_output=True, text=True)
    if signature.returncode == 0:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
        signing = 'ad-hoc' if 'Signature=adhoc' in signature.stderr else 'signed'
    elif 'not signed at all' in signature.stderr:
        signing = 'unsigned'
    else:
        raise ValueError('cannot determine macOS code signature')
    # Keep the bundle identifier and executable; use the product name in Finder.
    # ditto preserves framework symlinks, resource forks and executable permissions.
    with tempfile.TemporaryDirectory(prefix='agent-dashboard-macos-') as temporary:
        staged = Path(temporary) / f'{PRODUCT}.app'
        subprocess.run(['ditto', str(source), str(staged)], check=True)
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(staged), str(destination)], check=True)
    return {'arch': arch, 'architectures': sorted(architectures),
            'signing': signing, 'notarization': 'not-verified'}


def package(args, root=ROOT):
    release = metadata(args.tag, args.commit)
    check(root, args.tag)
    source = args.source.resolve()
    output = args.output.resolve()
    if source == output or source in output.parents:
        raise ValueError('release output must be outside the build source')
    if args.platform == 'macos' and not args.arch:
        raise ValueError('--arch is required for macOS')
    platform_suffix = 'web' if args.platform == 'web' else f'macos-{args.arch}'
    extension = 'tar.gz' if args.platform == 'web' else 'zip'
    output.mkdir(parents=True, exist_ok=True)
    filename = f'agent-dashboard-{args.tag}-{platform_suffix}.{extension}'
    destination = output / filename
    if destination.exists():
        raise ValueError(f'artifact already exists: {filename}')
    try:
        extra = {}
        if args.platform == 'web':
            package_web(source, destination, release)
        else:
            extra = package_macos(source, destination, release, args.arch)
        artifact = dict(platform=args.platform, file=filename, sha256=sha256(destination),
                        size_bytes=destination.stat().st_size, **extra)
        if not artifact['size_bytes']:
            raise ValueError('empty release artifact')
        receipt = dict(release, artifact=artifact)
        (output / f'{platform_suffix}.artifact.json').write_bytes(json_bytes(receipt))
        return receipt
    except Exception:
        destination.unlink(missing_ok=True)
        raise


def combine(args):
    release = metadata(args.tag, args.commit)
    artifacts = []
    sources = []
    for receipt_path in sorted(args.input.rglob('*.artifact.json')):
        receipt = json.loads(receipt_path.read_text())
        if any(receipt.get(key) != value for key, value in release.items()):
            raise ValueError('artifact receipt has a different release version or source commit')
        artifact = receipt['artifact']
        name = artifact['file']
        if len(safe_path(name).parts) != 1:
            raise ValueError('artifact filename must not contain a directory')
        source = receipt_path.parent / name
        if (source.is_symlink() or not source.is_file() or sha256(source) != artifact['sha256']
                or source.stat().st_size != artifact['size_bytes']):
            raise ValueError(f'artifact differs from its receipt: {name}')
        identity = (artifact['platform'], artifact.get('arch'))
        if any((item['platform'], item.get('arch')) == identity or item['file'] == name
               for item in artifacts):
            raise ValueError('duplicate platform or filename in release artifacts')
        artifacts.append(artifact)
        sources.append(source)
    if {item['platform'] for item in artifacts} != {'web', 'macos'}:
        raise ValueError('release requires both web and macOS artifacts')
    args.output.mkdir(parents=True, exist_ok=True)
    for source in sources:
        destination = args.output / source.name
        if source.resolve() != destination.resolve():
            shutil.copyfile(source, destination)
    release['artifacts'] = sorted(artifacts, key=lambda item: item['file'])
    (args.output / 'release.json').write_bytes(json_bytes(release))
    (args.output / 'SHA256SUMS').write_text(''.join(
        f"{item['sha256']}  {item['file']}\n" for item in release['artifacts']))
    return release


def verify_web(args):
    release = metadata(args.tag, args.commit)
    if not re.fullmatch(r'[0-9a-f]{64}', args.sha256) or sha256(args.archive) != args.sha256:
        raise ValueError('web archive SHA256 mismatch')
    if args.output.exists() and (not args.output.is_dir() or any(args.output.iterdir())):
        raise ValueError('web extraction destination must be empty or absent')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.release-web-', dir=args.output.parent) as temporary:
        stage = Path(temporary) / 'web'
        stage.mkdir()
        with tarfile.open(args.archive, 'r:gz') as archive:
            members = archive.getmembers()
            names = set()
            total = 0
            if len(members) > MAX_FILES:
                raise ValueError('too many web archive entries')
            for member in members:
                safe_path(member.name)
                if not member.isfile() or member.name in names:
                    raise ValueError('web archive contains links, special files or duplicate paths')
                if member.size < 0 or member.size > MAX_FILE_BYTES:
                    raise ValueError('web archive entry exceeds the Pages asset size limit')
                names.add(member.name)
                total += member.size
            if total > MAX_WEB_BYTES:
                raise ValueError('web archive exceeds the extraction budget')
            for member in members:
                destination = stage / member.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as stream, destination.open('wb') as target:
                    shutil.copyfileobj(stream, target)
        embedded = json.loads((stage / WEB_METADATA).read_text())
        if embedded != dict(release, platform='web'):
            raise ValueError('web archive metadata differs from requested version or source commit')
        web_files(stage, release['version'])
        if args.output.exists():
            args.output.rmdir()
        stage.rename(args.output)
    return embedded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('package', 'combine', 'verify-web'):
        command = commands.add_parser(name)
        command.add_argument('--tag', required=True)
        command.add_argument('--commit', required=True)
        command.add_argument('--output', type=Path, required=True)
        if name == 'package':
            command.add_argument('--platform', choices=['web', 'macos'], required=True)
            command.add_argument('--source', type=Path, required=True)
            command.add_argument('--arch', choices=['arm64', 'x86_64', 'universal'])
        elif name == 'combine':
            command.add_argument('--input', type=Path, required=True)
        else:
            command.add_argument('--archive', type=Path, required=True)
            command.add_argument('--sha256', required=True)
    args = parser.parse_args()
    try:
        result = {'package': package, 'combine': combine, 'verify-web': verify_web}[args.command](args)
        print(json.dumps(result))
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()

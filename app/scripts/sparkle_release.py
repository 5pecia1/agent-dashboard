#!/usr/bin/env python3
"""Sign the delivered macOS ZIP and construct its Sparkle 2 appcast."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
import zipfile


SPARKLE_VERSION = '2.10.1'
TOOLS_SHA256 = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
TOOLS_URL = f'https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/Sparkle-{SPARKLE_VERSION}.tar.xz'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
S = '{' + NS + '}'
REPO = '5pecia1/agent-dashboard'
PRODUCT = 'Agent Dashboard'
BUNDLE_ID = 'io.github.5pecia1.mydashboard'
PUBLIC_FEED = 'https://agent-dashboard.5pecia1.dev/appcast.xml'
SIGN_TOOL_SHA256 = '43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def install_tools(output):
    if output.exists():
        raise ValueError('use a new directory for the pinned Sparkle tools')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        work = Path(temp)
        archive = work / 'distribution.tar.xz'
        downloaded = None
        if shutil.which('gh'):
            downloaded = subprocess.run(['gh', 'release', 'download', SPARKLE_VERSION, '--repo', 'sparkle-project/Sparkle',
                                         '--pattern', f'Sparkle-{SPARKLE_VERSION}.tar.xz', '--output', archive])
        if downloaded is None or downloaded.returncode:
            subprocess.run(['curl', '-fsSL', '--retry', '3', '--connect-timeout', '20', '--max-time', '180',
                            '--proto', '=https', TOOLS_URL, '-o', archive], check=True)
        if digest(archive) != TOOLS_SHA256:
            raise ValueError('Sparkle tools download differs from the pinned release SHA256')
        tools = work / 'bin'
        tools.mkdir()
        with tarfile.open(archive) as package:
            for name in ['sign_update', 'generate_keys']:
                member = package.getmember('./bin/' + name)
                if not member.isfile():
                    raise ValueError('unexpected Sparkle tool archive structure')
                target = tools / name
                with package.extractfile(member) as stream:
                    target.write_bytes(stream.read())
                target.chmod(0o755)
        tools.rename(output)


def https_url(url):
    uri = urlsplit(url)
    if (uri.scheme != 'https' or not uri.hostname or uri.username or uri.password or not uri.path
            or uri.query or uri.fragment or any(ord(c) < 32 or c.isspace() for c in url)):
        raise ValueError('supply a fixed HTTPS URL without credentials or temporary query parameters')
    return url


def binary_value(value, size):
    data = base64.b64decode(value, validate=True)
    if len(data) != size:
        raise ValueError('invalid Ed25519 key or signature length')
    return data


def verify_ed(archive, public, signature):
    key = binary_value(public, 32)
    sig = binary_value(signature, 64)
    if sys.platform == 'darwin':
        code = '''import CryptoKit
import Foundation
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[2])!)
let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(Data(base64Encoded: CommandLine.arguments[3])!, for: file) else { exit(1) }
'''
        result = subprocess.run(['xcrun', 'swift', '-', archive, public, signature], input=code, text=True)
    else:
        with tempfile.TemporaryDirectory() as temp:
            pem, signature_file = Path(temp) / 'key.der', Path(temp) / 'signature'
            # RFC 8410 SubjectPublicKeyInfo for a raw Ed25519 key.
            pem.write_bytes(bytes.fromhex('302a300506032b6570032100') + key)
            signature_file.write_bytes(sig)
            result = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER',
                                     '-inkey', pem, '-sigfile', signature_file, '-rawin', '-in', archive],
                                    stdout=subprocess.DEVNULL)
    if result.returncode:
        raise ValueError('Ed25519 signature does not verify against the public key in the delivered app')


def archive_info(archive, product, bundle_id):
    info_path = f'{product}.app/Contents/Info.plist'
    with zipfile.ZipFile(archive) as zipped:
        if zipped.namelist().count(info_path) != 1:
            raise ValueError('archive must contain one expected application Info.plist')
        info = plistlib.loads(zipped.read(info_path))
    if (info.get('CFBundleIdentifier') != bundle_id or info.get('CFBundleDisplayName') != product
            or not re.fullmatch(r'[1-9][0-9]*', str(info.get('CFBundleVersion', '')))
            or not info.get('CFBundleShortVersionString')):
        raise ValueError('archive product, identifier or version differs from the release')
    binary_value(info.get('SUPublicEDKey', ''), 32)
    https_url(info.get('SUFeedURL', ''))
    return info


def sign(args):
    seed = os.environ.pop('SPARKLE_PRIVATE_KEY', '').strip()
    if not seed:
        raise ValueError('configure SPARKLE_PRIVATE_KEY in the product signing environment')
    if args.output.exists() or args.output.is_symlink() or (args.app and args.output.resolve().is_relative_to(args.app.resolve())):
        raise ValueError('choose a new appcast path outside the signed app')
    https_url(args.url)
    info = archive_info(args.archive, args.product, args.bundle_id)
    if args.app:
        signed_info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        if signed_info != info:
            raise ValueError('provided application does not match the Info.plist in the final ZIP')
    verification_tool = Path(os.environ['SPARKLE_BIN_DIR']) / 'sign_update'
    if digest(verification_tool) != SIGN_TOOL_SHA256:
        raise ValueError('sign_update differs from the pinned Sparkle distribution')
    signature = subprocess.check_output([verification_tool, '--ed-key-file', '-', '-p', args.archive],
                                        input=seed + '\n', text=True).strip()
    verify_ed(args.archive, info['SUPublicEDKey'], signature)
    size = args.archive.stat().st_size
    version = info['CFBundleShortVersionString']
    build = str(info['CFBundleVersion'])
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = args.product
    ET.SubElement(channel, 'link').text = info['SUFeedURL']
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'{args.product} {version}'
    ET.SubElement(item, S + 'version').text = build
    ET.SubElement(item, S + 'shortVersionString').text = version
    if info.get('LSMinimumSystemVersion'):
        ET.SubElement(item, S + 'minimumSystemVersion').text = info['LSMinimumSystemVersion']
    ET.SubElement(item, 'enclosure', {'url': args.url, 'type': 'application/octet-stream',
                                       'length': str(size), S + 'edSignature': signature})
    ET.indent(rss)
    metadata = dict(sparkle_ed_signature=signature, sha256=digest(args.archive), bytes=size, version=version, build=build)
    if args.artifact_receipt:
        receipt = json.loads(args.artifact_receipt.read_bytes())
        artifact = receipt['artifact']
        if (receipt['product'] != args.product or receipt['version'] != version or artifact['file'] != args.archive.name
                or artifact['size_bytes'] != size or artifact['sha256'] != metadata['sha256']
                or artifact['notarization'] != 'stapled' or artifact['signing'] != 'developer-id'):
            raise ValueError('final ZIP differs from the notarization-verified product receipt')
        artifact.update(build=build, sparkle_ed_signature=signature)
        args.artifact_receipt.write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    args.output.write_bytes(ET.tostring(rss, encoding='utf-8', xml_declaration=True))
    return metadata


def public_item(feed, tag, asset):
    root = ET.fromstring(feed)
    items = root.findall('./channel/item')
    url = f'https://github.com/{REPO}/releases/download/{tag}/{asset["name"]}'
    if asset['name'] != f'agent-dashboard-{tag}-macos-universal.zip':
        raise ValueError('public update must use the immutable universal release filename')
    if len(items) != 1 or root.findtext('./channel/link') != PUBLIC_FEED:
        raise ValueError('public appcast must contain one item on the production update channel')
    item, = items
    enclosure = item.find('enclosure')
    build = item.findtext(S + 'version', '')
    if (not re.fullmatch(r'[1-9][0-9]*', build) or item.findtext(S + 'shortVersionString') != tag[1:]
            or enclosure is None or enclosure.get('url') != url or enclosure.get('length') != str(asset['size'])):
        raise ValueError(f'appcast release metadata differs from its immutable macOS ZIP: {tag}')
    signature = enclosure.get(S + 'edSignature', '')
    binary_value(signature, 64)
    return int(build), signature


def verify_public(feed, tag, artifact, archive):
    asset = {'name': archive.name, 'size': archive.stat().st_size}
    build, signature = public_item(feed, tag, asset)
    if (artifact['file'] != archive.name or artifact['sha256'] != digest(archive)
            or artifact['size_bytes'] != asset['size'] or artifact['notarization'] != 'stapled'
            or artifact['signing'] != 'developer-id' or artifact['arch'] != 'universal'
            or artifact['bundle_id'] != BUNDLE_ID or artifact['sparkle_ed_signature'] != signature
            or str(artifact['build']) != str(build)):
        raise ValueError('ZIP or appcast differs from the verified release receipt')
    info = archive_info(archive, PRODUCT, BUNDLE_ID)
    if (info['SUFeedURL'] != PUBLIC_FEED or info['CFBundleShortVersionString'] != tag[1:]
            or str(info['CFBundleVersion']) != str(build)):
        raise ValueError('public feed differs from the app version or update channel')
    verify_ed(archive, info['SUPublicEDKey'], signature)


def gh_download(tag, name, dest):
    subprocess.run(['gh', 'release', 'download', tag, '--repo', REPO, '--pattern', name, '--dir', dest], check=True)
    return dest / name


def live_feed():
    url = f'{PUBLIC_FEED}?check={time.time_ns()}'
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            data = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    # Before the first feed release, Pages may return the Flutter SPA's index for an unknown route.
    if data.lstrip().lower().startswith((b'<!doctype html', b'<html')):
        return None
    if len(data) > 1024 * 1024 or ET.fromstring(data).tag != 'rss':
        raise ValueError('unexpected response from the production appcast')
    return data


def confirm_pages(directory):
    target = directory / 'appcast.xml'
    if not target.exists():
        return
    expected = target.read_bytes()
    for attempt in range(24):
        try:
            if live_feed() == expected:
                print('Public appcast.xml matches the verified stable release.')
                return
        except (urllib.error.URLError, TimeoutError):
            pass
        if attempt < 23:
            time.sleep(5)
    raise ValueError('the production appcast does not match the verified stable release')


def stage_pages(directory):
    """Deploy the highest stable app build, independently of the web version being deployed."""
    target = directory / 'appcast.xml'
    if target.exists():
        raise ValueError('web archive contains an unexpected appcast.xml')
    pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp',
                                               f'repos/{REPO}/releases?per_page=100']))
    candidates = []
    with tempfile.TemporaryDirectory() as temp:
        scratch = Path(temp)
        for release in (r for page in pages for r in page):
            tag = release['tag_name']
            if release['draft'] or release['prerelease'] or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
                continue
            assets = {a['name']: a for a in release['assets']}
            if 'appcast.xml' not in assets:
                continue
            folder = scratch / tag
            archive_name = f'agent-dashboard-{tag}-macos-universal.zip'
            asset = assets[archive_name]
            feed = gh_download(tag, 'appcast.xml', folder).read_bytes()
            build, sig = public_item(feed, tag, asset)
            candidates.append((build, tag, sig, feed, asset))
        previous = live_feed()
        if not candidates:
            if previous is not None:
                raise ValueError('a live update feed exists but no published stable release can reproduce it')
            print('No stable Sparkle release has been published.')
            return
        build, tag, _, feed, asset = max(candidates, key=lambda entry: entry[0])
        if previous is not None:
            live_build = int(ET.fromstring(previous).findtext('./channel/item/' + S + 'version', ''))
            if live_build > build or (live_build == build and previous != feed):
                raise ValueError('refusing to replace the live update with an older or different build')
        if sum(1 for entry in candidates if entry[0] == build) != 1:
            raise ValueError(f'multiple published versions reuse Sparkle build {build}')
        folder = scratch / tag
        archive = gh_download(tag, asset['name'], folder)
        release = json.loads(gh_download(tag, 'release.json', folder).read_bytes())
        mac, = [a for a in release['artifacts'] if a['platform'] == 'macos']
        if release['tag'] != tag or archive.stat().st_size != asset['size']:
            raise ValueError('published release metadata differs from its GitHub asset')
        verify_public(feed, tag, mac, archive)
        target.write_bytes(feed)
        print(f'Staged verified public appcast for {tag} (build {build}).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    tools = commands.add_parser('tools')
    tools.add_argument('--output', type=Path, required=True)
    signer = commands.add_parser('sign')
    signer.add_argument('--archive', type=Path, required=True)
    signer.add_argument('--app', type=Path)
    signer.add_argument('--bundle-id', required=True)
    signer.add_argument('--product', required=True)
    signer.add_argument('--url', required=True)
    signer.add_argument('--output', type=Path, required=True)
    signer.add_argument('--artifact-receipt', type=Path, help='bind the signature and build to a public product receipt')
    verify = commands.add_parser('verify-public')
    verify.add_argument('--directory', type=Path, required=True)
    verify.add_argument('--tag', required=True)
    for name in ('stage-pages', 'confirm-pages'):
        stage = commands.add_parser(name)
        stage.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == 'tools':
            install_tools(args.output)
        elif args.action == 'sign':
            print(json.dumps(sign(args)))
        elif args.action == 'verify-public':
            receipt, = args.directory.glob('macos-*.artifact.json')
            record = json.loads(receipt.read_bytes())
            artifact = record['artifact']
            if record['tag'] != args.tag:
                raise ValueError('release tag differs from the receipt')
            if 'sparkle_ed_signature' in artifact or (args.directory / 'appcast.xml').exists():
                verify_public((args.directory / 'appcast.xml').read_bytes(), args.tag, artifact,
                              args.directory / artifact['file'])
        elif args.action == 'stage-pages':
            stage_pages(args.directory)
        else:
            confirm_pages(args.directory)
    except (OSError, KeyError, ValueError, ET.ParseError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()

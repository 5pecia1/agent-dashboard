#!/usr/bin/env python3
"""Upload verified assets to a draft, verify the complete remote inventory, then publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import quote


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True).strip()


def file_digest(path):
    with path.open('rb') as stream:
        return 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()


def remote_release(repo, tag):
    pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{repo}/releases?per_page=100'))
    return next((item for page in pages for item in page if item['tag_name'] == tag), None)


def compare_assets(release, local, repo, tag):
    existing = set()
    for asset in release['assets']:
        name = asset['name']
        if name not in local or name in existing or asset.get('state') != 'uploaded':
            raise ValueError(f'unexpected or incomplete asset on {tag}: {name}')
        digest = asset.get('digest')
        if not digest:
            with tempfile.TemporaryDirectory() as temp:
                gh('release', 'download', tag, '--repo', repo, '--pattern', name, '--dir', temp)
                digest = file_digest(Path(temp) / name)
        if digest != local[name]:
            raise ValueError(f'published or staged bytes differ: {name}')
        existing.add(name)
    return set(local) - existing


def publish(args):
    repo = os.environ['GH_REPO']
    source = gh('api', f'repos/{repo}/commits/{quote(args.tag, safe="")}', '--jq', '.sha')
    if source != args.commit:
        raise ValueError('release tag differs from the verified commit')
    assets = sorted(args.directory.iterdir())
    if not assets or any(not p.is_file() or p.is_symlink() or not p.stat().st_size for p in assets):
        raise ValueError('expected a nonempty directory of verified release files')
    local = {path.name: file_digest(path) for path in assets}
    release = remote_release(repo, args.tag)
    flags = ['--prerelease'] if args.prerelease else []
    if not release:
        gh('release', 'create', args.tag, '--repo', repo, '--verify-tag', '--target', args.commit,
           '--draft', '--latest=false', '--title', args.title, '--notes-file', str(args.notes), *flags)
        release = remote_release(repo, args.tag)
    if not release:
        raise ValueError('new release draft is unavailable')
    missing = compare_assets(release, local, repo, args.tag)
    if not release['draft']:
        if missing:
            raise ValueError('published release has missing assets; release a new version')
        return
    for name in sorted(missing):
        gh('release', 'upload', args.tag, '--repo', repo, str(args.directory / name))
    staged = remote_release(repo, args.tag)
    if not staged or not staged['draft'] or staged['id'] != release['id'] or compare_assets(staged, local, repo, args.tag):
        raise ValueError('draft asset verification failed')
    gh('release', 'edit', args.tag, '--repo', repo, '--draft=false', '--latest=' + args.latest, *flags)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--title', required=True)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--latest', choices=['true', 'false'], required=True)
    parser.add_argument('--prerelease', action='store_true')
    try:
        publish(parser.parse_args())
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{error}\n')

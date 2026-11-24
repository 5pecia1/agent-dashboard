#!/usr/bin/env python3
"""Upload verified assets to a draft, verify the complete remote inventory, then publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.parse import quote


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True).strip()


def file_digest(path):
    with path.open('rb') as stream:
        return 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()


def release_id(repo, tag):
    # Pending tags on draft releases are visible to the authenticated tag lookup.
    owner, name = repo.split('/')
    query = ('query($owner:String!, $repo:String!, $tag:String!) {'
             'repository(owner:$owner,name:$repo) {release(tagName:$tag) {databaseId}}}')
    response = json.loads(gh('api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner,
                             '-f', 'repo=' + name, '-f', 'tag=' + tag))
    release = response['data']['repository']['release']
    return release['databaseId'] if release else None


def by_id(repo, identifier, tag):
    endpoint = f'repos/{repo}/releases/{identifier}'
    release = json.loads(gh('api', endpoint))
    if release['id'] != identifier or release['tag_name'] != tag:
        raise ValueError('release identity changed during publication')
    pages = json.loads(gh('api', '--paginate', '--slurp', endpoint + '/assets?per_page=100'))
    release['assets'] = [asset for page in pages for asset in page]
    return release


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
    identifier = release_id(repo, args.tag)
    if identifier is None:
        created = json.loads(gh('api', '--method', 'POST', f'repos/{repo}/releases',
                                '-f', 'tag_name=' + args.tag, '-f', 'target_commitish=' + args.commit,
                                '-f', 'name=' + args.title, '-f', 'body=' + args.notes.read_text(),
                                '-F', 'draft=true', '-F', 'prerelease=' + str(args.prerelease).lower(),
                                '-f', 'make_latest=false'))
        identifier = created['id']
        if not created['draft'] or created['tag_name'] != args.tag:
            raise ValueError('GitHub returned an unexpected draft')
        # gh release upload resolves tags. Wait for the exact draft ID, not the release list.
        for attempt in range(6):
            if release_id(repo, args.tag) == identifier:
                break
            if attempt < 5:
                time.sleep(2 ** attempt)
        else:
            raise ValueError(f'draft {identifier} is not visible by tag yet; rerun the failed publish job')
    release = by_id(repo, identifier, args.tag)
    missing = compare_assets(release, local, repo, args.tag)
    if not release['draft']:
        if missing:
            raise ValueError('published release has missing assets; release a new version')
        return
    for name in sorted(missing):
        gh('release', 'upload', args.tag, '--repo', repo, str(args.directory / name))
    for attempt in range(5):
        staged = by_id(repo, identifier, args.tag)
        if not staged['draft']:
            raise ValueError('draft was published concurrently')
        if not compare_assets(staged, local, repo, args.tag):
            break
        if attempt < 4:
            time.sleep(2 ** attempt)
    else:
        raise ValueError('draft asset verification failed; rerun after all assets are visible')
    gh('api', '--method', 'PATCH', f'repos/{repo}/releases/{identifier}', '-F', 'draft=false',
       '-f', 'make_latest=' + args.latest, '-F', 'prerelease=' + str(args.prerelease).lower())


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

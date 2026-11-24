#!/usr/bin/env python3
"""Verify web archive provenance independently of the downloaded GitHub release metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REPO = '5pecia1/agent-dashboard'
WORKFLOW = REPO + '/.github/workflows/release-product.yml'
PINS = Path(__file__).with_name('legacy-web-digests.json')


def verify(archive, tag, commit):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', tag):
        raise ValueError('expected an app release tag')
    if not re.fullmatch(r'[a-f0-9]{40}', commit) or archive.name != f'agent-dashboard-{tag}-web.tar.gz':
        raise ValueError('unexpected web archive name or source commit')
    legacy = json.loads(PINS.read_bytes()).get(tag)
    if legacy:
        with archive.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if legacy != {'commit': commit, 'sha256': digest}:
            raise ValueError('historical web release differs from its reviewed source and archive digest')
        print(f'Verified the historical archive digest and source for {tag}.')
        return
    subprocess.run(['gh', 'attestation', 'verify', str(archive), '--repo', REPO, '--signer-workflow', WORKFLOW,
                    '--source-ref', 'refs/tags/' + tag, '--source-digest', commit, '--deny-self-hosted-runners'],
                   check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    try:
        verify(args.archive, args.tag, args.commit)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{error}\n')

#!/usr/bin/env python3
"""Require tag, Cargo, pubspec and MSIX to describe the same app release."""
import argparse
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def check(root, tag=''):
    version = tomllib.loads((root / 'Cargo.toml').read_text(encoding="utf-8"))['workspace']['package']['version']
    pubspec = (root / 'flutter_app/pubspec.yaml').read_text(encoding="utf-8")
    flutter = re.search(r'(?m)^version:\s*([^\s]+)', pubspec)
    msix = re.search(r'(?m)^\s+msix_version:\s*([^\s]+)', pubspec)
    if not flutter or flutter[1].split('+')[0] != version:
        raise ValueError('Cargo and pubspec versions differ')
    if not msix or msix[1] != version.split('-')[0] + '.0':
        raise ValueError('MSIX version must be the numeric app version plus .0')
    if tag and tag != f'v{version}':
        raise ValueError(f'tag {tag} does not match app version v{version}')
    return version


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', default='')
    args = parser.parse_args()
    try:
        print(check(ROOT, args.tag))
    except ValueError as error:
        parser.exit(1, f'{error}\n')

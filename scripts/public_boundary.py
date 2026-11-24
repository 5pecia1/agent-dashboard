#!/usr/bin/env python3
"""Repository boundary checks for public pull requests and pushes."""
import argparse
import re
import subprocess
import sys

MAX_BYTES = 5 * 1024 * 1024
SUBJECT = 'Update Agent Dashboard public source'
MARKER = re.compile(r'^\s*GitOrigin-RevId\s*[:=]', re.I | re.M)


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout


def structure(rev):
    errors = []
    for line in git('ls-tree', '-r', '-l', '-z', rev).split('\0'):
        if not line:
            continue
        meta, path = line.split('\t', 1)
        mode, kind, _, size = meta.split()
        if mode == '120000':
            errors.append(f'symlink is not allowed: {path}')
        elif mode == '160000' or kind == 'commit':
            errors.append(f'submodule/gitlink is not allowed: {path}')
        elif int(size) > MAX_BYTES:
            errors.append(f'file exceeds {MAX_BYTES // 1024 // 1024} MiB: {path} ({int(size)} bytes)')
    return errors


def no_export_markers(base, head):
    """Only export pull requests may carry the export subject or a GitOrigin-RevId label."""
    errors = []
    log = git('log', '--format=%H%x00%B%x01', f'{base}..{head}')
    for record in filter(None, (item.strip('\n') for item in log.split('\x01'))):
        commit, message = record.split('\x00', 1)
        subject = message.split('\n', 1)[0].strip()
        if MARKER.search(message):
            errors.append(f'commit {commit[:12]} has a GitOrigin-RevId label from the retired export workflow')
        if subject.lower().startswith(SUBJECT.lower()):
            errors.append(f'commit {commit[:12]} uses the export subject "{SUBJECT}" from the retired export workflow')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('structure')
    p.add_argument('--rev', default='HEAD')
    p = sub.add_parser('no-export-markers')
    p.add_argument('--base', required=True)
    p.add_argument('--head', required=True)
    args = parser.parse_args()
    if args.command == 'structure':
        errors = structure(args.rev)
    else:
        errors = no_export_markers(args.base, args.head)
    for error in errors:
        print(f'error: {error}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

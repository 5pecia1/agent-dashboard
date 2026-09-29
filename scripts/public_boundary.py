#!/usr/bin/env python3
"""Repository boundary checks for public pull requests and pushes."""
import argparse
import re
import subprocess
import sys

MAX_BYTES = 5 * 1024 * 1024
IDENTITY = '5pecia1 <14145618+5pecia1@users.noreply.github.com>'
SUBJECT = 'Update Agent Dashboard public source'
MESSAGE = re.compile(re.escape(SUBJECT) + r'\n\nGitOrigin-RevId: [0-9a-f]{40}')
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


def export_commit(base, head):
    commits = git('rev-list', f'{base}..{head}').split()
    if len(commits) != 1:
        return [f'export branch must contain exactly one commit, found {len(commits)}']
    commit = commits[0]
    errors = []
    for label, fmt in (('author', '%an <%ae>'), ('committer', '%cn <%ce>')):
        actual = git('log', '-1', f'--format={fmt}', commit).strip()
        if actual != IDENTITY:
            errors.append(f'{label} must be {IDENTITY}, found {actual}')
    message = git('log', '-1', '--format=%B', commit).rstrip('\n')
    if not MESSAGE.fullmatch(message):
        errors.append(f'message must be "{SUBJECT}", a blank line, and "GitOrigin-RevId: <40-hex>"; found {message!r}')
    return errors


def no_export_markers(base, head):
    """Only export pull requests may carry the export subject or a GitOrigin-RevId label."""
    errors = []
    log = git('log', '--format=%H%x00%B%x01', f'{base}..{head}')
    for record in filter(None, (item.strip('\n') for item in log.split('\x01'))):
        commit, message = record.split('\x00', 1)
        subject = message.split('\n', 1)[0].strip()
        if MARKER.search(message):
            errors.append(f'commit {commit[:12]} has a GitOrigin-RevId label; only export pull requests may')
        if subject.lower().startswith(SUBJECT.lower()):
            errors.append(f'commit {commit[:12]} uses the export subject "{SUBJECT}"; only export pull requests may')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('structure')
    p.add_argument('--rev', default='HEAD')
    for name in ('export-commit', 'no-export-markers'):
        p = sub.add_parser(name)
        p.add_argument('--base', required=True)
        p.add_argument('--head', required=True)
    args = parser.parse_args()
    if args.command == 'structure':
        errors = structure(args.rev)
    elif args.command == 'export-commit':
        errors = export_commit(args.base, args.head)
    else:
        errors = no_export_markers(args.base, args.head)
    for error in errors:
        print(f'error: {error}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

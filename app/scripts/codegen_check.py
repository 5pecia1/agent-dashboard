#!/usr/bin/env python3
"""Regenerate in a disposable copy; never alter source files or the Git index."""
import argparse
import glob
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

OUTPUTS = ('app-frb/src/frb_generated.rs', 'flutter_app/lib/src/rust')
REQUIRED_FRB = ('app-frb/src/frb_generated.rs', 'flutter_app/lib/src/rust/frb_generated.dart')
IGNORED = {'.git', '.fvm', '.dart_tool', 'target', 'build', '.plugin_symlinks', 'ephemeral', '__pycache__'}


def snapshot(root, outputs):
    files = {}
    for output in outputs:
        path = root / output
        candidates = root.glob(output) if glob.has_magic(output) else ([path] if path.is_file() else path.rglob('*'))
        for item in candidates:
            if item.is_file():
                files[str(item.relative_to(root))] = item.read_bytes()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--output', action='append')
    parser.add_argument('--generator', choices=['frb', 'dart'], default='frb')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = args.root.resolve()
    outputs = args.output or (OUTPUTS if args.generator == 'frb' else ('flutter_app/lib/**/*.g.dart', 'flutter_app/lib/**/*.freezed.dart'))
    for output in outputs:
        if Path(output).is_absolute() or '..' in Path(output).parts:
            parser.error('outputs must be relative paths inside the project')
    before = snapshot(root, outputs)
    # ignore_cleanup_errors: Swift Package Manager (macos target) extracts
    # xcframework artifacts with deeply nested paths under
    # build/macos/SourcePackages/artifacts/.../PrivateHeaders/... during
    # `flutter pub get`; on some macOS/Python combos shutil.rmtree's dir_fd-based
    # walk hits ENOTEMPTY tearing those down. The check itself (generate +
    # snapshot diff) already completed by the time this scratch dir is torn
    # down, so a cleanup failure here is not a check result — don't let it
    # masquerade as a generator failure.
    with tempfile.TemporaryDirectory(prefix='device-app-codegen-', ignore_cleanup_errors=True) as directory:
        scratch = Path(directory) / 'project'
        shutil.copytree(root, scratch, ignore=lambda _, names: set(names) & IGNORED)
        for output in outputs:
            path = scratch / output
            if glob.has_magic(output):
                for generated in scratch.glob(output):
                    if generated.is_file():
                        generated.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()
        env = dict(os.environ, CARGO_TARGET_DIR=str(scratch / 'target'))
        command = args.command
        if command[:1] == ['--']:
            command = command[1:]
        if not command:
            result = subprocess.run(['flutter', 'pub', 'get'], cwd=scratch / 'flutter_app', env=env)
            if result.returncode:
                return result.returncode
            command = ['flutter_rust_bridge_codegen', 'generate'] if args.generator == 'frb' else ['dart', 'run', 'build_runner', 'build', '--delete-conflicting-outputs']
        cwd = scratch / 'flutter_app' if not args.command and args.generator == 'dart' else scratch
        result = subprocess.run(command, cwd=cwd, env=env)
        if result.returncode:
            return result.returncode
        after = snapshot(scratch, outputs)
        if args.generator == 'frb' and not args.output:
            absent = [path for path in REQUIRED_FRB if not after.get(path)]
            if absent:
                print('required FRB output missing or empty: ' + ', '.join(absent))
                return 1
    changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    for path in changed:
        kind = 'new' if path not in before else 'missing' if path not in after else 'changed'
        print(f'{kind}: {path}')
    return int(bool(changed))


if __name__ == '__main__':
    raise SystemExit(main())

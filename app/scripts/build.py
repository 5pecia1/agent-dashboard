#!/usr/bin/env python3
"""Build a selected target, defaulting to the current desktop or web-only app."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tomllib

from flutter_dependencies import prepare_flutter_project

ROOT = Path(__file__).resolve().parents[1]


def choose_target(targets, host, requested):
    native = {'Linux': 'linux', 'Darwin': 'macos', 'Windows': 'windows'}.get(host)
    target = requested or (native if native in targets else 'web' if targets == ['web'] else None)
    if requested and requested not in targets:
        raise ValueError(f'{requested} is not a selected target: {targets}')
    if target is None or target != 'web' and target != native:
        raise ValueError(f'host {host} cannot build selected targets {targets}; request --target web if selected')
    return target


def seal_web_shell(directory):
    """Embed only public build artifacts, using exact bytes to bind each cache entry."""
    root_files = {'index.html', 'flutter_bootstrap.js', 'flutter.js', 'main.dart.js', 'main.dart.mjs',
                  'main.dart.wasm', 'favicon.png', 'manifest.json', 'push_token_bridge.js', 'version.json'}
    asset_roots = {'assets', 'canvaskit', 'icons', 'pkg', 'vendor'}
    files = {}
    for path in sorted(directory.rglob('*')):
        relative = path.relative_to(directory)
        if (not path.is_file() or path.is_symlink() or any(part.startswith('.') for part in relative.parts)
                or (relative.as_posix() not in root_files and relative.parts[0] not in asset_roots)):
            continue
        files[relative.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not {'index.html', 'flutter_bootstrap.js', 'manifest.json'} <= files.keys():
        raise ValueError('incomplete public web shell')
    revision = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    worker = directory / 'my_dashboard_service_worker.js'
    source = worker.read_text(encoding='utf-8')
    marker = 'const BUILD = null; // Replaced by scripts/build.py.'
    if source.count(marker) != 1:
        raise ValueError('missing service-worker build marker')
    payload = json.dumps({'revision': revision, 'files': files}, separators=(',', ':'))
    worker.write_text(source.replace(marker, 'const BUILD = ' + payload + ';'), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['linux', 'macos', 'windows', 'web'])
    args = parser.parse_args()
    try:
        state = json.loads((ROOT / '.device-app.json').read_text(encoding="utf-8"))
        target = choose_target(state['targets'], platform.system(), args.target)
    except (ValueError, FileNotFoundError) as error:
        parser.exit(1, f'{error}\nRun mise run bootstrap first.\n')
    prepare_flutter_project(ROOT / 'flutter_app')
    if target == 'web':
        toolchain = tomllib.loads((ROOT / '.mise.toml').read_text(encoding="utf-8"))['env']['FRB_WEB_TOOLCHAIN']
        subprocess.run(['flutter_rust_bridge_codegen', 'build-web', '--dart-root', 'flutter_app', '--rust-root', '../app-frb', '--release', '--wasm-pack-rustup-toolchain', toolchain], cwd=ROOT, check=True)
    subprocess.run(['flutter', 'build', target], cwd=ROOT / 'flutter_app', check=True)
    if target == 'web':
        seal_web_shell(ROOT / 'flutter_app/build/web')


if __name__ == '__main__':
    main()

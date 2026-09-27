#!/usr/bin/env python3
"""Build a selected target, defaulting to the current desktop or web-only app."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def choose_target(targets, host, requested):
    native = {'Linux': 'linux', 'Darwin': 'macos', 'Windows': 'windows'}.get(host)
    target = requested or (native if native in targets else 'web' if targets == ['web'] else None)
    if requested and requested not in targets:
        raise ValueError(f'{requested} is not a selected target: {targets}')
    if target is None or target != 'web' and target != native:
        raise ValueError(f'host {host} cannot build selected targets {targets}; request --target web if selected')
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['linux', 'macos', 'windows', 'web'])
    args = parser.parse_args()
    try:
        state = json.loads((ROOT / '.device-app.json').read_text(encoding="utf-8"))
        target = choose_target(state['targets'], platform.system(), args.target)
    except (ValueError, FileNotFoundError) as error:
        parser.exit(1, f'{error}\nRun mise run bootstrap first.\n')
    if target == 'web':
        toolchain = tomllib.loads((ROOT / '.mise.toml').read_text(encoding="utf-8"))['env']['FRB_WEB_TOOLCHAIN']
        subprocess.run(['flutter_rust_bridge_codegen', 'build-web', '--dart-root', 'flutter_app', '--rust-root', '../app-frb', '--release', '--wasm-pack-rustup-toolchain', toolchain], cwd=ROOT, check=True)
    subprocess.run(['flutter', 'build', target], cwd=ROOT / 'flutter_app', check=True)


if __name__ == '__main__':
    main()

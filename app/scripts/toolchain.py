#!/usr/bin/env python3
""".mise.toml owns tool versions; package pins are checked derived values."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['flutter', 'frb', 'github', 'check', 'sync', 'rust'])
    args = parser.parse_args()
    config = tomllib.loads((ROOT / '.mise.toml').read_text(encoding="utf-8"))
    if args.command == 'rust':
        subprocess.run(['rustup', 'component', 'add', '--toolchain', config['tools']['rust'], 'rustfmt', 'clippy'], check=True)
        return
    flutter = config['env']['FLUTTER_VERSION']
    frb = config['tools']['cargo:flutter_rust_bridge_codegen']
    if args.command in ('flutter', 'frb'):
        print(flutter if args.command == 'flutter' else frb)
        return
    if args.command == 'github':
        print(f'FLUTTER_VERSION={flutter}')
        return
    files = {
        ROOT / 'Cargo.toml': (r'(?m)^flutter_rust_bridge = "[^"]+"', f'flutter_rust_bridge = "={frb}"'),
        ROOT / 'flutter_app/pubspec.yaml': (r'(?m)^  flutter_rust_bridge: [^\n]+', f'  flutter_rust_bridge: {frb}'),
    }
    for path, (pattern, expected) in files.items():
        content = path.read_text(encoding="utf-8")
        match = re.search(pattern, content)
        if args.command == 'sync':
            if not match:
                parser.error(f'cannot locate FRB dependency in {path}')
            path.write_text(re.sub(pattern, expected, content), encoding="utf-8", newline="\n")
        elif not match or match[0] != expected:
            parser.error(f'FRB version drift in {path}; run python3 scripts/toolchain.py sync')
    if args.command == 'check':
        # A fresh Windows SDK's shared.bat writes pub-upgrade progress to stdout.
        # Finish SDK initialization before requiring a clean machine response.
        subprocess.run(['flutter', '--version'], check=True, stdout=subprocess.DEVNULL)
        actual = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], text=True, encoding="utf-8"))['frameworkVersion']
        if actual != flutter:
            parser.error(f'Flutter {actual} is active; expected {flutter}')
        actual_frb = subprocess.check_output(['flutter_rust_bridge_codegen', '--version'], text=True, encoding="utf-8").strip().split()[-1]
        if actual_frb != frb:
            parser.error(f'FRB codegen {actual_frb} is active; expected {frb}')


if __name__ == '__main__':
    main()

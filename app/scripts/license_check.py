#!/usr/bin/env python3
"""Check resolved Rust and Dart licenses; warn never hides scanner failures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]


def classify(code, violation_code, policy, completed=True):
    if not completed:
        print("license scan did not produce a complete report")
        return 1
    if code == 0:
        return 0
    if code == violation_code:
        print(f'license policy findings ({policy})')
        return int(policy == 'enforce')
    print(f'license scanner failed with exit {code}; this is not a policy finding')
    return 1


def verify_product_license(root=ROOT):
    """Limit the custom-license allowance to our exact local bridge path."""
    license_path = root / 'LICENSE'
    if '## Sustainable Use License' not in license_path.read_text(encoding='utf-8'):
        raise ValueError('Product LICENSE must contain the Sustainable Use License terms')
    config_path = root / 'flutter_app/.dart_tool/package_config.json'
    if not config_path.is_file():
        raise ValueError('Run flutter pub get before checking local package licenses')
    config = json.loads(config_path.read_text(encoding='utf-8'))
    bridge = next((p for p in config['packages'] if p['name'] == 'my_dashboard_frb'), None)
    if bridge is None:
        raise ValueError('Local bridge is missing from the resolved package graph')
    uri = urlparse(bridge['rootUri'])
    if uri.scheme not in ('', 'file'):
        raise ValueError('Product license exception cannot be used for a remote package')
    resolved = (config_path.parent / unquote(uri.path)).resolve()
    expected = (root / 'flutter_app/rust_builder').resolve()
    if resolved != expected:
        raise ValueError('Product license exception only applies to flutter_app/rust_builder')
    if (expected / 'LICENSE').read_bytes() != license_path.read_bytes():
        raise ValueError('Bridge LICENSE differs from the product license')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy', choices=['enforce', 'warn'])
    parser.add_argument('--rust-config', type=Path)
    args = parser.parse_args()
    try:
        verify_product_license()
    except (ValueError, OSError, KeyError) as error:
        print(error)
        return 1
    state = ROOT / '.device-app.json'
    policy = args.policy or (json.loads(state.read_text(encoding="utf-8")).get('license_policy', 'enforce') if state.exists() else 'enforce')
    config = args.rust_config
    if config is None:
        candidates = [ROOT / 'deny.toml', ROOT / '.sol-platform/rust/deny.toml', ROOT.parent / '.sol-platform/rust/deny.toml']
        config = next((path for path in candidates if path.is_file()), None)
    if config is None:
        parser.error('Rust license policy missing')
    commands = [
        (['cargo', 'deny', 'check', '--config', str(config.resolve()), 'licenses'], ROOT, 4),
        (['dart', 'pub', 'global', 'run', 'license_checker:license_checker', '--config', str(ROOT / 'scripts/licenses.yaml'), 'check-licenses'], ROOT / 'flutter_app', 70),
    ]
    failed = 0
    for command, cwd, violation_code in commands:
        try:
            result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
        except OSError as error:
            print(error)
            failed = 1
            continue
        output = result.stdout + result.stderr
        # The scanners emit UTF-8 even when a Windows pipe defaults to ANSI.
        sys.stdout.flush()
        sys.stdout.buffer.write((output + "\n").encode("utf-8"))
        sys.stdout.buffer.flush()
        # Exit 70 can also mean a Dart runtime failure. Require a finished report.
        completed = ('licenses ok' in output or 'licenses FAILED' in output) if violation_code == 4 else ('└' in output or 'No package licenses need approval!' in output)
        failed |= classify(result.returncode, violation_code, policy, completed)
    return failed


if __name__ == '__main__':
    raise SystemExit(main())

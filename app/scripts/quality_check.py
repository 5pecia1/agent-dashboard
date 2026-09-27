#!/usr/bin/env python3
"""Configurable app source checks. Generated outputs have separate drift gates."""
import argparse
import fnmatch
import json
from pathlib import Path
import re
import tomllib


def matches(path, patterns):
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def inspect(root, config, rule):
    errors = []
    for directory in config['dart_dirs'] + config['rust_dirs']:
        for path in sorted((root / directory).rglob('*')):
            if path.suffix not in {'.dart', '.rs'} or not path.is_file():
                continue
            relative = path.relative_to(root).as_posix()
            if matches(relative, config['generated']):
                continue
            text = path.read_text(encoding="utf-8")
            code = re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S)
            if rule == 'budget' and len(text.splitlines()) > config['line_limit']:
                errors.append(f'{relative}: exceeds {config["line_limit"]} lines')
            if path.suffix == '.dart':
                if rule == 'theme' and not matches(relative, config['theme_allowed']):
                    for number, line in enumerate(text.splitlines(), 1):
                        if re.search(r'//\s*theme-exempt:\s*\S', line):
                            continue
                        line = line.split('//')[0]
                        if re.search(r'\b(?:Color\s*\(|Color\.(?:fromARGB|fromRGBO)|Colors\.)', line):
                            errors.append(f'{relative}:{number}: use a theme token')
                if rule == 'boundary' and not matches(relative, config['ffi_allowed']):
                    directives = re.findall(r"\b(?:import|export)\s+[^;]+;", code)
                    uris = [uri for directive in directives for uri in re.findall(r"['\"]([^'\"]+)['\"]", directive)]
                    if any(re.search(r"(?:^|/)rust/|^dart:ffi$|flutter_rust_bridge", uri) for uri in uris):
                        errors.append(f'{relative}: direct FFI import outside an adapter')
    if rule == 'boundary':
        for crate in config.get('pure_rust_crates', []):
            path = root / crate / 'Cargo.toml'
            cargo = tomllib.loads(path.read_text(encoding="utf-8"))
            scopes = [cargo, *cargo.get('target', {}).values()]
            for scope in scopes:
                for kind in ['dependencies', 'build-dependencies', 'dev-dependencies']:
                    for name, value in scope.get(kind, {}).items():
                        dependency = value.get('package', name) if isinstance(value, dict) else name
                        if dependency in config.get('forbidden_core_dependencies', []):
                            errors.append(f'{crate}/Cargo.toml: forbidden core dependency {dependency}')
    if rule == 'constants':
        for contract in config.get('constant_contracts', []):
            rust = set(re.findall(contract['rust_pattern'], (root / contract['rust_file']).read_text(encoding="utf-8")))
            dart = set(re.findall(contract['dart_pattern'], (root / contract['dart_file']).read_text(encoding="utf-8")))
            if not dart or not dart <= rust:
                errors.append(f'{contract["dart_file"]}: constants disagree with {contract["rust_file"]}: {sorted(dart - rust)}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rule', choices=['boundary', 'theme', 'budget', 'constants'])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--config', type=Path, default=Path('quality.json'))
    args = parser.parse_args()
    config = json.loads((args.root / args.config).read_text(encoding="utf-8"))
    errors = inspect(args.root, config, args.rule)
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())

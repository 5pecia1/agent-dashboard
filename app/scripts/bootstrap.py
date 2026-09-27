#!/usr/bin/env python3
"""Initialize verified seed files; run external scaffold generators in scratch."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

STATE = '.device-app.json'
MANIFEST = 'scripts/seed-files.json'
FEATURE_PACKAGES = {'window-control': 'window_manager', 'global-hotkey': 'hotkey_manager', 'model-codegen': None}


def run(command, cwd, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True)


def configured_executable(project, name):
    # Resolve while the app's mise configuration is in scope. On Windows a bare
    # executable search can select mise's flutter.exe instead of flutter.bat.
    executable = Path(subprocess.check_output(['mise', 'which', name], cwd=project, text=True, encoding='utf-8').strip())
    if not executable.is_absolute() or not executable.is_file():
        raise ValueError(f'mise did not resolve an installed executable for {name}: {executable}')
    if sys.platform == 'win32' and name == 'flutter':
        # The SDK ships both a POSIX 'flutter' script and flutter.bat. mise
        # can resolve the extensionless file, which CreateProcess cannot run.
        # Select the Windows launcher in that same configured SDK, never PATH.
        executable = executable.with_name('flutter.bat')
        if not executable.is_file():
            raise ValueError(f'Configured Flutter SDK has no Windows launcher: {executable}')
    print(f'Scaffold launcher ({name}): {json.dumps(str(executable))}', flush=True)
    return str(executable)


def identity_for(name, org, targets, license_policy, features=None):
    dart_name = name.replace('-', '_')
    if not re.fullmatch(r'[a-z][a-z0-9]*(?:_[a-z0-9]+)*', dart_name):
        raise ValueError('name must be a lower-case project slug')
    if not re.fullmatch(r'[a-z0-9][a-z0-9]*(?:\.[a-z0-9][a-z0-9]*)+', org):
        raise ValueError('org must be a reverse domain, such as io.example')
    if not targets or set(targets) - {'linux', 'macos', 'windows', 'web'}:
        raise ValueError('unsupported targets')
    if license_policy not in {'enforce', 'warn'}:
        raise ValueError('license_policy must be enforce or warn')
    features = sorted(set(features or []))
    if set(features) - FEATURE_PACKAGES.keys():
        raise ValueError('unsupported app features')
    if set(features) & {'window-control', 'global-hotkey'} and not set(targets) - {'web'}:
        raise ValueError('desktop features require at least one desktop target')
    app_id = org + '.' + dart_name.replace('_', '')
    identity = {'name': dart_name, 'display_name': name.replace('-', ' ').replace('_', ' ').title(), 'org': org, 'app_id': app_id, 'crate': f'{dart_name}_frb', 'targets': targets, 'license_policy': license_policy}
    # Empty selection preserves the identity contract of already-created apps.
    if features:
        identity['features'] = features
    return identity


def check_feature_requirements(identity, prepare_only=False):
    if (not prepare_only and sys.platform.startswith('linux') and 'linux' in identity['targets']
            and 'global-hotkey' in identity.get('features', [])):
        pkg_config = shutil.which('pkg-config')
        if not pkg_config or subprocess.run([pkg_config, '--exists', 'keybinder-3.0'], capture_output=True).returncode:
            raise ValueError('global-hotkey requires pkg-config and keybinder-3.0 development headers before bootstrap; on Debian/Ubuntu install pkg-config and libkeybinder-3.0-dev, then retry. No app files were changed')


def safe_path(project, relative):
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError(f'path escapes project: {relative}')
    path = project / relative
    for candidate in [path, *path.parents]:
        if candidate == project:
            break
        if candidate.is_symlink():
            raise ValueError(f'initialization refuses symlink: {candidate}')
    return path


def prepare(project, identity):
    manifest = json.loads(safe_path(project, MANIFEST).read_text(encoding="utf-8"))
    for relative in [STATE, '.device-app-owned.json']:
        if safe_path(project, relative).exists():
            raise ValueError(f'initialization would overwrite {relative}')
    replacements = {'io.github._5pecia1.sol_app': identity['app_id'], 'Sol App': identity['display_name'], 'sol_app': identity['name'], 'app_frb': identity['crate']}
    pattern = re.compile('|'.join(re.escape(key) for key in replacements))
    substitute = lambda value: pattern.sub(lambda match: replacements[match[0]], value)
    writes = []
    features = identity.get('features', [])
    dependencies = []
    for feature in features:
        package = FEATURE_PACKAGES[feature]
        if package:
            declaration = safe_path(project, f'feature-seeds/{feature}/pubspec.yaml').read_text(encoding='utf-8')
            versions = re.findall(r'^  ' + re.escape(package) + r': ([^\n]+)$', declaration, re.M)
            if len(versions) != 1:
                raise ValueError(f'feature dependency declaration missing: {feature}')
            dependencies.append(f'  {package}: {versions[0]}\n')
    # Preflight the entire owned seed inventory before making any change.
    # Unknown files (including .git) are never read, renamed, or written.
    for relative, digest in manifest.items():
        path = safe_path(project, relative)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f'seed changed before initialization: {relative}; preserve it and initialize a fresh copy')
        target = safe_path(project, substitute(relative))
        if relative.startswith('feature-seeds/'):
            _, feature, asset = relative.split('/', 2)
            if feature not in features or asset == 'pubspec.yaml':
                continue
            target = safe_path(project, 'flutter_app/' + asset)
            if target.exists():
                raise ValueError(f'feature initialization would overwrite {target}; preserve it and use a fresh seed')
        if target != path and target.exists():
            raise ValueError(f'initialization would overwrite {target}')
        content = path.read_bytes()
        if path.name != 'bootstrap.py':
            try:
                text = content.decode()
                # Golden fixtures stay constant across app names; only their package imports change.
                if relative == 'flutter_app/test/widget_tests/goldens_test.dart':
                    text = text.replace('package:sol_app/', 'package:' + identity['name'] + '/')
                else:
                    text = substitute(text)
                if relative == 'flutter_app/pubspec.yaml':
                    text = text.replace('  # Optional desktop dependencies.\n', ''.join(dependencies))
                if relative == 'flutter_app/lib/src/platform/feature_setup.dart':
                    if 'window-control' in features:
                        text = text.replace('// Optional feature imports.\n', "import 'package:" + identity['name'] + "/src/platform/window_control.dart';\n")
                        text = text.replace('  // Optional feature initialization.\n', '  await windowControl.initialize();\n')
                content = text.encode()
            except UnicodeDecodeError:
                pass
        writes.append((path, target, content))
    for source, target, content in writes:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        if source != target:
            source.unlink()
    (project / STATE).write_text(json.dumps(identity, indent=2) + '\n', encoding="utf-8", newline="\n")
    owned = {str(target.relative_to(project)): hashlib.sha256(content).hexdigest() for _, target, content in writes if target.suffix in {'.rs', '.dart'}}
    (project / '.device-app-owned.json').write_text(json.dumps(owned, indent=2) + '\n', encoding="utf-8", newline="\n")


def format_owned(project):
    inventory = project / '.device-app-owned.json'
    if not inventory.exists():
        return
    owned = json.loads(inventory.read_text(encoding="utf-8"))
    for relative, digest in list(owned.items()):
        path = safe_path(project, relative)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            continue  # User-edited files are never reformatted on a later bootstrap.
        if path.suffix == '.rs':
            run(['rustfmt', '--edition', '2024', '--config', 'skip_children=true', str(path)], project)
        else:
            run(['dart', 'format', str(path)], project)
        owned[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    inventory.write_text(json.dumps(owned, indent=2) + '\n', encoding="utf-8", newline="\n")


def initialize(project, name, org, prepare_only=False, targets=None, license_policy='enforce', features=None):
    identity = identity_for(name, org, targets or ['linux', 'web'], license_policy, features)
    check_feature_requirements(identity, prepare_only)
    state = safe_path(project, STATE)
    existing_fvm = safe_path(project, '.fvmrc')
    safe_path(project, '.device-app-owned.json')
    if existing_fvm.exists() and not prepare_only:
        version = tomllib.loads((project / '.mise.toml').read_text(encoding="utf-8"))['env']['FLUTTER_VERSION']
        if json.loads(existing_fvm.read_text(encoding="utf-8")) != {'flutter': version}:
            raise ValueError('.fvmrc conflicts with pinned Flutter; no files changed')
    if state.exists():
        if json.loads(state.read_text(encoding="utf-8")) != identity:
            raise ValueError('already initialized with different identity/options; existing app files are preserved. Generate a separate fresh seed with the desired features and review its dependency, startup and source changes before migrating this app')
    else:
        prepare(project, identity)
    if prepare_only:
        return
    config = tomllib.loads((project / '.mise.toml').read_text(encoding="utf-8"))
    toolchain = config['env']
    version = toolchain['FLUTTER_VERSION']
    fvmrc = project / '.fvmrc'
    expected_fvm = {'flutter': version}
    if fvmrc.exists() and json.loads(fvmrc.read_text(encoding="utf-8")) != expected_fvm:
        raise ValueError('.fvmrc differs from the pinned Flutter version; preserved without changes')
    if not fvmrc.exists():
        fvmrc.write_text(json.dumps(expected_fvm) + '\n', encoding="utf-8", newline="\n")
    run([sys.executable, 'scripts/toolchain.py', 'check'], project)
    # mise may install Rust with the minimal profile on a fresh machine.
    # Code generation and the verify contract both require these components.
    baked_image = os.environ.get('SOL_PLATFORM_IMAGE') == '1'
    if baked_image:
        run([sys.executable, 'scripts/image_tools.py'] + (['--web'] if 'web' in identity['targets'] else []), project)
    else:
        run(['rustup', 'component', 'add', '--toolchain', config['tools']['rust'], 'rustfmt', 'clippy'], project)
    native = [target for target in identity['targets'] if target != 'web']
    folders = [*native, 'rust_builder']
    if any(not (project / 'flutter_app' / folder).exists() for folder in folders):
        flutter = configured_executable(project, 'flutter')
        frb = configured_executable(project, 'flutter_rust_bridge_codegen')
        # FRB shells out to flutter/dart in its temporary project. Keep the
        # selected SDK first for those children without changing global config.
        scaffold_env = dict(os.environ)
        scaffold_env['PATH'] = str(Path(flutter).parent) + os.pathsep + scaffold_env.get('PATH', '')
        with tempfile.TemporaryDirectory(prefix='device-app-bootstrap-') as directory:
            scratch = Path(directory)
            run([flutter, 'create', '--platforms=' + ','.join(identity['targets']), '--org', org, '--project-name', identity['name'], 'scaffold'], scratch, env=scaffold_env)
            scaffold = scratch / 'scaffold'
            (scaffold / '.fvmrc').write_text(json.dumps(expected_fvm) + '\n', encoding="utf-8", newline="\n")
            run([frb, 'integrate', '--no-write-lib', '--no-integration-test', '--no-dart-fix', '--no-dart-format', '--rust-crate-name', identity['crate'], '--rust-crate-dir', '../app-frb'], scaffold, env=scaffold_env)
            camel_name = identity['name'].split('_')[0] + ''.join(part.title() for part in identity['name'].split('_')[1:])
            for folder in native:
                for file in (scaffold / folder).rglob('*'):
                    if file.is_file():
                        try:
                            content = file.read_text(encoding="utf-8")
                        except UnicodeDecodeError:
                            continue
                        for old_id in (org + '.' + identity['name'], org + '.' + camel_name):
                            content = content.replace(old_id, identity['app_id'])
                        file.write_text(content, encoding="utf-8", newline="\n")
            for folder in folders:
                target = project / 'flutter_app' / folder
                if not target.exists():
                    shutil.copytree(scaffold / folder, target, ignore=shutil.ignore_patterns('.dart_tool', 'build', 'ephemeral'))
    builder_license = project / 'flutter_app/rust_builder/LICENSE'
    if not builder_license.exists():
        shutil.copy2(project / 'LICENSE', builder_license)
    if 'web' in identity['targets'] and not baked_image:
        run(['rustup', 'toolchain', 'install', toolchain['FRB_WEB_TOOLCHAIN'], '--profile', 'minimal', '--component', 'rust-src', '--target', 'wasm32-unknown-unknown'], project)
    if not baked_image:
        run(['dart', 'pub', 'global', 'activate', 'license_checker', toolchain['DART_LICENSE_CHECKER_VERSION']], project)
    run(['flutter', 'pub', 'get'], project / 'flutter_app')
    run(['flutter_rust_bridge_codegen', 'generate'], project)
    if 'model-codegen' in identity.get('features', []):
        run(['dart', 'run', 'build_runner', 'build', '--delete-conflicting-outputs'], project / 'flutter_app')
    format_owned(project)


def arguments(parser):
    parser.add_argument('--name')
    parser.add_argument('--org')
    parser.add_argument('--targets', nargs='+', choices=['linux', 'macos', 'windows', 'web'])
    parser.add_argument('--license-policy', choices=['enforce', 'warn'])
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--features', nargs='*', choices=sorted(FEATURE_PACKAGES))


def resolve_options(project, args):
    previous = json.loads((project / STATE).read_text(encoding="utf-8")) if (project / STATE).exists() else {}
    return (args.name or previous.get('name', 'sol_app'), args.org or previous.get('org', 'io.example'), args.targets or previous.get('targets', ['linux', 'web']), args.license_policy or previous.get('license_policy', 'enforce'), args.features if args.features is not None else previous.get('features', []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    arguments(parser)
    parser.add_argument('--in-place', type=Path, default=Path.cwd())
    args = parser.parse_args()
    project = args.in_place.resolve()
    name, org, targets, policy, features = resolve_options(project, args)
    try:
        initialize(project, name, org, args.prepare_only, targets, policy, features)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()

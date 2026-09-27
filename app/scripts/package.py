#!/usr/bin/env python3
"""Stage unsigned platform packages. Publication belongs to the release workflow."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from version_check import check

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd=ROOT, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True)


def appimage_runtime(architecture):
    pin = json.loads((ROOT / 'packaging/appimage-runtimes.json').read_text(encoding="utf-8"))[architecture]
    destination = ROOT / 'target/package-tools' / ('runtime-' + architecture)
    if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == pin['sha256']:
        return destination
    with urllib.request.urlopen(pin['url'], timeout=60) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != pin['sha256']:
        raise ValueError('AppImage runtime SHA256 mismatch; no unverified runtime used')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)
    return destination


def package(target, tag):
    version = check(ROOT, tag)
    state = json.loads((ROOT / '.device-app.json').read_text(encoding="utf-8"))
    name = state['name']
    if target not in state['targets']:
        raise ValueError(f'{target} is not selected in .device-app.json')
    out = ROOT / 'target/packages' / target
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)
    app = ROOT / 'flutter_app'
    expected = []
    if target == 'web':
        expected = [f'{name}-{version}-web.tar.gz']
        run(['mise', 'run', 'build:web'])
        if not list((app / 'build/web/pkg').glob('*_bg.wasm')):
            raise ValueError('Rust WASM asset is missing')
        with tarfile.open(out / f'{name}-{version}-web.tar.gz', 'w:gz') as archive:
            archive.add(app / 'build/web', arcname='.')
    elif target == 'macos':
        expected = [f'{name}-{version}.dmg']
        run(['flutter', 'build', 'macos', '--release'], app)
        bundle = app / f'build/macos/Build/Products/Release/{name}.app'
        if not bundle.is_dir():
            raise ValueError(f'missing macOS bundle: {bundle}')
        with tempfile.TemporaryDirectory(prefix='device-app-dmg-') as temporary:
            stage = Path(temporary) / name
            stage.mkdir()
            shutil.copytree(bundle, stage / bundle.name, symlinks=True)
            (stage / 'Applications').symlink_to('/Applications')
            run(['hdiutil', 'create', '-volname', name, '-srcfolder', str(stage), '-ov', '-format', 'UDZO', str(out / f'{name}-{version}.dmg')])
    elif target == 'windows':
        expected = [f'{name}-{version}.msix']
        run(['flutter', 'build', 'windows', '--release'], app)
        run(['dart', 'run', 'msix:create', '--sign-msix', 'false'], app)
        packages = list((app / 'build').rglob('*.msix'))
        if len(packages) != 1:
            raise ValueError(f'expected one MSIX package, found {len(packages)}')
        shutil.copy2(packages[0], out / f'{name}-{version}.msix')
    elif target == 'linux':
        run(['flutter', 'build', 'linux', '--release'], app)
        architecture = 'x64' if platform.machine() == 'x86_64' else 'arm64'
        bundle = app / f'build/linux/{architecture}/release/bundle'
        if not (bundle / name).is_file():
            raise ValueError('Linux executable is missing')
        with tempfile.TemporaryDirectory(prefix='device-app-linux-') as temporary:
            stage = Path(temporary) / 'deb'
            shutil.copytree(bundle, stage / 'opt' / name)
            control = stage / 'DEBIAN/control'
            control.parent.mkdir()
            deb_arch = 'amd64' if architecture == 'x64' else 'arm64'
            appimage_arch = 'x86_64' if architecture == 'x64' else 'aarch64'
            expected = [f'{name}-{version}-{deb_arch}.deb', f'{name}-{version}-{appimage_arch}.AppImage']
            control.write_text(f'Package: {name.replace("_", "-")}\nVersion: {version}\nArchitecture: {deb_arch}\nMaintainer: sol-platform contributors\nDepends: libgtk-3-0\nDescription: {state["display_name"]}\n', encoding="utf-8", newline="\n")
            (stage / 'usr/bin').mkdir(parents=True)
            (stage / 'usr/bin' / name).symlink_to(f'/opt/{name}/{name}')
            for relative, source in [(f'usr/share/applications/{name}.desktop', ROOT / f'packaging/linux/{name}.desktop'), (f'usr/share/metainfo/{state["app_id"]}.metainfo.xml', ROOT / f'packaging/linux/{state["app_id"]}.metainfo.xml'), (f'usr/share/icons/hicolor/512x512/apps/{name}.png', app / 'web/icons/Icon-512.png')]:
                (stage / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, stage / relative)
            run(['dpkg-deb', '--root-owner-group', '--build', str(stage), str(out / f'{name}-{version}-{deb_arch}.deb')])
            appdir = Path(temporary) / f'{name}.AppDir'
            shutil.copytree(bundle, appdir)
            shutil.copy2(ROOT / f'packaging/linux/{name}.desktop', appdir / f'{name}.desktop')
            metadata = appdir / f'usr/share/metainfo/{name}.appdata.xml'
            metadata.parent.mkdir(parents=True)
            shutil.copy2(ROOT / f'packaging/linux/{state["app_id"]}.metainfo.xml', metadata)
            shutil.copy2(app / 'web/icons/Icon-512.png', appdir / f'{name}.png')
            (appdir / 'AppRun').write_text(f'#!/bin/sh\nHERE=$(dirname "$(readlink -f "$0")")\nexec "$HERE/{name}" "$@"\n', encoding="utf-8", newline="\n")
            (appdir / 'AppRun').chmod(0o755)
            env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN='1', ARCH='x86_64' if architecture == 'x64' else 'aarch64')
            run(['appimagetool', '--runtime-file', str(appimage_runtime(env['ARCH'])), str(appdir), str(out / f'{name}-{version}-{env["ARCH"]}.AppImage')], env=env)
    for filename in expected:
        artifact = out / filename
        if not artifact.is_file() or artifact.stat().st_size == 0:
            raise ValueError(f'required package missing or empty: {filename}')
    packages = [path for path in out.iterdir() if path.is_file() and not path.name.startswith('SHA256SUMS')]
    if not packages or any(path.stat().st_size == 0 for path in packages):
        raise ValueError('package output is empty')
    (out / f'SHA256SUMS.{target}').write_text(''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in sorted(packages)), encoding="utf-8", newline="\n")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['linux', 'macos', 'windows', 'web'])
    parser.add_argument('--tag', default='')
    args = parser.parse_args()
    try:
        package(args.target, args.tag)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')

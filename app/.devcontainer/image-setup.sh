#!/usr/bin/env bash
set -euo pipefail
# Runs once while building the selected image, with exact mise versions already installed.
cd /opt/mise/config
export PATH="/opt/mise/shims:$PATH"
flutter --disable-analytics
flutter precache --linux
rustup component add rustfmt clippy
license_version="$(python3 -c 'import tomllib; print(tomllib.load(open("config.toml", "rb"))["env"]["DART_LICENSE_CHECKER_VERSION"])')"
dart pub global activate license_checker "$license_version"
mkdir -p /opt/appimage/bin
curl -fsSL --retry 3 https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage -o /opt/appimage/bin/appimagetool
printf '%s  /opt/appimage/bin/appimagetool\n' ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 | sha256sum --check --strict
chmod 0755 /opt/appimage/bin/appimagetool
ln -s /opt/appimage/bin/appimagetool /usr/local/bin/appimagetool

cd /opt/mise/config
export PATH="/opt/mise/shims:$PATH"
uv venv /opt/sol-browser
uv pip install --python /opt/sol-browser/bin/python playwright==1.62.0
PLAYWRIGHT_BROWSERS_PATH=/opt/sol-browser/browsers /opt/sol-browser/bin/playwright install --with-deps chromium
PLAYWRIGHT_BROWSERS_PATH=/opt/sol-browser/browsers /opt/sol-browser/bin/python -c 'from playwright.sync_api import sync_playwright; from pathlib import Path; p = sync_playwright().start(); Path("/opt/sol-browser/chromium").symlink_to(p.chromium.executable_path); p.stop()'

cd /opt/mise/config
export PATH="/opt/mise/shims:$PATH"
flutter precache --web
nightly="$(python3 -c 'import tomllib; print(tomllib.load(open("config.toml", "rb"))["env"]["FRB_WEB_TOOLCHAIN"])')"
rustup toolchain install "$nightly" --profile minimal --component rust-src --target wasm32-unknown-unknown

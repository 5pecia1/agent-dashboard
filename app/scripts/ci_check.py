#!/usr/bin/env python3
"""Verify the app, build its selected web target, and check its real browser runtime."""
import hashlib
from functools import partial
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
from threading import Thread
import urllib.request

from serve_web import Handler

APP = Path(__file__).resolve().parents[1]
EVIDENCE = Path('/evidence')
SERVER_HOST = '127.0.0.1'
SERVER_PORT = 0  # Let the OS reserve an unused port for this exact server.


def run(command, cwd, name):
    with (EVIDENCE / f'{name}.log').open('w') as log:
        result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
    print((EVIDENCE / f'{name}.log').read_text(errors='replace'), end='', flush=True)
    result.check_returncode()


def main():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    browser = os.environ['CHROME_BIN']
    browser_python = os.environ['WEB_CHECK_PYTHON']
    # The image contains the toolchain. Resolve packages without regenerating
    # committed bindings before verify checks whether those bindings are current.
    run(['mise', 'exec', '--', 'flutter', 'pub', 'get'], APP / 'flutter_app', 'pub-get')
    run(['mise', 'run', 'verify'], APP, 'verify')
    run(['mise', 'run', 'build:web'], APP, 'build-web')
    bundle = APP / 'flutter_app/build/web'
    wasm = list((bundle / 'pkg').glob('*_bg.wasm'))
    if not wasm or any(path.stat().st_size == 0 for path in wasm):
        raise ValueError('Rust WASM output is missing or empty')
    (EVIDENCE / 'wasm-sha256.json').write_text(json.dumps({
        str(path.relative_to(bundle)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in wasm
    }, indent=2) + '\n')
    with ThreadingHTTPServer((SERVER_HOST, SERVER_PORT), partial(Handler, directory=str(bundle))) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f'http://{SERVER_HOST}:{server.server_port}'
        try:
            with urllib.request.urlopen(url) as response:
                (EVIDENCE / 'headers.txt').write_text(str(response.headers))
            run([browser_python, 'scripts/web_push_smoke.py', url,
                 '--browser', browser, '--output', str(EVIDENCE / 'web')],
                APP, 'web-smoke')
        finally:
            server.shutdown()
            thread.join()


if __name__ == '__main__':
    try:
        main()
    finally:
        tests = APP / 'flutter_app/test'
        for failures in tests.rglob('failures'):
            if failures.is_dir():
                shutil.copytree(failures, EVIDENCE / 'flutter-test' / failures.relative_to(tests),
                                dirs_exist_ok=True)

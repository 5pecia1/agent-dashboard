#!/usr/bin/env python3
"""Verify image-provided tools, then run workspace-dependent bootstrap."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


def git_environment(workspace, environment):
    """Append one protected Git setting; keep every caller setting intact."""
    result = dict(environment)
    count = result.get('GIT_CONFIG_COUNT', '0')
    if not re.fullmatch(r'\d+', count):
        raise ValueError('workspace Git trust requires a literal GIT_CONFIG_COUNT')
    slot = str(int(count))
    result.update(GIT_CONFIG_COUNT=str(int(count) + 1))
    result['GIT_CONFIG_KEY_' + slot] = 'safe.directory'
    result['GIT_CONFIG_VALUE_' + slot] = str(workspace)
    return result


def container_mounts():
    """Return non-root mounts only inside a recognized Linux container."""
    if sys.platform != 'linux' or not any(Path(path).exists() for path in ('/.dockerenv', '/run/.containerenv')):
        return None
    try:
        fields = [line.split() for line in Path('/proc/self/mountinfo').read_text().splitlines()]
        return [Path(re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), row[4]))
                for row in fields if row[4] != '/']
    except (OSError, IndexError):
        return None


def persist_workspace_git_trust(workspace, environment):
    """Keep developer shells working without writing any host-mounted Git file."""
    mounts = container_mounts()
    if mounts is None or not (workspace / '.git').exists():
        return
    config = Path(environment.get('GIT_CONFIG_GLOBAL', str(Path.home() / '.gitconfig'))).resolve()
    if any(config.is_relative_to(mount) for mount in mounts) or (config.exists() and not config.is_file()):
        return
    config.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(['git', 'config', '--file', str(config), '--get-all', 'safe.directory'],
                            env=environment, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise ValueError('cannot read container Git trust configuration')
    if str(workspace) not in result.stdout.splitlines():
        subprocess.run(['git', 'config', '--file', str(config), '--add', 'safe.directory', str(workspace)],
                       env=environment, capture_output=True, text=True, check=True)


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', newline='\n')
    if sys.version_info < (3, 11):
        print('Devcontainer setup requires Python 3.11 or newer', file=sys.stderr)
        return 1
    workspace = Path.cwd().resolve()
    env = {**os.environ, 'MISE_TRUSTED_CONFIG_PATHS': str(workspace), 'MISE_YES': '1'}
    try:
        persist_workspace_git_trust(workspace, env)
        env = git_environment(workspace, env)
        scopes = Path(__file__).with_name('tool-configs.json')
        directories = json.loads(scopes.read_text()) if scopes.exists() else ['.']
        if not isinstance(directories, list) or not directories:
            raise ValueError('invalid image tool config directories')
        for directory in directories:
            path = (workspace / directory).resolve()
            if not path.is_relative_to(workspace) or not path.is_dir():
                raise ValueError('image tool config directory is outside or missing from workspace')
            result = subprocess.run(['mise', 'ls', '--current', '--missing', '--json'], cwd=path,
                                    env=env, text=True, encoding='utf-8', capture_output=True, check=True)
            missing = json.loads(result.stdout)
            if not isinstance(missing, dict) or missing:
                raise ValueError(f'workspace tools are missing from image; rebuild the Devcontainer ({directory})')
        task_directory = workspace if (workspace / '.mise.toml').is_file() else workspace / 'app'
        result = subprocess.run(['mise', 'tasks', '--json'], cwd=task_directory, env=env, text=True, encoding='utf-8', capture_output=True, check=True)
        tasks = {task['name'] for task in json.loads(result.stdout)}
        bootstrap = next((task for task in ('platform:bootstrap', 'bootstrap') if task in tasks), None)
        if bootstrap:
            subprocess.run(['mise', 'run', bootstrap], cwd=task_directory, env=env, check=True)
        print('Selected environment tools and bootstrap are ready.')
        return 0
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        return error.returncode
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'Devcontainer setup failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

"""Check SDK components baked into the image without downloading or changing them."""
import subprocess


def verify_baked_tools(config, web, project):
    def output(*command):
        return subprocess.check_output(command, cwd=project, text=True, encoding='utf-8')

    components = output('rustup', 'component', 'list', '--installed', '--toolchain', config['tools']['rust']).splitlines()
    if any(not any(line.startswith(name + '-') or line == name for line in components) for name in ('rustfmt', 'clippy')):
        raise ValueError('image is missing Rust components; rebuild the Devcontainer')
    if web:
        nightly = config['env']['FRB_WEB_TOOLCHAIN']
        components = output('rustup', 'component', 'list', '--installed', '--toolchain', nightly).splitlines()
        targets = output('rustup', 'target', 'list', '--installed', '--toolchain', nightly).splitlines()
        if 'rust-src' not in components or 'wasm32-unknown-unknown' not in targets:
            raise ValueError('image is missing pinned web components; rebuild the Devcontainer')
    expected = 'license_checker ' + config['env']['DART_LICENSE_CHECKER_VERSION']
    if expected not in output('dart', 'pub', 'global', 'list').splitlines():
        raise ValueError('image is missing the pinned license checker; rebuild the Devcontainer')


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    import tomllib
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--web', action='store_true')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    verify_baked_tools(tomllib.loads((project / '.mise.toml').read_text(encoding='utf-8')), args.web, project)

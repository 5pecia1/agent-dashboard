#!/usr/bin/env python3
"""Validate the tested archive and write public release evidence, without publishing."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile

EXPECTED_NAME = '@5pecia1/agent-dashboard-server'
EXPECTED_REPOSITORY = 'git+https://github.com/5pecia1/agent-dashboard.git'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tarball', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--upgrade-receipt', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = json.loads(args.receipt.read_text())
    upgrade = json.loads(args.upgrade_receipt.read_text())
    digest = hashlib.sha256(args.tarball.read_bytes()).hexdigest()
    assert receipt['ok'] is True and receipt['sha256'] == digest, 'archive differs from tested artifact'
    assert upgrade['ok'] is True and upgrade['sha256'] == digest, 'archive differs from upgrade-tested artifact'
    assert upgrade['checks'], 'upgrade validation checks missing'
    assert re.fullmatch(r'[0-9a-f]{40}', args.commit), 'expected public Git commit SHA'
    with tarfile.open(args.tarball, 'r:gz') as archive:
        members = {item.name: item for item in archive.getmembers()}
        assert all(item.isfile() for item in members.values()), 'archive contains non-regular entries'
        assert all(name.startswith('package/') and '..' not in Path(name).parts for name in members), 'unsafe archive path'
        package = json.load(archive.extractfile('package/package.json'))
        assert package['name'] == EXPECTED_NAME, 'wrong package name'
        assert package['repository']['url'] == EXPECTED_REPOSITORY, 'wrong public repository metadata'
        assert args.tag == 'server-v' + package['version'], 'tag and package version differ'
        protocol_bytes = archive.extractfile('package/contracts/dashboard-protocol.v1.json').read()
        sql = [{'path': name.removeprefix('package/'), 'sha256': hashlib.sha256(archive.extractfile(name).read()).hexdigest()}
               for name in sorted(members) if name.startswith('package/migrations/') and name.endswith('.sql')]
        assert sql, 'migrations missing'
        for name in ['package/LICENSE', 'package/NOTICE', 'package/LICENSES/sol-platform-MIT.txt']:
            assert name in members, f'license notice missing: {name}'
    evidence = {'schema': 1, 'package': package['name'], 'version': package['version'],
                'tag': args.tag, 'public_commit': args.commit, 'tarball': args.tarball.name,
                'sha256': digest, 'protocol_sha256': hashlib.sha256(protocol_bytes).hexdigest(),
                'migrations': sql, 'checks': receipt['checks'] + upgrade['checks'],
                'upgrade_baseline': upgrade['sourceRevision'], 'npm_publish_enabled': package.get('private') is not True}
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    args.tarball.with_name(args.tarball.name + '.sha256').write_text(f'{digest}  {args.tarball.name}\n')
    print(json.dumps({'package': package['name'], 'version': package['version'], 'sha256': digest}))


if __name__ == '__main__':
    main()

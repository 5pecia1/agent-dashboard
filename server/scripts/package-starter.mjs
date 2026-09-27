import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createExample } from './create-example.mjs';

export async function packageStarter({ tarball, out, commit, tag }) {
  if (!/^[0-9a-f]{40}$/.test(commit ?? '')) throw new Error('Expected a source Git commit SHA');
  const input = path.resolve(tarball);
  const metadata = JSON.parse(execFileSync('tar', ['-xOf', input, 'package/package.json'], {encoding:'utf8'}));
  if (metadata.name !== '@5pecia1/agent-dashboard-server') throw new Error('Wrong server package');
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(metadata.version)) throw new Error('Invalid server version');
  if (tag !== `server-v${metadata.version}`) throw new Error('Tag and server package version differ');
  const bytes = await readFile(input);
  const workspace = await mkdtemp(path.join(tmpdir(), 'agent-dashboard-starter-package-'));
  try {
    const project = path.join(workspace, 'agent-dashboard-server');
    await createExample(input, project, { install:false });
    const manifest = {
      schema: 1,
      product: 'Agent Dashboard',
      server_version: metadata.version,
      tag,
      source_commit: commit,
      package_file: `vendor/${path.basename(input)}`,
      package_sha256: createHash('sha256').update(bytes).digest('hex'),
    };
    await writeFile(path.join(project, 'starter-manifest.json'), JSON.stringify(manifest, null, 2)+'\n');
    await mkdir(out, {recursive:true});
    const archive = path.resolve(out, `agent-dashboard-server-${metadata.version}-starter.tar.gz`);
    // Stable headers make a retry produce identical bytes on macOS and Linux.
    execFileSync('python3', ['-c', String.raw`
import gzip, pathlib, sys, tarfile
source = pathlib.Path(sys.argv[1])
with open(sys.argv[2], 'wb') as output, gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
    with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as archive:
        for file in sorted(source.rglob('*')):
            if not file.is_file() or file.is_symlink():
                if file.is_symlink():
                    raise ValueError('Symlinks are not allowed in the starter')
                continue
            info = archive.gettarinfo(str(file), arcname=str(file.relative_to(source.parent)))
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            info.mode = 0o644
            with file.open('rb') as content:
                archive.addfile(info, content)
`, project, archive], {stdio:'pipe'});
    const sha256 = createHash('sha256').update(await readFile(archive)).digest('hex');
    await writeFile(`${archive}.sha256`, `${sha256}  ${path.basename(archive)}\n`);
    return {archive, sha256, manifest};
  } finally {
    await rm(workspace, {recursive:true, force:true});
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const values = {};
  for (let index=0; index<args.length; index+=2) {
    const key = args[index];
    if (!['--tarball','--out','--commit','--tag'].includes(key) || !args[index+1] || args[index+1].startsWith('--')) {
      throw new Error('Usage: package-starter.mjs --tarball archive.tgz --out release --commit SHA --tag server-vVERSION');
    }
    values[key.slice(2)] = args[index+1];
  }
  if (!values.tarball || !values.out) throw new Error('--tarball and --out are required');
  console.log(JSON.stringify(await packageStarter(values), null, 2));
}

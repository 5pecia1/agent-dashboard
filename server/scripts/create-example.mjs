import { cp, mkdir, readFile, writeFile, access, readdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { packageRoot } from './generate-hooks.mjs';

export async function createExample(tarball, out, { install = true, release = false } = {}) {
  const absoluteTarball = path.resolve(tarball);
  await access(absoluteTarball);
  const archive = await readFile(absoluteTarball);
  const packageName = path.basename(absoluteTarball);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.tgz$/.test(packageName)) throw new Error('Invalid package archive filename');
  const metadata = JSON.parse(execFileSync('tar', ['-xOf', absoluteTarball, 'package/package.json'], {encoding:'utf8'}));
  if (metadata.name !== '@5pecia1/agent-dashboard-server') throw new Error('Wrong server package');
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(metadata.version)) throw new Error('Invalid server version');
  try {
    if ((await readdir(out)).length) throw new Error(`Output directory must be empty: ${out}`);
  } catch (error) { if (error.code !== "ENOENT") throw error; }
  await mkdir(out, {recursive:true});
  const template = path.join(packageRoot, '../examples/cloudflare-worker');
  for (const name of ['src', 'wrangler.jsonc', 'tsconfig.json', '.dev.vars.example', '.gitignore']) {
    await cp(path.join(template, name), path.join(out, name), {recursive:true});
  }
  await cp(path.join(template, release ? 'DEPLOY.md' : 'STARTER.md'), path.join(out, 'README.md'));
  if (!release) {
    await mkdir(path.join(out, 'vendor'));
    await writeFile(path.join(out, 'vendor', packageName), archive);
  }
  const pkg = JSON.parse(await readFile(path.join(template, 'package.template.json'), 'utf8'));
  const dependency = release
    ? `https://github.com/5pecia1/agent-dashboard/releases/download/server-v${metadata.version}/${packageName}`
    : `file:vendor/${packageName}`;
  pkg.dependencies['@5pecia1/agent-dashboard-server'] = dependency;
  await writeFile(path.join(out, 'package.json'), JSON.stringify(pkg, null, 2)+'\n');
  const lock = JSON.parse(await readFile(path.join(template, 'package-lock.template.json'), 'utf8'));
  lock.packages[''].dependencies['@5pecia1/agent-dashboard-server'] = dependency;
  const lockedPackage = lock.packages['node_modules/@5pecia1/agent-dashboard-server'];
  lockedPackage.version = metadata.version;
  lockedPackage.resolved = dependency;
  lockedPackage.integrity = `sha512-${createHash('sha512').update(archive).digest('base64')}`;
  // Keep the bundled dependency tree fixed, while embedding this exact release archive.
  lockedPackage.peerDependencies = metadata.peerDependencies;
  lockedPackage.engines = metadata.engines;
  await writeFile(path.join(out, 'package-lock.json'), JSON.stringify(lock, null, 2)+'\n');
  if (install) execFileSync('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], {cwd:out, stdio:'pipe'});
}
export async function refreshDeploymentLock(tarball, out) {
  const workspace = await mkdtemp(path.join(tmpdir(), 'agent-dashboard-refresh-'));
  try {
    const generated = path.join(workspace, 'deploy');
    await createExample(tarball, generated, { install: false, release: true });
    async function validate(source, destination, relative = '') {
      const names = (await readdir(source)).sort();
      if (JSON.stringify((await readdir(destination)).sort()) !== JSON.stringify(names)) {
        throw new Error('Deployment tree differs from the generator; refusing lock-only refresh');
      }
      for (const entry of await readdir(source, { withFileTypes: true })) {
        const name = path.join(relative, entry.name);
        if (entry.isDirectory()) await validate(path.join(source, entry.name), path.join(destination, entry.name), name);
        else if (name !== 'package-lock.json' && !(await readFile(path.join(source, entry.name))).equals(await readFile(path.join(destination, entry.name)))) {
          throw new Error(`Deployment source differs from the generator: ${name}`);
        }
      }
    }
    await validate(generated, out);
    await cp(path.join(generated, 'package-lock.json'), path.join(out, 'package-lock.json'));
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const tarball = args[args.indexOf('--package-tgz')+1];
  const out = args[args.indexOf('--out')+1];
  if (!args.includes('--package-tgz') || !args.includes('--out') || !tarball || !out) throw new Error('Usage: node scripts/create-example.mjs --package-tgz archive.tgz --out /path/to/new-project');
  const release = args.includes('--release');
  if (args.includes('--refresh-lock')) {
    if (!release) throw new Error('--refresh-lock requires --release and an existing generated deployment');
    await refreshDeploymentLock(tarball, path.resolve(out));
  } else {
    await createExample(tarball, path.resolve(out), { release, install: !release });
  }
  console.log(`Created ${release ? 'release deployment' : 'installed example'}: ${path.resolve(out)}`);
}

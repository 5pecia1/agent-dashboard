import { cp, mkdir, readFile, writeFile, access, readdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { packageRoot } from './generate-hooks.mjs';

export async function createExample(tarball, out) {
  const absoluteTarball = path.resolve(tarball);
  await access(absoluteTarball);
  try {
    if ((await readdir(out)).length) throw new Error(`Output directory must be empty: ${out}`);
  } catch (error) { if (error.code !== "ENOENT") throw error; }
  await mkdir(out, {recursive:true});
  const template = path.join(packageRoot, '../examples/cloudflare-worker');
  for (const name of ['src', 'wrangler.jsonc', 'tsconfig.json', '.dev.vars.example', '.gitignore']) {
    await cp(path.join(template, name), path.join(out, name), {recursive:true});
  }
  const pkg = JSON.parse(await readFile(path.join(template, 'package.template.json'), 'utf8'));
  // A generated local project may use an absolute archive path; this file is never committed.
  pkg.dependencies['@5pecia1/agent-dashboard-server'] = `file:${absoluteTarball}`;
  await writeFile(path.join(out, 'package.json'), JSON.stringify(pkg, null, 2)+'\n');
  execFileSync('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund'], {cwd:out, stdio:'pipe'});
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const tarball = args[args.indexOf('--package-tgz')+1];
  const out = args[args.indexOf('--out')+1];
  if (!args.includes('--package-tgz') || !args.includes('--out') || !tarball || !out) throw new Error('Usage: node scripts/create-example.mjs --package-tgz archive.tgz --out /path/to/new-project');
  await createExample(tarball, path.resolve(out));
  console.log(`Created and installed example: ${path.resolve(out)}`);
}

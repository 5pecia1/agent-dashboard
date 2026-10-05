import { createHash } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const hookNames = ['agent-event-hook.sh', 'codex-hooks.toml', 'codex-notify.sh', 'herdr-context.py', 'install.sh', 'send-generic.sh', 'setup.sh', 'test-hooks.sh'];
export async function generateHooks() {
  const files = {};
  const sha256 = {};
  for (const name of hookNames) {
    const bytes = await readFile(path.join(packageRoot, '..', 'hooks', name));
    files[name] = bytes.toString('utf8');
    sha256[name] = createHash('sha256').update(bytes).digest('hex');
  }
  let fnv = 0x811c9dc5;
  for (const byte of Buffer.from(hookNames.map(name => files[name]).join(''))) {
    fnv ^= byte;
    fnv = Math.imul(fnv, 0x01000193);
  }
  const revision = (fnv >>> 0).toString(16).padStart(8, '0');
  await mkdir(path.join(packageRoot, 'src/generated'), {recursive:true});
  await mkdir(path.join(packageRoot, 'contracts'), {recursive:true});
  await writeFile(path.join(packageRoot, 'src/generated/hooks.ts'),
    '// Generated from root hooks; edit the originals and run npm run generate.\n' +
    `export const HOOK_REV = ${JSON.stringify(revision)};\n` +
    `export const HOOK_FILES: Readonly<Record<string, string>> = ${JSON.stringify(files)};\n`);
  await writeFile(path.join(packageRoot, 'contracts/hooks-manifest.json'), JSON.stringify({revision, sha256}, null, 2)+'\n');
  return {revision, sha256};
}
if (process.argv[1] === fileURLToPath(import.meta.url)) await generateHooks();

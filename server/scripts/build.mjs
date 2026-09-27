import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { cp, copyFile, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { generateHooks, packageRoot } from './generate-hooks.mjs';

await rm(path.join(packageRoot, 'dist'), { recursive: true, force: true });
await generateHooks();
await copyFile(path.join(packageRoot, '../contracts/dashboard-protocol.v1.json'), path.join(packageRoot, 'contracts/dashboard-protocol.v1.json'));
const contract = await readFile(path.join(packageRoot, 'contracts/dashboard-protocol.v1.json'));
await writeFile(path.join(packageRoot, 'contracts/manifest.json'), JSON.stringify({
  'dashboard-protocol.v1.json': createHash('sha256').update(contract).digest('hex'),
}, null, 2)+'\n');
// Hono is a peer so an embedding host and the package use the same router implementation.
await build({ absWorkingDir: packageRoot, entryPoints: ['src/index.ts'], outfile:'dist/index.js', bundle:true,
  format:'esm', platform:'browser', target:'es2022', external:['hono'], sourcemap:false, legalComments:'none' });
execFileSync(path.join(packageRoot, 'node_modules/.bin/tsc'), ['-p', 'tsconfig.build.json'], {cwd:packageRoot, stdio:'inherit'});

for (const name of ["LICENSE", "LICENSES"]) {
  await cp(path.join(packageRoot, "..", name), path.join(packageRoot, name), {recursive:true});
}

// The npm archive does not ship Flutter/Firebase assets; reference only notices it contains.
await writeFile(path.join(packageRoot, 'NOTICE'), `Agent Dashboard server
Copyright (c) 2026 Sol and contributors.

This archive contains Agent Dashboard server and hook code. See LICENSE for its terms.
The source distribution also contains MIT-licensed platform seed code; its notice is
retained in LICENSES/sol-platform-MIT.txt. Existing grants remain unchanged.
License text provenance is recorded in LICENSES/Sustainable-Use-License-source.md.
Hono is an external peer dependency and retains its own MIT license.
`);

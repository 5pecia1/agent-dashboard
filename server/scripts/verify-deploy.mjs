import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdtemp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createExample } from './create-example.mjs';
import { packageRoot } from './generate-hooks.mjs';
import { api, run, wrangler, startWorker } from './test-support.mjs';

const workspace = await mkdtemp(path.join(tmpdir(), 'agent-dashboard-deploy-test-'));
const committed = path.join(packageRoot, '../examples/cloudflare-worker/deploy');
const published = process.argv.includes('--published');
const index = process.argv.indexOf('--tarball');
let tarball = index === -1 ? undefined : process.argv[index + 1];
if (index !== -1 && (!tarball || tarball.startsWith('--'))) throw new Error('--tarball requires a value');
let worker;
try {
  if (!tarball) {
    if (published) {
      const pkg = JSON.parse(await readFile(path.join(committed, 'package.json'), 'utf8'));
      const url = pkg.dependencies['@5pecia1/agent-dashboard-server'];
      assert.match(url, /^https:\/\/github\.com\/5pecia1\/agent-dashboard\/releases\/download\/server-v[0-9A-Za-z.-]+\/[0-9A-Za-z.-]+\.tgz$/);
      const response = await fetch(url);
      assert.equal(response.status, 200, 'pinned release must be published');
      tarball = path.join(workspace, path.basename(url));
      await writeFile(tarball, Buffer.from(await response.arrayBuffer()));
    } else {
      run('npm', ['run', 'build'], packageRoot);
      const [packed] = JSON.parse(run('npm', ['pack', '--json', '--pack-destination', workspace], packageRoot));
      tarball = path.join(workspace, packed.filename);
    }
  }
  tarball = path.resolve(tarball);
  const expected = path.join(workspace, 'expected');
  await createExample(tarball, expected, { install: false, release: true });
  async function compare(source, target) {
    const files = (await readdir(source)).sort();
    assert.deepEqual((await readdir(target)).sort(), files, `unexpected files in ${target}`);
    for (const entry of await readdir(source, { withFileTypes: true })) {
      if (entry.isDirectory()) await compare(path.join(source, entry.name), path.join(target, entry.name));
      else assert.deepEqual(await readFile(path.join(target, entry.name)), await readFile(path.join(source, entry.name)), `regenerate deployment file: ${entry.name}`);
    }
  }
  await compare(expected, committed);
  const consumer = path.join(workspace, 'standalone');
  await cp(committed, consumer, { recursive: true });
  if (!published) {
    // Before publication, test the exact locked bytes locally. The committed
    // URL and integrity were checked above; --published exercises the real URL.
    await mkdir(path.join(consumer, 'vendor'));
    await cp(tarball, path.join(consumer, 'vendor', path.basename(tarball)));
    const dependency = `file:vendor/${path.basename(tarball)}`;
    const pkg = JSON.parse(await readFile(path.join(consumer, 'package.json'), 'utf8'));
    const lock = JSON.parse(await readFile(path.join(consumer, 'package-lock.json'), 'utf8'));
    pkg.dependencies['@5pecia1/agent-dashboard-server'] = dependency;
    lock.packages[''].dependencies['@5pecia1/agent-dashboard-server'] = dependency;
    lock.packages['node_modules/@5pecia1/agent-dashboard-server'].resolved = dependency;
    await writeFile(path.join(consumer, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');
    await writeFile(path.join(consumer, 'package-lock.json'), JSON.stringify(lock, null, 2) + '\n');
  }
  run('npm', ['ci', '--cache', path.join(workspace, 'empty-cache'), '--no-audit', '--no-fund'], consumer);
  run('npm', ['run', 'check'], consumer);
  wrangler(consumer, ['deploy', '--dry-run', '--outdir', path.join(workspace, 'bundle')]);
  const persist = path.join(workspace, 'd1');
  wrangler(consumer, ['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', persist]);
  assert.match(wrangler(consumer, ['d1', 'migrations', 'apply', 'DB', '--local', '--persist-to', persist]), /No migrations to apply/);
  await writeFile(path.join(consumer, '.dev.vars'), 'INGEST_TOKEN=test-ingest-token\nCLIENT_TOKEN=test-client-token\n');
  worker = await startWorker(consumer, persist);
  await api(worker.origin, '/dashboard/auth/ingest-check', { token: 'test-ingest-token', status: 204 });
  await api(worker.origin, '/dashboard/auth/ingest-check', { token: 'test-client-token', status: 403 });
  await api(worker.origin, '/dashboard/events', { token: 'test-ingest-token', body: { protocol_version: 1, event: 'Status', source: 'generic', session_id: 'button-install', event_id: 'button-1', state: 'working', project: '/workspace/example', host: 'example-host' } });
  const sync = await api(worker.origin, '/dashboard/sync');
  assert.equal(sync.sessions.find(row => row.key === 'generic:button-install')?.state, 'working');
  const favicon = await fetch(worker.origin + '/favicon.png');
  assert.equal(favicon.status, 200);
  assert.equal(favicon.headers.get('content-type'), 'image/png');
  const faviconBytes = Buffer.from(await favicon.arrayBuffer());
  assert.equal(createHash('sha256').update(faviconBytes).digest('hex'), '239ae0048550773c0e21767570462af4b69bfb7f8fda5acbe14237477e493b3e');
  const faviconIco = await fetch(worker.origin + '/favicon.ico');
  assert.equal(faviconIco.status, 200);
  assert.equal(Buffer.from(await faviconIco.arrayBuffer()).equals(faviconBytes), true);
  console.log(JSON.stringify({ ok: true, published, checks: ['generated tree and locked integrity', 'detached clean-cache install', 'types and Worker bundle', 'D1 migrations and repeat', 'HTTP role isolation and ingestion', 'server favicon'] }, null, 2));
} finally {
  await worker?.stop();
  console.log(`Deployment verification artifacts: ${workspace}`);
}

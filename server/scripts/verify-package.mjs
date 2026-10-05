import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { createExample } from './create-example.mjs';
import { packageRoot, hookNames } from './generate-hooks.mjs';
import { api, run, wrangler, startWorker } from './test-support.mjs';

const workspace = await mkdtemp(path.join(tmpdir(), 'agent-dashboard-package-'));
const consumer = path.join(workspace, 'consumer');
let worker;
try {
  const supplied = process.argv.indexOf('--tarball');
  let tarball;
  if (supplied !== -1) {
    if (!process.argv[supplied+1]) throw new Error('--tarball requires a path');
    tarball = path.resolve(process.argv[supplied+1]);
  } else {
    run('npm', ['run','build'], packageRoot);
    const [packed] = JSON.parse(run('npm', ['pack','--json','--pack-destination',workspace], packageRoot));
    tarball = path.join(workspace, packed.filename);
  }
  const names = run('tar',['-tzf',tarball],packageRoot).trim().split('\n').map(name=>name.replace(/^package\//,''));
  assert(names.includes('dist/index.js') && names.includes('dist/index.d.ts'));
  assert(names.includes('LICENSE') && names.includes('NOTICE'));
  assert(!names.some(name => name.endsWith('.map') || name.startsWith('src/') || name.includes('.dev.vars')));
  const verifiedHash=createHash('sha256').update(await readFile(tarball)).digest('hex');
  await createExample(tarball, consumer);
  const installed = path.join(consumer, 'node_modules/@5pecia1/agent-dashboard-server');
  const required = ['dist/index.js','dist/index.d.ts','contracts/dashboard-protocol.v1.json','contracts/hooks-manifest.json'];
  async function assertComplete() {
    for (const name of required) await readFile(path.join(installed, name));
    const contract = JSON.parse(await readFile(path.join(installed, 'contracts/dashboard-protocol.v1.json'), 'utf8'));
    const actual = (await readdir(path.join(installed, 'migrations'))).filter(name => name.endsWith('.sql')).sort();
    assert.deepEqual(actual, [...contract.storage.migrations].sort());
  }
  await assertComplete();
  for (const name of ['contracts/dashboard-protocol.v1.json','contracts/hooks-manifest.json']) {
    const filename = path.join(installed, name);
    const original = await readFile(filename);
    await rm(filename);
    await assert.rejects(assertComplete);
    await writeFile(filename, original);
  }
  assert.deepEqual(await readFile(path.join(installed, 'contracts/dashboard-protocol.v1.json')), await readFile(path.join(packageRoot, '../contracts/dashboard-protocol.v1.json')));
  run('npm', ['run','check'], consumer);
  wrangler(consumer, ['deploy','--dry-run','--outdir',path.join(workspace,'bundle')]);
  await writeFile(path.join(consumer, '.dev.vars'), 'AUTH_TOKEN=test-auth-token\nINGEST_TOKEN=test-ingest-token\nCLIENT_TOKEN=test-client-token\n');
  const persist = path.join(workspace,'d1');
  wrangler(consumer, ['d1','migrations','apply','DB','--local','--persist-to',persist]);
  const reapplied = wrangler(consumer, ['d1','migrations','apply','DB','--local','--persist-to',persist]);
  assert.match(reapplied, /No migrations to apply/);
  worker = await startWorker(consumer, persist);
  await api(worker.origin,'/dashboard/auth/ingest-check',{token:'test-ingest-token',status:204});
  await api(worker.origin,'/dashboard/auth/ingest-check',{token:'test-client-token',status:403});
  await api(worker.origin,'/dashboard/events',{token:'test-ingest-token',body:{protocol_version:1,event:'Status',source:'generic',session_id:'installed',event_id:'installed-1',state:'working',project:'/workspace/example',host:'example-host',message:'package-content-canary',unexpected:'package-content-canary',raw:'package-content-canary'}});
  const stored = JSON.parse(wrangler(consumer,['d1','execute','DB','--local','--persist-to',persist,'--json','--command',"SELECT raw, message FROM dashboard_events WHERE event_id = 'installed-1'"]));
  assert.equal(stored[0].results[0].message,null);
  assert(!stored[0].results[0].raw.includes('package-content-canary'));
  const sync = await api(worker.origin,'/dashboard/sync');
  assert.equal(sync.sessions.find(row => row.key==='generic:installed')?.state, 'working');
  const manifest = JSON.parse(await readFile(path.join(installed,'contracts/hooks-manifest.json'),'utf8'));
  for (const name of hookNames) {
    const original = await readFile(path.join(packageRoot,'../hooks',name),'utf8');
    assert.equal(manifest.sha256[name],createHash('sha256').update(original).digest('hex'));
    const response = await fetch(worker.origin+(name==='setup.sh'?'/setup.sh':`/hooks/files/${name}`));
    assert.equal(response.status,200);
    const expected = original.replaceAll('__MY_DASHBOARD_HOOK_REV__',manifest.revision).replaceAll('__MY_DASHBOARD_ORIGIN__',worker.origin);
    assert.equal(await response.text(),expected,`installed HTTP hook ${name}`);
  }
  assert.equal((await fetch(worker.origin+'/hooks/files/constructor')).status,404);
  wrangler(consumer,['d1','execute','DB','--local','--persist-to',persist,'--command',"UPDATE dashboard_sessions SET last_progress_at = 1 WHERE key = 'generic:installed'"]);
  assert.equal((await fetch(worker.origin+'/__scheduled')).status,200);
  const stalled = await api(worker.origin,'/dashboard/sync');
  assert.equal(stalled.sessions.find(row => row.key==='generic:installed')?.state,'stalled');
  await worker.stop(); worker = undefined;
  await writeFile(path.join(consumer, '.dev.vars'), 'DASHBOARD_STORE_MESSAGE=1\nAUTH_TOKEN=test-auth-token\nINGEST_TOKEN=test-ingest-token\nCLIENT_TOKEN=test-client-token\n');
  const { spawnSync } = await import('node:child_process');
  const hooks = spawnSync('bash',[path.join(packageRoot,'../hooks/test-hooks.sh')], {cwd:path.join(packageRoot,'..'),encoding:'utf8',env:{...process.env,
    MY_DASHBOARD_TEST_SERVER_DIR:consumer,MY_DASHBOARD_TEST_SERVER_CONFIG:path.join(consumer,'wrangler.jsonc'),
    MY_DASHBOARD_TEST_DATABASE:'DB',MY_DASHBOARD_TEST_WRANGLER:path.join(consumer,'node_modules/.bin/wrangler'),MY_DASHBOARD_TEST_TOKEN:'test-auth-token',MY_DASHBOARD_TEST_KEEP:'1',
  }});
  await writeFile(path.join(workspace,'hooks-test.log'),(hooks.stdout ?? '')+(hooks.stderr ?? ''));
  if (hooks.status !== 0) throw new Error(`Installed hook integration failed: ${hooks.stderr} ${hooks.stdout}`);
  assert.equal(createHash('sha256').update(await readFile(tarball)).digest('hex'),verifiedHash,'tarball changed during verification');
  const receipt = {ok:true,tarball,sha256:verifiedHash,consumer,checks:['archive','negative missing assets','strict consumer types','Worker dry-run','D1 first install and no-op','HTTP role isolation and default privacy',`all ${hookNames.length} hook assets`,'actual scheduled maintenance','installed hook integration']};
  const receiptIndex = process.argv.indexOf('--receipt');
  if (receiptIndex !== -1) await writeFile(path.resolve(process.argv[receiptIndex+1]),JSON.stringify(receipt,null,2)+'\n');
  console.log(JSON.stringify(receipt,null,2));
} finally {
  await worker?.stop();
  console.log(`Package verification artifacts: ${workspace}`);
}

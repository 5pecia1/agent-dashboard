import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { createExample } from './create-example.mjs';
import { packageRoot } from './generate-hooks.mjs';
import { api, run, wrangler, startWorker } from './test-support.mjs';

const fixtures = path.join(packageRoot,'test/fixtures/before-package');
const tables = ['d1_migrations','dashboard_events','dashboard_sessions','dashboard_transitions','dashboard_seen','dashboard_settings','dashboard_meta','dashboard_devices','dashboard_push_log'];
function rows(cwd,persist,table) {
  const result = JSON.parse(wrangler(cwd,['d1','execute','DB','--local','--persist-to',persist,'--json','--command',`SELECT * FROM ${table} ORDER BY rowid`]));
  return result[0].results;
}
function snapshot(cwd,persist) {
  const result=JSON.parse(wrangler(cwd,['d1','execute','DB','--local','--persist-to',persist,'--json','--command',tables.map(table=>`SELECT * FROM ${table} ORDER BY rowid`).join(';')]));
  return Object.fromEntries(tables.map((table,index)=>[table,result[index].results]));
}
const workspace = await mkdtemp(path.join(tmpdir(),'agent-dashboard-upgrade-'));
const consumer = path.join(workspace,'consumer');
const persist=path.join(workspace,'d1');
let worker;
try {
  const supplied=process.argv.indexOf('--tarball');
  let tarball;
  if (supplied !== -1) {
    if (!process.argv[supplied+1]) throw new Error('--tarball requires a path');
    tarball=path.resolve(process.argv[supplied+1]);
  } else {
    run('npm',['run','build'],packageRoot);
    const [packed]=JSON.parse(run('npm',['pack','--json','--pack-destination',workspace],packageRoot));
    tarball=path.join(workspace,packed.filename);
  }
  const verifiedHash=createHash('sha256').update(await readFile(tarball)).digest('hex');
  await createExample(tarball,consumer);
  await writeFile(path.join(consumer,'.dev.vars'),'INGEST_TOKEN=test-ingest-token\nCLIENT_TOKEN=test-client-token\n');
  let expected;
  const legacyIndex = process.argv.indexOf('--capture-legacy');
  if (legacyIndex !== -1) {
    // One-time provenance capture: point only at an isolated copy of the pre-package Worker.
    const legacy = path.resolve(process.argv[legacyIndex+1]);
    const config = JSON.parse(await readFile(path.join(consumer,'wrangler.jsonc'),'utf8'));
    config.main='src/index.ts';
    config.d1_databases[0].migrations_dir='migrations';
    config.rules=[{type:'Text',globs:['**/*.sh','**/*.toml']}];
    config.vars={INGEST_TOKEN:'test-ingest-token',CLIENT_TOKEN:'test-client-token'};
    await writeFile(path.join(legacy,'wrangler.jsonc'),JSON.stringify(config,null,2));
    wrangler(legacy,['d1','migrations','apply','DB','--local','--persist-to',persist]);
    worker=await startWorker(legacy,persist);
    const events=[
      {source:'generic',session_id:'upgrade-working',state:'working',event:'Status'},
      {source:'generic',session_id:'upgrade-waiting',state:'waiting_input',event:'Status'},
      {source:'generic',session_id:'upgrade-ended',state:'ended',event:'Status'},
      {source:'devin',session_id:'upgrade-devin',event:'UserPromptSubmit',prompt_id:'prompt-fixture'},
      {source:'devin',session_id:'upgrade-devin',event:'PermissionRequest',prompt_id:'prompt-fixture',tool_use_id:'tool-a',tool_name:'exec'},
      {source:'devin',session_id:'upgrade-devin',event:'PermissionRequest',prompt_id:'prompt-fixture',tool_use_id:'tool-b',tool_name:'exec'},
    ].map((event,index)=>({protocol_version:1,project:'/workspace/example',host:'fixture-host',hook_rev:'1234abcd',event_id:`upgrade-${index}`,occurred_at:Date.now()+index,...event}));
    for (const body of events) await api(worker.origin,'/dashboard/events',{token:'test-ingest-token',body});
    const sync=await api(worker.origin,'/dashboard/sync?include_ended=1');
    const waiting=sync.sessions.find(row=>row.key==='generic:upgrade-waiting');
    await api(worker.origin,'/dashboard/sessions/generic%3Aupgrade-waiting/seen',{body:{last_transition_id:waiting.last_transition_id}});
    await api(worker.origin,'/dashboard/mute',{body:{minutes:60}});
    await api(worker.origin,'/dashboard/ui-lang',{body:{lang:'ko'}});
    await api(worker.origin,'/dashboard/devices',{body:{token:'fixture-fcm-token',platform:'web',transport:'fcm',label:'fixture browser'}});
    await worker.stop();worker=undefined;
    expected={tables:snapshot(legacy,persist),cursor:sync.cursor,sourceRevision:'adb92a6b829477d36bda8301f05da7278372258e'};
    await mkdir(fixtures,{recursive:true});
    const sql = run('python3',['-c',String.raw`import pathlib,sqlite3,sys
for p in pathlib.Path(sys.argv[1]).rglob('*.sqlite'):
 with sqlite3.connect(p) as db:
  if db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='dashboard_events'").fetchone()[0]:
   print('\n'.join(line for line in db.iterdump() if '_cf_' not in line and line not in ['BEGIN TRANSACTION;', 'COMMIT;']));break
else: raise RuntimeError('dashboard database not found')`,persist],legacy);
    await writeFile(path.join(fixtures,'database.sql'),sql);
    expected.migrationSha256=Object.fromEntries(await Promise.all((await readdir(path.join(legacy,'migrations'))).filter(name=>name.endsWith('.sql')).sort().map(async name=>[name,createHash('sha256').update(await readFile(path.join(legacy,'migrations',name))).digest('hex')])));
    expected.databaseSha256=createHash('sha256').update(await readFile(path.join(fixtures,'database.sql'))).digest('hex');
    await writeFile(path.join(fixtures,'expected.json'),JSON.stringify(expected,null,2)+'\n');
    await writeFile(path.join(fixtures,'requests.json'),JSON.stringify(events,null,2)+'\n');
    console.log('Captured pre-package HTTP-produced fixture; continuing against its same persisted database.');
  } else {
    expected=JSON.parse(await readFile(path.join(fixtures,'expected.json'),'utf8'));
    const sql=await readFile(path.join(fixtures,'database.sql'));
    assert.equal(createHash('sha256').update(sql).digest('hex'),expected.databaseSha256);
    wrangler(consumer,['d1','execute','DB','--local','--persist-to',persist,'--file',path.join(fixtures,'database.sql')]);
  }
  for (const [name, hash] of Object.entries(expected.migrationSha256)) {
    assert.equal(createHash('sha256').update(await readFile(path.join(consumer,'node_modules/@5pecia1/agent-dashboard-server/migrations',name))).digest('hex'),hash,`immutable migration ${name}`);
  }
  assert.deepEqual(snapshot(consumer,persist),expected.tables,'pre-upgrade fixture must match');
  wrangler(consumer,['d1','migrations','apply','DB','--local','--persist-to',persist]);
  const migrated=snapshot(consumer,persist);
  const titledTables=new Set(['dashboard_events','dashboard_sessions','dashboard_transitions']);
  for (const table of tables.filter(table=>table!=='d1_migrations')) {
    const expectedRows=titledTables.has(table)
      ? expected.tables[table].map(row=>({...row,display_title:null}))
      : expected.tables[table];
    assert.deepEqual(migrated[table],expectedRows,`preserve existing ${table} rows`);
  }
  const oldLedger=expected.tables.d1_migrations;
  assert.deepEqual(migrated.d1_migrations.slice(0,oldLedger.length),oldLedger);
  assert.equal(migrated.d1_migrations.length,oldLedger.length+1);
  assert.equal(migrated.d1_migrations.at(-1).name,'0006_display_title.sql');
  assert.equal(migrated.d1_migrations.at(-1).id,oldLedger.at(-1).id+1);
  assert.equal(typeof migrated.d1_migrations.at(-1).applied_at,'string');
  const repeated=wrangler(consumer,['d1','migrations','apply','DB','--local','--persist-to',persist]);
  assert.match(repeated,/No migrations to apply/);
  assert.deepEqual(snapshot(consumer,persist),migrated,'migration rerun is a no-op');
  worker=await startWorker(consumer,persist);
  const sync=await api(worker.origin,'/dashboard/sync?include_ended=1');
  assert.equal(sync.cursor,expected.cursor);
  assert.equal(sync.ui_lang,'ko');
  assert.equal(sync.seen.find(row=>row.key==='generic:upgrade-waiting')?.seen_transition_id,expected.tables.dashboard_seen[0].seen_transition_id);
  assert.equal(sync.sessions.find(row=>row.key==='generic:upgrade-ended')?.state,'ended');
  assert.equal(sync.sessions.find(row=>row.key==='devin:upgrade-devin')?.state,'waiting_input');
  const delta=await api(worker.origin,`/dashboard/sync?since=${expected.cursor}`);
  assert.equal(delta.reset,false);
  assert.equal(delta.transitions.length,0);
  assert.deepEqual(snapshot(consumer,persist),migrated,'read APIs must not rewrite data or rebuild state');
  const nextOccurredAt = Math.max(...expected.tables.dashboard_events.map(row=>row.occurred_at))+1;
  await api(worker.origin,'/dashboard/events',{token:'test-ingest-token',body:{protocol_version:1,project:'/workspace/example',source:'devin',session_id:'upgrade-devin',event:'PostToolUse',event_id:'upgrade-new-tool-a',prompt_id:'prompt-fixture',tool_use_id:'tool-a',tool_name:'exec',occurred_at:nextOccurredAt}});
  const inputAfterA=JSON.parse(rows(consumer,persist,'dashboard_sessions').find(row=>row.key==='devin:upgrade-devin').input_state);
  assert.equal(inputAfterA.pending.length,1);
  assert.equal(inputAfterA.pending[0].tool_use_id,'tool-b');
  await api(worker.origin,'/dashboard/events',{token:'test-ingest-token',body:{protocol_version:1,project:'/workspace/example',source:'devin',session_id:'upgrade-devin',event:'PostToolUse',event_id:'upgrade-new-tool-b',prompt_id:'prompt-fixture',tool_use_id:'tool-b',tool_name:'exec',occurred_at:nextOccurredAt+1}});
  const after=await api(worker.origin,`/dashboard/sync?since=${expected.cursor}`);
  assert.equal(after.reset,false);
  assert(after.cursor>expected.cursor);
  assert(after.transitions.some(row=>row.session_key==='devin:upgrade-devin' && row.to_state==='working'));
  assert.deepEqual(rows(consumer,persist,'d1_migrations'),migrated.d1_migrations);
  assert.equal(createHash('sha256').update(await readFile(tarball)).digest('hex'),verifiedHash,'tarball changed during verification');
  const receipt={ok:true,tarball,sha256:verifiedHash,workspace,sourceRevision:expected.sourceRevision,checks:['immutable migration hashes','0006 adds nullable display_title to three tables as additive migration','old table columns and migration ledger rows preserved','migration rerun is a no-op','cursor continuity','seen/settings/devices preserved','Devin pending correlation retained and resolved']};
  const receiptIndex=process.argv.indexOf('--receipt');
  if (receiptIndex !== -1) await writeFile(path.resolve(process.argv[receiptIndex+1]),JSON.stringify(receipt,null,2)+'\n');
  console.log(JSON.stringify(receipt,null,2));
} finally {
  await worker?.stop();
  console.log(`Upgrade verification artifacts: ${workspace}`);
}

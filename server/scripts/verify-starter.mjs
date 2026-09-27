import assert from 'node:assert/strict';
import { cp, mkdtemp, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { packageRoot } from './generate-hooks.mjs';
import { packageStarter } from './package-starter.mjs';
import { api, localEnv, run, wrangler, startWorker } from './test-support.mjs';

const workspace = await mkdtemp(path.join(tmpdir(), 'agent-dashboard-starter-test-'));
const argument = name => {
  const index=process.argv.indexOf(name);
  if (index === -1) return undefined;
  if (!process.argv[index+1] || process.argv[index+1].startsWith('--')) throw new Error(`${name} requires a value`);
  return process.argv[index+1];
};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
let worker;
try {
  let tarball=argument('--tarball');
  if (!tarball) {
    run('npm', ['run','build'], packageRoot);
    const [packed]=JSON.parse(run('npm',['pack','--json','--pack-destination',workspace],packageRoot));
    tarball=path.join(workspace,packed.filename);
  }
  tarball=path.resolve(tarball);
  const libraryHash=hash(await readFile(tarball));
  const metadata=JSON.parse(run('tar',['-xOf',tarball,'package/package.json'],packageRoot));
  let starter=argument('--starter');
  if (!starter) {
    const source=path.join(workspace,'temporary release source');
    await mkdir(source);
    const copy=path.join(source,path.basename(tarball));
    await cp(tarball,copy);
    const args={tarball:copy,out:path.join(workspace,'release'),commit:run('git',['rev-parse','HEAD'],packageRoot).trim(),tag:`server-v${metadata.version}`};
    await assert.rejects(packageStarter({...args,tag:'server-v0.0.0'}),/Tag and server package version differ/);
    const first=await packageStarter(args);
    const second=await packageStarter({...args,out:path.join(workspace,'repeat')});
    assert.equal(first.sha256,second.sha256,'starter packaging must be reproducible');
    starter=first.archive;
    // The original input is unavailable before installation; only vendor/ may be used.
    await rm(source,{recursive:true});
  }
  starter=path.resolve(starter);
  const archiveHash=hash(await readFile(starter));
  assert.equal((await readFile(`${starter}.sha256`,'utf8')).trim(),`${archiveHash}  ${path.basename(starter)}`);
  const extraction=path.join(workspace,'unpacked');
  await mkdir(extraction);
  run('python3',['-c',String.raw`
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    members = archive.getmembers()
    names = set()
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        assert member.isfile() and not path.is_absolute() and '..' not in path.parts
        assert path.parts[0] == 'agent-dashboard-server'
        assert not any(part in ['node_modules', '.dev.vars', '.wrangler', '.git'] for part in path.parts)
        assert member.name not in names
        names.add(member.name)
    archive.extractall(sys.argv[2])
`,starter,extraction],packageRoot);
  const consumer=path.join(workspace,'moved independent project');
  await rename(path.join(extraction,'agent-dashboard-server'),consumer);
  await rm(extraction,{recursive:true});
  const manifest=JSON.parse(await readFile(path.join(consumer,'starter-manifest.json'),'utf8'));
  assert.equal(manifest.schema,1);
  assert.equal(manifest.product,'Agent Dashboard');
  assert.equal(manifest.server_version,metadata.version);
  assert.equal(manifest.tag,`server-v${metadata.version}`);
  assert.match(manifest.source_commit,/^[0-9a-f]{40}$/);
  assert.equal(manifest.package_sha256,libraryHash);
  assert.match(manifest.package_file,/^vendor\/[A-Za-z0-9][A-Za-z0-9._-]*\.tgz$/);
  assert.equal(hash(await readFile(path.join(consumer,manifest.package_file))),libraryHash);
  const pkg=JSON.parse(await readFile(path.join(consumer,'package.json'),'utf8'));
  const lock=JSON.parse(await readFile(path.join(consumer,'package-lock.json'),'utf8'));
  assert.equal(pkg.dependencies['@5pecia1/agent-dashboard-server'],`file:${manifest.package_file}`);
  for (const [name, value] of Object.entries(lock.packages)) {
    if (value.resolved?.startsWith('file:')) assert.equal(value.resolved,`file:${manifest.package_file}`,`nonportable lock entry ${name}`);
  }
  const config=JSON.parse(await readFile(path.join(consumer,'wrangler.jsonc'),'utf8'));
  assert.equal(config.account_id,undefined);
  assert.equal(config.d1_databases[0].database_id,'00000000-0000-4000-8000-000000000001');
  assert.match(await readFile(path.join(consumer,'README.md'),'utf8'),/npm ci/);
  assert.match(await readFile(path.join(consumer,'.dev.vars.example'),'utf8'),/INGEST_TOKEN=\nCLIENT_TOKEN=\n/);
  // An empty npm cache prevents a previously cached local path masking a broken archive.
  execFileSync('npm',['ci','--no-audit','--no-fund'],{cwd:consumer,env:{...localEnv,npm_config_cache:path.join(workspace,'fresh-npm-cache')},stdio:'pipe',maxBuffer:20*1024*1024});
  run('npm',['run','check'],consumer);
  wrangler(consumer,['deploy','--dry-run','--outdir',path.join(workspace,'bundle')]);
  const persist=path.join(workspace,'d1');
  wrangler(consumer,['d1','migrations','apply','DB','--local','--persist-to',persist]);
  assert.match(wrangler(consumer,['d1','migrations','apply','DB','--local','--persist-to',persist]),/No migrations to apply/);
  await writeFile(path.join(consumer,'.dev.vars'),'INGEST_TOKEN=test-ingest-token\nCLIENT_TOKEN=test-client-token\n');
  worker=await startWorker(consumer,persist);
  await api(worker.origin,'/dashboard/auth/ingest-check',{token:'test-ingest-token',status:204});
  await api(worker.origin,'/dashboard/auth/ingest-check',{token:'test-client-token',status:403});
  await api(worker.origin,'/dashboard/events',{token:'test-ingest-token',body:{protocol_version:1,event:'Status',source:'generic',session_id:'starter-installed',event_id:'starter-1',state:'working',project:'/workspace/example',host:'example-host'}});
  const sync=await api(worker.origin,'/dashboard/sync');
  assert.equal(sync.sessions.find(row=>row.key==='generic:starter-installed')?.state,'working');
  assert.equal(hash(await readFile(starter)),archiveHash);
  const receipt={ok:true,starter:path.basename(starter),sha256:archiveHash,package_sha256:libraryHash,checks:['safe archive and checksum','portable relative dependency and pinned lock','no credentials or personal account IDs','detached npm ci with empty cache','consumer types and Worker dry-run','D1 install and no-op','HTTP role isolation and ingestion']};
  if (argument('--receipt')) await writeFile(path.resolve(argument('--receipt')),JSON.stringify(receipt,null,2)+'\n');
  console.log(JSON.stringify(receipt,null,2));
} finally {
  await worker?.stop();
  console.log(`Starter verification artifacts: ${workspace}`);
}

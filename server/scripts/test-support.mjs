import { execFileSync, spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';

export const localEnv = { ...process.env, CI:'1', WRANGLER_SEND_METRICS:'false', CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV:'false' };
export function run(command, args, cwd) {
  try { return execFileSync(command, args, {cwd, env:localEnv, encoding:'utf8', stdio:'pipe', maxBuffer:20*1024*1024}); }
  catch (error) { throw new Error(`${command} ${args.join(' ')} failed in ${cwd}\n${error.stdout ?? ''}\n${error.stderr ?? ''}`); }
}
export function wrangler(cwd, args) { return run(path.join(cwd, 'node_modules/.bin/wrangler'), args, cwd); }
export async function freePort() {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
export async function startWorker(cwd, persistTo, extraArgs = []) {
  const port = await freePort();
  const child = spawn(path.join(cwd, 'node_modules/.bin/wrangler'), [
    'dev','--local','--ip','127.0.0.1','--port',String(port),'--persist-to',persistTo,'--test-scheduled', ...extraArgs,
  ], {cwd, env:localEnv, stdio:['ignore','pipe','pipe']});
  let output = '';
  for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => {output += chunk;});
  const origin = `http://127.0.0.1:${port}`;
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = new Promise(resolve => child.once('exit', resolve));
      child.kill('SIGTERM');
      await exited;
    }
    await writeFile(path.join(cwd, 'worker-test.log'), output);
  };
  for (let attempt = 0; attempt < 120; attempt++) {
    if (child.exitCode !== null) throw new Error(`Worker exited: ${output}`);
    try { if ((await fetch(`${origin}/healthz`)).ok) return {origin, stop}; } catch {}
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  await stop();
  throw new Error(`Worker did not become ready: ${output}`);
}
export async function api(origin, pathname, {token='test-client-token', body, method=body === undefined ? 'GET' : 'POST', status=200} = {}) {
  const response = await fetch(origin+pathname, {method, headers:{Connection:'close',Authorization:`Bearer ${token}`,...(body === undefined ? {} : {'Content-Type':'application/json'})}, body:body === undefined ? undefined : JSON.stringify(body)});
  const text = await response.text();
  if (response.status !== status) throw new Error(`${method} ${pathname}: expected ${status}, got ${response.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

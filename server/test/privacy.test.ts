import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { DashboardEnv } from "../src/index";
import worker from "./worker";

const bindings = env as unknown as DashboardEnv;
const secret = "arbitrary-private-content-canary-8142";
async function request(path: string, body: unknown, flag?: string) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(new Request("https://worker.example/dashboard" + path, {
    method:"POST",headers:{Authorization:"Bearer test-auth-token","Content-Type":"application/json"},body:JSON.stringify(body),
  }), {...bindings,DASHBOARD_STORE_MESSAGE:flag},ctx);
  await waitOnExecutionContext(ctx);
  return response;
}
function payload(id: string, extra: Record<string,unknown> = {}) {
  return {protocol_version:1,source:"generic",session_id:id,event_id:id,event:"Status",state:"working",project:"/workspace/project",host:"example-host",occurred_at:1000,
    message:secret,raw:JSON.stringify({tool_output:secret}),tool_input:{unknown:secret},unexpected:secret,...extra};
}
async function projection() {
  return (await bindings.DB.prepare("SELECT key, source, project, host, state, last_event, last_message, last_occurred_at, input_state FROM dashboard_sessions ORDER BY key").all()).results;
}

describe("content retention is explicit opt-in", () => {
  beforeEach(async () => {
    await bindings.DB.batch(["dashboard_events","dashboard_sessions","dashboard_transitions","dashboard_seen","dashboard_meta","dashboard_push_log"].map(table=>bindings.DB.prepare(`DELETE FROM ${table}`)));
  });
  for (const flag of [undefined,"0","invalid"]) it(`default/off ${flag} stores only normalized fields`, async () => {
    const id="privacy-"+String(flag);
    expect((await request("/events",payload(id),flag)).status).toBe(200);
    const row=await bindings.DB.prepare("SELECT raw, message FROM dashboard_events WHERE event_id = ?").bind(id).first<{raw:string;message:string|null}>();
    expect(row?.message).toBeNull();
    expect(row?.raw).not.toContain(secret);
    expect(JSON.parse(row!.raw)).toMatchObject({project:"/workspace/project",state:"working",host:"example-host"});
    for (const field of ["raw","message","tool_input","unexpected"]) expect(JSON.parse(row!.raw)).not.toHaveProperty(field);
    expect(JSON.stringify(await projection())).not.toContain(secret);
  });
  it("explicit 1 preserves legacy content behavior",async()=>{
    expect((await request("/events",payload("privacy-enabled"),"1")).status).toBe(200);
    const row=await bindings.DB.prepare("SELECT raw,message FROM dashboard_events WHERE event_id=?").bind("privacy-enabled").first<{raw:string;message:string}>();
    expect(row?.message).toBe(secret);
    expect(row?.raw).toContain(secret);
  });
  it("normalized generic/project/Devin data replays to the same projection",async()=>{
    expect((await request("/events",payload("privacy-generic"))).status).toBe(200);
    for(const [index,event,tool] of [[0,"UserPromptSubmit",null],[1,"PermissionRequest","tool-a"],[2,"PermissionRequest","tool-b"],[3,"PostToolUse","tool-a"]] as const){
      expect((await request("/events",payload("privacy-devin",{source:"devin",event_id:"privacy-devin-"+index,event,occurred_at:2000+index,prompt_id:"prompt",tool_use_id:tool,tool_name:"exec"}))).status).toBe(200);
    }
    const before=await projection();
    expect(JSON.stringify(before)).not.toContain(secret);
    expect((await request("/admin/rebuild",{})).status).toBe(200);
    expect(await projection()).toEqual(before);
    const rows=await bindings.DB.prepare("SELECT raw FROM dashboard_events").all<{raw:string}>();
    for(const row of rows.results){expect(()=>JSON.parse(row.raw)).not.toThrow();expect(row.raw).not.toContain(secret);}
  });
  it("rejects oversized normalized metadata rather than truncating replay fields",async()=>{
    const response=await request("/events",payload("privacy-oversized",{project:"가".repeat(6000)}));
    expect(response.status).toBe(400);
    expect(await bindings.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events WHERE event_id='privacy-oversized'").first()).toEqual({n:0});
  });
});

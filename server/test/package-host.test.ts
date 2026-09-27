import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { createDashboardApp, createDashboardHooksApp, type DashboardEnv } from "../src/index";
import worker from "./worker";
import { eventPayload } from "./fixtures";

const bindings = { ...env, ALLOWED_ORIGINS: "https://allowed.example" } as unknown as DashboardEnv;
function host() {
  const app = new Hono<{ Bindings: DashboardEnv }>();
  app.route("/", createDashboardHooksApp());
  app.route("/dashboard", createDashboardApp());
  app.get("/private", c => c.text("host"));
  app.all("/ecosystem/*", c => c.text("ecosystem"));
  app.on("OPTIONS", "/private", c => c.text("host options"));
  return app;
}
async function call(app: ReturnType<typeof host>, path: string, token?: string, method = "GET") {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`https://worker.example${path}`, {
    method, headers: { Origin: "https://allowed.example", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  }), bindings, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

describe("public package composition", () => {
  it("leaves later host routes, unknown routes, and host preflight untouched", async () => {
    const app = host();
    for (const path of ["/private", "/ecosystem/release"]) {
      const response = await call(app, path);
      expect(response.status).toBe(200);
      expect(response.headers.has("Cache-Control")).toBe(false);
      expect(response.headers.has("Access-Control-Allow-Origin")).toBe(false);
    }
    expect(await (await call(app, "/private", undefined, "OPTIONS")).text()).toBe("host options");
    expect((await call(app, "/unknown")).status).toBe(404);
  });
  it("applies dashboard CORS to OPTIONS, denied, and unknown dashboard paths", async () => {
    const app = host();
    for (const [path, token, method, status] of [
      ["/dashboard/sync", undefined, "OPTIONS", 204],
      ["/dashboard/sync", undefined, "GET", 401],
      ["/dashboard/sync", "test-ingest-token", "GET", 403],
      ["/dashboard/unknown", "test-client-token", "GET", 404],
    ] as const) {
      const response = await call(app, path, token, method);
      expect(response.status).toBe(status);
      expect(response.headers.get("Access-Control-Allow-Origin")).toBe("https://allowed.example");
      expect(response.headers.get("Cache-Control")).toBe("no-store");
    }
  });
  it("ingestion check distinguishes roles without touching database rows", async () => {
    const app = host();
    const before = await bindings.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first();
    for (const [token, status] of [["test-ingest-token", 204], ["test-auth-token", 204], ["test-client-token", 403], ["wrong", 401], [undefined, 401]] as const) {
      const response = await call(app, "/dashboard/auth/ingest-check", token);
      expect(response.status).toBe(status);
      if (status === 204) expect(await response.text()).toBe("");
    }
    expect(await bindings.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first()).toEqual(before);
  });
  it("factory instances do not accumulate each other's routes", async () => {
    const first = createDashboardApp();
    const count = first.routes.length;
    first.get("/only-first", c => c.text("first"));
    const second = createDashboardApp();
    expect(second.routes.length).toBe(count);
    const app = new Hono<{ Bindings: DashboardEnv }>().route("/dashboard", second);
    const ctx = createExecutionContext();
    expect((await app.fetch(new Request("https://worker.example/dashboard/only-first", {headers:{Authorization:"Bearer test-client-token"}}), bindings, ctx)).status).toBe(404);
    await waitOnExecutionContext(ctx);
  });
  it("the real scheduled entrypoint runs maintenance and persists a stalled transition", async () => {
    const ctx = createExecutionContext();
    await worker.fetch(new Request("https://worker.example/dashboard/events", {
      method:"POST", headers:{Authorization:"Bearer test-ingest-token", "Content-Type":"application/json"},
      body: JSON.stringify(eventPayload({source:"generic",session_id:"actual-scheduled", event_id:"actual-scheduled",state:"working"})),
    }), bindings, ctx);
    await waitOnExecutionContext(ctx);
    await bindings.DB.prepare("UPDATE dashboard_sessions SET last_progress_at = 1 WHERE key = ?").bind("generic:actual-scheduled").run();
    const scheduledContext = createExecutionContext();
    await worker.scheduled({} as ScheduledController, bindings, scheduledContext);
    await waitOnExecutionContext(scheduledContext);
    expect(await bindings.DB.prepare("SELECT state FROM dashboard_sessions WHERE key = ?").bind("generic:actual-scheduled").first()).toEqual({state:"stalled"});
    expect(await bindings.DB.prepare("SELECT to_state FROM dashboard_transitions WHERE session_key = ? ORDER BY id DESC LIMIT 1").bind("generic:actual-scheduled").first()).toEqual({to_state:"stalled"});
  });
});

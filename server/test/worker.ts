import { Hono } from "hono";
import { createDashboardApp, createDashboardHooksApp, runDashboardMaintenance, type DashboardEnv } from "../src/index";
import { corsMiddleware } from "../src/middleware/cors";

const app = new Hono<{ Bindings: DashboardEnv }>();
// Health is a host concern; this fixture preserves the existing health response contract.
app.use("/healthz", corsMiddleware);
app.get("/healthz", (c) => c.json({ ok: true }));
app.route("/", createDashboardHooksApp());
app.route("/dashboard", createDashboardApp());
export default {
  fetch: app.fetch,
  async scheduled(_controller: ScheduledController, env: DashboardEnv, ctx: ExecutionContext) {
    ctx.waitUntil(runDashboardMaintenance(env, Date.now()).catch((error) => {
      console.error("dashboard maintenance failed", error);
    }));
  },
};

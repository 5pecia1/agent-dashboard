import { Hono } from "hono";
import type { DashboardEnv } from "../env";
import { corsMiddleware } from "../middleware/cors";
import { HOOK_FILES, HOOK_REV } from "../generated/hooks";

export { HOOK_REV } from "../generated/hooks";
const TEXT_HEADERS = { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } as const;
const ORIGIN_PLACEHOLDER = "__MY_DASHBOARD_ORIGIN__";
const REV_PLACEHOLDER = "__MY_DASHBOARD_HOOK_REV__";

/** Public assets only. No root wildcard middleware: the host owns all other paths. */
export function createDashboardHooksApp(): Hono<{ Bindings: DashboardEnv }> {
  const app = new Hono<{ Bindings: DashboardEnv }>();
  app.use("/setup.sh", corsMiddleware);
  app.use("/hooks/files/:name", corsMiddleware);
  app.get("/setup.sh", (c) => c.body(
    HOOK_FILES["setup.sh"].split(ORIGIN_PLACEHOLDER).join(new URL(c.req.url).origin)
      .split(REV_PLACEHOLDER).join(HOOK_REV), 200, TEXT_HEADERS,
  ));
  app.get("/hooks/files/:name", (c) => {
    const name = c.req.param("name");
    if (name === "setup.sh" || !Object.prototype.hasOwnProperty.call(HOOK_FILES, name)) {
      return c.json({ error: "not found" }, 404);
    }
    return c.body(HOOK_FILES[name].split(REV_PLACEHOLDER).join(HOOK_REV), 200, TEXT_HEADERS);
  });
  return app;
}

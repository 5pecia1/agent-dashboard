import { Hono } from "hono";
import type { DashboardEnv } from "./env";
import { dashboardAuth } from "./middleware/auth";
import { corsMiddleware } from "./middleware/cors";
import { dashboard } from "./dashboard/routes";
import { syncRoutes } from "./dashboard/sync";
import { dashboardOps } from "./dashboard/ops";
import { dashboardAdmin } from "./dashboard/rebuild";

/** Mount at /dashboard. Middleware cannot intercept any of the host's other routes. */
export function createDashboardApp(): Hono<{ Bindings: DashboardEnv }> {
  const app = new Hono<{ Bindings: DashboardEnv }>();
  app.use("*", corsMiddleware);
  app.use("*", dashboardAuth);
  app.get("/auth/ingest-check", (c) => c.body(null, 204));
  app.route("/", dashboard);
  app.route("/", syncRoutes);
  app.route("/", dashboardOps);
  app.route("/", dashboardAdmin);
  return app;
}

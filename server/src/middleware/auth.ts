import type { MiddlewareHandler } from "hono";
import type { DashboardEnv } from "../env";

function authorize(scope: "dashboard" | "maintenance"): MiddlewareHandler<{ Bindings: DashboardEnv }> {
  return async (c, next) => {
    const header = c.req.header("Authorization");
    const token = header?.startsWith("Bearer ") ? header.slice(7) : null;
    if (!token) return c.json({ error: "unauthorized" }, 401);
    const legacy = token === c.env.AUTH_TOKEN;
    const ingest = token === c.env.INGEST_TOKEN;
    const client = token === c.env.CLIENT_TOKEN;
    const maintenance = token === c.env.MAINTENANCE_TOKEN;
    if (!legacy && !ingest && !client && !maintenance) return c.json({ error: "unauthorized" }, 401);

    if (scope === "maintenance") {
      // Reusing an ordinary credential must never elevate its existing holders.
      if (maintenance && !legacy && !ingest && !client) return next();
    } else {
      const ingestEndpoint =
        (c.req.method === "POST" && c.req.path === "/dashboard/events") ||
        (c.req.method === "GET" && c.req.path === "/dashboard/auth/ingest-check");
      if (legacy || (ingestEndpoint ? ingest : client)) return next();
    }
    return c.json({ error: "forbidden" }, 403);
  };
}

export const dashboardAuth = authorize("dashboard");
export const dashboardMaintenanceAuth = authorize("maintenance");

import type { MiddlewareHandler } from "hono";
import type { DashboardEnv } from "../env";

/** Attach only to the dashboard sub-app. Hono preserves its mount-relative route path. */
export const dashboardAuth: MiddlewareHandler<{ Bindings: DashboardEnv }> = async (c, next) => {
  const header = c.req.header("Authorization");
  const token = header?.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) return c.json({ error: "unauthorized" }, 401);
  const legacy = Boolean(c.env.AUTH_TOKEN) && token === c.env.AUTH_TOKEN;
  const ingest = Boolean(c.env.INGEST_TOKEN) && token === c.env.INGEST_TOKEN;
  const client = Boolean(c.env.CLIENT_TOKEN) && token === c.env.CLIENT_TOKEN;
  if (!legacy && !ingest && !client) return c.json({ error: "unauthorized" }, 401);
  if (legacy) return next();
  // Version 1's documented mount is /dashboard. Endpoint methods remain part of the role gate.
  const ingestEndpoint =
    (c.req.method === "POST" && c.req.path === "/dashboard/events") ||
    (c.req.method === "GET" && c.req.path === "/dashboard/auth/ingest-check");
  if (ingestEndpoint ? ingest : client) return next();
  return c.json({ error: "forbidden" }, 403);
};

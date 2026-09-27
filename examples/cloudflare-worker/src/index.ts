import { Hono } from 'hono';
import { createDashboardApp, createDashboardHooksApp, runDashboardMaintenance, type DashboardEnv } from '@5pecia1/agent-dashboard-server';

const app = new Hono<{ Bindings: DashboardEnv }>();
app.get('/healthz', c => c.json({ok:true}));
app.route('/', createDashboardHooksApp());
app.route('/dashboard', createDashboardApp());

export default {
  fetch: app.fetch,
  scheduled(_event: ScheduledController, env: DashboardEnv, ctx: ExecutionContext) {
    ctx.waitUntil(runDashboardMaintenance(env, Date.now()));
  },
} satisfies ExportedHandler<DashboardEnv>;

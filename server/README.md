# Agent Dashboard server

This package provides an agent-status server for Cloudflare Workers and D1. Mount it in a Hono app or generate a [standalone Worker starter](https://github.com/5pecia1/agent-dashboard/tree/main/examples/cloudflare-worker). The API prefix is `/dashboard`.

## Install a release

For a new Worker, install Node.js 22 or newer and npm, then run the following commands. No source build is required.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --prerelease
cd agent-dashboard-server
npm ci
```

The server currently has alpha releases only, so use `--prerelease`. To select an exact version, use `--version 0.1.0-alpha.2`. The installer verifies the starter's SHA256 and extracts it into a new folder without overwriting an existing project. Follow the generated `README.md` to sign in to Cloudflare, create D1, set `INGEST_TOKEN` and `CLIENT_TOKEN`, and deploy. See the [quickstart](https://github.com/5pecia1/agent-dashboard/blob/main/docs/quickstart.md#set-up-your-cloudflare-server) for details.

For an existing Hono Worker, install an exact version of the verified package archive:

```sh
npm install --save-exact https://github.com/5pecia1/agent-dashboard/releases/download/server-v0.1.0-alpha.2/5pecia1-agent-dashboard-server-0.1.0-alpha.2.tgz
```

Commit the generated lockfile. [Releases](https://github.com/5pecia1/agent-dashboard/releases) include SHA256 checksums and package installation and upgrade verification results. The package is not yet published to the npm registry; install the GitHub Release archive.

## Connect an existing Worker

```ts
import { Hono } from 'hono';
import {
  createDashboardApp,
  createDashboardHooksApp,
  runDashboardMaintenance,
  type DashboardEnv,
} from '@5pecia1/agent-dashboard-server';

const app = new Hono<{ Bindings: DashboardEnv }>();
app.get('/healthz', c => c.json({ ok: true }));
app.route('/', createDashboardHooksApp());
app.route('/dashboard', createDashboardApp());

export default {
  fetch: app.fetch,
  scheduled(_event: ScheduledController, env: DashboardEnv, ctx: ExecutionContext) {
    ctx.waitUntil(runDashboardMaintenance(env, Date.now()));
  },
};
```

`DB` is the D1 binding. `INGEST_TOKEN` permits ingestion and `GET /dashboard/auth/ingest-check` only. `CLIENT_TOKEN` permits queries, read tracking, manual acknowledgment, deletion, and settings changes. Generate the two values separately and store them as Worker secrets. The compatibility token `AUTH_TOKEN` permits both roles; do not use it for new installations. `ALLOWED_ORIGINS` is a comma-separated list of web app origins.

By default, the server does not store messages or raw hook input. Set `DASHBOARD_STORE_MESSAGE=1` to enable detailed retention. Hooks must also enable `MY_DASHBOARD_INCLUDE_CONTENT=1` to send the original content. Default retention keeps the metadata needed to replay state: source, session and event identifiers, project, host, timestamps, generic state, hook revision, and Devin correlation identifiers. Project and host remain available by default because they identify sessions and connect them to windows. If normalized metadata exceeds 16 KiB in UTF-8, the entire request is rejected with 400 rather than truncating replay data. Detailed collection retains the limits of 4,096 bytes for raw input and 300 characters for messages.

FCM is optional. Configure `FCM_SERVICE_ACCOUNT`, `FIREBASE_WEB_CONFIG`, `FIREBASE_APPLE_CONFIG`, `FCM_WEB_VAPID_KEY`, and `DASHBOARD_APP_ORIGIN` for the channels you use. State ingestion and queries continue to work without them. Adjust the stalled threshold and retention periods through `DASHBOARD_STALL_MS` and `DASHBOARD_RETAIN_*_DAYS` in `DashboardEnv`.

Installation does not modify the database automatically. In the consuming Worker's Wrangler configuration, set `migrations_dir` to `node_modules/@5pecia1/agent-dashboard-server/migrations` and explicitly run `npx wrangler d1 migrations apply DB --remote` before deployment. Existing SQL migrations `0001` through `0005` retain their names and contents. Preserve the migration ledger and do not run `/admin/rebuild` during the transition. Rolling back the package version does not roll back the database.

## Development and verification

Run these commands from the repository root:

```sh
npm --prefix server ci
npm --prefix server run check
npm --prefix server test
npm --prefix server run verify:package
npm --prefix server run test:upgrade
```

`verify:package` installs a temporary tarball into a separate directory and checks types, the Worker bundle, D1, the API, hook delivery, maintenance, and hook integration. The verified archive and logs remain at the printed temporary path. Pass `-- --tarball /path/package.tgz --receipt /path/receipt.json` to verify that archive without rebuilding it. `test:upgrade` accepts the same `--tarball` and `--receipt` options to verify the exact release archive. It restores a synthetic database fixture created through HTTP requests to the previous Worker and checks the migration ledger, cursors, read tracking, and correlation data. Fixture expectations are not regenerated from the current implementation.

`hono` is a peer dependency so the host and package share the router implementation, pinned to the verified version. esbuild and TypeScript are build tools and do not run after package installation. SQL migrations are included under `migrations/`; the API contract and hook manifest are included under `contracts/`. Edit hook sources and the API contract only at the repository root.

See [LICENSE](LICENSE) for license terms and [NOTICE](NOTICE) for existing distribution and third-party notices. The current prerelease package is consumed as a verified `.tgz` before public registry publication.

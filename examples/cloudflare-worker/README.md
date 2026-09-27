# Standalone Worker starter

Start a new server from a released starter archive. Install Node.js 22 or newer and npm, then run the following commands. The server currently has alpha releases only, so include `--prerelease` explicitly.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --prerelease
cd agent-dashboard-server
npm ci
```

To select an exact version, replace `--prerelease` with `--version 0.1.0-alpha.2`. Follow the generated project's `README.md` or the [deployment instructions](STARTER.md) to sign in to Cloudflare, create D1, configure tokens, and deploy. You do not need to clone the source repository or build the server. The installer does not overwrite an existing server folder.

## Generate a starter from source

This directory is a generation template; do not run `npm ci` here directly. When modifying and verifying the package, generate an independent project from the repository root:

```sh
npm --prefix server ci
npm --prefix server run build
(cd server && npm pack --pack-destination /tmp)
node server/scripts/create-example.mjs \
  --package-tgz /tmp/5pecia1-agent-dashboard-server-0.1.0-alpha.2.tgz \
  --out /tmp/agent-dashboard-worker
```

The generator copies the package into the project's `vendor/` directory and references it by a relative path. Moving the generated folder does not leave it dependent on the original tarball path. Generation installs dependencies; if you move the project without `node_modules`, run `npm ci` again.

In the generated project, copy `.dev.vars.example` to `.dev.vars` and enter separate ingest and client tokens. Keep this file out of Git.

```sh
cd /tmp/agent-dashboard-worker
npm run check
npm run migrate:local
npm run dev
```

See the [deployment instructions](STARTER.md) for deployment steps. The default web origin is `https://agent-dashboard.5pecia1.dev`; update `ALLOWED_ORIGINS` and `DASHBOARD_APP_ORIGIN` if you use another web app.

By default, the server stores only state metadata. Detailed collection requires both server `DASHBOARD_STORE_MESSAGE=1` and hook `MY_DASHBOARD_INCLUDE_CONTENT=1`. See the [server guide](../../server/README.md) for optional push and retention settings. The API and hook installation scripts come from the same package version.

# Standalone Worker starter

Deploy from your browser with the [Cloudflare button](deploy/README.md), or start a new server from a released starter archive. Install Node.js 22 or newer and npm, then run the following commands. The server currently has alpha releases only, so include `--prerelease` explicitly.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --prerelease
cd agent-dashboard-server
npm ci
```

To select an exact version, replace `--prerelease` with `--version 0.1.0-alpha.5`. Follow the generated project's `README.md` or the [deployment instructions](STARTER.md) to sign in to Cloudflare, create D1, configure tokens, and deploy. You do not need to clone the source repository or build the server. The installer does not overwrite an existing server folder.

## Generate a starter from source

This directory is a generation template; do not run `npm ci` here directly. When modifying and verifying the package, generate an independent project from the repository root:

```sh
npm --prefix server ci
npm --prefix server run build
(cd server && npm pack --pack-destination /tmp)
node server/scripts/create-example.mjs \
  --package-tgz /tmp/5pecia1-agent-dashboard-server-0.1.0-alpha.5.tgz \
  --out /tmp/agent-dashboard-worker
```

The generator copies the package into the project's `vendor/` directory and references it by a relative path. Moving the generated folder does not leave it dependent on the original tarball path. Generation installs dependencies; if you move the project without `node_modules`, run `npm ci` again.

## Maintain the browser deployment template

`deploy/` is a generated, standalone project for the Cloudflare button. Edit the source templates in this directory and `DEPLOY.md`, then regenerate `deploy/` from the exact server archive prepared for release. The generator requires an empty output directory:

```sh
node server/scripts/create-example.mjs \
  --package-tgz /tmp/5pecia1-agent-dashboard-server-0.1.0-alpha.5.tgz \
  --out /tmp/agent-dashboard-deploy --release
```

Replace the tracked `deploy/` files with that output. This mode writes a fixed GitHub Release dependency URL and lockfile integrity; it does not copy a `.tgz` into Git or install dependencies. Run `npm --prefix server run verify:deploy -- --tarball /path/to/package.tgz` before publication, and `npm --prefix server run verify:deploy -- --published` after publication. The latter installs the real release URL with an empty npm cache.

The `server-package.yml` check requires the tracked lock to match an archive built from the same commit, so the updated button reaches `main` together with the server source and cannot be held back until the release exists. Release in this order: merge the change that updates `deploy/` into `main`, immediately create the `server-vVERSION` tag on the resulting `main` commit, and dispatch `publish-server.yml` from that tag. The workflow verifies the archive, attaches it to the release, and then runs `verify:deploy -- --published`. Until the release exists, which takes a few minutes, the button points at an archive that does not exist yet.

## Develop locally

In the generated project, copy `.dev.vars.example` to `.dev.vars` and enter separate ingest and client tokens. Keep this file out of Git.

```sh
cd /tmp/agent-dashboard-worker
npm run check
npm run migrate:local
npm run dev
```

See the [deployment instructions](STARTER.md) for deployment steps. The default web origin is `https://agent-dashboard.5pecia1.dev`; update `ALLOWED_ORIGINS` and `DASHBOARD_APP_ORIGIN` if you use another web app.

By default, the server stores only state metadata. Detailed collection requires both server `DASHBOARD_STORE_MESSAGE=1` and hook `MY_DASHBOARD_INCLUDE_CONTENT=1`. See the [server guide](../../server/README.md) for optional push and retention settings. The API and hook installation scripts come from the same package version.

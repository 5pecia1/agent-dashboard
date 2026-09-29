# Deploy Agent Dashboard

Create your own Agent Dashboard server on Cloudflare Workers and D1. You need Cloudflare and GitHub accounts. Server deployment happens in your browser; no local Node.js or Wrangler installation is required.

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/5pecia1/agent-dashboard/tree/main/examples/cloudflare-worker/deploy)

1. Select **Deploy to Cloudflare**, sign in, and connect GitHub. Cloudflare copies this directory into a new repository in your GitHub account.
2. Choose unique repository, Worker, and database names. Set the deploy command to `npm run deploy` if it was not detected; it applies D1 migrations before deploying the Worker.
3. Generate and save two different random tokens of at least 32 characters in your password manager. Enter them as `INGEST_TOKEN` and `CLIENT_TOKEN` in the setup form. Keep tokens out of Git. The first token lets agent hooks send events; the second lets the dashboard read and manage sessions.
4. Deploy. Cloudflare creates and binds D1, stores your secrets, and builds the Worker. Copy the resulting `https://…workers.dev` origin, without `/dashboard`.
5. Open [Agent Dashboard](https://agent-dashboard.5pecia1.dev) or the macOS app, and enter that origin and your `CLIENT_TOKEN`.
6. On each machine running an agent, install your server's hooks:

   ```sh
   curl -fsSL https://YOUR_SERVER/setup.sh | bash
   ```

   Replace `https://YOUR_SERVER` with your Worker origin. This local Bash step supports Claude Code, Codex, Devin, and Antigravity CLI, needs `curl`, `jq`, and `python3`, and asks for `INGEST_TOKEN`. Check prerequisites with `command -v curl jq python3`; install any missing tools using your machine's package manager. In the Codex terminal interface, enter `/hooks` and trust the installed hooks. Start an agent session and check that it appears in the dashboard. See the [hook guide](https://github.com/5pecia1/agent-dashboard/blob/main/hooks/README.md) for configuration and troubleshooting.

Push notifications are optional. The default web origins allow the public web app and `http://localhost:8080`. To use another web app, update `ALLOWED_ORIGINS` and `DASHBOARD_APP_ORIGIN` in your copied repository's `wrangler.jsonc`.

## Versions and updates

This directory installs one exact server package from GitHub Releases. Its `package-lock.json` checks the package's integrity. The server is currently an alpha release. Deploying this template creates a new server; it does not update an existing server or automatically track upstream releases.

Keep your copied repository and D1 database. To upgrade, back up the database, review the [server release notes](https://github.com/5pecia1/agent-dashboard/releases), update the package dependency and lockfile to an exact newer release, and deploy from your repository. Do not replace your database ID with the template placeholder. Reinstall hooks from the upgraded server afterward.

For terminal-based installation or embedding in an existing Worker, see the [server guide](https://github.com/5pecia1/agent-dashboard/blob/main/server/README.md). Cloudflare usage is subject to your account's plan and limits. See [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) and [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/).

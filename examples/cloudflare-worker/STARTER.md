# Agent Dashboard server

This project runs your own Agent Dashboard server on Cloudflare Workers and D1. It includes a released server package in `vendor/`, its lockfile, and the Worker configuration. You do not need to clone or build the Agent Dashboard repository.

## Deploy

Requirements: Node.js 22 or newer, npm, and a Cloudflare account.

1. Open a terminal in this folder, install the pinned dependencies, and sign in:

   ```sh
   npm ci
   npm run check
   npx wrangler login
   npx wrangler d1 create agent-dashboard
   ```

2. Open `wrangler.jsonc`. Replace the placeholder `database_id` with the ID printed by the last command. If you chose another database name, also update `database_name`. Change the Worker `name` if you already use `agent-dashboard` for another Worker.

   The default `ALLOWED_ORIGINS` permits the public web app at `https://agent-dashboard.5pecia1.dev` and local development at `http://localhost:8080`. Set your own web origin here if you host the app elsewhere. `DASHBOARD_APP_ORIGIN` is the URL used for app links.

3. Generate two different tokens in your password manager and save them. Set each secret when prompted; token values do not belong in `wrangler.jsonc`:

   ```sh
   npx wrangler secret put INGEST_TOKEN
   npx wrangler secret put CLIENT_TOKEN
   ```

   Use `INGEST_TOKEN` for agent hooks and `CLIENT_TOKEN` for the dashboard.

4. Apply the database migrations and deploy:

   ```sh
   npm run deploy
   ```

   This command applies remote D1 migrations before uploading the Worker. Copy the `https://…workers.dev` origin printed by Wrangler. You can check it with `curl -fsS https://YOUR_SERVER/healthz`.

5. Open [Agent Dashboard](https://agent-dashboard.5pecia1.dev) or the macOS app. Enter the Worker origin and your `CLIENT_TOKEN`. On each machine running an agent, install the matching hooks:

   ```sh
   curl -fsSL https://YOUR_SERVER/setup.sh | bash
   ```

   Replace `https://YOUR_SERVER` with your Worker origin. The hook installer requires `curl`, `jq`, and `python3`, and asks for `INGEST_TOKEN` through the terminal. In Codex, open `/hooks` and trust the installed hooks. Start an agent session and check that it appears in the dashboard.

## Run locally

Copy `.dev.vars.example` to `.dev.vars` and enter two separate local test tokens. Keep that file out of version control.

```sh
cp .dev.vars.example .dev.vars
npm run migrate:local
npm run dev
```

Local D1 data and secrets are separate from the deployed Worker. Use the macOS app or a locally served web build when testing an HTTP localhost server. Connect the public web app to your deployed HTTPS Worker.

## Update an existing server

Keep this project, its configuration, and its D1 database. A new starter is for a new project; the installer will not overwrite an existing server folder. To upgrade this project, back up your database, install an exact newer server package from [GitHub Releases](https://github.com/5pecia1/agent-dashboard/releases), review its release notes, run `npm run check`, and run `npm run deploy`. Commit the updated `package.json` and lockfile. Reinstall the hooks from your upgraded server afterward.

The default collection stores state metadata, including project and host identifiers, without prompt/message content. Detailed collection requires both server `DASHBOARD_STORE_MESSAGE=1` and hook `MY_DASHBOARD_INCLUDE_CONTENT=1`. See the [server guide](https://github.com/5pecia1/agent-dashboard/blob/main/server/README.md) for retention, optional push, and the data policy.

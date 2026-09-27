# Agent Dashboard

[Open the web app](https://agent-dashboard.5pecia1.dev) · [Download the app](https://github.com/5pecia1/agent-dashboard/releases/latest)

Agent Dashboard collects coding-agent activity so you can see which sessions need your attention. It includes a web/macOS dashboard, agent hooks, and a Cloudflare Workers + D1 server that can also be embedded in another Worker.

This is source-available software. Read [LICENSE](LICENSE) for the permitted uses and restrictions and [NOTICE](NOTICE) for third-party notices. The first alpha server package is available from [GitHub Releases](https://github.com/5pecia1/agent-dashboard/releases). The npm registry workflow is prepared; until its trusted-publisher connection is configured, install the fixed Release archive directly with npm.

## Install the server package

For an existing Hono Worker, install the tested alpha archive:

```sh
npm install --save-exact https://github.com/5pecia1/agent-dashboard/releases/download/server-v0.1.0-alpha.1/5pecia1-agent-dashboard-server-0.1.0-alpha.1.tgz
```

Commit the generated lockfile. Release assets include SHA256 and the independent installation/upgrade checks. [The server guide](server/README.md) shows the imports, D1 binding, and explicit migration step. For a new Worker, use the template below.

## Start with the server

Requirements: Node.js 22 or newer, npm, and a Cloudflare account for deployment. Local verification uses an isolated local D1 database and does not require an account.

```sh
npm --prefix server ci
npm --prefix server run check
npm --prefix server test
npm --prefix server run verify:package
```

Follow [the server guide](server/README.md) and [the Worker example](examples/cloudflare-worker/README.md) to deploy your own instance. The package exports `createDashboardApp`, `createDashboardHooksApp`, `runDashboardMaintenance`, and `DashboardEnv`. It contains the SQL migrations and served hook assets.

Use a separate ingest token for agent hooks and client token for the dashboard. Store secrets in your Worker environment. Database migrations are an explicit deployment step; installing the npm package does not apply them.

## Connect the app and hooks

Build the app with [the app guide](app/README.md), then enter your own server origin and client token in its setup screen. The app starts without an embedded server token. [The deployment guide](docs/deployment.md) covers Cloudflare Pages hosting and versioned web/macOS releases.

Download your server's `setup.sh`, inspect it, and run it locally:

```sh
curl -fsSL https://YOUR_SERVER/setup.sh -o setup.sh
less setup.sh
bash setup.sh
```

Use the ingest token when asked. [The hook guide](hooks/README.md) explains the integration and data handling. Push notifications are optional; server polling works without Firebase credentials.

## Usage integrations

TeamClaude and Devin usage panels are included in the web and macOS apps. Configure your own endpoint and key in Settings; an unconfigured integration makes no requests. [Usage integration setup](docs/integrations.md) explains browser HTTPS/CORS requirements and local credential storage.

## Development and upgrades

The API contract lives in `contracts/dashboard-protocol.v1.json`. The server, app, and hooks are versioned together in this repository. For an embedded server, pin `@5pecia1/agent-dashboard-server` to an exact version once it is published. Before publication, install the exact locally built `.tgz` described in the server guide.

Review release notes, apply pending SQL migrations, and update the server package before upgrading the hooks served by that server. Back up your database before schema upgrades. Do not run the administrative rebuild endpoint as a package upgrade step.

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change and [SECURITY.md](SECURITY.md) to report a vulnerability.

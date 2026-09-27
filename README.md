# Agent Dashboard

Agent Dashboard collects coding-agent activity so you can see which sessions need your attention. It includes a web/macOS dashboard, agent hooks, and a Cloudflare Workers + D1 server that can also be embedded in another Worker.

This is source-available software. Read [LICENSE](LICENSE) for the permitted uses and restrictions and [NOTICE](NOTICE) for third-party notices. Public package and release publication is still being prepared; the commands below build from this checkout.

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

Build the app with [the app guide](app/README.md), then enter your own server origin and client token in its setup screen. The app starts without an embedded server token.

Download your server's `setup.sh`, inspect it, and run it locally:

```sh
curl -fsSL https://YOUR_SERVER/setup.sh -o setup.sh
less setup.sh
bash setup.sh
```

Use the ingest token when asked. [The hook guide](hooks/README.md) explains the integration and data handling. Push notifications are optional; server polling works without Firebase credentials.

## Development and upgrades

The API contract lives in `contracts/dashboard-protocol.v1.json`. The server, app, and hooks are versioned together in this repository. For an embedded server, pin `@5pecia1/agent-dashboard-server` to an exact version once it is published. Before publication, install the exact locally built `.tgz` described in the server guide.

Review release notes, apply pending SQL migrations, and update the server package before upgrading the hooks served by that server. Back up your database before schema upgrades. Do not run the administrative rebuild endpoint as a package upgrade step.

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change and [SECURITY.md](SECURITY.md) to report a vulnerability.

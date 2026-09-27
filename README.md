# Agent Dashboard

[English](README.md) · [한국어](README.ko.md)

> Tired of switching between agent windows and checking terminals one by one?
>
> I built this project to see the status of agents running across multiple servers and clients in one place. There are many tools for managing agent status, but I found them difficult to use in my setup, which combines SSH and devcontainers.
>
> With help from AI agents, we can now build the tools we need or adapt existing ones to our own environments. I'm sharing this project's source code so that others facing similar frustrations can get started more easily and adapt it to their needs.

[Open the web app](https://agent-dashboard.5pecia1.dev) · [Install macOS](#install-the-macos-app) · [Set up your server](#set-up-your-server) · [Quickstart](docs/quickstart.md)

Agent Dashboard collects coding-agent activity so you can see which sessions need your attention. It includes a web/macOS dashboard, agent hooks, and a Cloudflare Workers + D1 server that can also be embedded in another Worker.

The web and macOS apps connect to **your own server**. The public web app does not include a hosted account or store your dashboard data on a shared server.

## Install the macOS app

On an Apple silicon Mac, install the latest stable app from GitHub Releases:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh | bash
```

The installer verifies the release checksum and installs `~/Applications/Agent Dashboard.app`. Open it and enter your server origin and client token. No source build is needed. You can also download the macOS ZIP from [Releases](https://github.com/5pecia1/agent-dashboard/releases).

The current app is not Developer ID signed or notarized; macOS may require approval on first launch. See [macOS installation and updates](docs/quickstart.md#macos-installation-and-updates). For a browser, simply [open the web app](https://agent-dashboard.5pecia1.dev).

## Set up your server

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/5pecia1/agent-dashboard/tree/main/examples/cloudflare-worker/deploy)

Deploy from your browser with Cloudflare and GitHub accounts. The setup form asks for two different tokens: `INGEST_TOKEN` for hooks and `CLIENT_TOKEN` for the dashboard. Cloudflare creates D1 and deploys the server. Then connect the app and install hooks on your agent machines. See the [browser deployment guide](examples/cloudflare-worker/deploy/README.md).

For terminal-based installation, use Node.js 22 or newer, npm, and a Cloudflare account:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --prerelease
cd agent-dashboard-server
npm ci
```

The server is currently an alpha release, so this command explicitly includes prereleases. Follow the generated `README.md` or the [quickstart](docs/quickstart.md#set-up-your-cloudflare-server) to sign in to Cloudflare, create D1, set two tokens, and deploy. The installer creates a project; it does not create cloud resources or deploy them.

For an existing Hono Worker, [install the server package](server/README.md) instead. Use `INGEST_TOKEN` for agent hooks and a separate `CLIENT_TOKEN` for the dashboard.

## Connect your agents

After deploying your server, install its matching hooks on each agent machine. Replace `https://YOUR_SERVER` with the server origin:

```sh
curl -fsSL https://YOUR_SERVER/setup.sh | bash
```

The hook installer needs `curl`, `jq`, and `python3`. Enter the ingest token when asked; in Codex, trust the new hooks through `/hooks`. Start an agent session and check it in the dashboard. [The hook guide](hooks/README.md) covers previewing changes, updates, and data handling. Push notifications are optional.

## Choose a version or update

Without a version, the installer selects the latest stable release **for that component** and fixes the download target for that installation. `--prerelease` includes prereleases. `--version` selects an exact version, including a prerelease, and fails if it does not exist; it never falls back to another version.

```sh
# Install a particular app version.
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- --version v0.1.1

# Update an existing app to the latest stable version; keep its settings.
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- --replace

# Create a server project from an exact prerelease.
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --version 0.1.0-alpha.4 --dir ./my-agent-server
```

Use `--dry-run` to see the selected release and destination without installing. To inspect the installer first, [read install.sh](install.sh), or download it and run it locally. The script is served by GitHub Raw; release archives and checksums come from GitHub Releases. Pages hosts the web app only.

## Usage integrations

TeamClaude and Devin usage panels are included in the web and macOS apps. Configure your own endpoint and key in Settings; an unconfigured integration makes no requests. [Usage integration setup](docs/integrations.md) explains browser HTTPS/CORS requirements and local credential storage.

## Development and upgrades

The API contract lives in `contracts/dashboard-protocol.v1.json`. App releases use `vVERSION`; server releases use `server-vVERSION`. Each server release includes the matching hook assets. To work on the server, run from the repository root:

```sh
npm --prefix server ci
npm --prefix server run check
npm --prefix server test
npm --prefix server run verify:package
```

See [the app guide](app/README.md) for source builds and [the deployment guide](docs/deployment.md) for web hosting and releases.

Review release notes, apply pending SQL migrations, and update the server package before upgrading the hooks served by that server. Back up your database before schema upgrades. Do not run the administrative rebuild endpoint as a package upgrade step.

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change and [SECURITY.md](SECURITY.md) to report a vulnerability.

This is source-available software. Read [LICENSE](LICENSE) for permitted uses and restrictions and [NOTICE](NOTICE) for third-party notices.

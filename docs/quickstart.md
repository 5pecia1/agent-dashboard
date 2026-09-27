# Start using Agent Dashboard

Use the [web app](https://agent-dashboard.5pecia1.dev) or install the macOS app, deploy your own server, and connect your agent hooks. You do not need to clone or build this repository.

## macOS installation and updates

The published macOS download is for Apple silicon. The web app is available on other platforms.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh | bash
open "$HOME/Applications/Agent Dashboard.app"
```

The installer uses macOS tools and `curl`; it does not require Node.js, Python, Xcode, or Flutter. It downloads a released ZIP, checks SHA256, and installs the app in `~/Applications`. To choose another installation folder, pass `--dir /Applications` if your account can write there.

The current release has an ad-hoc signature and is not Developer ID signed or notarized. If macOS blocks the first launch, review [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445). After attempting to open it, approve this app in **System Settings → Privacy & Security → Open Anyway** if you trust this download. The installer does not disable Gatekeeper or remove quarantine attributes.

For manual installation, download the macOS ZIP from [GitHub Releases](https://github.com/5pecia1/agent-dashboard/releases), extract it, and move `Agent Dashboard.app` to your Applications folder.

To update, quit the app and run:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- --replace
```

The installer replaces only the app bundle, keeps a backup of the previous bundle, and leaves saved connection settings alone. Without `--replace`, it refuses to overwrite an installed app. If you installed into a different folder, pass the same `--dir` again. Use `--version v0.1.1 --replace` to intentionally install that app version.

## Set up your Cloudflare server

### Deploy in your browser

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/5pecia1/agent-dashboard/tree/main/examples/cloudflare-worker/deploy)

Use Cloudflare and GitHub accounts to create your server without installing local build tools. Cloudflare copies the deployment template into your GitHub account, asks for `INGEST_TOKEN` and `CLIENT_TOKEN`, creates D1, and deploys the Worker. Generate and save two different random tokens in your password manager.

Follow the [browser deployment guide](../examples/cloudflare-worker/deploy/README.md), then continue with [Connect agent hooks](#connect-agent-hooks). Firebase push is optional.

### Deploy from a terminal

1. Install Node.js 22 or newer and npm, and have a Cloudflare account ready. Download the current server starter:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
     | bash -s -- server --prerelease
   cd agent-dashboard-server
   npm ci
   npm run check
   ```

   The server currently has alpha releases only. `--prerelease` allows them; without it, the installer reports that no stable server release is available. The starter contains the released package in `vendor/` and a lockfile. It installs into a new folder and refuses to overwrite an existing project.

2. Sign in and create a database:

   ```sh
   npx wrangler login
   npx wrangler d1 create agent-dashboard
   ```

   Edit `wrangler.jsonc`: replace `database_id` with the returned ID. If you chose another database name, also update `database_name`. Change the Worker `name` if that name already belongs to another Worker in your account. The starter already permits `https://agent-dashboard.5pecia1.dev` in `ALLOWED_ORIGINS`.

3. Generate two different tokens in your password manager and save them. Paste each into the corresponding Wrangler prompt:

   ```sh
   npx wrangler secret put INGEST_TOKEN
   npx wrangler secret put CLIENT_TOKEN
   npm run deploy
   ```

   `npm run deploy` applies remote D1 migrations before deploying the Worker. Copy the `https://…workers.dev` origin from the output. The Pages API token used to publish the public web app is not needed for this setup; Wrangler signs in to your own account.

4. Open [the web app](https://agent-dashboard.5pecia1.dev) or the macOS app. Enter your Worker origin and `CLIENT_TOKEN`. Use the HTTPS origin without `/dashboard`. Browser connection settings belong to that browser origin; opening another web address requires configuring it again.

For local development, upgrades, or custom origins, use the `README.md` inside the generated project. To embed the package in an existing Worker, use the [server guide](../server/README.md).

## Connect agent hooks

On each machine running Claude Code, Codex, or Devin, ensure `curl`, `jq`, and `python3` are installed. Replace `https://YOUR_SERVER` below with the Worker origin you deployed:

```sh
curl -fsSL https://YOUR_SERVER/setup.sh | bash
```

The script asks for `INGEST_TOKEN` through the terminal, so the prompt works when the script is piped to Bash. It installs the hooks served by that server and prints configuration backup paths. In Codex, open `/hooks` and trust the new hooks. Start an agent session and check that it appears in the dashboard.

You can also use the common installer:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- hooks --server-url https://YOUR_SERVER
```

Hook versions come from your server, so `hooks` does not accept `--version`. The common installer's `--dry-run` downloads and checks the setup script without executing it. To preview the hook configuration changes, download your server's script and run `bash setup.sh --dry-run` as shown in the [hook guide](../hooks/README.md). Repeating the hook setup updates the files while retaining existing connection values.

## Installer options

| Option | Behavior |
|---|---|
| No component, or `app` | Installs the macOS app; defaults to the latest stable app release. |
| `server` | Creates a server project from the latest stable server starter. |
| `--version VERSION` | Selects exactly that component's version. Accepts `v0.1.1` or `0.1.1` for the app, and `server-v0.1.0-alpha.4` or `0.1.0-alpha.4` for the server. |
| `--prerelease` | Includes prereleases when resolving the latest version. Explicit prerelease versions do not need this flag. |
| `--dir DIR` | Sets the app installation parent or the new server project directory. |
| `--replace` | Allows replacing an existing app, retaining a backup and its settings. Does not overwrite server projects. |
| `--dry-run` | Downloads and verifies the selected release without installing; for hooks, checks the setup script without running it. |
| `hooks --server-url URL` | Runs the hook setup served by your HTTPS server. |
| `--help` | Shows usage. |

App and server release selection are independent. Once the installer resolves a release, it uses that fixed tag for the download and checksum. A missing requested version or checksum failure stops installation; the installer does not substitute a different release. Old server releases without a starter archive cannot be installed through `server`; their package archive is still usable in an existing Worker.

To inspect the current installer before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh -o install.sh
less install.sh
bash install.sh --dry-run
bash install.sh
```

This URL follows `main`. For a reproducible installer revision, replace `main` in the Raw URL with a reviewed commit SHA that contains the script, and use `--version` for the component. The script lives in GitHub Raw; archives, release metadata, and checksums live in GitHub Releases. Web deployment or rollback does not change the installer.

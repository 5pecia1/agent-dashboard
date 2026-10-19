# Agent Dashboard app

The common Flutter/Rust app displays session state, history, and notifications. Optional push uses your own Firebase configuration. It does not ship server credentials.

On macOS, click a session card to switch to its connected work window. If no window is connected or the saved window is unavailable, choose an open window on this Mac. On the web, clicking a card opens its details. Sessions with the same host and full project path share a window connection; it switches to the window rather than a particular terminal tab.

With mouse input on macOS or the web, hover over a card to reveal **View session details** and **Delete session**. Deletion removes the dashboard record and saved history. It does not stop the running agent, which may reappear after new activity.

## Install a release

Use the [web app](https://agent-dashboard.5pecia1.dev), or install the latest stable macOS release on an Apple silicon Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh | bash
open "$HOME/Applications/Agent Dashboard.app"
```

For a specific version, use `bash -s -- --version v0.1.1` at the end of the command. To update an existing app, quit it and use `bash -s -- --replace`; the installer backs up the old bundle and keeps your saved settings. No source build is required. [Releases](https://github.com/5pecia1/agent-dashboard/releases) also provides the macOS ZIP for manual installation.

The current release has an ad-hoc signature and is not Developer ID signed or notarized. See the [quickstart](../docs/quickstart.md#macos-installation-and-updates) for the first-launch approval, installer options, and server setup. Open the app and enter your own server origin and client token.

## Delete multiple sessions

Choose **Select sessions** above the session list to select cards across projects. You can select a whole project or use **Select all shown** for every non-ended session in the current list, including cards below the viewport. Choose **Delete selected** to review the selected count and the count for each project. Canceling keeps the selection; confirming deletes only the sessions selected when the confirmation opened and then exits selection mode. While selecting, tapping a card changes its selection instead of opening a work window or session details.

Projects with multiple sessions also have a **Delete all sessions** icon beside their session count. Its confirmation shows the full project path, hosts, and number of sessions. Both bulk actions delete the selected session records and their saved event history; locally saved snippets remain. Sessions added after confirmation opens are kept. Failed deletions are restored when the server connection stays the same, and the result reports successful and failed counts. Active sessions may reappear after new activity.

Groups use the exact full project path across hosts and agent types. Unknown projects can be selected individually; they have no project-wide delete button. Ended sessions hidden from the default list are excluded from both bulk actions. Another device's cached list may keep deleted sessions until its next full snapshot.

Changing the server URL or token clears the previous selection. If either changes while confirming or deleting, the app stops the remaining requests and asks you to review the current list before trying again. An in-flight request's outcome may be unknown in that case.

## Antigravity CLI usage

In the macOS app's settings, expand **Antigravity** and enable **Show Antigravity CLI usage**. Install `agy` 1.2.9 or newer and sign in to it first. The dashboard uses that CLI login to show the reported model groups' 5-hour and weekly usage on the home screen and in the tray. The home screen also shows time remaining until reset.

Usage refreshes every 60 seconds while the dashboard is visible. Refresh manually or open the tray menu to query while the window is hidden. A failed query keeps the last successful reading with a warning; turning usage off clears that cache. After changing the agy account, refresh to fetch its quotas, or turn usage off and back on to clear the previous account's reading. The web app shows the macOS-only notice and does not run a local CLI.

The app checks `~/.local/bin/agy`, common macOS installation locations, and its process `PATH`. For a custom installation, launch the app with `AGY_CLI_PATH` set to the absolute executable path. Quota queries disable agy's auto-update and use temporary logs that are removed after each query.

Quit the app before launching with a custom path. Adjust the app location for your installation:

```sh
open --env AGY_CLI_PATH=/absolute/path/to/agy "$HOME/Applications/Agent Dashboard.app"
```

## Build from source

For Linux web development, open the repository root in VS Code and select **Dev Containers: Reopen in Container**. The root [Devcontainer configuration](../.devcontainer/devcontainer.json) mounts the whole repository and initializes the app from `app/`. It uses Linux x86_64; native macOS builds require a macOS host. Server development separately requires Node.js 22 or newer and npm, as described in the [server guide](../server/README.md).

On macOS, install Xcode 16.4 or newer (Swift 6.1 for Firebase) and [mise](https://mise.jdx.dev), then run from this directory:

```sh
mise install
mise run tools:rust
mise run tools:licenses
mise run deps
mise run check
mise run verify
mise run build
```

The tool versions are pinned in `.mise.toml`. `deps` also prepares the macOS Swift Package Manager cache required on a fresh checkout. The normal build selects the native desktop target. A web build also needs the pinned nightly Rust toolchain:

```sh
mise run tools:web
mise run build:web
```

Host a web build at the origin root and preserve its `_headers` file. [The deployment guide](../docs/deployment.md) shows Cloudflare Pages setup and the app release workflow, which publishes web/macOS archives and deploys the published web archive when an app version is tagged.

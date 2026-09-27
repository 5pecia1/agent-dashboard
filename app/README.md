# Agent Dashboard app

The common Flutter/Rust app displays session state, history, and notifications. Optional push uses your own Firebase configuration. It does not ship server credentials.

## Install a release

Use the [web app](https://agent-dashboard.5pecia1.dev), or install the latest stable macOS release on an Apple silicon Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh | bash
open "$HOME/Applications/Agent Dashboard.app"
```

For a specific version, use `bash -s -- --version v0.1.1` at the end of the command. To update an existing app, quit it and use `bash -s -- --replace`; the installer backs up the old bundle and keeps your saved settings. No source build is required. [Releases](https://github.com/5pecia1/agent-dashboard/releases) also provides the macOS ZIP for manual installation.

The current release has an ad-hoc signature and is not Developer ID signed or notarized. See the [quickstart](../docs/quickstart.md#macos-installation-and-updates) for the first-launch approval, installer options, and server setup. Open the app and enter your own server origin and client token.

## Build from source

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

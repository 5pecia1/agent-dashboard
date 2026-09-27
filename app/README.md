# Dashboard app

The common Flutter/Rust app displays session state, history, and notifications. Optional push uses your own Firebase configuration. It does not ship server credentials.

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

Open the app and configure your server origin and client token. Host the web build at the origin root and preserve its `_headers` file. [The deployment guide](../docs/deployment.md) shows Cloudflare Pages setup and the app release workflow, which publishes web/macOS archives and deploys the published web archive when an app version is tagged.

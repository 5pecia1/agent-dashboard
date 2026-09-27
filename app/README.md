# Dashboard app

The common Flutter/Rust app displays session state, history, and notifications. Optional push uses your own Firebase configuration. It does not ship server credentials.

On macOS, install Xcode and [mise](https://mise.jdx.dev), then run from this directory:

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

Open the app and configure your server origin and client token. Start with the web deployment at the origin root; subpath hosting is not part of the current server contract.

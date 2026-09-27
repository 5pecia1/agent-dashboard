# Unsigned app packaging

Package only the targets selected during initialization. Run the relevant commands on each target OS:

```sh
mise run verify
python3 scripts/package.py linux --tag v0.1.0
python3 scripts/package.py macos --tag v0.1.0
python3 scripts/package.py windows --tag v0.1.0
python3 scripts/package.py web --tag v0.1.0
```

Linux produces deb and AppImage files, macOS produces a dmg, Windows produces an msix, and web produces a tar.gz. Artifacts and SHA-256 checksums are written to `target/packages/<target>`. Regeneration replaces previous temporary artifacts for the same target. Linux requires dpkg-deb and appimagetool; the release workflow downloads the pinned appimagetool 1.9.1 and verifies its SHA-256.

The app's canonical SemVer is `workspace.package.version` in `Cargo.toml`. It must match the version before the build number in `pubspec.yaml`; MSIX appends `.0` to the three numeric components. A tag, if supplied, must exactly match `v<app version>`. `scripts/version_check.py` rejects mismatches. The platform's `SOL_PLATFORM_VERSION` is separate from the app version.

The tag supplied to a manual release must already exist. The workflow resolves its commit first, then checks out the same SHA for verification and every packaging job. A single publication job creates the GitHub Release only after all selected OS jobs succeed. With no input tag, the workflow retains artifacts without publishing. Publication is skipped if any packaging job fails or produces no artifacts.

All packages produced by this packaging path are unsigned. MSIX explicitly sets `sign_msix: false`. Each consuming project adds distribution certificates, Windows signing, and macOS signing and notarization as separate steps. An unsigned MSIX does not establish that end users can install it; actual distribution must satisfy Windows signing requirements. Retry a failed publication with the same tag and SHA, comparing existing assets and checksums. Atomic publication across multiple external package registries is not guaranteed.

Record verification separately for each OS. Launch the installed package and confirm that the Rust greeting appears. For web, verify initial boot, an offline reload, and the Rust response after switching to a new version. Success on another OS or a successful `flutter build web` does not replace runtime verification.

References: [FRB's built-in integration](https://cjycode.com/flutter_rust_bridge/manual/integrate/builtin), [MSIX options](https://pub.dev/packages/msix), and [appimagetool](https://github.com/AppImage/appimagetool/releases/tag/1.9.1).

The platform release implementation lives in the central reusable `.github/workflows/device-app-release.yml` workflow. The app seed's `release.yml` is a thin entry point calling a pinned platform tag. For a composed repository with product code under `app/`, the root workflow entry point passes `app-directory: app`. GitHub does not execute workflows in nested `.github/workflows` directories, so the composer creates the root entry point. The public Agent Dashboard product uses the separate [product release workflow](../../.github/workflows/release-product.yml) described in the [deployment guide](../../docs/deployment.md).

Checks on the release workflow's Ubuntu 24.04 host run in a different environment from the pinned Docker image. The consuming repository's pinned Linux QA image is authoritative for Linux goldens and the complete composition contract. Release hosts also compare existing goldens and fail on differences. They do not update goldens automatically or substitute another OS's goldens.

The AppImage runtime is verified against the SHA256 in `packaging/appimage-runtimes.json` and passed to `appimagetool --runtime-file`. If the upstream `continuous` URL changes, verification fails; review the official asset again before updating its digest. Implicit runtime downloads by the tool are not permitted. On ARM Macs, the default execution layer has rejected the x86_64 runtime's static-PIE ELF, requiring explicit QEMU. Record those results separately from native Linux results.

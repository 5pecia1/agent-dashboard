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

The v0.1.10 release uses ad-hoc signing. Later releases require Developer ID signing and Apple notarization. See the [quickstart](../docs/quickstart.md#macos-installation-and-updates) for the first-launch approval, installer options, and server setup. Open the app and enter your own server origin and client token.

## macOS updates

The macOS app checks once when its process launches. Choose **Check for Updates…** in the application menu to check again while the app is open. An explicit check shows the available version, confirms that the app is up to date, or reports an error. When offered an update, choose **Install Update** or **Remind Me Later**. Dismissing the offer keeps the installed build in place. The app starts normally when the update service is unavailable. Reopening a window or waking the Mac does not start another check.

Sparkle verifies the downloaded archive using the Ed25519 public key in the installed app before extracting the update. Builds released before the updater was introduced can be upgraded using the [release installer](../install.sh).

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

## Browser storage and offline use

A completed online launch makes the app shell available offline. Dashboard API requests, authenticated requests, and URLs with query parameters always require a network connection. The service worker caches only build-verified files under the app's own scope and honors `Cache-Control: private` and `no-store`. An upgrade removes older dashboard shell caches when the new worker activates.

The browser keeps the current connection in this app's local storage. Loading or saving the configuration removes the redundant backup used by older versions, including after the active connection was cleared.

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

For a first-launch smoke test, use a fresh temporary home with a `.my-dashboard-qa-home` marker, an isolated QA bundle ID and a Profile build. Follow the [native QA environment setup](flutter_app/tool/visual_qa/README.md#check-sync-errors-and-server-changes-in-an-isolated-profile-app) with target `integration_test/boot_test.dart` and driver `test_driver/sync_qa_driver.dart`. The test starts the production entry point and checks the empty connection form.

## Use the dashboard in another macOS app

Add the Flutter package to the application's `pubspec.yaml`. Pin the full commit of the public version you have tested and commit the application's `pubspec.lock`.

```yaml
dependencies:
  my_dashboard:
    git:
      url: https://github.com/5pecia1/agent-dashboard.git
      ref: <full-commit-sha>
      path: app/flutter_app
```

```dart
import 'package:my_dashboard/agent_dashboard.dart';

Future<void> main() => runDashboard(
  stateDirectoryName: 'example-dashboard',
  packageAssets: true,
);
```

Give the app its own bundle identifier and state directory name. The name selects its desktop files under `~/.local/state/` and its browser storage keys. Use `packageAssets: true` when the dashboard is a dependency so its tray icons resolve from the Flutter package. To append panels, pass provider overrides for `additionalHomeSectionsProvider` or `additionalSetupSectionsProvider` through `extensions`.

The macOS Runner supplies its generated plugin registrant. Follow the small [application delegate](flutter_app/macos/Runner/AppDelegate.swift) and [Flutter window](flutter_app/macos/Runner/MainFlutterWindow.swift) adapters in your Runner. The linked `my_dashboard_frb` CocoaPod provides the resident-window behavior, Accessibility window navigation and Rust bridge. Retain the package's repository layout so CargoKit can locate the Rust workspace.

For a macOS host, declare the Sparkle pod immediately after `flutter_install_all_macos_pods` in its Podfile. The shared plugin supplies the pinned 2.10.1 specification and upstream checksum.

```ruby
pod 'Sparkle', :podspec => 'Flutter/ephemeral/.symlinks/plugins/my_dashboard_frb/macos/Sparkle.podspec'
```

To enable launch checks for an embedded app, set `DashboardUpdateBundleIdentifier` to its own bundle ID, `SUFeedURL` to its fixed HTTPS appcast, and `SUPublicEDKey` to its update signing public key. Use `SUVerifyUpdateBeforeExtraction` and disable automatic installs with `SUAllowsAutomaticUpdates` as in the public [Runner configuration](flutter_app/macos/Runner/Info.plist). A host that needs authenticated updates can override `prepareDashboardUpdateFeed` to supply a short-lived ticket on the configured feed's origin and path.


An embedding host can optionally pass `DashboardHostSession` to `runDashboard` to manage dashboard credentials itself. Its `wrapApp` callback surrounds the complete dashboard provider scope and configuration recovery screen. Mount the supplied widget after sign-in, remove it at sign-out, and key it by account or session generation. Supply account controls through `connectionSettings(context, languageCode)` to replace the manual connection form. Its language code follows the dashboard language selector. To preserve unread and sync state across launches, pass `syncScope`, a callback returning a non-secret account identifier that survives token rotation. A matching origin and scope restore their saved cursor and seen watermark. The first launch, a different account or server, and hosts without a scope all start with a fresh snapshot.

The host's `accessToken` callback obtains credentials for the configured HTTPS origin (HTTP loopback is supported for local testing). If a request receives a 401, the callback receives the rejected token so the host can coalesce refreshes. Reads may retry once with a new token. A write returns its original authorization failure so that the caller decides whether to repeat the action. Requests from other usage integrations retain their own credentials and transport.

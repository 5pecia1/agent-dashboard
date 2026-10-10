# tool/visual_qa/

Golden tests (`test/widget_tests/goldens_test.dart`) render with the Ahem fallback font to keep pixels deterministic across hosts. They do not cover real Korean glyph rendering, character composition, font fallback, or visual regressions such as incorrect ellipsis placement.

This directory provides entry points for manual visual QA using `flutter run -t tool/visual_qa/<scenario>_main.dart -d <device>`. Each scenario uses real widgets and Provider overrides. Input and storage isolation vary by scenario; entry points that exercise native features require macOS plugins and the Rust bundle. Run the commands below from `app/flutter_app`.

## Account period dates

```sh
mise exec -- flutter run -d macos -t tool/visual_qa/account_periods_main.dart
```

This scenario renders the real Devin and Grok cards with synthetic period dates and no personal settings or network requests. Switch between Korean and English, missing dates, stale readings, and large text. Resize the window to verify wrapping. The plan and billing period boundaries must remain separate from weekly usage resets. Past dates must remain unchanged; they do not establish a future payment or cancellation.

For screenshot-only environments, pass `--dart-define=QA_ENGLISH=true`, `--dart-define=QA_STALE=true`, `--dart-define=QA_MISSING=true`, `--dart-define=QA_LARGE_TEXT=true`, or `--dart-define=QA_CARD_WIDTH=320` to select the initial scenario without clicking controls.

## Switch to a task window from the tray

```sh
mise exec -- flutter run -d macos -t tool/visual_qa/window_navigation_main.dart
```

This scenario uses the real tray and macOS window discovery and focus. Server requests, personal settings, connection rules, and read tracking are isolated in memory. Grant Accessibility permission to the running app. When a build's code signature changes, the permission shown in Settings may differ from the effective permission; query it again to confirm.

1. Open two VS Code windows and select an unacknowledged tray item. Choose Code in the app filter, select a window, and save a title rule.
2. Select another agent's item and confirm that it shares the rule for the same host and project. Check both `Native focus: focused` and the actual window brought to the foreground.
3. Reset unread state, press `5초 뒤 새 알림` (new notification in five seconds), and open the tray. After the new notification arrives, click the item displayed before it and confirm that `latest=30`, `seen=10`, and `unread=true` remain.
4. Test a minimized window, a hidden app, another Space, full screen, a window closed during selection, missing permission, and cancellation. Failed or canceled focus attempts must not mark the item as read.
5. Rebuild the normal `lib/main.dart` entry point for production. Do not leave a QA entry point installed as the production app.

## Open a task window from a macOS banner

```sh
mise exec -- flutter run -d macos -t tool/visual_qa/notification_window_main.dart
```

To use another default target, add `--dart-define=QA_WINDOW_APP=com.microsoft.VSCode --dart-define='QA_WINDOW_TITLE=Exact window title to verify'` to the run or build command. This default rule survives quitting and relaunching the same QA bundle. Do not store real window titles in source code.

This entry point uses real macOS local banners and window discovery and focus. It blocks server requests, does not read personal settings or tokens, and keeps settings, rules, and read tracking in memory. Check both `network sends=0` and `Blocked HTTP requests`. The screen's notification backend (`알림 백엔드`) must be `flutterLocalNotifications` to test banner clicks; `osascript` has no click callback. Before starting, enable notifications for the app in macOS Settings. If no banner appears, check the notification style and Focus mode; look for previously delivered notifications in Notification Center. Record an unverified backend or notification permission as incomplete environment setup.

First quit any production app with the same app ID. A QA build that changes the code signature may report `trusted=false` even when Accessibility Settings shows permission enabled. Have the user confirm permission for the actual QA app in macOS Settings, then query it again. If necessary, remove the old entry and add the running bundle. The user must approve any system authentication request; do not modify the permission database directly.

1. Open a VS Code window for QA. The default rule matches app `com.microsoft.VSCode` and the exact title `Dashboard`. For another title, use `연결 대상 확인·변경` (check or change target) and save an in-memory rule. Confirm that the screen uses the fixed fixture values `my-dashboard`, `notification-qa.local`, and `/visual-qa/my-dashboard`, and that the target remains visible while scrolling the window list.
2. Leave `가짜 동기화 목록에 세션 포함` (include session in fake sync list) off and press `배너 보내기 (전이 10)` (send banner, transition 10). Click the banner and confirm that the selected task window comes forward and `Native focus: focused` appears. It must open the task window directly without passing through dashboard session details. Even with `cachedSessions=0`, `Seen` must record the original upper bound `2000000010`.
3. Reset read tracking, send another banner, and press `새 전이 30` (new transition 30). Clicking the earlier banner must leave `latest=2000000030`, `seen=2000000010`, and `unread=true`. For a minimized or hidden target, check both the restored window and `Native focus: focused`. If the window closes during selection, the app must report focus failure. Failure or cancellation must not add a `Seen` record.
4. Test clicks after quit by letting the OS relaunch **the same QA bundle**. Press `배너 보내기 → Cmd+Q 종료` (send banner, then quit with Cmd+Q), quit the app completely, and click the QA banner in Notification Center. Confirm that the relaunched QA app handles the click after its first frame and opens the actual target window. In-memory rules reset on quit, so use the default `Dashboard` rule or select a window when the chooser appears after relaunch. A production app opening instead does not count as a successful QA result.
5. To verify Release QA from the installation directory, first run the backup commands below and retain the printed path. Build with `mise exec -- flutter build macos --release -t tool/visual_qa/notification_window_main.dart` from `app/flutter_app`. Quit the app, copy `build/macos/Build/Products/Release/my_dashboard.app` to `/Applications/my_dashboard.app`, and launch it. Recheck Accessibility permission after the installation path or signature changes.

```sh
mkdir -p "$HOME/Library/Application Support/my-dashboard/backups"
notification_qa_backup="$(mktemp -d "$HOME/Library/Application Support/my-dashboard/backups/notification-qa.XXXXXX")"
ditto /Applications/my_dashboard.app "$notification_qa_backup/my_dashboard.app"
echo "$notification_qa_backup"
```

After verification, quit the QA app and rebuild and run the normal `lib/main.dart` entry point from the repository root. Confirm that the production app can query Accessibility permission. These commands build and launch the current production source. If the build fails and you need the previous installation, quit the running app and restore `my_dashboard.app` from the saved `notification_qa_backup` directory to `/Applications`. In-memory rules are not written to the production settings file.

```sh
cd app
mise run build
open flutter_app/build/macos/Build/Products/Release/my_dashboard.app
```

Clicking an already-delivered local banner after quit is separate from receiving a new APNs banner while the app is closed. This entry point does not register for APNs. APNs verification needs separate signing, entitlements, and server Firebase configuration; successful local banners do not establish APNs behavior. See [notification click handling](../../lib/src/ui/notification_click_actions.dart) and the [regression tests](../../test/widget_tests/notification_app_wiring_test.dart) for delivery and read-tracking boundaries.

## Check sync errors and server changes in an isolated Profile app

The integration targets use the real application entry point, Rust translations, native plugins, timers, configuration files, and loopback HTTP servers. Each run needs a fresh temporary HOME containing `.my-dashboard-qa-home`. Profile mode avoids pausing the Rust bridge's initialization isolate during desktop integration testing. Screenshots and request observations are written to `MY_DASHBOARD_QA_OUT`.

Run from `app/flutter_app`. Create a separate bundle ID before building; these targets do not need to replace the installed application:

```sh
qa_original_home="$HOME"
qa_home="$(mktemp -d)"
touch "$qa_home/.my-dashboard-qa-home"
qa_settings="$(mktemp)"
cat > "$qa_settings" <<'XCCONFIG'
PRODUCT_BUNDLE_IDENTIFIER = io.github.5pecia1.mydashboard.qa64
PRODUCT_DISPLAY_NAME = Dashboard QA64
XCCONFIG

mise exec -- env HOME="$qa_home" \
  PUB_CACHE="${PUB_CACHE:-$qa_original_home/.pub-cache}" \
  CARGO_HOME="${CARGO_HOME:-$qa_original_home/.cargo}" \
  RUSTUP_HOME="${RUSTUP_HOME:-$qa_original_home/.rustup}" \
  XCODE_XCCONFIG_FILE="$qa_settings" \
  MY_DASHBOARD_QA_SCENARIO=transport MY_DASHBOARD_QA_LANG=en \
  MY_DASHBOARD_QA_OUT="$qa_home/evidence" \
  flutter drive --profile --no-pub -d macos \
    --target integration_test/sync_error_locale_qa_test.dart \
    --driver test_driver/sync_qa_driver.dart
```

Repeat with a fresh HOME for `transport`, `timeout`, `malformed`, `protocol_newer`, `protocol_older`, and `unexpected`, in `en` and `ko`. Every case checks the first error screen, recovery, and the stale-data banner. Runtime diagnostic text may be truncated; the localized description, update direction, window bounds, and screenshots need review. Missing QA environment variables fail the run instead of silently skipping it.

For native notification delivery, use target `integration_test/notification_server_switch_qa_test.dart`, scenario `notification_server_switch`, and add `MY_DASHBOARD_QA_BUNDLE_ID=io.github.5pecia1.mydashboard.qa64`. The running application's Info.plist must match that identifier before the test inspects or clears its three fixture notification IDs. If permission is missing, the QA dialog opens that application's own notification settings or requests permission; allow notifications for the verified QA app. Real device pointer events are enabled for this interactive target.

The native case verifies A:901, B:6, a repeated B:6, and B:7 through production sync and notification code. A transparent channel recorder forwards the original messages to the native plugin and checks cancel/show counts; delivered notification IDs, bodies, and server origins come from macOS. When `await-old-source-click` appears, open Notification Center and click `QA A alert 901: old server` within ten minutes. The previous-server notice must appear without a seen or ack request, and B's read markers must stay unchanged. Do not substitute a direct callback for this OS click. Receiving APNs while the app is closed remains a separate check requiring APNs signing and server configuration.

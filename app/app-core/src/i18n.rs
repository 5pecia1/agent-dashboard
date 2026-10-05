//! my_dashboard 번역 카탈로그 + 조회 메커니즘.
//!
//! 조회 메커니즘(폴백 체인)과 카탈로그 내용을 크레이트 경계로 나누는 큰
//! 프로젝트도 있다 — surface마다 서로 다른 카탈로그를 두고 싶을 때(예:
//! 데스크톱 전용 문구가 별도 CLI 카탈로그로 새면 안 될 때) 그 구분이 값어치를
//! 한다. 이 스타터는 surface가 아직 하나(Flutter, `app-frb`를 통해)뿐이라
//! 그 구분을 유지할 이유가 없어 메커니즘과 카탈로그를 한 모듈로 합쳤다.
//! surface가 늘어나 카탈로그가 서로 새면 안 되는 시점이 오면, 이 모듈을
//! 메커니즘 부분(`t`/`t_args`/`substitute_args`)과 카탈로그 부분(EN/KO
//! 테이블)으로 다시 나누는 걸 고려한다.
//!
//! 조회 `(locale, key)`의 폴백 체인:
//!   1. `(locale, key)` 직접 히트.
//!   2. `(Locale::En, key)` — 지원하는 모든 로케일은 최소 English 키
//!      커버리지를 가정하고, 번역이 빠졌을 때 화면을 비우는 대신 English로
//!      우아하게 대체한다.
//!   3. `key` 원문 대신 눈에 띄는 표식([`MISSING_KEY_MARKER`]) — 오타난
//!      조회가 조용히 빈 문자열이 되는 대신 화면에 드러나야 디버깅된다.
//!
//! 저장 형태: 로케일별 `phf::Map<&'static str, &'static str>` 컴파일타임
//! perfect-hash 조회. 키를 추가할 때는 [`EN`]과 [`KO`] 양쪽에 항목을 넣어야
//! 하며, `모든_영어_키는_하나의_한국어_번역을_가진다` 테스트가 그 계약을
//! 고정한다.

use phf::{Map, phf_map};

/// 지원 로케일. 문자열 대신 열거형으로 고정해 오타·미지원 로케일이
/// 컴파일 타임에 걸러지게 한다.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum Locale {
    En,
    Ko,
}

/// 두 폴백이 모두 실패했을 때 반환하는, 화면에서 눈에 띄는 표식.
const MISSING_KEY_MARKER: &str = "???";

/// `key`를 `locale`로 조회한다 — 없으면 English로, 그래도 없으면
/// [`MISSING_KEY_MARKER`]로 대체한다.
///
/// `&'static str`을 반환해(`String`이 아니라) 인자 치환이 필요 없는
/// 호출자는 할당 비용을 물지 않는다.
#[must_use]
pub fn t(locale: Locale, key: &str) -> &'static str {
    if let Some(hit) = catalog(locale, key) {
        return hit;
    }
    if locale != Locale::En
        && let Some(hit) = catalog(Locale::En, key)
    {
        return hit;
    }
    MISSING_KEY_MARKER
}

/// `key`를 조회한 뒤 `{name}` 자리표시자를 `args`로 치환한다.
///
/// 일치하지 않는 자리표시자는 그대로 남긴다(`{needle}`이 리터럴 텍스트로
/// 남는다) — 누락된 인자가 조용히 사라지는 대신 화면에 드러나야 한다.
/// `args`에 있지만 템플릿에 없는 이름은 무시한다.
#[must_use]
pub fn t_args(locale: Locale, key: &str, args: &[(&str, &str)]) -> String {
    substitute_args(t(locale, key), args)
}

/// 카탈로그 조회 어댑터 — 로케일별 [`phf::Map`]으로 분기한다.
fn catalog(locale: Locale, key: &str) -> Option<&'static str> {
    match locale {
        Locale::En => EN.get(key).copied(),
        Locale::Ko => KO.get(key).copied(),
    }
}

fn substitute_args(template: &str, args: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let Some(close) = after.find('}') else {
            // 짝없는 여는 중괄호 — 나머지를 그대로 내보내고 스캔을 멈춘다.
            out.push('{');
            out.push_str(after);
            return out;
        };
        let name = &after[..close];
        if let Some((_, value)) = args.iter().find(|(n, _)| *n == name) {
            out.push_str(value);
        } else {
            // 디버깅을 위해 자리표시자를 그대로 남긴다.
            out.push('{');
            out.push_str(name);
            out.push('}');
        }
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    out
}

// ─── 카탈로그 테이블 ────────────────────────────────────────────
//
// 키는 점(dot) 네임스페이스 형태로 유지한다: `<화면_또는_영역>.<역할>[.detail]`.
// 두 맵은 같은 키 집합을 가져야 하며, 아래 대칭성 테스트가 그걸 고정한다.
//
// `state.*` 10개 키(상태 라벨 6종 + push 문구 4종)는
// `contracts/dashboard-protocol.v1.json`의 `i18n` 절을 전량 옮긴 것이다 —
// 한국어 문구는 그 계약의 `ko` 값과 바이트 단위로 같아야 하고, 아래
// `dashboard_i18n` 테스트 모듈이 계약 파일을 직접 읽어 대조한다. 계약에는
// `en`이 없어(default_locale이 `ko`) 영어 문구는 이 카탈로그가 최초
// 출처다. `capability.web_only`는 `capability.rs`의 `Host::Web` 확장이
// 추가한 `UnsupportedReason::NoBrowserHost`에 대응하는 화면 문구다.

static EN: Map<&'static str, &'static str> = phf_map! {
    "app.title"            => "Agent Dashboard",
    "capability.available" => "Available",
    "capability.desktop_only" => "Not available in this browser",
    "capability.web_only"  => "Only available in a browser",
    "capability.not_configured" => "Not available in this app",
    "capability.unknown" => "Feature unavailable",
    "action.save"          => "Save",
    "action.cancel"        => "Cancel",
    "error.unknown_item"   => "Unknown item: {id}",
    "error.invalid_input"  => "Invalid input: {reason}",
    "state.idle"           => "Idle",
    "state.working"        => "Working",
    "state.waiting_input"  => "Waiting for input",
    // "Done"은 "작업이 끝났다"로 읽혀 계약의 뜻("턴 실행을 마쳤다. 세션
    // 자체는 살아 있다.", terminal:false)과 어긋난다 — 사용자가 "일하는
    // 중인데 왜 Done이냐"고 혼동한 원인. "Turn finished"로 바꿔 턴 단위
    // 종료임을 명시하고, "ended"를 피해 `state.ended`("Session ended")와
    // 헷갈리지 않게 한다.
    "state.done"           => "Turn finished",
    "state.ended"          => "Session ended",
    "state.stalled"        => "Possibly stalled",
    // 제목은 project로 시작한다(정본 계약 i18n의 $note 참고): 알림 센터는
    // 제목 뒤쪽부터 잘라내고 host는 한 기계의 모든 세션이 공유하는 값이라,
    // 배너끼리 구분되는 유일한 조각인 project가 맨 앞에 있어야 한다.
    "push.title"           => "{project} · {host} · {label}",
    "push.title_no_host"   => "{project} · {label}",
    "push.title_titled"    => "{project} · {display_title}",
    "push.body_fallback"   => "{source} session is now '{label}'.",
    "push.test_body"       => "This is a test notification. If you see this, device registration is working.",

    // ── action (T15: shared verbs across screens) ────────────────────
    "action.retry"         => "Retry",

    // ── session.list (T15: sessions_page.dart) ───────────────────────
    "session.list.title"        => "Sessions",
    "session.list.action.setup" => "Setup",
    "session.list.action.diagnostics" => "Diagnostics",
    "session.list.action.refresh" => "Refresh all",
    "session.list.loading"      => "Loading sessions…",
    "session.list.empty.title"  => "No sessions yet",
    "session.list.empty.body"   => "Sessions will appear here once an agent starts.",
    "session.list.error.title"  => "Couldn't sync",

    // ── sync error detail (sessions_page.dart: syncErrorDetailText) ───
    // Shown under `session.list.error.title` and in the stale-data banner.
    // {method} and {path} name the request. {cause} and {detail} are the
    // runtime's own error text (for example `SocketException: ...`) and are
    // shown as is, untranslated. transport_failed also covers failures after
    // the server started answering (a body that is not UTF-8, a connection
    // closed mid-body), so it does not claim the server was unreachable.
    // The app accepts only its own protocol major, so the protocol sentence
    // names the side that is behind.
    // unexpected is the sentence for a failure that is not an API failure (a
    // bug, a type mismatch while reading a response, a provider error). The
    // runtime's own text for it is a developer dump, so it takes no
    // placeholders and the app only logs it.
    "sync.error.transport_failed" => "Request failed: {method} {path} ({cause})",
    "sync.error.timeout" => "No response within {timeout_ms} ms: {method} {path}",
    "sync.error.malformed_response" => "The response wasn't a JSON object: {method} {path} ({detail})",
    "sync.error.protocol_update_app" => "The server and this app use different protocol versions (server: {server_version}, app: {supported_version}). Update the app.",
    "sync.error.protocol_update_server" => "The server and this app use different protocol versions (server: {server_version}, app: {supported_version}). Update the server.",
    "sync.error.unexpected" => "Syncing failed unexpectedly. Try again.",

    // ── session.card (T15: widgets/session_card.dart) ─────────────────
    "session.card.host_unknown" => "Unknown host",
    "session.card.no_message"   => "No messages yet",
    "session.card.stale_badge"  => "Stale",
    // working 카드의 "마지막 신호 경과" 라벨. {time}은
    // `relative_time.dart`(time.* 키)가 이미 만든 문구를 그대로 끼운다.
    "session.card.last_signal"  => "Last signal {time}",
    // waiting_input 카드의 상태 칩에 다는 툴팁 — 탭하면 UserAck를 보내
    // working으로 전환한다는 것을 알린다(UserAck-impl). 다른 상태의 칩은
    // 탭할 수 없으므로 이 키를 쓰지 않는다.
    "session.card.ack_tooltip"  => "Mark as responded — switch to in progress",
    // 0004 삭제 UI: 카드 hover ×([session_card.dart]의
    // `_DeleteHoverButton`) 툴팁. AppBar 쪽(`session.detail.delete_tooltip`)과
    // 문구는 같지만 호출 맥락이 달라 키를 따로 둔다(위 tray.mute_30 항목
    // 옆 주석과 같은 이유).
    "session.card.delete_tooltip" => "Delete session",
    "session.group.count"       => "{count} session(s)",
    "session.group.unknown_project" => "Unknown project",
    "session.source.claude_code" => "Claude Code",
    "session.source.codex"      => "Codex",
    "session.source.devin"      => "Devin",
    "session.source.generic"    => "Generic",
    "session.source.grok"       => "Grok",
    "session.source.antigravity" => "Antigravity",

    // ── time (T15: relative timestamps) ───────────────────────────────
    "time.just_now"    => "Just now",
    "time.minutes_ago"  => "{minutes}m ago",
    "time.hours_ago"    => "{hours}h ago",
    "time.days_ago"     => "{days}d ago",

    // ── catchup (T15: widgets/catchup_panel.dart) ─────────────────────
    "catchup.title"          => "What happened while you were away",
    "catchup.count"           => "{count} unread update(s)",
    "catchup.empty"           => "No new alerts",
    "catchup.toggle_expand"   => "Expand",
    "catchup.toggle_collapse" => "Collapse",

    // ── alert.banner (T15: widgets/alert_banner.dart) ─────────────────
    "alert.banner.needs_setup.title"    => "Setup needed",
    "alert.banner.needs_setup.body"     => "Check your server URL and token in Setup.",
    "alert.banner.needs_setup.action"   => "Open Setup",
    "alert.banner.stale_data.title"        => "Sync issue",
    "alert.banner.stale_data.last_synced"  => "Last synced {time}.",
    "alert.banner.stale_data.never_synced" => "Not synced yet this session.",
    // hook_skew: some machines are running a hook older than the one the
    // server is currently serving.
    "alert.banner.hook_skew.title" => "Hook update needed",
    "alert.banner.hook_skew.body"  => "Outdated hook on: {hosts}. Re-run the one-line command there.",
    // copy_tooltip/copied: 배너의 복사 아이콘 — 평소엔 tooltip, 복사
    // 직후 잠깐 copied로 바뀐다(alert_banner.dart의 _CopyUpdateCommandButton).
    "alert.banner.hook_skew.copy_tooltip" => "Copy update command",
    "alert.banner.hook_skew.copied"       => "Copied",

    // ── session.detail (T15: session_detail_page.dart) ────────────────
    "session.detail.title"               => "Session",
    "session.detail.state_label"         => "State",
    "session.detail.project_label"       => "Project",
    "session.detail.host_label"          => "Host",
    "session.detail.source_label"        => "Source",
    "session.detail.updated_label"       => "Updated",
    "session.detail.timeline_title"      => "Timeline",
    "session.detail.timeline_empty"      => "No recent transitions for this session.",
    "session.detail.timeline_limited_note" => "This timeline shows unacknowledged alerts. Saved event history is below.",
    "session.detail.not_found"           => "Session not found.",
    // 0004 삭제 UI: 상세 화면 AppBar 삭제 아이콘 툴팁.
    "session.detail.delete_tooltip"      => "Delete session",

    "session.history.title"       => "Saved history",
    "session.history.all"         => "All logs",
    "session.history.prompts"     => "My messages",
    "session.history.user_prompt" => "My message",
    "session.history.refresh"     => "Refresh history",
    "session.history.older"       => "Load older records",
    "session.history.empty"       => "No saved records.",
    "session.history.error"       => "Could not load history.",

    // ── session.delete (0004: shared confirmation dialog, session_card.dart
    // + session_detail_page.dart via widgets/delete_session_dialog.dart) ──
    "session.delete.dialog_title"   => "Delete session?",
    "session.delete.dialog_body"    => "The session record will be deleted from the server. A session that's still alive will reappear on its next event.",
    "session.delete.confirm_action" => "Delete",

    // ── config read failure (ui/config_read_failure.dart, integration panels) ──
    // Shown instead of an empty form when the saved settings exist but cannot
    // be read; nothing is written until a read succeeds. Only access errors
    // retry automatically, so the corrupt hint asks for an explicit Retry.
    // An automatic retry that finds nothing stored stops and shows the
    // nothing_stored hint: the user may be in the middle of restoring a file.
    // A browser has no file to move, so web gets its own corrupt hint.
    "config.read_failed.title"       => "Couldn't read saved settings",
    "config.read_failed.body"        => "Nothing was changed or overwritten.",
    "config.read_failed.access_hint" => "Check that the location below is accessible. Retrying automatically.",
    "config.read_failed.corrupt_hint" => "The saved settings are damaged. Repair them or move them aside, then choose Retry.",
    "config.read_failed.corrupt_hint_web" => "The settings saved in this browser are damaged. To start over, delete only the entry shown below from this site's local storage in the browser's developer tools, then choose Retry. Clearing all site data also deletes the backup copy.",
    "config.read_failed.nothing_stored_hint" => "Nothing is saved at this location right now. If you are restoring your settings, put them back first, then choose Retry. If nothing is there when you choose Retry, the app starts without saved settings.",
    "config.read_failed.boot_note"   => "Sync and notifications stay paused until the settings can be read.",
    "config.read_failed.inline"      => "Couldn't read saved settings. Nothing was changed.",

    // ── setup (T15: setup_page.dart) ───────────────────────────────────
    "setup.title"                    => "Setup",
    "setup.section.server"           => "Server",
    "setup.server_url_label"         => "Server URL",
    "setup.client_token_label"       => "Client token",
    "setup.save_success"             => "Saved.",
    "setup.save_error"               => "Couldn't save settings.",
    // Shown instead of setup.save_success when the saved server address can't
    // be read as a URL (for example `https://host:443x`). The text is saved,
    // but the app doesn't connect to it.
    "setup.server_url_invalid"       => "Saved, but the server address can't be read. Check the address and save again.",
    "setup.section.notifications"    => "Notifications",
    "setup.notifications_enabled_label" => "Enable notifications",
    "setup.hide_content_label"       => "Hide message content in notifications",
    "setup.device_label_label"       => "Device label",
    "setup.test_notification_action" => "Send test notification",
    "setup.test_notification_success" => "Test notification sent.",
    "setup.test_notification_error"  => "Couldn't send test notification.",
    "setup.notification_permission_denied_title" => "macOS notification permission is turned off.",
    "setup.notification_permission_denied_body" => "Notifications won't be sent until you allow them in System Settings.",
    "setup.notification_permission_denied_action" => "Open System Settings",
    "setup.notification_osascript_fallback_note" => "Notifications are shown through a fallback mode that can't open the app when tapped (appears as being sent by Script Editor).",
    "setup.section.mute"             => "Mute",
    "setup.mute_30_action"           => "Mute 30 min",
    "setup.mute_60_action"           => "Mute 60 min",
    "setup.mute_success"             => "Muted.",
    "setup.mute_error"               => "Couldn't update mute.",
    // 결함 수정(뮤트 무표시·해제 불가): 설정 화면의 상시 뮤트 상태 표시 +
    // 해제 버튼/결과. `{time}`은 `util/mute_time.dart`의 순수 함수가 만든
    // "HH:mm"(로컬 시각)이지 번역 키가 아니다.
    "setup.mute_status_muted"        => "Muted until {time}.",
    "setup.mute_status_unmuted"      => "Not muted.",
    "setup.unmute_action"            => "Unmute now",
    "setup.unmute_success"           => "Unmuted.",
    "setup.unmute_error"             => "Couldn't unmute.",
    // TASK TRAY-impl: macOS 메뉴 바 트레이 아이콘의 우클릭 컨텍스트 메뉴
    // 3개 라벨. 위젯 트리 밖(부팅 이후 `_AppHomeState.initState`)에서
    // `tRead`로 한 번만 읽어 메뉴를 굽는다 — `setup.mute_30_action`과 문구는
    // 같지만 키를 따로 둔다: 이 문구는 트레이 메뉴 항목이고 설정 화면의
    // 버튼과는 호출 맥락이 다르며, 나중에 둘 중 하나만 바뀔 수 있다(예:
    // 트레이는 공간이 좁아 "Mute 30m"처럼 더 축약될 수 있다).
    "window.application" => "Target app",
    "window.all_apps" => "All apps",
    "window.connect"                => "Connect a window",
    "window.connect_project"        => "Connect a work window for {project}",
    "window.target_project"         => "Project to connect",
    "window.alert_host"             => "Alert source host",
    "window.identity_unknown"       => "Unknown",
    "window.local_windows"          => "App and window to open on this Mac",
    "window.scope_note"             => "A saved connection applies to all sessions with this project and host.",
    "notification.target_missing"   => "The project information is missing, so a work window cannot be connected. Check the session details.",
    "notification.open_failed"      => "Could not open the alert's work window",
    "notification.server_changed"   => "This alert came from a previous server connection. Check the current session.",
    "window.manage"                 => "Window connections",
    "window.manage_note"            => "On this Mac, all sessions with the same host and full project path share a window connection, including sessions from different agents.",
    "window.add"                    => "Add connection",
    "window.choose"                 => "Choose window",
    "window.disconnect"             => "Remove connection",
    "window.host"                   => "Host",
    "window.project"                => "Full project path",
    "window.no_connections"         => "No projects or saved window connections yet.",
    "window.unconnected"            => "No window connected",
    "window.missing_identity"       => "The host or project path is missing. You can open a window without saving a connection.",
    "window.permission"             => "Allow Agent Dashboard in System Settings → Privacy & Security → Accessibility to find and switch windows.",
    "window.open_settings"          => "Open Accessibility settings",
    "window.permission_retry"       => "After granting access, choose Find again.",
    "window.partial"                => "Some windows could not be checked. Automatic switching is paused; choose a window or find again.",
    "window.saved_rule"             => "Saved condition: {app} · {title}",
    "window.search"                 => "Search by app or window title",
    "window.refresh"                => "Find again",
    "window.show_all"               => "Show all windows",
    "window.none"                   => "No matching windows. Open the target window, then find again, or change your search.",
    "window.untitled"               => "Untitled window",
    "window.remember"               => "Save this connection for all sessions with this host and project",
    "window.title_pattern"          => "Window title contains",
    "window.exact"                  => "Match the entire title",
    "window.match_count"            => "Matching windows: {count}",
    "window.rule_note"              => "Matching is case-sensitive and uses the text literally. Enable entire-title matching to require an exact title. If several windows match, you will choose one.",
    "window.rule_required"          => "Choose an app window and enter a title condition to save the connection.",
    "window.open"                   => "Switch to window",
    "window.save_and_open"          => "Save and switch to window",
    "window.failed"                 => "Could not find or switch to the window. Check Accessibility permission and whether the target window is still open, then try again.",
    "window.save_failed"            => "Could not save connection changes. Check the storage location and permissions, then try again.",
    "window.load_failed"            => "Could not read saved window connections. The file has not been overwritten. Check or restore ~/.local/state/my-dashboard/window-connections.json, then find again.",
    "window.focus_failed"           => "Could not switch windows",
    "window.stale"                  => "The selected window was closed or changed. Find it again and reconnect.",
    "window.show_session"           => "View session details",
    "tray.open"                      => "Open",
    "tray.mute_30"                   => "Mute notifications 30 min",
    // 결함 수정(뮤트 해제 불가): 음소거 중일 때 `tray.mute_30` 자리를
    // 대신하는 항목(`tray_native.dart`의 `buildTrayMenuItems` 참고).
    "tray.mute_unmute"               => "Unmute notifications (until {time})",
    "tray.quit"                      => "Quit",
    // TASK TRAY-unseen: menu-bar badge tooltip. `{count}` is the number of
    // unseen (unread) sessions - the same number the badge title shows next
    // to the icon. This is a different axis from the icon variant itself,
    // which still reflects attention (waiting_input + stalled) regardless
    // of read status - see `tray_native.dart` for the split.
    "tray.tooltip_unseen"            => "Agent Dashboard - {count} unread session update(s)",
    "tray.tooltip_idle"              => "Agent Dashboard - no unread updates",
    // Tray unread-session items: one top-level context-menu row per
    // unseen-reportable session (the same set `trayBadgeCountsListenable`
    // counts), wrapped in separators under "Open" - no submenu. Clicking a
    // row switches to its connected window, then marks the displayed update
    // seen on success - see `tray_native.dart`'s buildTrayMenuItems.
    // Item label: "{project} — {state}". {project} is the path basename
    // (or session id fallback), {state} is already-translated via state.* keys.
    "tray.unseen_item"               => "{project} — {state}",
    // TASK D-app (A안 설계 ④): 상주 동작은 이제 안내 문구가 아니라 토글이다 —
    // `setup.resident_note`는 그 토글의 설명(subtitle)으로 흡수됐다.
    "setup.resident_label"           => "Keep running in the background when the window is closed",
    "setup.resident_note"            => "Notifications keep coming in the background even if you close the window. Fully quitting (Cmd+Q) means you'll see everything at once next time you open it.",
    "setup.resident_error"           => "Couldn't change the background setting.",
    // Theme mode toggle (system/light/dark), persisted to
    // `DashboardConfigValues.themeMode` and applied to `MaterialApp.themeMode`.
    "setup.section.appearance"       => "Appearance",
    "setup.theme_mode_system"        => "System",
    "setup.theme_mode_light"         => "Light",
    "setup.theme_mode_dark"          => "Dark",
    "setup.theme_mode_error"         => "Couldn't change the theme setting.",
    // UI display language toggle (system/ko/en), persisted to
    // `DashboardConfigValues.uiLang` and mirrored to the server's
    // `dashboard_settings.ui_lang` (Opus-adjudicated final directive [모델]).
    // `setup.ui_lang_system` is the only label routed through the catalog -
    // the ko/en options name themselves in their own language and are never
    // translated (see `ui/setup_page.dart`'s `// i18n-exempt:` comment).
    "setup.section.language"         => "Language",
    "setup.ui_lang_system"           => "System",
    "setup.ui_lang_error"            => "Couldn't change the language setting.",
    // TASK P-impl (4): one-line notification-path status, same spot/weight as
    // `setup.notification_osascript_fallback_note` right above it.
    "setup.notification_path_polling" => "Notification path: polling (8/30s)",
    "setup.notification_path_apns"   => "Notification path: APNs",
    // T17f: web-only. The browser permission prompt may only appear behind this
    // button - never on boot (see lib/src/platform/web_push_web.dart).
    "setup.section.web_push"         => "Browser notifications",
    "setup.web_push_action"          => "Allow notifications in this browser",
    "setup.web_push_registered"      => "This browser is registered for notifications.",
    "setup.web_push_permission_denied" => "The browser blocked notification permission.",
    "setup.web_push_unavailable"     => "Push isn't set up on the server; the app keeps polling.",
    "setup.web_push_error"           => "Couldn't register this browser for notifications.",

    // ── diagnostics (T15: diagnostics_page.dart) ───────────────────────
    "diagnostics.title"           => "Diagnostics",
    "diagnostics.loading"         => "Loading diagnostics…",
    "diagnostics.error"           => "Couldn't load diagnostics.",
    "diagnostics.last_event_label" => "Last event",
    "diagnostics.max_transition_label" => "Max transition id",
    "diagnostics.pruned_below_label" => "Pruned below id",
    "diagnostics.device_failures_label" => "Device failures",
    "diagnostics.subscription_failures_label" => "Subscription failures",
    "diagnostics.channels_title"  => "Push channels",
    "diagnostics.channel_ready"   => "Ready",
    "diagnostics.channel_not_ready" => "Not ready",
    "diagnostics.table_counts_title" => "Table counts",
    "diagnostics.last_push_title" => "Last push",
    "diagnostics.last_push_none"  => "No push sent yet.",
    "diagnostics.none_value"      => "—",
};

static KO: Map<&'static str, &'static str> = phf_map! {
    "app.title"            => "Agent Dashboard",
    "capability.available" => "사용할 수 있습니다",
    "capability.desktop_only" => "이 브라우저에서는 사용할 수 없습니다",
    "capability.web_only"  => "브라우저에서만 사용할 수 있습니다",
    "capability.not_configured" => "이 앱에서는 사용할 수 없습니다",
    "capability.unknown" => "사용할 수 없는 기능입니다",
    "action.save"          => "저장",
    "action.cancel"        => "취소",
    "error.unknown_item"   => "알 수 없는 항목입니다: {id}",
    "error.invalid_input"  => "입력값이 올바르지 않습니다: {reason}",
    "state.idle"           => "대기",
    "state.working"        => "진행 중",
    "state.waiting_input"  => "질문·승인 대기",
    "state.done"           => "실행 마침",
    "state.ended"          => "세션 종료",
    "state.stalled"        => "멈춘 듯",
    // 제목은 project로 시작한다(정본 계약 i18n의 $note 참고): 알림 센터는
    // 제목 뒤쪽부터 잘라내고 host는 한 기계의 모든 세션이 공유하는 값이라,
    // 배너끼리 구분되는 유일한 조각인 project가 맨 앞에 있어야 한다.
    "push.title"           => "{project} · {host} · {label}",
    "push.title_no_host"   => "{project} · {label}",
    "push.title_titled"    => "{project} · {display_title}",
    "push.body_fallback"   => "{source} 세션이 '{label}' 상태가 되었습니다.",
    "push.test_body"       => "테스트 알림입니다. 이 문구가 보이면 기기 등록이 살아 있습니다.",

    // ── action (T15) ───────────────────────────────────────────────────
    "action.retry"         => "다시 시도",

    // ── session.list (T15) ─────────────────────────────────────────────
    "session.list.title"        => "세션",
    "session.list.action.setup" => "설정",
    "session.list.action.diagnostics" => "진단",
    "session.list.action.refresh" => "전체 새로고침",
    "session.list.loading"      => "세션을 불러오는 중…",
    "session.list.empty.title"  => "아직 세션이 없습니다",
    "session.list.empty.body"   => "에이전트가 시작되면 여기에 세션이 나타납니다.",
    "session.list.error.title"  => "동기화할 수 없습니다",

    // ── sync error detail ────────────────────────────────────────────────
    "sync.error.transport_failed" => "요청이 실패했습니다: {method} {path} ({cause})",
    "sync.error.timeout" => "{timeout_ms}ms 안에 응답이 없습니다: {method} {path}",
    "sync.error.malformed_response" => "응답이 JSON 객체가 아닙니다: {method} {path} ({detail})",
    "sync.error.protocol_update_app" => "서버와 앱의 프로토콜 버전이 다릅니다(서버: {server_version}, 앱: {supported_version}). 앱을 업데이트하세요.",
    "sync.error.protocol_update_server" => "서버와 앱의 프로토콜 버전이 다릅니다(서버: {server_version}, 앱: {supported_version}). 서버를 업데이트하세요.",
    "sync.error.unexpected" => "동기화 중 예상하지 못한 오류가 발생했습니다. 다시 시도하세요.",

    // ── session.card (T15) ──────────────────────────────────────────────
    "session.card.host_unknown" => "호스트 알 수 없음",
    "session.card.no_message"   => "아직 메시지가 없습니다",
    "session.card.stale_badge"  => "오래됨",
    "session.card.last_signal"  => "마지막 신호 {time}",
    "session.card.ack_tooltip"  => "응답했음으로 표시 — 진행 중으로 전환",
    "session.card.delete_tooltip" => "세션 삭제",
    "session.group.count"       => "세션 {count}개",
    "session.group.unknown_project" => "알 수 없는 프로젝트",
    "session.source.claude_code" => "Claude Code",
    "session.source.codex"      => "Codex",
    "session.source.devin"      => "Devin",
    "session.source.generic"    => "일반",
    "session.source.grok"       => "Grok",
    "session.source.antigravity" => "Antigravity",

    // ── time (T15) ───────────────────────────────────────────────────────
    "time.just_now"    => "방금 전",
    "time.minutes_ago"  => "{minutes}분 전",
    "time.hours_ago"    => "{hours}시간 전",
    "time.days_ago"     => "{days}일 전",

    // ── catchup (T15) ─────────────────────────────────────────────────────
    "catchup.title"          => "그동안 있었던 일",
    "catchup.count"           => "확인하지 않은 알림 {count}건",
    "catchup.empty"           => "새 알림이 없습니다",
    "catchup.toggle_expand"   => "펼치기",
    "catchup.toggle_collapse" => "접기",

    // ── alert.banner (T15) ────────────────────────────────────────────────
    "alert.banner.needs_setup.title"    => "설정이 필요합니다",
    "alert.banner.needs_setup.body"     => "설정에서 서버 주소와 토큰을 확인하세요.",
    "alert.banner.needs_setup.action"   => "설정 열기",
    "alert.banner.stale_data.title"        => "동기화 문제",
    "alert.banner.stale_data.last_synced"  => "마지막 동기화: {time}",
    "alert.banner.stale_data.never_synced" => "이번 세션에서 아직 동기화되지 않았습니다.",
    "alert.banner.hook_skew.title" => "훅 업데이트 필요",
    "alert.banner.hook_skew.body"  => "{hosts}에서 훅이 구버전입니다. 해당 기계에서 curl 원커맨드를 다시 실행하세요.",
    "alert.banner.hook_skew.copy_tooltip" => "업데이트 명령 복사",
    "alert.banner.hook_skew.copied"       => "복사됨",

    // ── session.detail (T15) ────────────────────────────────────────────
    "session.detail.title"               => "세션",
    "session.detail.state_label"         => "상태",
    "session.detail.project_label"       => "프로젝트",
    "session.detail.host_label"          => "호스트",
    "session.detail.source_label"        => "소스",
    "session.detail.updated_label"       => "갱신됨",
    "session.detail.timeline_title"      => "타임라인",
    "session.detail.timeline_empty"      => "이 세션의 최근 전이가 없습니다.",
    "session.detail.timeline_limited_note" => "이 타임라인은 미확인 알림을 보여줍니다. 저장된 이벤트 이력은 아래에서 확인할 수 있습니다.",
    "session.detail.not_found"           => "세션을 찾을 수 없습니다.",
    "session.detail.delete_tooltip"      => "세션 삭제",

    "session.history.title"       => "저장된 이력",
    "session.history.all"         => "전체 로그",
    "session.history.prompts"     => "내 발언",
    "session.history.user_prompt" => "내 발언",
    "session.history.refresh"     => "이력 새로고침",
    "session.history.older"       => "이전 기록 더 보기",
    "session.history.empty"       => "저장된 기록이 없습니다.",
    "session.history.error"       => "이력을 불러오지 못했습니다.",

    // ── session.delete (0004) ───────────────────────────────────────────
    "session.delete.dialog_title"   => "세션을 삭제할까요?",
    "session.delete.dialog_body"    => "서버에서 세션 기록이 삭제됩니다. 살아있는 세션은 다음 이벤트에서 다시 나타납니다.",
    "session.delete.confirm_action" => "삭제",

    // ── config read failure ───────────────────────────────────────────────
    "config.read_failed.title"       => "저장된 설정을 읽을 수 없습니다",
    "config.read_failed.body"        => "아무것도 바꾸거나 덮어쓰지 않았습니다.",
    "config.read_failed.access_hint" => "아래 위치에 접근할 수 있는지 확인하세요. 자동으로 다시 시도합니다.",
    "config.read_failed.corrupt_hint" => "저장된 설정이 손상되었습니다. 고치거나 다른 곳으로 옮긴 뒤 다시 시도를 누르세요.",
    "config.read_failed.corrupt_hint_web" => "이 브라우저에 저장된 설정이 손상되었습니다. 처음부터 시작하려면 브라우저 개발자 도구에서 이 사이트의 로컬 저장소 중 아래 항목만 지운 뒤 다시 시도를 누르세요. 사이트 데이터를 모두 지우면 백업 사본도 함께 지워집니다.",
    "config.read_failed.nothing_stored_hint" => "지금 이 위치에는 저장된 설정이 없습니다. 설정을 복구하는 중이면 먼저 제자리에 둔 뒤 다시 시도를 누르세요. 그때도 아무것도 없으면 저장된 설정 없이 시작합니다.",
    "config.read_failed.boot_note"   => "설정을 읽을 수 있을 때까지 동기화와 알림은 멈춰 있습니다.",
    "config.read_failed.inline"      => "저장된 설정을 읽을 수 없습니다. 아무것도 바꾸지 않았습니다.",

    // ── setup (T15) ───────────────────────────────────────────────────────
    "setup.title"                    => "설정",
    "setup.section.server"           => "서버",
    "setup.server_url_label"         => "서버 주소",
    "setup.client_token_label"       => "클라이언트 토큰",
    "setup.save_success"             => "저장했습니다.",
    "setup.save_error"               => "설정을 저장할 수 없습니다.",
    "setup.server_url_invalid"       => "저장했지만 서버 주소를 읽을 수 없습니다. 주소를 확인하고 다시 저장하세요.",
    "setup.section.notifications"    => "알림",
    "setup.notifications_enabled_label" => "알림 사용",
    "setup.hide_content_label"       => "알림 본문에서 메시지 내용 숨기기",
    "setup.device_label_label"       => "기기 이름",
    "setup.test_notification_action" => "테스트 알림 보내기",
    "setup.test_notification_success" => "테스트 알림을 보냈습니다.",
    "setup.test_notification_error"  => "테스트 알림을 보낼 수 없습니다.",
    "setup.notification_permission_denied_title" => "macOS 알림 권한이 꺼져 있습니다.",
    "setup.notification_permission_denied_body" => "시스템 설정에서 허용하기 전까지 알림이 전송되지 않습니다.",
    "setup.notification_permission_denied_action" => "시스템 설정 열기",
    "setup.notification_osascript_fallback_note" => "지금은 탭해도 앱으로 이동하지 않는 폴백 방식(Script Editor 명의)으로 알림이 표시되고 있습니다.",
    "setup.section.mute"             => "음소거",
    "setup.mute_30_action"           => "30분 음소거",
    "setup.mute_60_action"           => "60분 음소거",
    "setup.mute_success"             => "음소거했습니다.",
    "setup.mute_error"               => "음소거를 변경할 수 없습니다.",
    "setup.mute_status_muted"        => "{time}까지 음소거 중입니다.",
    "setup.mute_status_unmuted"      => "음소거되어 있지 않습니다.",
    "setup.unmute_action"            => "지금 해제",
    "setup.unmute_success"           => "음소거를 해제했습니다.",
    "setup.unmute_error"             => "음소거를 해제할 수 없습니다.",
    "window.application" => "대상 앱",
    "window.all_apps" => "모든 앱",
    "window.connect"                => "창 연결",
    "window.connect_project"        => "{project}의 작업 창 연결",
    "window.target_project"         => "연결 대상 프로젝트",
    "window.alert_host"             => "알림 발생 호스트",
    "window.identity_unknown"       => "확인할 수 없음",
    "window.local_windows"          => "이 Mac에서 열 앱과 창",
    "window.scope_note"             => "연결을 저장하면 같은 프로젝트·호스트의 모든 세션에 적용됩니다.",
    "notification.target_missing"   => "프로젝트 정보를 찾을 수 없어서 작업 창을 연결할 수 없습니다. 세션 정보를 확인해 주세요.",
    "notification.open_failed"      => "알림의 작업 창을 열지 못했습니다",
    "notification.server_changed"   => "이 알림은 이전 서버 연결에서 온 알림입니다. 현재 세션을 확인해 주세요.",
    "window.manage"                 => "창 연결 관리",
    "window.manage_note"            => "이 Mac에서는 호스트와 프로젝트 전체 경로가 같은 모든 세션이 창 연결을 공유합니다. 에이전트가 달라도 같은 연결을 사용합니다.",
    "window.add"                    => "연결 추가",
    "window.choose"                 => "창 선택",
    "window.disconnect"             => "연결 해제",
    "window.host"                   => "호스트",
    "window.project"                => "프로젝트 전체 경로",
    "window.no_connections"         => "표시할 프로젝트나 저장된 창 연결이 없습니다.",
    "window.unconnected"            => "연결된 창 없음",
    "window.missing_identity"       => "호스트나 프로젝트 경로가 없습니다. 연결을 저장하지 않고 창으로 이동할 수 있습니다.",
    "window.permission"             => "창을 찾고 전환하려면 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 Agent Dashboard를 허용해 주세요.",
    "window.open_settings"          => "손쉬운 사용 설정 열기",
    "window.permission_retry"       => "권한을 허용한 뒤 ‘다시 찾기’를 눌러 주세요.",
    "window.partial"                => "일부 창을 확인하지 못해 자동으로 전환하지 않았습니다. 직접 창을 선택하거나 다시 찾아 주세요.",
    "window.saved_rule"             => "저장된 조건: {app} · {title}",
    "window.search"                 => "앱 또는 창 제목 검색",
    "window.refresh"                => "다시 찾기",
    "window.show_all"               => "모든 창 표시",
    "window.none"                   => "일치하는 창이 없습니다. 대상 창을 연 뒤 다시 찾거나 검색어를 바꿔 주세요.",
    "window.untitled"               => "제목 없는 창",
    "window.remember"               => "이 호스트·프로젝트의 모든 세션에 사용할 연결 저장",
    "window.title_pattern"          => "창 제목에 포함된 문구",
    "window.exact"                  => "제목 전체 일치",
    "window.match_count"            => "일치하는 창: {count}개",
    "window.rule_note"              => "대소문자를 구분하고 입력한 문구 그대로 찾습니다. ‘제목 전체 일치’를 켜면 제목 전체를 비교합니다. 여러 창이 일치하면 직접 선택합니다.",
    "window.rule_required"          => "연결을 저장하려면 앱의 창을 선택하고 제목 조건을 입력해 주세요.",
    "window.open"                   => "창으로 이동",
    "window.save_and_open"          => "저장하고 창으로 이동",
    "window.failed"                 => "창을 찾거나 전환하지 못했습니다. 손쉬운 사용 권한과 대상 창이 열려 있는지 확인한 뒤 다시 시도해 주세요.",
    "window.save_failed"            => "창 연결 변경사항을 저장하지 못했습니다. 저장 위치와 권한을 확인한 뒤 다시 시도해 주세요.",
    "window.load_failed"            => "저장된 창 연결을 읽지 못했습니다. 기존 파일은 덮어쓰지 않았습니다. ~/.local/state/my-dashboard/window-connections.json을 확인하거나 백업에서 복원한 뒤 다시 찾아 주세요.",
    "window.focus_failed"           => "창을 전환하지 못했습니다",
    "window.stale"                  => "선택한 창이 닫혔거나 변경되었습니다. 다시 찾아 연결해 주세요.",
    "window.show_session"           => "세션 상세 보기",
    "tray.open"                      => "열기",
    "tray.mute_30"                   => "알림 음소거 30분",
    "tray.mute_unmute"               => "알림 음소거 해제 ({time}까지)",
    "tray.quit"                      => "종료",
    // TASK TRAY-unseen: 메뉴 바 배지 툴팁. `{count}`는 미확인(안읽은) 세션
    // 수로, 배지 제목 숫자와 같다 — 아이콘 변형(여전히 attention, 즉
    // waiting_input+stalled 기준, 읽음 여부와 무관)과는 다른 축이다
    // (`tray_native.dart`의 분리 설명 참고).
    "tray.tooltip_unseen"            => "Agent Dashboard - 안읽은 세션 {count}개",
    "tray.tooltip_idle"              => "Agent Dashboard - 안읽은 세션 없음",
    // "안읽은 세션" 항목들: 미확인 세션(트레이 카운트와 같은 필터) 하나씩을
    // 서브메뉴 없이 최상위 메뉴에 구분선으로 감싸 나열한다 — 클릭은 연결된
    // 창으로 전환하고, 성공하면 표시했던 전이까지 읽음 처리한다.
    // 항목 라벨 "{project} — {state}": {project}는 경로 basename(없으면
    // sessionId 폴백), {state}는 state.* 키로 이미 번역된 문구다.
    "tray.unseen_item"               => "{project} — {state}",
    // TASK D-app (A안 설계 ④): 상주 동작은 이제 안내 문구가 아니라 토글이다 —
    // `setup.resident_note`는 그 토글의 설명(subtitle)으로 흡수됐다.
    "setup.resident_label"           => "창을 닫아도 백그라운드 유지",
    "setup.resident_note"            => "창을 닫아도 백그라운드에서 알림이 계속 옵니다. 완전히 종료(Cmd+Q)하면 다시 열 때 몰아서 확인됩니다.",
    "setup.resident_error"           => "백그라운드 설정을 바꾸지 못했습니다.",
    // 테마 모드 토글(시스템/라이트/다크) — `DashboardConfigValues.themeMode`에
    // 저장되고 `MaterialApp.themeMode`에 반영된다.
    "setup.section.appearance"       => "화면 모드",
    "setup.theme_mode_system"        => "시스템",
    "setup.theme_mode_light"         => "라이트",
    "setup.theme_mode_dark"          => "다크",
    "setup.theme_mode_error"         => "화면 모드 설정을 바꾸지 못했습니다.",
    // UI 표시 언어 토글(시스템/ko/en) — `DashboardConfigValues.uiLang`에
    // 저장되고 서버 `dashboard_settings.ui_lang`과 맞춰진다(Opus 판정 확정
    // 지시 [모델]). `setup.ui_lang_system`만 카탈로그를 거친다 — ko/en
    // 선택지는 각 언어를 그 언어로 표기하며 번역하지 않는다(`ui/setup_page.
    // dart`의 `// i18n-exempt:` 주석 참고).
    "setup.section.language"         => "언어",
    "setup.ui_lang_system"           => "시스템",
    "setup.ui_lang_error"            => "언어 설정을 바꾸지 못했습니다.",
    // TASK P-impl (4): 알림 경로 한 줄 고지. 바로 위
    // `setup.notification_osascript_fallback_note`와 같은 자리·수위다.
    "setup.notification_path_polling" => "알림 경로: 폴링(8/30초)",
    "setup.notification_path_apns"   => "알림 경로: APNs",
    // T17f: 웹 전용. 브라우저 권한 프롬프트는 이 버튼 뒤에서만 뜬다 —
    // 부팅 경로에서는 절대 띄우지 않는다(web_push_web.dart 참고).
    "setup.section.web_push"         => "브라우저 알림",
    "setup.web_push_action"          => "이 브라우저에서 알림 허용",
    "setup.web_push_registered"      => "이 브라우저가 알림을 받도록 등록했습니다.",
    "setup.web_push_permission_denied" => "브라우저가 알림 권한을 거부했습니다.",
    "setup.web_push_unavailable"     => "서버에 push가 설정되어 있지 않습니다 — 폴링으로 계속 동작합니다.",
    "setup.web_push_error"           => "이 브라우저를 알림에 등록하지 못했습니다.",

    // ── diagnostics (T15) ───────────────────────────────────────────────
    "diagnostics.title"           => "진단",
    "diagnostics.loading"         => "진단 정보를 불러오는 중…",
    "diagnostics.error"           => "진단 정보를 불러올 수 없습니다.",
    "diagnostics.last_event_label" => "마지막 이벤트",
    "diagnostics.max_transition_label" => "최대 전이 id",
    "diagnostics.pruned_below_label" => "정리 경계 id",
    "diagnostics.device_failures_label" => "기기 실패 수",
    "diagnostics.subscription_failures_label" => "구독 실패 수",
    "diagnostics.channels_title"  => "푸시 채널",
    "diagnostics.channel_ready"   => "준비됨",
    "diagnostics.channel_not_ready" => "준비되지 않음",
    "diagnostics.table_counts_title" => "테이블 수",
    "diagnostics.last_push_title" => "마지막 발송",
    "diagnostics.last_push_none"  => "아직 보낸 알림이 없습니다.",
    "diagnostics.none_value"      => "—",
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 모든_영어_키는_하나의_한국어_번역을_가진다() {
        // EN에만 있고 KO에 없는 키가 있으면 core 폴백 체인을 통해 조용히
        // Locale::Ko에서도 English가 보이게 된다 — 새 로케일을 점진적으로
        // 채워나갈 땐 의도적일 수 있지만, En/Ko는 둘 다 완전히 번역되어야
        // 하는 출시 로케일이라 여기서는 원치 않는다.
        let missing: Vec<&str> = EN
            .keys()
            .copied()
            .filter(|k| KO.get(*k).is_none())
            .collect();
        assert!(missing.is_empty(), "KO 카탈로그에 없는 키: {missing:?}");
    }

    #[test]
    fn 고아_한국어_키는_없다() {
        // Ko 전용 키는 절대 조회되지 않는다 — 조회는 항상 En 쪽 리터럴로
        // 키를 식별하기 때문이다. 고아 Ko 항목은 낡은 카탈로그 행이라는
        // 뜻이다.
        let orphans: Vec<&str> = KO
            .keys()
            .copied()
            .filter(|k| EN.get(*k).is_none())
            .collect();
        assert!(orphans.is_empty(), "EN에 없는 KO 전용 키: {orphans:?}");
    }

    #[test]
    fn 직접_조회는_해당_로케일_번역을_반환한다() {
        assert_eq!(t(Locale::En, "action.save"), "Save");
        assert_eq!(t(Locale::Ko, "action.save"), "저장");
    }

    #[test]
    fn 없는_키는_보이는_표식을_반환한다() {
        assert_eq!(t(Locale::En, "no.such.key"), MISSING_KEY_MARKER);
        assert_eq!(t(Locale::Ko, "no.such.key"), MISSING_KEY_MARKER);
    }

    #[test]
    fn 인자_치환은_이름_있는_자리표시자를_바꾼다() {
        assert_eq!(
            t_args(Locale::En, "error.unknown_item", &[("id", "42")]),
            "Unknown item: 42",
        );
        assert_eq!(
            t_args(Locale::Ko, "error.unknown_item", &[("id", "42")]),
            "알 수 없는 항목입니다: 42",
        );
    }

    #[test]
    fn 동기화_오류_문구는_로케일별_문장에_요청과_런타임_원문을_그대로_끼운다() {
        // sessions_page.dart의 syncErrorDetailText가 넘기는 인자 그대로다 —
        // 위젯 테스트(sync_error_detail_test.dart)의 가짜 카탈로그도 같은
        // 문장을 쓴다.
        struct Case {
            key: &'static str,
            args: &'static [(&'static str, &'static str)],
            en: &'static str,
            ko: &'static str,
        }
        let cases = [
            Case {
                key: "sync.error.transport_failed",
                args: &[
                    ("method", "GET"),
                    ("path", "/dashboard/sync"),
                    ("cause", "SocketException: Connection refused"),
                ],
                en: "Request failed: GET /dashboard/sync (SocketException: Connection refused)",
                ko: "요청이 실패했습니다: GET /dashboard/sync (SocketException: Connection refused)",
            },
            Case {
                key: "sync.error.timeout",
                args: &[
                    ("method", "GET"),
                    ("path", "/dashboard/sync"),
                    ("timeout_ms", "10000"),
                ],
                en: "No response within 10000 ms: GET /dashboard/sync",
                ko: "10000ms 안에 응답이 없습니다: GET /dashboard/sync",
            },
            Case {
                key: "sync.error.malformed_response",
                args: &[
                    ("method", "GET"),
                    ("path", "/dashboard/sync"),
                    ("detail", "FormatException: Unexpected character"),
                ],
                en: "The response wasn't a JSON object: GET /dashboard/sync (FormatException: Unexpected character)",
                ko: "응답이 JSON 객체가 아닙니다: GET /dashboard/sync (FormatException: Unexpected character)",
            },
            Case {
                key: "sync.error.protocol_update_app",
                args: &[("server_version", "2"), ("supported_version", "1")],
                en: "The server and this app use different protocol versions (server: 2, app: 1). Update the app.",
                ko: "서버와 앱의 프로토콜 버전이 다릅니다(서버: 2, 앱: 1). 앱을 업데이트하세요.",
            },
            Case {
                key: "sync.error.protocol_update_server",
                args: &[("server_version", "1"), ("supported_version", "2")],
                en: "The server and this app use different protocol versions (server: 1, app: 2). Update the server.",
                ko: "서버와 앱의 프로토콜 버전이 다릅니다(서버: 1, 앱: 2). 서버를 업데이트하세요.",
            },
        ];
        for case in cases {
            let key = case.key;
            assert_eq!(t_args(Locale::En, key, case.args), case.en, "key={key}");
            assert_eq!(t_args(Locale::Ko, key, case.args), case.ko, "key={key}");
        }
    }

    #[test]
    fn 예상하지_못한_동기화_오류_문구는_런타임_원문을_받지_않는다() {
        // 이 문구가 대신 보이는 원문은 스택 트레이스를 담은 개발자용 덤프일 수
        // 있다. 문장이 자리표시자를 갖지 않으므로 호출자가 원문을 넘겨도
        // 화면에 닿지 않는다(sessions_page.dart의 syncErrorDetailText).
        let dump = [("cause", "Bad state: dump"), ("detail", "StateError")];
        let en = "Syncing failed unexpectedly. Try again.";
        let ko = "동기화 중 예상하지 못한 오류가 발생했습니다. 다시 시도하세요.";
        assert_eq!(t(Locale::En, "sync.error.unexpected"), en);
        assert_eq!(t(Locale::Ko, "sync.error.unexpected"), ko);
        assert_eq!(t_args(Locale::En, "sync.error.unexpected", &dump), en);
        assert_eq!(t_args(Locale::Ko, "sync.error.unexpected", &dump), ko);
    }

    #[test]
    fn 읽을_수_없는_서버_주소를_저장한_뒤의_문구는_양쪽_로케일에_있다() {
        assert_eq!(
            t(Locale::En, "setup.server_url_invalid"),
            "Saved, but the server address can't be read. Check the address and save again.",
        );
        assert_eq!(
            t(Locale::Ko, "setup.server_url_invalid"),
            "저장했지만 서버 주소를 읽을 수 없습니다. 주소를 확인하고 다시 저장하세요.",
        );
    }

    #[test]
    fn 인자_치환은_일치하지_않은_자리표시자를_그대로_둔다() {
        assert_eq!(
            t_args(Locale::En, "error.unknown_item", &[]),
            "Unknown item: {id}",
        );
    }

    #[test]
    fn 인자_대체는_짝없는_여는_중괄호를_보존한다() {
        let out = substitute_args("price: {amount with no close", &[("amount", "5")]);
        assert_eq!(out, "price: {amount with no close");
    }

    /// `contracts/dashboard-protocol.v1.json`의 `i18n` 절과 KO 카탈로그를
    /// 직접 대조한다 — `app-core/src`에서 세 단계 위가 레포 루트다.
    const CONTRACT_JSON: &str = include_str!("../../../contracts/dashboard-protocol.v1.json");

    #[test]
    fn ko_카탈로그는_계약의_i18n_절과_바이트_단위로_같다() {
        let contract: serde_json::Value =
            serde_json::from_str(CONTRACT_JSON).expect("계약 파일은 유효한 JSON이어야 한다");
        let ko = contract["i18n"]["ko"]
            .as_object()
            .expect("i18n.ko는 객체여야 한다");
        assert!(!ko.is_empty(), "계약의 i18n.ko가 비어 있다");
        for (key, value) in ko {
            let expected = value
                .as_str()
                .unwrap_or_else(|| panic!("{key}는 문자열이어야 한다"));
            assert_eq!(t(Locale::Ko, key), expected, "key={key}");
        }
    }
}

/// `app-core/src/capability.rs`의 [CAPABILITIES] 카탈로그, `app-core/src/dashboard.rs`의
/// [SessionState] 코드 문자열과 값이 같은 Dart 상수.
///
/// 화면 코드가 capability id/상태 코드 문자열을 직접 타이핑하면 오타가
/// 컴파일 타임에 걸리지 않는다 — 이 파일의 상수를 대신 참조한다.
///
/// `quality.json`의 `constant_contracts`가 이 파일의 값들이 Rust 쪽
/// 정본(위 두 파일)에 실제로 존재하는 문자열의 부분집합인지 정적으로
/// 대조한다 — 두 값이 갈라지면 `mise run verify`가 실패한다.
library;

// ─── capability id (app-core/src/capability.rs의 CAPABILITIES) ──────────

const String kCapabilityDesktopWindowControl = 'desktop.window_control';
const String kCapabilityDesktopGlobalHotkey = 'desktop.global_hotkey';
const String kCapabilityNotifyLocal = 'notify.local';
const String kCapabilityNotifyWebPush = 'notify.web_push';

// ─── 세션 상태 코드 (app-core/src/dashboard.rs의 SessionState::code) ────

const String kSessionStateIdle = 'idle';
const String kSessionStateWorking = 'working';
const String kSessionStateWaitingInput = 'waiting_input';
const String kSessionStateDone = 'done';
const String kSessionStateEnded = 'ended';
const String kSessionStateStalled = 'stalled';

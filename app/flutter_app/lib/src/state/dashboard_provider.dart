/// 대시보드 FRB 어댑터 — 이 레이어에서 `lib/src/rust/api/dashboard.dart`를
/// import하는 **유일한** 파일이다.
///
/// `notify_provider.dart` 등 나머지 T13 시임은
/// 세션 상태·정렬·라벨이 필요할 때 이 파일이 여는 Provider만 거친다 —
/// `package:my_dashboard/src/rust/**`를 직접 import하지 않는다. 그래서
/// `python3 scripts/quality_check.py boundary`가 FRB 접근 지점을 이 한 파일로
/// 계속 좁혀 둘 수 있다.
///
/// `capability_provider.dart`와 같은 3계층을 네 개의 함수 각각에 반복한다:
///   1. 함수 타입을 typedef로 고정한다.
///   2. 그 타입의 `Provider`를 연다 — 테스트는 이것만 override한다.
///   3. 실제 FRB 호출은 최상위 얇은 함수 하나에만 있다.
///
/// 네 함수 모두 `#[flutter_rust_bridge::frb(sync)]`라 동기 호출이 안전하다
/// (`app-frb/src/api/dashboard.rs` 참고) — 별도 FutureProvider가 필요 없다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// FRB의 64비트 정수 표현(`PlatformInt64`)은 io 빌드에서는 `int`, web(wasm/js)
// 빌드에서는 `BigInt`다 — `isSessionStale`이 그 타입을 그대로 쓴다. 이 시임의
// 공개 typedef(`IsSessionStaleFn`)는 나머지 계층(예: `sync_reducer.dart`)이
// 이미 epoch ms를 plain `int`로 들고 다니는 관용에 맞춰 `int`로 남기고,
// `PlatformInt64Util.from`으로 여기서만 변환한다 — 변환 지점을 이 얇은
// 함수 하나로 좁혀 두는 게 3계층 규칙의 취지다.
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import 'package:my_dashboard/src/rust/api/dashboard.dart';
export 'package:my_dashboard/src/rust/api/dashboard.dart'
    show EventSourceDto, SessionOrderKeyDto, SessionStateDto;

// ─── stateForEvent ─────────────────────────────────────────────────────────

/// `(source, event)` -> 다음 상태(표에 없으면 null = 상태 불변).
typedef StateForEventFn =
    SessionStateDto? Function({required EventSourceDto source, required String event});

SessionStateDto? _stateForEventBridge({
  required EventSourceDto source,
  required String event,
}) => stateForEvent(source: source, event: event);

final Provider<StateForEventFn> stateForEventFnProvider =
    Provider<StateForEventFn>(
      (ref) => ({required EventSourceDto source, required String event}) =>
          _stateForEventBridge(source: source, event: event),
    );

// ─── stateLabelKey ──────────────────────────────────────────────────────────

/// 프로토콜 상태 코드 문자열(`SessionViewDto.state`/`TransitionDto.toState`,
/// 예: `'waiting_input'`)을 FRB [SessionStateDto]로 옮긴다.
///
/// 이 파일이 재노출하는 [SessionStateDto]는 camelCase Dart enum이라 정본의
/// snake_case 코드와 이름이 갈라진다 — 그 둘을 잇는 매핑은 곧 이 FRB
/// 어댑터의 일이다. 그래서 원래 있던 자리(`ui/widgets/state_chip.dart`)에서
/// 여기로 내려왔다: 화면(칩·타임라인·카드)뿐 아니라 화면이 아닌 계층
/// (`state/notify_provider.dart`의 알림 제목)도 같은 매핑을 쓰게 되면서,
/// state 계층이 ui 계층을 import하는 역방향 의존이 생기기 때문이다.
/// `state_chip.dart`는 이 이름을 그대로 재노출하므로 기존 화면 호출부의
/// import 경로는 바뀌지 않는다.
///
/// 표에 없는 값은 [SessionStateDto.idle]로 접는다(알 수 없는 상태를 침묵으로
/// 숨기지 않되, 화면이 죽지도 않게 하는 안전한 기본값).
SessionStateDto sessionStateDtoFromCode(String code) => switch (code) {
  'idle' => SessionStateDto.idle,
  'working' => SessionStateDto.working,
  'waiting_input' => SessionStateDto.waitingInput,
  'done' => SessionStateDto.done,
  'ended' => SessionStateDto.ended,
  'stalled' => SessionStateDto.stalled,
  _ => SessionStateDto.idle,
};

/// 상태 -> i18n 키.
typedef StateLabelKeyFn = String Function(SessionStateDto state);

String _stateLabelKeyBridge(SessionStateDto state) =>
    stateLabelKey(state: state);

final Provider<StateLabelKeyFn> stateLabelKeyFnProvider =
    Provider<StateLabelKeyFn>((ref) => _stateLabelKeyBridge);

// ─── isSessionStale ─────────────────────────────────────────────────────────

/// `updated_at`부터 `now`까지 `stale_ms`를 초과해 지났는가(전부 epoch ms).
typedef IsSessionStaleFn =
    bool Function({
      required int now,
      required int updatedAt,
      required int staleMs,
    });

bool _isSessionStaleBridge({
  required int now,
  required int updatedAt,
  required int staleMs,
}) => isSessionStale(
  now: PlatformInt64Util.from(now),
  updatedAt: PlatformInt64Util.from(updatedAt),
  staleMs: PlatformInt64Util.from(staleMs),
);

final Provider<IsSessionStaleFn> isSessionStaleFnProvider =
    Provider<IsSessionStaleFn>((ref) => _isSessionStaleBridge);

// ─── sortSessionOrder ───────────────────────────────────────────────────────

/// alert 우선 -> `updated_at` 내림차순 안정 정렬.
typedef SortSessionOrderFn =
    List<SessionOrderKeyDto> Function(List<SessionOrderKeyDto> sessions);

List<SessionOrderKeyDto> _sortSessionOrderBridge(
  List<SessionOrderKeyDto> sessions,
) => sortSessionOrder(sessions: sessions);

final Provider<SortSessionOrderFn> sortSessionOrderFnProvider =
    Provider<SortSessionOrderFn>((ref) => _sortSessionOrderBridge);

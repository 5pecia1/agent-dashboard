/// 대시보드 프로토콜 v1의 Dart 표현(DTO).
///
/// 정본은 `contracts/dashboard-protocol.v1.json`이다. 이 파일은 그 문서의
/// `sync.response` / `sync.session_object` / `sync.transition_object`와
/// 운영 엔드포인트(`GET /dashboard/diagnostics`, `POST /dashboard/test-push`,
/// `GET /dashboard/push-config`)의 응답 모양을 그대로 옮긴 것뿐이고, 해석은
/// 하지 않는다 — 해석은 `sync_reducer.dart`(순수 리듀서)와 화면 계층의 몫이다.
///
/// 설계 규칙 세 가지:
///
/// 1. **모르는 키는 무시한다.** 정본 versioning 규칙이 "필드 추가는 major를
///    올리지 않는다(forward compatible)"이므로, 서버가 새 키를 붙여도
///    `fromJson`이 깨지지 않아야 한다. json_serializable 기본 동작이 그렇다.
/// 2. **없는 키는 기본값으로 접는다.** 필수로 둔 필드는 그것이 없으면 응답을
///    해석할 수 없는 것들(`key`/`state`/`id`/`to_state`)뿐이다. 나머지는
///    `@Default`를 준다 — 서버 트랙이 아직 못 채운 필드 하나가 동기화 전체를
///    실패로 만들면 안 된다.
/// 3. **상태는 문자열 코드 그대로 담는다.** `SessionStateDto`(FRB enum)로의
///    변환은 `lib/src/state/`의 어댑터가 한다. 이 계층은 FRB를 import하지
///    않는다(`quality.json`의 `ffi_allowed`가 데이터 계층을 허용하지 않는다).
///    상태 코드 문자열의 정본 목록은 `lib/src/state/capability_ids.dart`의
///    `kSessionState*` 상수다.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'dashboard_dto.freezed.dart';
part 'dashboard_dto.g.dart';

/// 이 클라이언트가 이해하는 프로토콜 major(정본 `versioning.current`).
const int kDashboardProtocolVersion = 1;

/// 정본 `states.enum`. 순서까지 정본과 같다.
const List<String> kDashboardStates = <String>[
  'idle',
  'working',
  'waiting_input',
  'done',
  'ended',
  'stalled',
];

/// [kDashboardStates]의 `'working'` 낱값. TASK P-impl (2):
/// `sync_reducer.dart`의 `SyncState.hasWorkingSession`이 이 값으로 세션
/// 맵을 스캔해 `sync_controller.dart`의 적응형 비활성 폴링 간격(8초/30초)을
/// 고른다.
const String kDashboardStateWorking = 'working';

/// [kDashboardStates]의 `'waiting_input'` 낱값. 트레이 아이콘이 심각도별
/// 색을 고를 때(`platform/tray_native.dart`의 `trayBadgeIconAssetPath`)
/// `sync_reducer.dart`의 `SyncState.waitingInputSessionCount`가 이 값으로
/// 센다.
const String kDashboardStateWaitingInput = 'waiting_input';

/// [kDashboardStates]의 `'stalled'` 낱값. [kDashboardStateWaitingInput]과
/// 같은 이유 — `SyncState.stalledSessionCount`가 이 값으로 세고, 트레이
/// 아이콘 색의 최우선(stalled > waiting) 근거다.
const String kDashboardStateStalled = 'stalled';

/// 정본 `push_states.enum`. "이 상태로 **전이**했을 때만" 알림 대상이다.
///
/// `done`은 없다(2026-09-14, Sol 확정) — done은 "턴 실행을 마쳤다"일 뿐인데
/// 서버의 조건부 승격(하트비트가 background 서브에이전트 활동을 보고 done을
/// working으로 되돌리는 것)이 곧바로 뒤따라, "끝났다" 알림 직후 "진행 중"이
/// 이어지는 소음을 만들었다. 자세한 사유는 정본
/// `push_states.$note_done_excluded` 참고.
const List<String> kDashboardPushStates = <String>[
  kDashboardStateWaitingInput,
  kDashboardStateStalled,
];

/// TASK A-impl (2): 트레이 주의 배지가 세는 상태.
///
/// [kDashboardPushStates]와 마찬가지로 두 상태뿐이지만 의미는 다르다 —
/// 이건 사람이 **지금 개입해야 하는** 상태(사용자가 무언가 해야 비로소
/// 진행되는 상태)만 센다는 뜻이고, [kDashboardPushStates]는 "전이했을 때
/// 알림을 보낼 상태"라는 별개 기준이다. 지금은 두 목록의 값이 우연히
/// 같지만(`done` push가 빠지면서), 새 상태가 하나만 만족하는 조건으로
/// 늘어날 수 있으므로 상수를 통합하지 않는다.
const List<String> kDashboardAttentionStates = <String>[
  kDashboardStateWaitingInput,
  kDashboardStateStalled,
];

/// 정본 `states.detail.stalled.derivation.env.default_ms`.
const int kDefaultStallMs = 300000;

/// 프로젝션(`dashboard_sessions`) 한 줄 = 화면의 세션 카드 하나.
///
/// 정본 `sync.session_object`에 서버가 얹는 legacy `stale` 불린까지 담는다
/// (파생 상태 `stalled`가 그 역할을 넘겨받았지만 서버는 아직 둘 다 보낸다).
@freezed
abstract class SessionViewDto with _$SessionViewDto {
  const SessionViewDto._();

  const factory SessionViewDto({
    /// `<source>:<session_id>`. 프로젝션·전이·push가 공유하는 식별자다.
    required String key,

    /// 현재 상태. [kDashboardStates] 중 하나.
    required String state,

    @Default('') String source,
    @JsonKey(name: 'session_id') @Default('') String sessionId,
    @Default('') String project,
    String? host,
    @JsonKey(name: 'last_event') @Default('') String lastEvent,
    @JsonKey(name: 'last_message') String? lastMessage,

    @JsonKey(name: 'display_title') String? displayTitle,

    /// 마지막 이벤트의 발생 시각(epoch ms, **이벤트를 낸 기계의 시계**).
    @JsonKey(name: 'last_occurred_at') int? lastOccurredAt,

    /// 세션 첫 이벤트 수신 시각(epoch ms, 서버 시계).
    @JsonKey(name: 'created_at') @Default(0) int createdAt,

    /// 프로젝션 마지막 갱신 시각(epoch ms, 서버 시계).
    @JsonKey(name: 'updated_at') @Default(0) int updatedAt,

    /// 마지막 **진척** 신호를 서버가 **수신한** 시각(epoch ms, 서버 시계).
    /// 정본 `sync.session_object.fields.last_progress_at` — 상태를 바꾼
    /// 이벤트와 heartbeat_events만 이 값을 밀고, 기록-전용 이벤트는 밀지
    /// 않는다. stalled 판정과 이 화면의 stale 배지가 둘 다 이 값을 서버
    /// 시각([SyncState.serverTime])과 비교한다 — [lastOccurredAt](클라이언트
    /// 기계 시계)이나 기기의 `DateTime.now()`와는 절대 비교하지 않는다
    /// (교차 시계 오염 방지). additive라 구형 응답에는 없을 수 있어
    /// nullable — 그 경우 [updatedAt](역시 서버 시계)으로 접는다.
    @JsonKey(name: 'last_progress_at') int? lastProgressAt,

    /// 0001 시절의 legacy 플래그. 새 화면은 [state]의 `stalled`를 쓴다.
    @Default(false) bool stale,

    /// 이 세션에 마지막으로 적재된 전이의 id(0004 seen 기능의 기준값,
    /// `dashboard_sessions.last_transition_id`). 전이가 한 번도 없던 세션은
    /// null. additive라 구형 응답에는 없을 수 있어 nullable이다 —
    /// `sync_reducer.dart`가 델타 경로에서도 `transition.id`로 직접
    /// 채운다(sync.ts는 델타 응답에 `sessions`를 담지 않는다).
    @JsonKey(name: 'last_transition_id') int? lastTransitionId,
  }) = _SessionViewDto;

  factory SessionViewDto.fromJson(Map<String, dynamic> json) =>
      _$SessionViewDtoFromJson(json);

  /// 세션이 끝났는지(정본 `states.detail.ended.terminal`).
  bool get isEnded => state == 'ended';

  /// 이 상태가 알림 대상 상태인지(정본 `push_states.enum`).
  bool get isAlertState => kDashboardPushStates.contains(state);

  /// TASK A-impl (2): 사람이 지금 개입해야 하는 상태인지
  /// ([kDashboardAttentionStates]). 트레이 주의 배지가 이 값으로 센다.
  bool get needsAttention => kDashboardAttentionStates.contains(state);
}

/// 세션 목록의 표시 순서 정본 — "알림 대상 상태([SessionViewDto.isAlertState])
/// 우선 -> `updated_at` 내림차순 -> `key` 오름차순(완전 결정, 정렬 알고리즘의
/// 안정성에 의존하지 않는다)".
///
/// 원래 `ui/sessions_page.dart`에 있던 화면용 정렬이었는데, 트레이 우클릭
/// 메뉴의 "안읽은 세션" 서브메뉴(`platform/tray_native.dart`)가 같은 순서를
/// 필요로 하면서 두 계층이 함께 쓰는 값이 됐다 — `util/project_path.dart`의
/// `projectBasename`이 내려온 것과 같은 이유로 여기로 옮겼다.
/// `sortSessionOrderFnProvider`(FRB)를 쓰지 않는 이유는 옮기기 전 문서 그대로다:
/// `SessionOrderKeyDto`(state+updatedAt뿐, 식별자 없음)만 다뤄서 실제
/// `SessionViewDto` 목록을 무손실로 되짚을 수 없다(알려진 한계 — followup
/// 으로 보고).
List<SessionViewDto> sortedSessionsFor(Iterable<SessionViewDto> sessions) {
  final list = sessions.toList();
  list.sort((a, b) {
    final aAlert = a.isAlertState ? 0 : 1;
    final bAlert = b.isAlertState ? 0 : 1;
    if (aAlert != bAlert) return aAlert.compareTo(bAlert);
    final byTime = b.updatedAt.compareTo(a.updatedAt);
    if (byTime != 0) return byTime;
    return a.key.compareTo(b.key);
  });
  return list;
}

/// 전이 로그(`dashboard_transitions`) 한 줄. [id]가 곧 sync 커서다.
///
/// 정본 `sync.transition_object`.
@freezed
abstract class TransitionDto with _$TransitionDto {
  const TransitionDto._();

  const factory TransitionDto({
    /// AUTOINCREMENT 커서. 서버에서 단조 증가하고 재사용되지 않는다.
    required int id,

    @JsonKey(name: 'session_key') required String sessionKey,
    @JsonKey(name: 'to_state') required String toState,
    @JsonKey(name: 'from_state') String? fromState,
    @Default('') String source,
    String? project,
    String? host,
    String? message,

    @JsonKey(name: 'display_title') String? displayTitle,

    /// 이벤트 발생 시각(epoch ms, 이벤트를 낸 기계의 시계).
    @JsonKey(name: 'occurred_at') @Default(0) int occurredAt,

    /// 전이 기록 시각(epoch ms, 서버 시계).
    @JsonKey(name: 'created_at') @Default(0) int createdAt,
  }) = _TransitionDto;

  factory TransitionDto.fromJson(Map<String, dynamic> json) =>
      _$TransitionDtoFromJson(json);

  /// 이 전이가 push(=알림) 대상인지. 정본 `push_states.enum`.
  bool get isAlert => kDashboardPushStates.contains(toState);

  /// `session_key`에서 뽑은 세션 id(`<source>:<session_id>`의 뒤쪽).
  ///
  /// 전이만으로 세션 카드를 새로 만들 때 쓴다. `session_id` 자체에
  /// `:`가 들어갈 수 있으므로 **첫 번째** 구분자에서만 자른다.
  String get sessionIdFromKey {
    final separator = sessionKey.indexOf(':');
    return separator < 0 ? sessionKey : sessionKey.substring(separator + 1);
  }

  /// `session_key`에서 뽑은 source. [source]가 비었을 때의 대비책이다.
  String get sourceFromKey {
    final separator = sessionKey.indexOf(':');
    return separator < 0 ? '' : sessionKey.substring(0, separator);
  }
}

/// 세션 하나의 읽음/안읽음(seen) 마커 한 칸. `sync.response.seen`의 원소.
///
/// 읽음 계약: `dashboard_seen`에서 온 값을 세션 프로젝션
/// (`sync.session_object`)이 아니라 sync 응답 **최상위**에서, 매 응답
/// (스냅샷·델타 공통) 절대값으로 동봉한다 — `mute_until`과 같은 "절대값
/// 서버 상태" 선례를 따른다. 같은 사실(이 세션을 마지막으로 언제까지 봤는가)
/// 을 두 자리(세션 객체 + 이 배열)에서 중복 표현하지 않는다 — 예전
/// `SessionViewDto.seenTransitionId`는 이 배열로 완전히 대체됐다.
@freezed
abstract class SeenMarkerDto with _$SeenMarkerDto {
  const factory SeenMarkerDto({
    /// `session_key`. [SessionViewDto.key]/[TransitionDto.sessionKey]와
    /// 같은 값 공간이다.
    required String key,

    /// 사용자가 마지막으로 확인 처리(seen)한 전이 id. 한 번도 MarkSeen을
    /// 호출한 적 없으면 null.
    @JsonKey(name: 'seen_transition_id') int? seenTransitionId,
  }) = _SeenMarkerDto;

  factory SeenMarkerDto.fromJson(Map<String, dynamic> json) =>
      _$SeenMarkerDtoFromJson(json);
}

/// 훅 구버전(스큐) 한 기계. `sync.response.hook_skew`의 원소.
///
/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 하나를
/// 가리킨다 — `SessionViewDto`/`TransitionDto`와 달리 세션이 아니라
/// **기계(host)** 단위 정보다. `hook_skew.dart`(app-frb)의 판정을 그대로
/// 옮긴 것으로, rev 비교나 "구버전인가" 자체는 여기서 하지 않는다.
@freezed
abstract class HookSkewDto with _$HookSkewDto {
  const factory HookSkewDto({
    /// 구버전 훅을 돌리는 기계명. `SessionViewDto.host`와 같은 값 공간이다.
    required String host,

    /// 그 기계 훅이 신고한 리비전(8자리 hex). 훅이 아직 버전을 신고하지
    /// 않는 더 구버전이면 null이다 — "모름"이 아니라 "더 오래됨"의 신호다.
    String? rev,

    /// 그 기계에서 이 훅이 마지막으로 관측된 프로젝트 경로. `SessionViewDto.
    /// project`와 같은 값 공간(보통 절대경로)이다. devcontainer 등 host명이
    /// 무작위 hex라 식별 불가한 경우를 위한 additive 필드라 서버 구버전
    /// 응답에는 없을 수 있어 nullable이다 — null이면 host만으로 표시한다.
    @JsonKey(name: 'project') String? project,
  }) = _HookSkewDto;

  factory HookSkewDto.fromJson(Map<String, dynamic> json) =>
      _$HookSkewDtoFromJson(json);
}

/// `GET /dashboard/sync` 응답 한 통. 정본 `sync.response`.
///
/// `sessions`와 `transitions`는 **항상 둘 다 존재**한다(클라이언트 분기
/// 단순화). [reset]이 true면 `sessions`가 전체 스냅샷이고 `transitions`는
/// 비어 있다. false면 반대다.
@freezed
abstract class SyncResponseDto with _$SyncResponseDto {
  const SyncResponseDto._();

  const factory SyncResponseDto({
    @JsonKey(name: 'protocol_version')
    @Default(kDashboardProtocolVersion)
    int protocolVersion,

    /// true면 로컬 상태를 버리고 [sessions]로 갈아탄다.
    @Default(false) bool reset,

    /// 이 응답까지 반영한 최대 전이 id. 다음 요청의 `since`에 그대로 넣는다.
    @Default(0) int cursor,

    /// limit에 걸려 잘렸다. [cursor]로 즉시 한 번 더 요청한다.
    @JsonKey(name: 'has_more') @Default(false) bool hasMore,

    /// 서버 시각(epoch ms). 리듀서의 `nowMs`로 쓰는 것이 기본이다 —
    /// 기기 시계가 틀어져도 알림 판정이 흔들리지 않는다.
    @JsonKey(name: 'server_time') @Default(0) int serverTime,

    /// 이 값보다 작은 전이 id는 보존 정리로 사라졌다.
    @JsonKey(name: 'pruned_below_id') @Default(0) int prunedBelowId,

    /// 서버가 쓰는 `DASHBOARD_STALL_MS`.
    @JsonKey(name: 'stall_ms') @Default(kDefaultStallMs) int stallMs,

    /// 음소거 종료 시각(epoch ms). null이면 음소거 아님.
    @JsonKey(name: 'mute_until') int? muteUntil,

    /// UI 표시 언어(서버 `dashboard_settings.ui_lang`, 정본은 서버 —
    /// 서버 상태 계약). `'ko'`/`'en'` 또는 null — null이면
    /// 서버가 아직 정하지 않아 각 기기가 자기 플랫폼 로케일을 쓴다는 뜻이다
    /// (`'system'`은 로컬 기기 사실이라 서버에는 없는 값이다). [muteUntil]/
    /// [hookSkew]와 같은 절대값 서버 상태 관용 — 매 응답(스냅샷·델타 공통)에
    /// 무조건 대입된다(`sync_reducer.dart`의 `reduceSync` 참고).
    @JsonKey(name: 'ui_lang') String? uiLang,

    @Default(<SessionViewDto>[]) List<SessionViewDto> sessions,
    @Default(<TransitionDto>[]) List<TransitionDto> transitions,

    /// 이번 델타가 건드린 `session_key` 목록(서버 편의 필드).
    @JsonKey(name: 'sessions_touched')
    @Default(<String>[])
    List<String> sessionsTouched,

    /// 읽음/안읽음(seen) 마커 전체(읽음 계약) — 범위는 [sessions]의 스냅샷과
    /// 같다(비-ended 세션), 매 응답(스냅샷·델타 공통)에 절대값으로 동봉된다.
    /// `sync_reducer.dart`의 `reduceSync`가 이 배열을 `SyncState.
    /// seenTransitionIds`에 MAX(로컬, 수신)로 멱등 병합한다 — 낙관 갱신
    /// 직후 비행 중이던 옛 응답이 점을 되살리는 깜빡임을 막는다.
    @Default(<SeenMarkerDto>[]) List<SeenMarkerDto> seen,

    /// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
    /// additive라 구형 응답에는 없을 수 있어 빈 리스트로 접힌다 — 빈
    /// 배열은 "전부 최신"이지 "모름"이 아니다. `sync_reducer.dart`의
    /// `reduceSync`가 이 값을 `SyncState.hookSkew`에 매 응답(스냅샷·델타
    /// 공통) **무조건 대입**한다([muteUntil]과 같은 절대값 관용 —
    /// [seen]의 MAX 병합과 다르다: 훅이 갱신되면 그 기계가 목록에서
    /// 사라져야 하므로 "낮아지지 않는다"가 아니라 "매번 그대로"가 맞다).
    @JsonKey(name: 'hook_skew')
    @Default(<HookSkewDto>[])
    List<HookSkewDto> hookSkew,
  }) = _SyncResponseDto;

  factory SyncResponseDto.fromJson(Map<String, dynamic> json) =>
      _$SyncResponseDtoFromJson(json);

  /// 이 클라이언트가 아는 major인지. 아니면 갱신을 안내해야 한다.
  bool get isSupportedProtocol => protocolVersion == kDashboardProtocolVersion;
}

/// `GET /dashboard/push-config` 응답.
///
/// 웹 클라이언트의 FCM 구독 설정(firebaseConfig·VAPID 키)을 앱 번들에 굽지
/// 않고 서버에서 받아오기 위한 통로다. 자격증명이 서버에 없으면 활성 채널
/// 목록이 비어서 오고, 그 경우 API 계층이 `DashboardPushUnavailable`을 던진다.
///
/// 응답 모양을 한 가지로 못박지 않는다. [PushConfigDto.fromServer]가 아래를
/// 모두 받아들인다 — **첫 줄이 실제 서버가 보내는 모양**이고
/// (dashboard-server `push/routes.ts`의 `GET /dashboard/push-config`), 나머지는 이
/// DTO가 서버 트랙보다 먼저 쓰이던 시절의 모양이라 호환으로 남긴다:
///
/// ```json
/// {"channels":["fcm"],"fcm":{"web_config":{...},"vapid_key":"...","client_ready":true}}
/// {"channels":["fcm"],"firebase_config":{...},"vapid_key":"..."}
/// {"fcm":{"firebase_config":{...},"vapid_key":"..."}}
/// {"fcm":{"firebaseConfig":{...},"vapidKey":"..."}}
/// ```
///
/// `web_config`와 `firebase_config`는 같은 값의 다른 이름이다(둘 다 Firebase
/// 웹 앱 설정). 서버가 쓰는 이름이 `web_config`다.
///
/// **A안 설계 ③(TASK D-app/D-server)**: macOS 상주 앱은 `web_config`가 아니라
/// `apple_config`(+ `apple_client_ready`)를 읽는다 — Firebase Apple 앱 설정은
/// 웹 앱 설정과 값이 다르다(`appId`가 다른 앱이다). 두 값이 `fcm` 블록 안에
/// 나란히 오고, 클라이언트는 자기 호스트에 맞는 쪽만 본다.
@freezed
abstract class PushConfigDto with _$PushConfigDto {
  const PushConfigDto._();

  const factory PushConfigDto({
    /// 서버가 실제로 발송 가능한 채널 목록(예: `['fcm']`). 비어 있으면
    /// 자격증명이 없다는 뜻이다.
    @Default(<String>[]) List<String> channels,

    /// 웹 FCM SDK 초기화 인자(apiKey/projectId/appId/messagingSenderId 등).
    /// 키 구성이 SDK 버전마다 달라서 맵 그대로 들고 다닌다.
    @JsonKey(name: 'firebase_config')
    @Default(<String, Object?>{})
    Map<String, Object?> firebaseConfig,

    /// 웹 푸시 구독에 쓰는 VAPID 공개키.
    @JsonKey(name: 'vapid_key') String? vapidKey,

    /// macOS/iOS 상주 앱이 `Firebase.initializeApp`에 코드로 주입하는 Apple
    /// 앱 설정(apiKey/appId/messagingSenderId/projectId 등). 웹의
    /// [firebaseConfig]와 **동형이지만 값이 다른 앱**이다 — 서버는
    /// `FIREBASE_APPLE_CONFIG` env를 파싱해 그대로 전달만 한다(A안 설계 ③).
    @JsonKey(name: 'apple_config')
    @Default(<String, Object?>{})
    Map<String, Object?> appleConfig,

    /// 서버가 직접 말한 "웹 클라이언트가 지금 `getToken()`을 불러도 되는가".
    /// dashboard-server는 `web_config`와 `vapid_key`가 **둘 다** 있을 때만 true를
    /// 보낸다. 서버가 이 값을 안 보내면(구형 응답) null이고, 그때는
    /// [canSubscribeOnWeb]이 값의 존재로 직접 판정한다 — 즉 null은 "모름"이지
    /// "false"가 아니다.
    @JsonKey(name: 'client_ready') bool? clientReady,

    /// [clientReady]의 Apple판 — "상주 앱이 지금 APNs 등록을 시도해도
    /// 되는가". dashboard-server는 `apple_config`가 있을 때만 true를 보낸다.
    /// 서버가 이 값을 안 보내면(D-server 이전의 구형 응답) null이고, 그때는
    /// [canSubscribeOnApple]이 값의 존재로 직접 판정한다 — null은 "모름"이지
    /// "false"가 아니다([clientReady]와 같은 관용).
    @JsonKey(name: 'apple_client_ready') bool? appleClientReady,

    /// 서비스워커 경로 등 서버가 얹어 보내는 부가 설정. 모르는 값은
    /// 그대로 보관만 한다.
    @Default(<String, Object?>{}) Map<String, Object?> options,
  }) = _PushConfigDto;

  factory PushConfigDto.fromJson(Map<String, dynamic> json) =>
      _$PushConfigDtoFromJson(json);

  /// 위 세 가지 응답 모양을 하나로 접어 읽는다.
  factory PushConfigDto.fromServer(Map<String, dynamic> json) =>
      PushConfigDto.fromJson(
        _flattenPushConfig(Map<String, Object?>.from(json)),
      );

  /// 서버가 발송 가능한 채널이 하나도 없다 = 자격증명 미설정.
  bool get isUnavailable => channels.isEmpty;

  bool hasChannel(String channel) => channels.contains(channel);

  /// 웹에서 FCM 토큰을 발급받는 데 필요한 값이 다 있는지.
  ///
  /// 서버가 [clientReady]로 명시적으로 아니라고 하면 그 말을 따른다 —
  /// 자격증명이 절반만 설정된 서버(`wrangler dev`로 재현 가능)에서 앱이
  /// `getToken()`까지 갔다가 실패하는 대신, 조용히 폴링 전용으로 남는다.
  bool get canSubscribeOnWeb =>
      hasChannel('fcm') &&
      (clientReady ?? true) &&
      firebaseConfig.isNotEmpty &&
      (vapidKey?.isNotEmpty ?? false);

  /// macOS 상주 앱이 Firebase를 초기화하고 APNs 경유 토큰을 받는 데 필요한
  /// 값이 다 있는지(A안 설계 ③).
  ///
  /// VAPID 키는 보지 않는다 — 그건 브라우저 구독 전용 값이고, Apple 대상은
  /// APNs가 그 자리를 대신한다. [canSubscribeOnWeb]과 같은 이유로 서버가
  /// [appleClientReady]로 명시적으로 아니라고 하면 그 말을 따른다.
  bool get canSubscribeOnApple =>
      hasChannel('fcm') && (appleClientReady ?? true) && appleConfig.isNotEmpty;
}

/// [PushConfigDto.fromServer]의 정규화. 중첩(`fcm.*`)과 camelCase를 편다.
Map<String, dynamic> _flattenPushConfig(Map<String, Object?> json) {
  final Object? nestedRaw = json['fcm'];
  final Map<String, Object?> nested = nestedRaw is Map<String, Object?>
      ? nestedRaw
      : const <String, Object?>{};

  Object? pick(String snake, String camel) =>
      json[snake] ?? json[camel] ?? nested[snake] ?? nested[camel];

  // 서버가 쓰는 이름은 `web_config`다. `firebase_config`/`firebaseConfig`는
  // 이 DTO가 서버보다 먼저 존재하던 시절의 이름이라 호환으로 함께 본다.
  final Object? firebaseRaw =
      pick('web_config', 'webConfig') ??
      pick('firebase_config', 'firebaseConfig');
  final Map<String, Object?> firebase = firebaseRaw is Map<String, Object?>
      ? firebaseRaw
      : const <String, Object?>{};

  // A안 설계 ③: Apple(macOS 상주) 앱 설정. 서버가 쓰는 이름이 `apple_config`다.
  final Object? appleRaw = pick('apple_config', 'appleConfig');
  final Map<String, Object?> apple = appleRaw is Map<String, Object?>
      ? appleRaw
      : const <String, Object?>{};

  final Object? vapidRaw = pick('vapid_key', 'vapidKey');
  final String? vapid = vapidRaw is String && vapidRaw.isNotEmpty
      ? vapidRaw
      : null;

  final Object? optionsRaw = pick('options', 'options');
  final Map<String, Object?> options = optionsRaw is Map<String, Object?>
      ? optionsRaw
      : const <String, Object?>{};

  final Object? channelsRaw = json['channels'];
  final List<String> channels = channelsRaw is List
      ? channelsRaw.whereType<String>().toList(growable: false)
      // 채널 목록을 안 준 서버라면 자격증명이 온 채널만 활성으로 본다.
      : (firebase.isNotEmpty ||
            apple.isNotEmpty ||
            vapid != null ||
            nested.isNotEmpty)
      ? const <String>['fcm']
      : const <String>[];

  final Object? readyRaw = pick('client_ready', 'clientReady');
  final Object? appleReadyRaw = pick('apple_client_ready', 'appleClientReady');

  return <String, dynamic>{
    'channels': channels,
    'firebase_config': firebase,
    'apple_config': apple,
    'vapid_key': vapid,
    // 서버가 말하지 않았으면 null(=모름)로 남긴다. false로 접으면 구형 응답이
    // 전부 "쓸 수 없음"이 된다.
    'client_ready': readyRaw is bool ? readyRaw : null,
    'apple_client_ready': appleReadyRaw is bool ? appleReadyRaw : null,
    'options': options,
  };
}

/// `dashboard_push_log`의 마지막 한 줄(진단 화면용).
@freezed
abstract class PushLogEntryDto with _$PushLogEntryDto {
  const factory PushLogEntryDto({
    @Default('') String transport,
    @Default('') String target,
    @Default('') String result,
    String? detail,
    @JsonKey(name: 'created_at') @Default(0) int createdAt,
  }) = _PushLogEntryDto;

  factory PushLogEntryDto.fromJson(Map<String, dynamic> json) =>
      _$PushLogEntryDtoFromJson(json);
}

/// `GET /dashboard/diagnostics` 응답 — "왜 알림이 안 왔나"에 답하는 스냅샷.
@freezed
abstract class DiagnosticsDto with _$DiagnosticsDto {
  const DiagnosticsDto._();

  const factory DiagnosticsDto({
    @JsonKey(name: 'last_event_at') int? lastEventAt,
    @JsonKey(name: 'max_transition_id') @Default(0) int maxTransitionId,
    @JsonKey(name: 'pruned_below_id') @Default(0) int prunedBelowId,
    @JsonKey(name: 'last_push') PushLogEntryDto? lastPush,
    @JsonKey(name: 'device_failure_count') @Default(0) int deviceFailureCount,
    @JsonKey(name: 'subscription_failure_count')
    @Default(0)
    int subscriptionFailureCount,

    /// 채널별 자격증명 유무(예: `{'fcm': true, 'web-push': false}`).
    @Default(<String, bool>{}) Map<String, bool> channels,

    @JsonKey(name: 'table_counts')
    @Default(<String, int>{})
    Map<String, int> tableCounts,
  }) = _DiagnosticsDto;

  factory DiagnosticsDto.fromJson(Map<String, dynamic> json) =>
      _$DiagnosticsDtoFromJson(json);

  /// 자격증명이 있는 채널이 하나라도 있는지.
  bool get hasLivePushChannel => channels.values.any((bool ready) => ready);
}

/// `POST /dashboard/test-push` 응답의 채널별 결과 한 칸.
@freezed
abstract class PushChannelResultDto with _$PushChannelResultDto {
  const factory PushChannelResultDto({
    @Default(0) int sent,
    @Default(0) int removed,

    /// 보내지 않았다면 그 사유(자격증명 미설정·대상 없음 등).
    String? skipped,
  }) = _PushChannelResultDto;

  factory PushChannelResultDto.fromJson(Map<String, dynamic> json) =>
      _$PushChannelResultDtoFromJson(json);
}

/// `POST /dashboard/test-push` 응답.
@freezed
abstract class TestPushResultDto with _$TestPushResultDto {
  const TestPushResultDto._();

  const factory TestPushResultDto({
    @Default(false) bool ok,

    /// 발송용으로 적재된 합성 전이의 커서 id.
    @JsonKey(name: 'transition_id') @Default(0) int transitionId,

    @Default(<String, PushChannelResultDto>{})
    Map<String, PushChannelResultDto> channels,
  }) = _TestPushResultDto;

  factory TestPushResultDto.fromJson(Map<String, dynamic> json) =>
      _$TestPushResultDtoFromJson(json);

  /// 실제로 한 통이라도 나갔는지.
  int get sentCount => channels.values.fold(
    0,
    (int total, PushChannelResultDto result) => total + result.sent,
  );
}

/// `POST /dashboard/sessions/{key}/ack` 응답.
///
/// 정본 `client_actions.UserAck.response`/`guard`: 세션이 `waiting_input`일
/// 때만 실제로 전이하고 [state]가 `working`으로 온다. 그 밖에는(이미 다른
/// 상태) 멱등 no-op이라 [state]가 **호출 당시의 현재 상태 그대로** 돌아오고
/// [transitionId]는 null이다 — 두 기기가 동시에 눌러도 안전하다.
/// 화면 쪽 낙관 갱신(`sync_controller.dart`의 `ackSession`)은 이 [state]
/// 값으로 그대로 덮어쓰는 것만으로 성공/no-op 두 경우를 모두 정확히
/// 반영한다: no-op이면 서버가 되돌려준 값이 곧 되돌리기 전 값이다.
///
/// [state]가 nullable인 이유(검증 리뷰 지적 medium 수정): 세션이 아예 없을
/// 때(`ack.test.ts`의 "존재하지 않는 세션" 케이스)는 서버가
/// `{ok:true, state:null, transition_id:null}`을 돌려준다 — 이때 예전에는
/// `@Default('')`가 `null`을 빈 문자열로 접어버렸고, 그 빈 문자열이
/// `sessionStateDtoFromCode`(dashboard_provider.dart)의 미인식 코드 폴백을 타 화면에
/// 가짜 idle 배지로 영구히 남았다(롤백도 오류 표시도 없이). 지금은 `state`가
/// null이면 `ackSession`이 그 값을 그대로 쓰지 않고 되돌리기(rollback) 경로를
/// 탄다 — 아래 `sync_controller.dart` 참고.
@freezed
abstract class AckResultDto with _$AckResultDto {
  const factory AckResultDto({
    @Default(false) bool ok,
    String? state,

    /// 실제로 전이했을 때만 값이 있다(정본: 기록된 `UserAck` 이벤트가 만든
    /// 전이 id). no-op이면 null.
    @JsonKey(name: 'transition_id') int? transitionId,
  }) = _AckResultDto;

  factory AckResultDto.fromJson(Map<String, dynamic> json) =>
      _$AckResultDtoFromJson(json);
}

/// `POST /dashboard/subscriptions` 요청 본문(Web Push 구독 한 건).
///
/// 정본 `storage.tables.dashboard_push_subscriptions`가 말하는 컬럼
/// (endpoint, p256dh, auth)과 같은 평평한 모양이다 — 브라우저
/// `PushSubscription.toJSON()`의 `keys` 중첩은 호출자가 편다.
@freezed
abstract class PushSubscriptionDto with _$PushSubscriptionDto {
  const factory PushSubscriptionDto({
    required String endpoint,
    required String p256dh,
    required String auth,
  }) = _PushSubscriptionDto;

  factory PushSubscriptionDto.fromJson(Map<String, dynamic> json) =>
      _$PushSubscriptionDtoFromJson(json);
}

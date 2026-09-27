/// 커서 동기화의 순수 리듀서.
///
/// `GET /dashboard/sync` 응답 한 통(스냅샷이거나 델타)을 이전 상태에 접어
/// **세션 맵**과 **미확인 전이 큐**를 만든다. 네트워크도, 시계도, FFI도 만지지
/// 않는다 — 시각은 전부 인자([reduceSync]의 `nowMs`)로 들어온다. 그래서 이
/// 파일의 모든 규칙은 값 몇 개만으로 재현 가능한 단위 테스트로 닫힌다.
///
/// 정본은 `contracts/dashboard-protocol.v1.json`의 `sync` 절이고, 이 리듀서가
/// 지키는 불변식은 여섯 개다.
///
/// 1. **`reset:true`면 전량 교체.** 스냅샷이 곧 진실이고 로컬 상태는 버린다.
/// 2. **커서는 단조 증가만.** 델타 응답의 커서가 뒤로 가도 로컬 커서는 그대로.
///    (유일한 예외가 1번의 reset이다 — 그게 손상 복구 경로다.)
/// 3. **중복 `transition_id`는 무시.** 알림 워터마크([SyncState.alertWatermark])
///    아래의 전이는 이미 본 것이므로 알림 큐를 두 번 채우지 않는다.
/// 4. **`occurred_at` 역행 방어.** 세션의 마지막 발생 시각보다 과거인 전이는
///    기록만 하고 상태를 되돌리지 않는다(동률이면 전이 id가 큰 쪽이 이긴다).
///    서버 프로젝션(`routes.ts` 5-b)과 같은 규칙이다.
/// 5. **첫 기동(커서 없음)은 최근 10분치만 알림 대상.** 며칠 치 전이를 한꺼번에
///    받아도 알림이 폭주하지 않는다. 상태 반영은 전부 하고 알림만 자른다.
/// 6. **손상된 커서는 reset으로 복구.** [parseCursor]가 이상한 값을 null로
///    떨어뜨리고, [cursorForRequest]가 null을 돌려주면 다음 요청이 `since`
///    없이 나가 스냅샷을 받는다.
///
/// 도착 순서에 의존하지 않는다: 한 응답 안의 전이는 적용 전에 항상 id 오름차순
/// 으로 정렬한다(서버의 `ORDER BY id ASC`와 같은 순서). 그래서 전송 계층이
/// 순서를 섞어 주더라도 결과 세션 맵은 같다.
library;

import 'dart:math' as math;

import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';

part 'sync_reducer.freezed.dart';

/// 첫 기동 알림 창. 커서가 없을 때 이보다 오래된 전이는 알림 대상이 아니다.
const Duration kFirstBootAlertWindow = Duration(minutes: 10);

/// 미확인 알림 큐의 상한. 넘으면 가장 오래된 것부터 버린다.
const int kMaxPendingAlerts = 200;

/// 커서로 받아들일 수 있는 최댓값.
///
/// 서버는 Cloudflare Worker(JS)라 전이 id가 IEEE754 정수 안전 범위를 넘지
/// 않는다. 이보다 큰 값은 저장소가 손상됐다는 뜻이다.
const int kMaxSafeCursor = 9007199254740991;

/// 동기화가 만들어 내는 클라이언트 상태 전부.
@freezed
abstract class SyncState with _$SyncState {
  const SyncState._();

  const factory SyncState({
    /// `session_key` -> 세션 카드.
    @Default(<String, SessionViewDto>{}) Map<String, SessionViewDto> sessions,

    /// 마지막으로 반영한 전이 id. null이면 아직 한 번도 동기화하지 않았다
    /// (= 다음 요청은 `since` 없이 나가 스냅샷을 받는다).
    int? cursor,

    /// 사용자가 아직 확인하지 않은 알림 전이(id 오름차순).
    @Default(<TransitionDto>[]) List<TransitionDto> pendingAlerts,

    /// 세션별로 마지막에 반영한 전이 id. `occurred_at` 동률일 때의 승자를
    /// 정하는 데만 쓴다.
    @Default(<String, int>{}) Map<String, int> lastTransitionIdBySession,

    /// 알림 판정을 마친 최대 전이 id. 이 값 이하는 중복이다.
    @Default(0) int alertWatermark,

    /// 서버가 limit에 걸려 잘랐다. true면 즉시 한 번 더 당겨야 한다.
    @Default(false) bool hasMore,

    /// 마지막 응답의 서버 시각(epoch ms).
    @Default(0) int serverTime,

    /// 서버가 쓰는 `DASHBOARD_STALL_MS`.
    @Default(kDefaultStallMs) int stallMs,

    /// 음소거 종료 시각(epoch ms). null이면 음소거 아님.
    int? muteUntil,

    /// UI 표시 언어(서버 `dashboard_settings.ui_lang`, 정본은 서버 —
    /// 서버 상태 계약). [muteUntil]/[hookSkew]와 같은 절대값
    /// 서버 상태 관용 — [reduceSync]가 매 응답(스냅샷·델타 공통)마다
    /// `response.uiLang`을 무조건 대입한다. `'ko'`/`'en'` 또는 null —
    /// null이면 서버가 아직 정하지 않아 각 기기가 자기 플랫폼 로케일을
    /// 쓴다(`i18n/t.dart`의 `localeProvider`, `app.dart`의 반영 배선 참고).
    String? uiLang,

    /// 이 값보다 작은 전이 id는 서버에서 이미 정리됐다.
    @Default(0) int prunedBelowId,

    /// `session_key` -> 사용자가 마지막으로 확인 처리(seen)한 전이 id.
    ///
    /// 읽음 계약: 정본 `sync.response.seen`(최상위 배열, 스냅샷·델타
    /// 공통, 절대값)을 접은 결과다 — 예전에는 이 사실이
    /// `SessionViewDto.seenTransitionId`에도 같이 실려 왔지만, 같은 사실의
    /// 복수 표현을 없애면서 이 맵이 유일한 표현이 됐다. [reduceSync]가 매
    /// 응답마다 `response.seen`의 각 항목을 **MAX(로컬, 수신)**로
    /// 멱등 병합한다(값을 낮추지 않는다) — 낙관 갱신(`SyncController.
    /// markSeen`/`ackSession`) 직후, 아직 그 갱신을 반영하지 못한 채
    /// 비행 중이던 옛 응답이 도착해도 이미 올라간 로컬 값을 되돌리지 않는다
    /// (미확인 점이 잠깐 되살아나는 깜빡임 방지). 키가 아예 없으면(한
    /// 번도 seen 정보를 받은 적 없음) [isSessionUnseen]이 [seenWatermark]로
    /// 접는다.
    @Default(<String, int>{}) Map<String, int> seenTransitionIds,

    /// 읽음/안읽음(seen) 기능의 "첫 도입 미확인 벽" 워터마크. null이면
    /// "아직 한 번도 세운 적 없음"이고, 이 상태에서 받는 **첫 스냅샷**의
    /// 커서로 딱 한 번만 올라간다([alertWatermark]가 매 reset마다 올라가는
    /// 것과 달리, 이 값은 정말로 한 번만 올라간다 — 재연결·재설치·캐시
    /// 삭제 뒤의 재스냅샷까지 벽을 다시 세우면 그 사이에 쌓인 진짜 미확인
    /// 전이가 지워지기 때문이다). [isFirstBoot](`cursor == null`)를 트리거로
    /// 쓰지 않는 이유: 이미 커서를 갖고 있던 기존 설치(이 기능 도입 이전에
    /// 깔려 있던 앱)에 이 기능이 배포되면 `isFirstBoot`가 처음부터 false라
    /// 벽이 영영 세워지지 않아 모든 카드가 미확인으로 뜬다(리뷰 지적 high).
    /// 그래서 이 값 자체가 "세웠는가"의 유일한 신호이자, [restoreState]로
    /// 영속화·복원된다(재기동마다 다시 0으로 풀리면 안 되므로).
    /// [seenTransitionIds]에 키가 없는 세션(한 번도 seen 정보를 받은 적
    /// 없음)은 이 값(null이면 0으로 접는다) 이하의 [SessionViewDto.
    /// lastTransitionId]를 "첫 스냅샷 시점에 이미 본 것"으로 간주한다 —
    /// [isSessionUnseen] 참고.
    int? seenWatermark,

    /// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
    /// [muteUntil]과 같은 "절대값 서버 상태" 관용 — [reduceSync]가 매
    /// 응답(스냅샷·델타 공통)마다 `response.hookSkew`를 그대로 대입한다.
    /// [seenTransitionIds]의 MAX 병합과 달리 낮아지지 않는 값이 아니다:
    /// 기계가 훅을 갱신하면 다음 응답에서 그 기계가 이 목록에서 통째로
    /// 사라져야 하므로, 옛 값을 지키는 병합은 오히려 틀린 동작이다.
    @Default(<HookSkewDto>[]) List<HookSkewDto> hookSkew,
  }) = _SyncState;

  /// 아직 한 번도 동기화하지 않은 상태.
  bool get isFirstBoot => cursor == null;

  /// `has_more`가 켜져 있으면 커서를 들고 즉시 재요청한다.
  bool get shouldFetchAgain => hasMore;

  /// 종료되지 않은 세션만(화면 기본 목록).
  List<SessionViewDto> get activeSessions => sessions.values
      .where((SessionViewDto session) => !session.isEnded)
      .toList(growable: false);

  /// 지금이 음소거 구간인지.
  bool isMuted(int nowMs) => (muteUntil ?? 0) > nowMs;

  /// TASK P-impl (2): 직전 동기화 결과에 `working` 상태 세션이 하나라도
  /// 있는가. `sync_controller.dart`의 적응형 비활성 폴링 간격이 이 값으로
  /// 8초(있음)/30초(없음)를 고른다 — 사람이 지금 agent를 보고 있을
  /// 가능성이 높을수록 더 자주 당긴다.
  bool get hasWorkingSession => sessions.values.any(
    (SessionViewDto session) => session.state == kDashboardStateWorking,
  );

  /// TASK A-impl (2): 지금 사람의 개입을 기다리는 세션 수
  /// (`waiting_input` + `stalled`, [SessionViewDto.needsAttention]).
  /// `platform/tray_native.dart`의 메뉴 바 주의 배지가 이 값을 그대로
  /// 쓴다 — [hasWorkingSession]이 폴링 간격을 고르는 것과 같은 자리·같은
  /// 모양의 파생값이다(화면·트레이가 세션 맵을 각자 다시 훑지 않는다).
  int get attentionSessionCount => sessions.values
      .where((SessionViewDto session) => session.needsAttention)
      .length;

  /// 지금 사람의 입력을 기다리는(`waiting_input`) 세션 수.
  ///
  /// [attentionSessionCount]는 두 상태를 합산하지만, 트레이 아이콘은 색으로
  /// 심각도를 나눠 쓴다(waiting=호박, stalled=적갈 — `platform/
  /// tray_native.dart`의 `trayBadgeIconAssetPath`) — 합산값 하나로는 어느
  /// 색을 띄울지 못 정하므로 상태별로 따로 센다. [hasWorkingSession]과
  /// 같은 자리·같은 모양의 파생값이다.
  int get waitingInputSessionCount => sessions.values
      .where((SessionViewDto s) => s.state == kDashboardStateWaitingInput)
      .length;

  /// 지금 멈춘 것으로 추정되는(`stalled`) 세션 수.
  ///
  /// [waitingInputSessionCount]와 같은 이유 — 트레이 아이콘 색의 최우선
  /// 신호(stalled가 waiting보다 앞선다)라 이 값이 1 이상이면 아이콘은
  /// 적갈이다.
  int get stalledSessionCount => sessions.values
      .where((SessionViewDto s) => s.state == kDashboardStateStalled)
      .length;

  /// TASK TRAY-unseen: 지금 "미확인"(카드의 미확인 점)인 활성 세션 수.
  ///
  /// [attentionSessionCount]와는 축이 다르다 — attention은 "행동이
  /// 필요한가"(상태 기반, 읽어도 안 꺼짐), 이건 "아직 안 열어 봤는가"
  /// (읽음 기반, 열면 즉시 꺼짐)다. `platform/tray_native.dart`의 트레이
  /// 숫자(제목/툴팁)가 이 값을 그대로 쓴다 — 카드를 열어 읽으면 그
  /// 카드의 미확인 점이 꺼지는 것과 정확히 같은 순간에 트레이 숫자도
  /// 줄어든다. [isSessionUnseen] 판정을 그대로 재사용한다.
  int get unseenSessionCount => activeSessions.where(isSessionUnseen).length;

  /// TASK TRAY-mute-working: [unseenSessionCount] 중 트레이(미는 신호면)가
  /// 보고할 몫 — `state == working`인 미확인 세션은 뺀다.
  ///
  /// 뷰(`sessions_page.dart`의 카드 미확인 점, [unseenSessionCount])는
  /// 사용자가 당겨서 보는 관찰면이라 working으로의 변화도 미확인으로
  /// 보여주는 게 정보값이지만, 트레이·알림은 사용자를 미는 신호면이라
  /// "행동할 일·확인할 결과·개입할 이상"일 때만 울려야 한다 — "그냥 일하는
  /// 중"이 숫자를 올리면 신호가 희석된다. 서버 push가 애초에 working
  /// 전이를 쏘지 않는 것([kDashboardPushStates]에 `working`이 없음), 유휴
  /// 알림을 분리한 것과 같은 원칙이다 — 이 필터로 "미는 표면은 전부
  /// working에 침묵, 당기는 표면은 전부 표시"가 시스템 전체에서 일관된다.
  /// [platform/tray_native.dart]의 `trayBadgeCountsListenable`이 이 값을
  /// unseen 축으로 쓴다(카드의 [isSessionUnseen] 자체는 이 필터와 무관하게
  /// 그대로다 — working이어도 카드 점은 계속 미확인으로 뜬다).
  int get unseenReportableSessionCount => unseenReportableSessions.length;

  /// [unseenReportableSessionCount]가 세는 바로 그 세션들의 목록 — 같은
  /// 필터의 정본이다. 트레이 우클릭 메뉴의 "안읽은 세션" 서브메뉴가 항목을
  /// 나열할 때 이 목록을 쓴다(`platform/tray_native.dart`의
  /// `trayMenuInputsListenable`). 순서는 [activeSessions]와 같은 맵 순서 —
  /// 표시 순서는 소비하는 쪽이 정한다(트레이는 `sortedSessionsFor`를 거친다).
  List<SessionViewDto> get unseenReportableSessions => activeSessions
      .where((session) => session.state != kDashboardStateWorking)
      .where(isSessionUnseen)
      .toList(growable: false);

  /// [session]이 지금 "미확인"인지 — attention 점(행동 필요)과 독립적으로
  /// 켜지는 별도 표시다. 기준은 전이 id 비교뿐, 시계는 전혀 관여하지 않는다
  /// (stale 판정 계약와 무긴장).
  ///
  /// [seenTransitionIds]에 이 세션 키가 없으면(한 번도 seen 정보를 받은 적
  /// 없음) 이 세션의 [SessionViewDto.lastTransitionId]가 [seenWatermark]
  /// 이하일 때 "첫 스냅샷 시점에 이미 본 것"으로 접는다 — 앱을 처음 깐
  /// 사람의 화면이 이미 몇 주 된 세션 전부를 "안읽음"으로 덮어버리는 것을
  /// 막는 첫 도입 미확인 벽이다. 워터마크보다 **큰** 전이(첫 스냅샷 이후
  /// 실제로 새로 생긴 변화)는 여전히 미확인으로 뜬다.
  bool isSessionUnseen(SessionViewDto session) {
    final last = session.lastTransitionId;
    if (last == null) return false;
    final seen = seenTransitionIds[session.key];
    if (seen != null) return last > seen;
    return last > (seenWatermark ?? 0);
  }
}

/// 스냅샷/델타 두 경로가 같은 상태로 수렴했는지 비교할 때 쓰는 투영.
///
/// 전이 로그(`dashboard_transitions`)만으로는 복원할 수 없는 필드
/// (`last_event`·`created_at`·`updated_at`·`stale`)는 일부러 뺐다.
typedef SessionCore = ({
  String key,
  String source,
  String sessionId,
  String project,
  String? host,
  String state,
  String? lastMessage,
  int? lastOccurredAt,
});

/// [SessionCore] 하나를 뽑는다.
SessionCore sessionCore(SessionViewDto session) => (
  key: session.key,
  source: session.source,
  sessionId: session.sessionId,
  project: session.project,
  host: session.host,
  state: session.state,
  lastMessage: session.lastMessage,
  lastOccurredAt: session.lastOccurredAt,
);

/// 세션 맵 전체의 투영.
Map<String, SessionCore> sessionCores(Map<String, SessionViewDto> sessions) =>
    sessions.map(
      (String key, SessionViewDto session) =>
          MapEntry<String, SessionCore>(key, sessionCore(session)),
    );

/// 저장소에서 읽은 커서 값을 검증한다. 손상된 값은 null(= 스냅샷 복구).
///
/// 받아들이는 모양: `int`, 정수인 유한 `double`, 십진 문자열. 그 밖(문자열
/// 쓰레기·음수·비현실적으로 큰 수·null)은 전부 null로 떨어뜨린다.
int? parseCursor(Object? raw) {
  if (raw is int) return _validCursor(raw);
  if (raw is double) {
    if (!raw.isFinite || raw != raw.roundToDouble()) return null;
    if (raw.abs() > kMaxSafeCursor) return null;
    return _validCursor(raw.toInt());
  }
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    return parsed == null ? null : _validCursor(parsed);
  }
  return null;
}

int? _validCursor(int value) =>
    value >= 0 && value <= kMaxSafeCursor ? value : null;

/// 저장된 커서로 상태를 되살린다. 손상된 커서는 조용히 버려지고, 그 결과
/// [cursorForRequest]가 null을 돌려줘 다음 동기화가 스냅샷을 받는다.
///
/// [persistedSeenWatermark]는 영속화된 첫 도입 미확인 벽 워터마크다(리뷰
/// 지적 high 수정) — 커서와 달리 이 값은 "손상되면 null(=아직 안 세움)로
/// 접는다"가 아니라 [parseCursor]와 같은 검증을 거친다(둘 다 서버가 주는
/// 전이 id 범위를 갖는 값이라 같은 손상 형태를 가질 수 있다). 복원에
/// 실패하면(처음 도입되는 기존 설치 포함) null로 남아, 다음에 실제로 받는
/// 스냅샷에서 [reduceSync]가 정상적으로 딱 한 번 세운다.
SyncState restoreState({
  Object? persistedCursor,
  Object? persistedSeenWatermark,
}) => SyncState(
  cursor: parseCursor(persistedCursor),
  seenWatermark: parseCursor(persistedSeenWatermark),
);

/// 다음 `GET /dashboard/sync` 요청의 `since` 값. null이면 스냅샷을 청한다.
///
/// null이 되는 경우는 셋이다: (1) 첫 기동, (2) 커서가 손상됨,
/// (3) 커서가 이미 정리된 구간(`pruned_below_id` 아래)을 가리킴 — 서버도
/// 어차피 reset을 줄 자리라 왕복 한 번을 아낀다.
int? cursorForRequest(SyncState state) {
  final cursor = state.cursor;
  if (cursor == null) return null;
  if (_validCursor(cursor) == null) return null;
  if (cursor < state.prunedBelowId) return null;
  return cursor;
}

/// 응답 한 통을 접는다. [nowMs]는 첫 기동 10분 규칙에만 쓰이며,
/// 기기 시계 대신 `response.serverTime`을 넣는 것이 기본이다(정본
/// `sync.response.fields.server_time`).
SyncState reduceSync(
  SyncState state,
  SyncResponseDto response, {
  required int nowMs,
}) {
  final sessions = <String, SessionViewDto>{};
  final appliedIds = <String, int>{};
  final alerts = <TransitionDto>[];
  var watermark = state.alertWatermark;
  var firstBoot = state.isFirstBoot;
  // 첫 도입 미확인 벽: [state.seenWatermark]가 아직 null(=한 번도 세운 적
  // 없음)인 채로 스냅샷을 받을 때만 딱 한 번 세운다. isFirstBoot(커서 유무)
  // 를 트리거로 쓰지 않는다 — 이 기능 도입 이전부터 커서를 갖고 있던 기존
  // 설치는 isFirstBoot가 처음부터 false라 그 신호로는 벽이 영영 안
  // 세워진다(리뷰 지적 high). seenWatermark 자신을 트리거 겸 값으로 쓰면
  // "아직 안 세움"과 "0으로 세움"을 구분할 수 있어 이 문제가 없다.
  var seenWatermark = state.seenWatermark;
  if (seenWatermark == null && response.reset) {
    seenWatermark = response.cursor;
  }

  if (response.reset) {
    // 1. reset은 전량 교체다. 미확인 알림 큐도 함께 비운다 — 스냅샷에는
    //    전이 id가 없어서 "확인했다"고 표시할 대상이 남지 않기 때문이다.
    //    화면에 필요한 정보(어느 세션이 지금 waiting_input인가)는 스냅샷의
    //    세션 상태가 그대로 갖고 있다.
    for (final session in response.sessions) {
      sessions[session.key] = session;
    }
    // 스냅샷은 커서 이하의 전이를 이미 반영한 결과다. 그 아래 전이가 뒤늦게
    // 배달돼도 알림이 되면 안 된다.
    watermark = math.max(watermark, response.cursor);
    firstBoot = false;
  } else {
    sessions.addAll(state.sessions);
    appliedIds.addAll(state.lastTransitionIdBySession);
    alerts.addAll(state.pendingAlerts);
  }

  // 도착 순서를 서버의 적재 순서로 되돌린다. 이 한 줄이 "무작위 순서로 와도
  // 같은 결과"를 보장한다.
  final ordered = List<TransitionDto>.of(response.transitions)
    ..sort((TransitionDto a, TransitionDto b) => a.id.compareTo(b.id));

  // 첫 기동이면 알림 바닥은 now-10분, 아니면 없음.
  final alertFloor = firstBoot
      ? nowMs - kFirstBootAlertWindow.inMilliseconds
      : null;

  for (final transition in ordered) {
    final existing = sessions[transition.sessionKey];
    final appliedId = appliedIds[transition.sessionKey] ?? 0;
    if (existing == null || _isNewer(existing, appliedId, transition)) {
      sessions[transition.sessionKey] = _project(existing, transition);
      appliedIds[transition.sessionKey] = transition.id;
    }

    final isDuplicate = transition.id <= watermark;
    final isTooOldForFirstBoot =
        alertFloor != null && transition.occurredAt < alertFloor;
    if (transition.isAlert && !isDuplicate && !isTooOldForFirstBoot) {
      alerts.add(transition);
    }
    watermark = math.max(watermark, transition.id);
  }

  final trimmed = alerts.length > kMaxPendingAlerts
      ? alerts.sublist(alerts.length - kMaxPendingAlerts)
      : alerts;

  // 읽음 계약: `response.seen`은 스냅샷·델타 공통으로 매 응답에 실리는
  // 절대값이다(mute_until과 같은 선례) — reset 여부와 무관하게 항상
  // 로컬 맵과 키별 MAX로 멱등 병합한다. null 항목(그 세션에 대해 한 번도
  // seen 정보가 없음)은 건너뛴다 — "모른다"로 기존 값을 지우지 않는다.
  // 이 병합이 낙관 갱신(`SyncController._bumpSeen`) 직후 비행 중이던 옛
  // 응답이 도착해도 이미 올라간 로컬 값을 되돌리지 않는 깜빡임 방지의
  // 핵심이다.
  final mergedSeen = Map<String, int>.of(state.seenTransitionIds);
  for (final marker in response.seen) {
    final incoming = marker.seenTransitionId;
    if (incoming == null) continue;
    final existing = mergedSeen[marker.key];
    if (existing == null || incoming > existing) {
      mergedSeen[marker.key] = incoming;
    }
  }

  return state.copyWith(
    sessions: Map<String, SessionViewDto>.unmodifiable(sessions),
    cursor: _nextCursor(state.cursor, response),
    pendingAlerts: List<TransitionDto>.unmodifiable(trimmed),
    lastTransitionIdBySession: Map<String, int>.unmodifiable(appliedIds),
    alertWatermark: watermark,
    hasMore: response.hasMore,
    serverTime: response.serverTime > 0
        ? response.serverTime
        : state.serverTime,
    stallMs: response.stallMs > 0 ? response.stallMs : state.stallMs,
    muteUntil: response.muteUntil,
    // muteUntil/hookSkew와 같은 절대값 관용 — reset이든 델타든 이번 응답
    // 값으로 무조건 덮는다(병합하지 않는다).
    uiLang: response.uiLang,
    // 보존 정리 경계는 뒤로 가지 않는다.
    prunedBelowId: math.max(state.prunedBelowId, response.prunedBelowId),
    seenTransitionIds: Map<String, int>.unmodifiable(mergedSeen),
    seenWatermark: seenWatermark,
    // mute_until과 같은 절대값 관용 — reset이든 델타든 이번 응답 값으로
    // 무조건 덮는다(병합하지 않는다). 빈 배열이 오면 스큐가 소멸했다는
    // 뜻이라 그대로 비운다.
    hookSkew: response.hookSkew,
  );
}

/// 알림을 확인 처리한다(큐에서 제거). 나머지 상태는 건드리지 않는다.
SyncState acknowledgeAlerts(SyncState state, Iterable<int> transitionIds) {
  final drop = transitionIds.toSet();
  if (drop.isEmpty || state.pendingAlerts.isEmpty) return state;
  final kept = state.pendingAlerts
      .where((TransitionDto alert) => !drop.contains(alert.id))
      .toList(growable: false);
  if (kept.length == state.pendingAlerts.length) return state;
  return state.copyWith(pendingAlerts: List<TransitionDto>.unmodifiable(kept));
}

/// 큐 전체를 확인 처리한다.
SyncState acknowledgeAllAlerts(SyncState state) => state.pendingAlerts.isEmpty
    ? state
    : state.copyWith(pendingAlerts: const <TransitionDto>[]);

/// 커서 단조 증가 규칙. reset만이 이 규칙의 예외이자 복구 경로다.
int? _nextCursor(int? current, SyncResponseDto response) {
  final incoming = _validCursor(response.cursor);
  if (response.reset) return incoming;
  if (current == null) return incoming;
  if (incoming == null) return current;
  return incoming > current ? incoming : current;
}

/// 이 전이가 세션의 현재 상태보다 새로운가(정본 `states.invariants`의
/// 순서 역행 방어). 동률이면 전이 id가 큰 쪽이 새것이다.
bool _isNewer(
  SessionViewDto existing,
  int appliedId,
  TransitionDto transition,
) {
  final lastOccurred = existing.lastOccurredAt;
  if (lastOccurred == null) return true;
  if (transition.occurredAt != lastOccurred) {
    return transition.occurredAt > lastOccurred;
  }
  return transition.id > appliedId;
}

/// 전이 한 줄을 세션 카드에 반영한다.
///
/// 없던 세션은 전이만으로 새로 만든다(정본 `sync.transition_object.apply_rule`).
/// 이미 있으면 서버 프로젝션(`routes.ts`의 `ON CONFLICT ... COALESCE`)과 같은
/// 규칙으로 덮는다 — 전이가 모르는 값(null)은 기존 값을 지우지 않는다.
SessionViewDto _project(SessionViewDto? existing, TransitionDto transition) {
  if (existing == null) {
    return SessionViewDto(
      key: transition.sessionKey,
      state: transition.toState,
      source: transition.source.isEmpty
          ? transition.sourceFromKey
          : transition.source,
      sessionId: transition.sessionIdFromKey,
      project: transition.project ?? '',
      host: transition.host,
      // 전이 로그에는 이벤트 이름이 없다. 다음 스냅샷이 채운다.
      lastEvent: '',
      lastMessage: transition.message,
      lastOccurredAt: transition.occurredAt,
      createdAt: transition.createdAt,
      updatedAt: transition.createdAt,
      // 전이는 정의상 상태를 바꾼 이벤트 = 진척이다. transition.createdAt은
      // 서버 수신 시각(routes.ts appendTransition의 `now`)이라 계약의
      // last_progress_at 정의와 그대로 맞는다(리뷰 지적 high 수정).
      lastProgressAt: transition.createdAt,
      // seen 기능의 기준값(0004): sync.ts는 델타 응답에 sessions를 담지
      // 않으므로, 델타로만 존재를 알게 된 세션은 이 전이 자체의 id가 곧
      // last_transition_id다(appendTransition이 이 자리에서 기록하는 것과
      // 같은 값).
      lastTransitionId: transition.id,
    );
  }
  return existing.copyWith(
    state: transition.toState,
    source: transition.source.isEmpty ? existing.source : transition.source,
    project: transition.project ?? existing.project,
    host: transition.host ?? existing.host,
    lastMessage: transition.message ?? existing.lastMessage,
    lastOccurredAt: transition.occurredAt,
    updatedAt: math.max(existing.updatedAt, transition.createdAt),
    lastProgressAt: math.max(
      existing.lastProgressAt ?? 0,
      transition.createdAt,
    ),
    // 새 전이가 왔으니 legacy stale 플래그는 더 이상 유효하지 않다.
    stale: false,
    // 뒤로 가지 않는다(도착 순서와 무관하게 max) — lastProgressAt과 같은 관용.
    lastTransitionId: math.max(existing.lastTransitionId ?? 0, transition.id),
  );
}

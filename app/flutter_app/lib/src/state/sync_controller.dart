/// 동기화 스케줄러와 생명주기 컨트롤러 (T14).
///
/// `sync_reducer.dart`(순수 리듀서)와 `dashboard_api.dart`(전송 시임)는 이미
/// "무엇을 어떻게 반영하는가"와 "어떻게 보내는가"를 갖고 있다. 이 파일이
/// 더하는 건 딱 하나 — **언제 부르는가**다: 포그라운드/비활성 주기 폴링,
/// 트리거가 오면 그 주기를 기다리지 않는 즉시 1회 실행, 실패가 이어지면
/// 늘어나는 지수 백오프, 401/403에서 완전히 멈추고 설정 화면을 가리키는
/// 신호, 그리고 커서 영속화·마지막 성공/오류 노출.
///
/// 시간·타이머·기기 활성 상태는 전부 이 파일 하단의 시임([SyncScheduleFn]/
/// [SyncNowMsFn]/[SyncActivityWatchFn])을 거친다 — `capability_provider.dart`
/// 등과 같은 3계층(typedef -> `Provider<Fn>` -> 얇은 함수) 패턴이다. 그래서
/// 테스트는 실제 `Timer`·실제 시계·실제 `AppLifecycleListener` 없이 폴링
/// 간격·백오프 상한·401 차단을 값만으로 재현한다(`sync_controller_test.dart`
/// 상단 문서 참고).
///
/// **의도적으로 하지 않는 것.**
/// - 세션 상태 문자열 해석(`stateForEvent` 등, `dashboard_provider.dart`)은
///   화면 계층 몫이다. 이 컨트롤러는 `sync_reducer.dart`가 이미 접은
///   [SyncState]를 그대로 들고 있을 뿐 다시 해석하지 않는다.
/// - 알림 발송(`notifyForAlerts`, `notify_provider.dart`)도 별도 관심사다.
///   이 컨트롤러는 `pendingAlerts`를 채우기만 하고, 그걸 언제 어떻게
///   알림으로 바꾸는지는 그 알림을 구독하는 쪽(향후 과제)의 몫이다.
/// - **"push 수신"·"알림 클릭" 즉시 트리거는 지금 코드베이스에 그 사건을
///   알려줄 이벤트 소스가 아예 없다** (`push_provider.dart`/
///   `push_bridge_web.dart`/`push_bridge_io.dart`는 구독 *등록*만, 수신·클릭
///   처리는 어디에도 없다 — 서비스워커 스크립트조차 아직 없다). 이 두
///   트리거의 진입점은 공개 메서드 [SyncController.triggerNow]로 이미
///   열려 있다 — push 수신 핸들러가 생기는 다음 과제가 그 핸들러 안에서
///   `ref.read(syncControllerProvider.notifier).triggerNow()`를 부르면 그
///   요구사항이 그대로 채워진다. 지금은 메커니즘만 완성하고 호출부가 없다는
///   것을 여기 정직하게 남긴다.
///
/// **TASK P-impl (3)이 채운 것.** 맥이 잠에서 깰 때는 위 문단과 다르다 —
/// 이벤트 소스가 이미 있다(`NSWorkspace.didWakeNotification`, AppKit). 그래서
/// 이 트리거는 바깥 호출부를 기다리지 않고 이 파일 안에서 직접 배선한다:
/// [SyncWakeWatchFn]이 그 신호를 스트림으로 들여오고, [SyncController.build]가
/// 이벤트마다 [SyncController.triggerNow]를 부른다 — `_activitySubscription`과
/// 정확히 같은 자리·같은 모양이다.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show
        SessionViewDto,
        TransitionDto,
        kDashboardStateWorking,
        kDashboardStates;
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/platform/background_activity_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/background_activity_web.dart'
    as wake_bridge;

part 'sync_controller_actions.dart';

// ─── 정책 상수 ──────────────────────────────────────────────────────────

/// 포그라운드일 때 폴링 간격.
const Duration kSyncForegroundInterval = Duration(seconds: 3);

/// 비활성(백그라운드)일 때 폴링 간격 — 직전 동기화에 `working` 세션이
/// **없을 때**의 기본값이다(TASK P-impl (2)). 데몬이 쓰던 30초/8초 조합보다
/// 보수적으로 8초/30초를 쓴다: 이 앱은 창을 숨겨도 살아 있는 유일한 배너
/// 발신자라, 데몬만큼 자주 깨어날 필요가 없다.
const Duration kSyncInactiveInterval = Duration(seconds: 30);

/// 비활성(백그라운드)일 때, 직전 동기화에 `working` 세션이 **있을 때**의
/// 폴링 간격(TASK P-impl (2)). 누군가 지금 agent를 지켜보고 있을 가능성이
/// 높은 구간이라 더 자주 당긴다. [SyncState.hasWorkingSession] 참고.
const Duration kSyncFastInactiveInterval = Duration(seconds: 8);

/// 지수 백오프의 상한. 연속 실패가 아무리 늘어도 이 값을 넘지 않는다.
const Duration kSyncBackoffCap = Duration(seconds: 60);

// ─── 순수 정책 함수 ──────────────────────────────────────────────────────

/// 다음 폴링까지 기다릴 시간. 실패가 없으면 포그라운드/비활성 기본 간격,
/// 있으면 [backoffDelay]로 넘긴다.
///
/// [hasWorkingSession]은 비활성일 때만 의미가 있다(TASK P-impl (2)) —
/// 포그라운드 3초는 이미 working 유무와 무관하게 가장 빠른 간격이라 더
/// 빨라질 여지가 없다. 기본값 `false`는 기존 호출부·테스트가 이 인자
/// 없이도 예전과 같은 30초를 계속 받게 한다.
///
/// 순수 함수라 `Timer` 없이 정수 몇 개만으로 완료 기준 (a)(b)(c)를 전부
/// 재현할 수 있다.
Duration pollInterval({
  required bool isForeground,
  required int consecutiveFailures,
  bool hasWorkingSession = false,
}) {
  final base = isForeground
      ? kSyncForegroundInterval
      : (hasWorkingSession ? kSyncFastInactiveInterval : kSyncInactiveInterval);
  if (consecutiveFailures <= 0) return base;
  return backoffDelay(base: base, consecutiveFailures: consecutiveFailures);
}

/// `base * 2^consecutiveFailures`, [kSyncBackoffCap]에서 잘린다.
///
/// 실패 횟수를 12로 접는 건 오버플로 방지용 안전장치일 뿐이다 — 가장 작은
/// `base`(3초)로도 2^12배면 이미 상한을 훨씬 넘어서 실질적인 값에는 영향이
/// 없다.
Duration backoffDelay({
  required Duration base,
  required int consecutiveFailures,
}) {
  final shift = consecutiveFailures < 0
      ? 0
      : (consecutiveFailures > 12 ? 12 : consecutiveFailures);
  final scaled = base * (1 << shift);
  return scaled > kSyncBackoffCap ? kSyncBackoffCap : scaled;
}

/// 실패를 화면이 구분해야 하는 종류로 나눈다. 정본 밖(HTTP 계층)의
/// [DashboardApiException] 계층을 그대로 반영한다.
enum SyncErrorKind {
  /// 401/403 — 재시도해도 같은 결과다. 사용자가 설정을 고쳐야 한다.
  auth,

  /// 타임아웃·전송 실패. 재시도가 의미 있다.
  network,

  /// 5xx. 재시도가 의미 있다.
  server,

  /// 서버가 이 클라이언트가 모르는 프로토콜 major를 말한다. 앱 갱신이 필요하다.
  protocol,

  /// 그 밖의 [DashboardApiException](4xx, 응답 파싱 실패 등) — 재시도해도
  /// 대개 같은 결과지만 401/403만큼 확실하지 않아 자동으로는 멈추지 않는다.
  other,

  /// [DashboardApiException]이 아닌 예외 — 시임 자체의 버그, 응답 해석 중의
  /// 타입 불일치, provider 오류 등. 원문은 런타임이 만든 개발자용 덤프라
  /// 화면에 보이지 않는다(`sessions_page.dart`의 `syncErrorDetailText`가
  /// 표시 언어의 일반 문장을 보인다). 원문은 [SyncErrorInfo.fromError]가
  /// 로그로 남긴다. 재시도 정책은 [other]와 같다.
  unexpected,
}

/// [error]를 [SyncErrorKind]로 분류한다. [DashboardApiException]이 아닌
/// 예외(시임 자체의 버그 등)는 [SyncErrorKind.unexpected]로 접어 안전하게
/// 다룬다.
SyncErrorKind classifyError(Object error) => switch (error) {
  DashboardUnauthorized() || DashboardForbidden() => SyncErrorKind.auth,
  DashboardTimeout() || DashboardNetworkFailure() => SyncErrorKind.network,
  DashboardServerError() => SyncErrorKind.server,
  DashboardProtocolMismatch() => SyncErrorKind.protocol,
  DashboardApiException() => SyncErrorKind.other,
  _ => SyncErrorKind.unexpected,
};

/// 이 종류의 실패가 "재시도를 멈추고 설정 화면으로 보내야 하는" 401/403인가.
bool isAuthFailure(SyncErrorKind kind) => kind == SyncErrorKind.auth;

// ─── 컨트롤러가 노출하는 값 ──────────────────────────────────────────────

/// 지금 사이클이 어느 단계인가.
enum SyncPhase {
  /// 서버 주소가 아직 없다(T-wire/U-fix) — 폴링을 시작하지 않는다. 홈
  /// 분기는 이미 이 경우 설정 화면을 보여준다([DashboardConfigValues]
  /// 참고); 이 phase는 그와 별개로 컨트롤러 스스로가 네트워크를 아예
  /// 시도하지 않는다는 것을 보장한다. [SyncController.configureAndStart]가
  /// 설정 저장 성공 뒤 이 phase를 벗어난다.
  unconfigured,

  /// 다음 폴링을 기다리는 중(성공했거나 아직 첫 시도 전).
  idle,

  /// 요청이 나가 있다.
  syncing,

  /// 방금 실패해서 백오프 간격을 기다리는 중(401/403 제외).
  backingOff,

  /// 401/403을 만나 재시도를 완전히 멈췄다. [SyncControllerState.needsSetup]이
  /// 이 상태를 가리킨다 — 화면은 설정 화면으로 유도해야 한다.
  stopped,
}

/// 마지막 오류 한 건. 화면의 "오류 배지"가 그리는 재료다 — 실패의 사실
/// ([fault])이 있으면 문장은 화면이 표시 언어로 만든다(`sessions_page.dart`의
/// `syncErrorDetailText`).
@immutable
class SyncErrorInfo {
  const SyncErrorInfo({
    required this.kind,
    required this.message,
    required this.atMs,
    this.fault,
  });

  /// 실패 경로(동기화 사이클·ack·삭제)가 [error]를 같은 규칙으로 접는다.
  ///
  /// [DashboardApiException]이 아닌 예외는 원문을 화면이 아니라 로그로
  /// 남긴다([SyncErrorKind.unexpected]). 이 팩토리가 세 실패 경로의 단일
  /// 진입점이라 한 곳에서 한 번만 남는다.
  factory SyncErrorInfo.fromError(Object error, {required int atMs}) {
    final kind = classifyError(error);
    if (kind == SyncErrorKind.unexpected) {
      debugPrint('sync: unexpected failure (${error.runtimeType}): $error');
    }
    return SyncErrorInfo(
      kind: kind,
      message: '$error',
      atMs: atMs,
      fault: error is DashboardApiException ? error.fault : null,
    );
  }

  final SyncErrorKind kind;

  /// 실패 원문(`'$error'`). 번역하지 않는다 — 화면은 [kind]가
  /// [SyncErrorKind.unexpected]가 아니고 [fault]도 없을 때만 이 값을 그대로
  /// 보여준다. 예상하지 못한 예외의 원문은 화면에 닿지 않는다.
  final String message;

  /// 오류가 관찰된 시각(epoch ms, [SyncNowMsFn] 기준).
  final int atMs;

  /// 실패의 사실([DashboardApiException.fault]) — 전송 실패·타임아웃·해석
  /// 실패·프로토콜 불일치. 그 밖의 실패면 null.
  final DashboardFault? fault;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncErrorInfo &&
          other.kind == kind &&
          other.message == message &&
          other.atMs == atMs &&
          other.fault == fault;

  @override
  int get hashCode => Object.hash(kind, message, atMs, fault);

  @override
  String toString() => 'SyncErrorInfo($kind @ $atMs: $message)';
}

/// 이 파일이 앱에 노출하는 상태 전부. `sync`(순수 리듀서 결과) 자체는
/// 실패해도 절대 손대지 않는다 — 완료 기준 (f)가 요구하는 "마지막 스냅샷
/// 유지"가 이 클래스가 아니라 [SyncController]의 실패 분기 쪽 규칙이다.
@immutable
class SyncControllerState {
  const SyncControllerState({
    this.sync = const SyncState(),
    this.phase = SyncPhase.idle,
    this.isForeground = true,
    this.consecutiveFailures = 0,
    this.lastSuccessAtMs,
    this.lastError,
  });

  /// `sync_reducer.dart`가 접은 세션 맵·커서·미확인 알림. 실패 사이클은
  /// 이 필드를 절대 바꾸지 않는다.
  final SyncState sync;
  final SyncPhase phase;

  /// 지금 앱이 포그라운드인지. [SyncActivityWatchFn]이 채운다.
  final bool isForeground;

  /// 연속 실패 횟수. 성공하면 0으로 접힌다.
  final int consecutiveFailures;

  /// 마지막으로 성공한 시각(epoch ms). 한 번도 성공한 적 없으면 null.
  final int? lastSuccessAtMs;

  /// 마지막 오류. 성공하면 지워진다(화면의 오류 배지는 "지금도 문제인가"를
  /// 보여줘야 하고, 지나간 오류의 흔적이 아니다).
  final SyncErrorInfo? lastError;

  /// 401/403으로 멈춘 상태 — 화면은 이 값이 true면 설정 화면으로 유도한다.
  bool get needsSetup => phase == SyncPhase.stopped;

  /// [lastSuccessAtMs]/[lastError]는 명시적으로 null을 줘야 지워지므로
  /// 일반적인 `??` copyWith로는 표현할 수 없다 — `config_provider.dart`의
  /// `DashboardConfigValues.copyWith`가 안고 가는 것과 같은 한계를 여기서는
  /// 안을 수 없다(오류가 사라졌다는 사실 자체가 이 상태의 핵심이다). 그래서
  /// 두 필드만 센티널([_unset])로 "안 줌"과 "null을 줌"을 구분한다.
  SyncControllerState copyWith({
    SyncState? sync,
    SyncPhase? phase,
    bool? isForeground,
    int? consecutiveFailures,
    Object? lastSuccessAtMs = _unset,
    Object? lastError = _unset,
  }) => SyncControllerState(
    sync: sync ?? this.sync,
    phase: phase ?? this.phase,
    isForeground: isForeground ?? this.isForeground,
    consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
    lastSuccessAtMs: identical(lastSuccessAtMs, _unset)
        ? this.lastSuccessAtMs
        : lastSuccessAtMs as int?,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as SyncErrorInfo?,
  );

  @override
  String toString() =>
      'SyncControllerState(phase: $phase, isForeground: $isForeground, '
      'consecutiveFailures: $consecutiveFailures, cursor: ${sync.cursor}, '
      'lastError: $lastError)';
}

/// [SyncControllerState.copyWith]가 "이 이름의 값을 아예 안 줬다"와 "null을
/// 명시적으로 줬다"를 구분하는 데 쓰는 표지. 어떤 실제 인자 값도 이
/// 인스턴스와 [identical]일 수 없다.
const Object _unset = Object();

// ─── 시임 (1계층: 함수 모양 + 2계층: Provider) ──────────────────────────

/// 지연 실행을 예약한다. 기본 구현은 진짜 `Timer` — 테스트는 이 시임을
/// 갈아끼워 시간을 흘리지 않고 `(delay, callback)`을 기록만 하는 가짜
/// 타이머를 준다(완료 기준 (a)(b)(c)가 실제로 3초/30초/60초를 기다리지
/// 않고 통과하는 이유).
typedef SyncScheduleFn =
    Timer Function(Duration delay, void Function() callback);

Timer _scheduleBridge(Duration delay, void Function() callback) =>
    Timer(delay, callback);

final Provider<SyncScheduleFn> syncScheduleFnProvider =
    Provider<SyncScheduleFn>((ref) => _scheduleBridge);

/// 현재 시각(epoch ms).
typedef SyncNowMsFn = int Function();

int _syncNowMsBridge() => DateTime.now().millisecondsSinceEpoch;

final Provider<SyncNowMsFn> syncNowMsFnProvider = Provider<SyncNowMsFn>(
  (ref) => _syncNowMsBridge,
);

/// 앱이 포그라운드로/비포그라운드로 바뀌는 사건의 스트림(`true`=포그라운드).
/// 기본 구현은 `AppLifecycleListener` — 이 리스너는 플러그인이 아니라
/// Flutter 프레임워크 자체가 데스크톱·모바일·웹 어디서나 주는 것이라
/// `http_provider.dart`/`config_provider.dart`처럼 io/web 조건부 import로
/// 나눌 필요가 없다.
typedef SyncActivityWatchFn = Stream<bool> Function();

Stream<bool> _activityWatchBridge() {
  AppLifecycleListener? listener;
  late final StreamController<bool> controller;
  controller = StreamController<bool>.broadcast(
    onListen: () {
      listener = AppLifecycleListener(
        onStateChange: (AppLifecycleState state) =>
            controller.add(state == AppLifecycleState.resumed),
      );
    },
    onCancel: () {
      listener?.dispose();
      listener = null;
    },
  );
  return controller.stream;
}

final Provider<SyncActivityWatchFn> syncActivityWatchFnProvider =
    Provider<SyncActivityWatchFn>((ref) => _activityWatchBridge);

/// 맥이 잠에서 깨어나는 사건의 스트림(TASK P-impl (3)). 기본 구현은
/// `background_activity_native.dart`가 감싼 MethodChannel(`app/resident`,
/// 메서드 `onWake`)을 거친다 — 새 채널을 만들지 않고 상주 토글이 이미 쓰는
/// 채널에 얹는다(`resident_mode_native.dart`의 [kResidentChannelName]).
/// 값 자체에는 정보가 없다(발생했다는 사실만 중요하다), 그래서 `Stream<void>`다.
typedef SyncWakeWatchFn = Stream<void> Function();

Stream<void> _syncWakeWatchBridge() => wake_bridge.watchWakeSignals();

final Provider<SyncWakeWatchFn> syncWakeWatchFnProvider =
    Provider<SyncWakeWatchFn>((ref) => _syncWakeWatchBridge);

// ─── 컨트롤러 (3계층: 조립) ──────────────────────────────────────────────

/// 동기화 주기·트리거·백오프·설정 유도를 갖고 있는 [Notifier].
///
/// `build()` 안에서는 [state]에 쓰지 않는다(riverpod 문서가 `build()` 중
/// `state` setter를 안전하다고 보장하지 않는다) — 앱 시작 즉시 1회 트리거도
/// `_scheduleNext(Duration.zero)`로 미뤄, 실제 상태 갱신은 항상 `build()`
/// 밖(타이머 콜백)에서 일어난다.
class SyncController extends Notifier<SyncControllerState>
    with SyncControllerActions {
  Timer? _timer;
  bool _cycleInFlight = false;
  bool _pendingImmediate = false;
  StreamSubscription<bool>? _activitySubscription;
  StreamSubscription<void>? _wakeSubscription;

  /// 이번 부팅(이 컨트롤러 인스턴스의 수명) 동안 스냅샷을 한 번이라도
  /// 반영했는가 — [_runCycle]의 콜드 부팅 reset 폴백이 딱 한 번만 도는
  /// 가드다. `false`로 시작해 첫 사이클이 끝나면(성공한 스냅샷이든, 실패한
  /// 폴백 시도든) 영구히 `true`로 남는다 — 다시 `false`로 되돌리는 경로는
  /// 없다(앱을 껐다 켜야 다음 기회가 온다). 계약 `sync.transition_object.
  /// apply_rule`("정보가 부족하면 reset을 한 번 받아 맞춘다")의 "한 번"이
  /// 이 필드다. 서버가 바뀌면([_resetIfServerChanged]) 새 서버에 대해 다시
  /// 한 번 연다 — 새 서버는 "이번 부팅"의 첫 서버와 같다.
  bool _snapshotReconciledThisBoot = false;

  /// 마지막 사이클이 말을 건 서버 주소. 설정 화면이 서버 주소를 바꿔 저장하면
  /// 다음 사이클에서 달라진다([_resetIfServerChanged]). 아직 한 번도 돌지
  /// 않았으면 null이다.
  Uri? _servedBaseUrl;
  int? _servedServerRevision;

  @override
  SyncControllerState build() {
    final configValues = ref.watch(dashboardConfigValuesProvider);
    final connection = ref.read(dashboardApiConfigControllerProvider.notifier);
    _servedBaseUrl = ref.read(dashboardApiConfigControllerProvider)?.baseUrl;
    _servedServerRevision = connection.serverRevision;
    // 주소 변경 즉시 이전 서버의 세션을 숨긴다. 느린 이전 요청을 기다리는
    // 동안 사용자가 그 세션을 새 서버에 ack/delete하지 못하게 한다.
    ref.listen<DashboardApiConfig?>(dashboardApiConfigControllerProvider, (
      previous,
      next,
    ) {
      if (next != null) {
        _resetIfServerChanged(next.baseUrl, connection.serverRevision);
      }
    });
    final restored = restoreState(
      persistedCursor: configValues.cursor,
      persistedSeenWatermark: configValues.seenWatermark,
    );
    final configured = configValues.serverUrl != null;

    // 활성/wake 구독은 서버 주소 유무와 무관하게 걸어 둔다 — 이 자체는
    // 네트워크를 타지 않는다(리스너 등록일 뿐). 실제 네트워크 시도는
    // `triggerNow`/`_runCycle`이 phase를 보고 막는다(U-fix: 미설정이면
    // 0회).
    final activityWatch = ref.watch(syncActivityWatchFnProvider);
    _activitySubscription = activityWatch().listen(setForeground);

    // TASK P-impl (3): wake마다 즉시 1회. `force`를 주지 않는다 — 401/403로
    // 멈춘 상태라면 wake도 그 중단을 풀 이유가 없다(다른 이벤트 트리거와
    // 같은 규칙, [triggerNow] 문서 참고).
    final wakeWatch = ref.watch(syncWakeWatchFnProvider);
    _wakeSubscription = wakeWatch().listen((_) => triggerNow());

    ref.onDispose(() {
      _timer?.cancel();
      _activitySubscription?.cancel();
      _wakeSubscription?.cancel();
    });

    // T-wire 계약(U-fix): 서버 주소가 없으면 폴링을 아예 예약하지 않는다
    // — `dashboardApiConfigProvider`가 이 상태에서는 override되지 않았을
    // 수 있고(main.dart 참고), 무엇보다 "미설정이면 네트워크 0회"가 계약
    // 그 자체다. [configureAndStart]가 설정 저장 성공 뒤 이 상태를 벗어나
    // 기존 [triggerNow] 경로를 연다.
    if (configured) {
      // 앱 시작 즉시 1회. `build()` 안에서 직접 사이클을 돌리지 않고 지연
      // 0으로 예약만 한다 — 실제 `state=` 쓰기는 그 콜백(build() 밖)에서
      // 일어난다.
      _scheduleNext(Duration.zero);
    }

    return SyncControllerState(
      sync: restored,
      phase: configured ? SyncPhase.idle : SyncPhase.unconfigured,
    );
  }

  /// 앱 생명주기 리스너가 부르는 진입점. 포그라운드로 막 돌아온 전환에서만
  /// 즉시 1회를 트리거한다(이미 포그라운드인데 같은 값이 다시 오는 건
  /// 트리거가 아니다 — 완료 기준 (d)).
  void setForeground(bool isForeground) {
    final wasForeground = state.isForeground;
    state = state.copyWith(isForeground: isForeground);
    if (isForeground && !wasForeground) {
      triggerNow();
    }
  }

  /// 다음 예약을 기다리지 않고 지금 한 번 동기화한다. 앱 시작·창 포커스·
  /// 데몬 변경이 전부 이 메서드로 모인다 — push 수신·알림 클릭 핸들러가
  /// 생기면 그것도 이 메서드를 부르면 된다(파일 상단 문서 참고).
  ///
  /// [force]가 아니면 [SyncControllerState.needsSetup] 동안은 아무것도 하지
  /// 않는다 — 401/403 뒤 재시도 중단은 자동 트리거로 절대 풀리면 안 된다.
  /// 설정 화면에서 자격증명을 고친 뒤 "다시 시도"가 `force: true`로 이
  /// 중단을 명시적으로 푼다.
  void triggerNow({bool force = false}) {
    // U-fix: 서버 주소가 없으면(unconfigured) 어떤 트리거(활성 전환·wake·
    // 수동 호출)도 네트워크를 타지 않는다. `force`도 이 phase는 풀지
    // 않는다 — `force`는 401/403(`needsSetup`) 전용 재시도 트리거다;
    // unconfigured를 벗어나는 유일한 문은 [configureAndStart]다.
    if (state.phase == SyncPhase.unconfigured) return;
    if (state.needsSetup && !force) return;
    if (force && state.needsSetup) {
      state = state.copyWith(phase: SyncPhase.idle, consecutiveFailures: 0);
    }
    _timer?.cancel();
    if (_cycleInFlight) {
      // 이미 도는 사이클이 있다 — 트리거를 큐에 쌓지 않고 "그 사이클이
      // 끝나면 한 번 더"로 뭉갠다(여러 트리거가 몰려도 즉시 트리거는
      // "즉시 1회"다).
      _pendingImmediate = true;
      return;
    }
    unawaited(_runCycle());
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    final schedule = ref.read(syncScheduleFnProvider);
    _timer = schedule(delay, () => unawaited(_runCycle()));
  }

  Future<void> _runCycle() async {
    // U-fix: build()가 unconfigured일 때 `_scheduleNext`를 아예 안 부르니
    // 정상 경로로는 여기 닿지 않는다 — 방어적으로만 막아 둔다(예: 미래에
    // 다른 호출부가 생기더라도 네트워크 0 계약이 깨지지 않게).
    if (state.phase == SyncPhase.unconfigured) return;
    if (state.needsSetup) return;
    if (_cycleInFlight) {
      _pendingImmediate = true;
      return;
    }
    _cycleInFlight = true;
    state = state.copyWith(phase: SyncPhase.syncing);

    final nowMsFn = ref.read(syncNowMsFnProvider);
    final connection = ref.read(dashboardApiConfigControllerProvider.notifier);
    final revision = connection.revision;

    try {
      // `dashboardApiProvider`(→ `dashboardApiConfigProvider`)를 try
      // 안에서 읽는다: 서버 주소가 아직 없을 때(미설정 부팅에서 누가
      // 게이팅을 건너뛰고 부른 경우) 이 read가 StateError를 던질 수 있고,
      // 그걸 기존 catch/분류(`classifyError` → `SyncErrorKind.unexpected`)
      // 로 안전하게 접어 백오프시킨다 — 크래시 대신 "첫 sync 시도는
      // 했다"는 계약을 지킨다.
      final api = ref.read(dashboardApiProvider);
      // 요청의 `since`를 정하기 전에 서버가 바뀌었는지 본다.
      _resetIfServerChanged(api.config.baseUrl, connection.serverRevision);
      final response = await api.sync(since: cursorForRequest(state.sync));
      if (connection.revision != revision) {
        _pendingImmediate = true;
      } else {
        final nowMs = nowMsFn();
        var nextSync = reduceSync(state.sync, response, nowMs: nowMs);

        if (!_snapshotReconciledThisBoot) {
          if (response.reset) {
            // 이번 응답 자체가 이미 스냅샷이다(첫 부팅에 커서가 없었거나,
            // 커서가 손상/정리됨). 계약이 요구하는 "정보 보강"은 이미 됐다
            // — 폴백을 쓸 필요가 없다. 완료 기준 (d): 재요청 0회 추가.
            _snapshotReconciledThisBoot = true;
          } else {
            // 콜드 부팅 + 델타(reset:false) 조합: 메모리 세션 맵은 부팅
            // 직후라 비어 있었는데, 델타는 그 사이 바뀐 세션만 알려줄 뿐
            // 나머지 세션의 존재조차 말해주지 않는다("정보 부족", 계약
            // apply_rule). 가드를 먼저 올려 둔다 — 아래 재요청이 성공하든
            // 실패하든 이번 부팅에서 다시 시도하지 않는다(무한 루프 금지).
            _snapshotReconciledThisBoot = true;
            try {
              final snapshot = await api.sync(since: null);
              if (connection.revision == revision) {
                final reconciled = reduceSync(
                  nextSync,
                  snapshot,
                  nowMs: nowMsFn(),
                );
                nextSync = _preserveBootCatchupAlerts(reconciled, nextSync);
              }
            } catch (_) {
              // 스냅샷 재조회 자체가 실패해도 이번 사이클을 실패로 치지
              // 않는다 — 델타만으로 만든 부분 상태(빈 화면일 수 있음)라도
              // 유지하고, 커서도 그 델타 기준으로 이어간다. 다음 폴링
              // 사이클이 정상적으로 계속되며(가드는 이미 소진됐으니 이
              // 폴백을 다시 시도하지는 않는다), 그때 세션 맵이 델타로
              // 점차 채워진다.
            }
          }
        }

        if (connection.revision == revision) {
          _afterSuccess(nextSync, nowMs);
          await _persistSyncMeta(nextSync, api.config.baseUrl, revision);
        } else {
          _pendingImmediate = true;
        }
      }
    } catch (error) {
      if (connection.revision == revision) {
        _afterFailure(error, nowMsFn());
      } else {
        _pendingImmediate = true;
      }
    } finally {
      _cycleInFlight = false;
    }

    _scheduleFollowUp();
  }

  /// 사이클이 말을 거는 서버([baseUrl])가 지난 사이클과 다르면(설정 화면이
  /// 서버 주소를 바꿔 저장했다) 이전 서버의 동기화 상태를 버리고 처음부터
  /// 시작한다 — 앱을 새로 켠 것과 같다.
  ///
  /// 이전 서버의 세션·커서·워터마크·미확인 알림은 새 서버의 전이 id와 맞지
  /// 않는다. 커서를 들고 가면 새 서버는 그 뒤의 델타만 주고, 그러면 이전
  /// 서버의 세션이 새 서버의 세션과 섞여 남는다. 커서가 없으면 새 서버가
  /// 스냅샷(`reset:true`)을 준다. 실패 횟수와 마지막 오류도 이전 서버의 것이라
  /// 함께 버린다. 토큰만 바뀌었으면(같은 서버) 아무것도 하지 않는다.
  ///
  /// 사이클이 시작할 때 비교하므로, 주소를 바꾼 순간 이전 서버로 나가 있던
  /// 요청의 응답이 늦게 도착해 상태에 반영돼도 새 서버로 나가는 첫 요청 전에
  /// 함께 버려진다.
  void _resetIfServerChanged(Uri baseUrl, int serverRevision) {
    final served = _servedBaseUrl;
    final servedRevision = _servedServerRevision;
    _servedBaseUrl = baseUrl;
    _servedServerRevision = serverRevision;
    if (served == null ||
        (served == baseUrl && servedRevision == serverRevision)) {
      return;
    }
    _snapshotReconciledThisBoot = false;
    state = state.copyWith(
      sync: const SyncState(),
      consecutiveFailures: 0,
      lastSuccessAtMs: null,
      lastError: null,
    );
  }

  /// 사이클이 끝난 뒤 무엇을 할지 정한다: 밀린 즉시 트리거 > 서버가 자른
  /// `has_more` > 평상시 폴링 간격. 401/403으로 멈췄으면 아무것도 예약하지
  /// 않는다 — 그게 "재시도 중단"의 실체다.
  void _scheduleFollowUp() {
    if (state.needsSetup) return;
    if (_pendingImmediate) {
      _pendingImmediate = false;
      unawaited(_runCycle());
      return;
    }
    if (state.sync.shouldFetchAgain) {
      unawaited(_runCycle());
      return;
    }
    _scheduleNext(
      pollInterval(
        isForeground: state.isForeground,
        consecutiveFailures: state.consecutiveFailures,
        hasWorkingSession: state.sync.hasWorkingSession,
      ),
    );
  }

  void _afterSuccess(SyncState nextSync, int nowMs) {
    // 초기 델타 뒤 스냅샷을 기다리는 동안에도 배너 클릭이 읽음을 올릴 수
    // 있다. 그 사이 갱신한 마커만 MAX로 보존하고 나머지는 동기화 결과를 따른다.
    final mergedSeen = Map<String, int>.of(nextSync.seenTransitionIds);
    for (final entry in state.sync.seenTransitionIds.entries) {
      if (entry.value > (mergedSeen[entry.key] ?? 0)) {
        mergedSeen[entry.key] = entry.value;
      }
    }
    state = state.copyWith(
      sync: nextSync.copyWith(
        seenTransitionIds: Map<String, int>.unmodifiable(mergedSeen),
      ),
      phase: SyncPhase.idle,
      consecutiveFailures: 0,
      lastSuccessAtMs: nowMs,
      lastError: null,
    );
  }

  /// 실패해도 [SyncControllerState.sync]는 절대 건드리지 않는다 — 완료
  /// 기준 (f)의 "마지막 스냅샷 유지"가 여기서 나온다. 401/403이면
  /// [SyncPhase.stopped]로 접어 [_scheduleFollowUp]이 다음 예약을 만들지
  /// 않게 한다(= 재시도 중단).
  void _afterFailure(Object error, int nowMs) {
    final info = SyncErrorInfo.fromError(error, atMs: nowMs);
    final kind = info.kind;
    state = state.copyWith(
      phase: isAuthFailure(kind) ? SyncPhase.stopped : SyncPhase.backingOff,
      consecutiveFailures: isAuthFailure(kind)
          ? state.consecutiveFailures
          : state.consecutiveFailures + 1,
      lastError: info,
    );
  }

  /// 새 커서와 seen 워터마크를 `configProvider`(`config_provider.dart`)에
  /// 영속화한다. 저장 실패는 동기화 자체를 막지 않는다 — 다음 성공한
  /// 사이클이 다시 시도한다.
  ///
  /// **왜 [dashboardConfigValuesProvider]가 아니라 [configPatchFnProvider]
  /// 인가.** [dashboardConfigValuesProvider]는 부팅 시점 스냅샷이라 그 뒤
  /// 설정 화면이 무엇을 저장했든 절대 갱신되지 않는다 — 예전 코드가 이
  /// 스냅샷을 베이스로 `copyWith(cursor: ...)`해 파일 전체를 다시 썼기
  /// 때문에, 이 컨트롤러가 사이클마다(포그라운드 3초 간격) 그 오래된
  /// `themeMode`/`resident`로 방금 저장된 값을 덮어 지우는 실기기 버그가
  /// 났다. [configPatchFnProvider]는 저장 직전에 파일을 다시 읽어 커서·
  /// seenWatermark 필드만 바꾸므로 이 컨트롤러는 자기가 소유한 필드 밖은
  /// 절대 건드리지 않는다.
  ///
  /// **왜 seenWatermark도 여기서 같이 영속화하는가(리뷰 지적 high 수정).**
  /// [seenWatermark]가 저장되지 않으면 [restoreState]가 매 재기동마다
  /// null(=아직 안 세움)로 복원하고, 그러면 다음에 받는 스냅샷마다 벽이
  /// 다시 서서 이미 확인한 세션 전부가 재차 "미확인"으로 뜬다 — cursor와
  /// 정확히 같은 종류의 문제라 같은 자리(사이클 성공 직후)에서 같은 방식
  /// (patch 큐)으로 같이 저장한다.
  Future<void> _persistSyncMeta(
    SyncState sync,
    Uri baseUrl,
    int revision,
  ) async {
    final cursor = sync.cursor;
    final seenWatermark = sync.seenWatermark;
    if (cursor == null && seenWatermark == null) return;
    final patch = ref.read(configPatchFnProvider);
    try {
      // 저장된 설정으로 부팅했는데 파일이 사라졌으면(사용자가 고치려고
      // 옮긴 순간) 커서만 담긴 새 파일을 만들지 않는다.
      await patch(
        backgroundConfigPatch((DashboardConfigValues current) {
          // 패치가 큐에서 기다리는 동안 Setup이 다른 서버를 저장할 수 있다.
          // 검사도 디스크를 다시 읽은 바로 이 자리에서 해야 한다.
          if (ref
                  .read(dashboardApiConfigControllerProvider.notifier)
                  .revision !=
              revision) {
            return current;
          }
          final storedUrl = current.serverUrl;
          if (storedUrl != null && parseServerUrl(storedUrl) != baseUrl) {
            return current;
          }
          return current.copyWith(cursor: cursor, seenWatermark: seenWatermark);
        }, storedAtBoot: ref.read(storedConfigAtBootProvider)),
      );
    } catch (_) {
      // 조용히 삼킨다 — config_provider.dart의 ConfigSaveFn 계약(저장
      // 실패는 예외)은 "화면이 알아야 한다"는 뜻이지, "동기화가 멈춰야
      // 한다"는 뜻은 아니다. 다음 성공 때 다시 저장을 시도한다. 읽기 실패
      // (ConfigReadException)면 패치 큐가 아무것도 쓰지 않은 채 던진 것이다.
    }
  }

  /// 설정 화면이 서버 주소를 처음 저장한 뒤 부른다 — 부팅이 서버 주소
  /// 없이 멈춰 둔 폴링을 정식으로 연다. 기존 "저장 후 재등록 트리거"
  /// (`setup_page.dart`의 [pushRegistrarProvider] 호출 자리)와 나란히
  /// 얹고, 새 스케줄 메커니즘을 만들지 않는다 — 여기서 하는 일은
  /// [SyncPhase.unconfigured]를 벗어나 기존 [triggerNow] 경로를 여는
  /// 것뿐이다. 이미 설정돼 있으면(= unconfigured가 아니면) 아무것도
  /// 하지 않는다 — 재저장·토큰 갱신 등으로 다시 불려도 안전하다.
  ///
  /// 호출자는 [dashboardApiConfigControllerProvider]를 저장한 값으로 **먼저**
  /// 바꿔 둬야 한다 — 여는 첫 사이클이 곧바로 `dashboardApiProvider`를 읽는다.
  /// 주소나 토큰을 바꿔 저장한 이미 설정된 앱은 이 메서드가 아니라
  /// `triggerNow(force: true)`로 새 연결에 곧바로 다시 동기화한다.
  void configureAndStart() {
    if (state.phase != SyncPhase.unconfigured) return;
    // 주소를 알 수 없던 부팅에서 복원한 커서는 어느 서버 것인지 증명할 수 없다.
    state = state.copyWith(sync: const SyncState(), phase: SyncPhase.idle);
    triggerNow();
  }
}

/// 콜드 부팅 스냅샷 폴백([SyncController._runCycle])이 만든 catchup
/// 알림을 그 폴백 자체가 지우지 않게 보존한다.
///
/// `sync_reducer.dart`의 `reduceSync` reset 분기는 의도적으로
/// `pendingAlerts`를 비우고 새로 시작한다 — 정상적인(서버가 먼저 보낸)
/// reset이라면 스냅샷 자체엔 `transitions`가 없어 "확인 처리할 대상"이
/// 애초에 없는 게 맞는 전제이기 때문이다. 하지만 이 폴백은 그 전제가
/// 깨지는 유일한 자리다: [delta]는 이미 실제로 도착한 전이로 catchup
/// 알림을 채워 뒀는데, 그 직후 정보 보강을 위해 이 컨트롤러가 스스로 부른
/// 스냅샷이 그걸 지우면 사용자는 부팅 사이에 일어난 일(예: 방금 끝난
/// 세션)을 영영 못 본다. 그래서 리듀서 자체([reduceSync])는 바꾸지 않고
/// —정상 런타임 reset의 의미는 그대로 두고서— 이 "부팅 직후 1회" 한정
/// 병합만 컨트롤러 쪽에 얹는다.
///
/// id로 중복을 접고(둘 다에 같은 전이가 있을 수 있다) id 오름차순으로
/// 정렬한 뒤, `reduceSync`와 같은 상한([kMaxPendingAlerts])으로 자른다.
SyncState _preserveBootCatchupAlerts(SyncState reconciled, SyncState delta) {
  if (delta.pendingAlerts.isEmpty) return reconciled;
  final byId = <int, TransitionDto>{
    for (final alert in delta.pendingAlerts) alert.id: alert,
    for (final alert in reconciled.pendingAlerts) alert.id: alert,
  };
  final ordered = byId.values.toList(growable: false)
    ..sort((TransitionDto a, TransitionDto b) => a.id.compareTo(b.id));
  final trimmed = ordered.length > kMaxPendingAlerts
      ? ordered.sublist(ordered.length - kMaxPendingAlerts)
      : ordered;
  return reconciled.copyWith(
    pendingAlerts: List<TransitionDto>.unmodifiable(trimmed),
  );
}

/// 조립된 컨트롤러. 앱 부팅은 [dashboardConfigValuesProvider]/
/// [dashboardApiProvider]/[httpSendProvider] 등을 먼저 override한 뒤 이걸
/// 읽어야 한다(그 provider들이 override 없이는 던지는 것과 같은 이유).
final NotifierProvider<SyncController, SyncControllerState>
syncControllerProvider = NotifierProvider<SyncController, SyncControllerState>(
  SyncController.new,
);

/// TASK MUTE-impl: 지금 음소거 중인지 + 그 종료 시각. `ui/setup_page.dart`
/// (설정 화면의 상시 상태 표시)와 `platform/tray_native.dart`(트레이 메뉴
/// 항목 선택) 둘 다 구독한다 — 그 둘은 서로 다른 계층이라(ui/platform)
/// 어느 쪽도 다른 쪽 파일을 import하면 안 되므로, 공유 지점을 이 provider
/// 계층에 둔다(`trayBadgeCountsListenable`이 트레이 배지 하나만
/// 구독하는 것과 달리 이건 두 계층이 같이 보므로 여기 있는 게 맞다).
///
/// `muted`는 `SyncState.isMuted`를 매 동기화의 `serverTime` 기준으로 다시
/// 판정한 값이다 — 서버는 만료된 `mute_until`을 굳이 지우지 않으므로,
/// 이 값이 필드 자체가 아니라 "지금(서버 기준) 그 값보다 이전인가"로
/// 매번 다시 계산돼야 음소거가 자연 만료된 뒤에도 화면·트레이가 계속
/// "음소거 중"으로 멈춰 있는 걸 막을 수 있다. 폴링이 도는 한(포그라운드
/// 3초~백그라운드 30초) 만료 시점 이후 다음 주기 안에 저절로 꺼진다.
final muteStateListenable = syncControllerProvider.select(
  (SyncControllerState state) => (
    muted: state.sync.isMuted(state.sync.serverTime),
    muteUntil: state.sync.muteUntil,
  ),
);

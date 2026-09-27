/// `sync_controller.dart`를 실제 `Timer`·실제 시계·실제 서버 없이 닫는다.
///
/// 완료 기준 (a)~(f)는 전부 값 조작만으로 재현한다:
/// - [syncScheduleFnProvider]를 `(delay, callback)`을 기록만 하는 가짜로
///   갈아끼워 "3초/30초/60초를 실제로 기다리지 않고" 그 값이 맞는지 본다.
/// - [syncNowMsFnProvider]로 시계를 고정한다.
/// - [syncActivityWatchFnProvider]를 테스트가 직접 `add()`할 수 있는 스트림
///   컨트롤러로 바꿔 포커스 변경을 흉내낸다.
/// - `httpSendProvider`를 가짜 핸들러로 바꿔 서버 없이 성공/401/네트워크
///   예외를 마음대로 만든다.
///
/// `dart:async`의 `Timer`는 `cancel()`/`tick`/`isActive` 세 멤버만 구현하면
/// 되는 `abstract interface class`라(`dart-sdk/lib/async/timer.dart`), 아래
/// [_FakeTimer]가 그 계약을 충실히 지키는 진짜 `Timer` 대체물이다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

void main() {
  group('pollInterval / backoffDelay (순수 정책 함수)', () {
    test('실패가 없으면 포그라운드 3초 · 비활성 30초다', () {
      expect(
        pollInterval(isForeground: true, consecutiveFailures: 0),
        kSyncForegroundInterval,
      );
      expect(
        pollInterval(isForeground: false, consecutiveFailures: 0),
        kSyncInactiveInterval,
      );
      expect(kSyncForegroundInterval, const Duration(seconds: 3));
      expect(kSyncInactiveInterval, const Duration(seconds: 30));
    });

    test('완료 기준 (c): 연속 실패마다 두 배씩 늘고 60초에서 잘린다', () {
      const base = kSyncForegroundInterval; // 3초
      expect(
        backoffDelay(base: base, consecutiveFailures: 1),
        const Duration(seconds: 6),
      );
      expect(
        backoffDelay(base: base, consecutiveFailures: 2),
        const Duration(seconds: 12),
      );
      expect(
        backoffDelay(base: base, consecutiveFailures: 3),
        const Duration(seconds: 24),
      );
      expect(
        backoffDelay(base: base, consecutiveFailures: 4),
        const Duration(seconds: 48),
      );
      // 3 * 2^5 = 96초 -> 60초 상한에서 잘린다.
      expect(backoffDelay(base: base, consecutiveFailures: 5), kSyncBackoffCap);
      expect(kSyncBackoffCap, const Duration(seconds: 60));
      // 아주 큰 연속 실패에도 상한을 넘지 않는다(오버플로 방지 클램프 확인).
      expect(
        backoffDelay(base: base, consecutiveFailures: 999999),
        kSyncBackoffCap,
      );
    });

    test('pollInterval도 실패 중엔 backoffDelay와 같은 값을 쓴다', () {
      expect(
        pollInterval(isForeground: true, consecutiveFailures: 2),
        backoffDelay(base: kSyncForegroundInterval, consecutiveFailures: 2),
      );
      expect(
        pollInterval(isForeground: false, consecutiveFailures: 2),
        backoffDelay(base: kSyncInactiveInterval, consecutiveFailures: 2),
      );
    });

    test('TASK P-impl (2): 비활성일 때 working 세션이 있으면 8초, 없으면 30초다', () {
      expect(
        pollInterval(
          isForeground: false,
          consecutiveFailures: 0,
          hasWorkingSession: true,
        ),
        kSyncFastInactiveInterval,
      );
      expect(
        pollInterval(
          isForeground: false,
          consecutiveFailures: 0,
          hasWorkingSession: false,
        ),
        kSyncInactiveInterval,
      );
      expect(kSyncFastInactiveInterval, const Duration(seconds: 8));
      // 데몬이 쓰던 2/8초보다 보수적이어야 한다.
      expect(
        kSyncFastInactiveInterval,
        greaterThan(const Duration(seconds: 2)),
      );
      expect(kSyncInactiveInterval, greaterThan(const Duration(seconds: 8)));
    });

    test('TASK P-impl (2): 포그라운드는 working 유무와 무관하게 항상 3초다', () {
      expect(
        pollInterval(
          isForeground: true,
          consecutiveFailures: 0,
          hasWorkingSession: true,
        ),
        kSyncForegroundInterval,
      );
      expect(
        pollInterval(
          isForeground: true,
          consecutiveFailures: 0,
          hasWorkingSession: false,
        ),
        kSyncForegroundInterval,
      );
    });
  });

  group('classifyError / isAuthFailure', () {
    test('401/403은 auth로 분류되고, auth만 재시도 중단 대상이다', () {
      expect(
        classifyError(const DashboardUnauthorized('x')),
        SyncErrorKind.auth,
      );
      expect(classifyError(const DashboardForbidden('x')), SyncErrorKind.auth);
      expect(isAuthFailure(SyncErrorKind.auth), isTrue);
      expect(isAuthFailure(SyncErrorKind.network), isFalse);
    });

    test('타임아웃 · 전송 실패는 network다', () {
      expect(classifyError(const DashboardTimeout('x')), SyncErrorKind.network);
      expect(
        classifyError(const DashboardNetworkFailure('x')),
        SyncErrorKind.network,
      );
    });

    test('5xx는 server, 프로토콜 불일치는 protocol이다', () {
      expect(
        classifyError(const DashboardServerError('x', statusCode: 500)),
        SyncErrorKind.server,
      );
      expect(
        classifyError(const DashboardProtocolMismatch('x', serverVersion: 99)),
        SyncErrorKind.protocol,
      );
    });

    test('그 밖의 4xx나 알 수 없는 예외는 other다(자동으로 멈추지 않는다)', () {
      expect(
        classifyError(const DashboardClientError('x', statusCode: 400)),
        SyncErrorKind.other,
      );
      expect(classifyError(StateError('무관한 예외')), SyncErrorKind.other);
    });
  });

  group('SyncController (조립)', () {
    late List<_Scheduled> scheduled;
    late int nowMs;
    late Future<ApiResponse> Function(ApiRequest request) httpHandler;
    late List<DashboardConfigValues> savedConfigs;
    late DashboardConfigValues storedConfig;
    late StreamController<bool> activity;
    late StreamController<void> wake;

    Timer fakeSchedule(Duration delay, void Function() callback) {
      scheduled.add(_Scheduled(delay, callback));
      return _FakeTimer();
    }

    // `serverUrl`은 기본값을 실제 값으로 둔다 — 이 그룹의 기존 테스트
    // 전부가 "이미 설정된 상태"를 전제로 짜여 있어서(U-fix 이전부터), 그
    // 전제를 이 매개변수 하나로 깨지 않고 유지한다. unconfigured 계열
    // 테스트만 명시적으로 `serverUrl: null`을 넘긴다.
    ProviderContainer buildContainer({
      int? persistedCursor,
      int? persistedSeenWatermark,
      String? serverUrl = 'https://example.test',
    }) {
      storedConfig = DashboardConfigValues(
        cursor: persistedCursor,
        seenWatermark: persistedSeenWatermark,
        serverUrl: serverUrl,
      );
      final container = ProviderContainer(
        overrides: [
          syncScheduleFnProvider.overrideWithValue(fakeSchedule),
          syncNowMsFnProvider.overrideWithValue(() => nowMs),
          syncActivityWatchFnProvider.overrideWithValue(() => activity.stream),
          syncWakeWatchFnProvider.overrideWithValue(() => wake.stream),
          httpSendProvider.overrideWithValue(
            (ApiRequest request) => httpHandler(request),
          ),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          ),
          // `build()`가 초기 복원에 쓰는 부팅 스냅샷 — `storedConfig`의
          // *그 순간* 값을 고정해 넣는다(예전과 같은 자리). 이후 사이클이
          // 도는 동안의 변화는 이 provider가 아니라 아래
          // [configLoadFnProvider]/[configSaveFnProvider]가 반영한다 —
          // `_persistSyncMeta`가 더는 이 provider를 읽지 않기 때문이다
          // (`sync_controller.dart`의 `_persistSyncMeta` 문서 참고, 버그 A).
          dashboardConfigValuesProvider.overrideWithValue(storedConfig),
          // `configPatchFnProvider`(기본 구현)가 이 둘로 조립된다 —
          // `storedConfig`를 공유해 실제 파일/localStorage 없이 "다시
          // 읽고 쓰기"를 흉내낸다(`config_provider_test.dart`의
          // `_MemoryConfigStore`와 같은 관용).
          configLoadFnProvider.overrideWithValue(() async => storedConfig),
          configSaveFnProvider.overrideWithValue((
            DashboardConfigValues values,
          ) async {
            storedConfig = values;
            savedConfigs.add(values);
          }),
        ],
      );
      return container;
    }

    setUp(() {
      scheduled = <_Scheduled>[];
      nowMs = 1000;
      savedConfigs = <DashboardConfigValues>[];
      storedConfig = DashboardConfigValues.empty;
      httpHandler = (ApiRequest request) async =>
          throw StateError('이 테스트는 httpHandler를 아직 설정하지 않았다.');
      // `sync: true` + `broadcast`: add() 안에서 리스너까지 동기 전달되어야
      // `add(); await Future<void>.delayed(Duration.zero);` 순서만으로
      // 리스너 콜백(setForeground)이 먼저 실행됨이 보장된다.
      activity = StreamController<bool>.broadcast(sync: true);
      wake = StreamController<void>.broadcast(sync: true);
    });

    tearDown(() {
      activity.close();
      wake.close();
    });

    /// 대기 중인 스케줄 콜백 하나를 지금 실행하고, 그 안에서 시작되는
    /// `_runCycle`의 비동기 체인(전송 -> 리듀서 -> 커서 저장 -> 다음 예약)이
    /// 전부 끝나도록 마이크로태스크를 여러 턴 흘려보낸다.
    Future<void> fireScheduled() async {
      final next = scheduled.removeAt(0);
      next.callback();
      await pumpMicrotasks();
    }

    Map<String, Object?> snapshotJson({
      int cursor = 1,
      List<Map<String, Object?>> sessions = const <Map<String, Object?>>[],
    }) => <String, Object?>{
      'protocol_version': kDashboardProtocolVersion,
      'reset': true,
      'cursor': cursor,
      'has_more': false,
      'server_time': nowMs,
      'pruned_below_id': 0,
      'stall_ms': kDefaultStallMs,
      'mute_until': null,
      'sessions': sessions,
      'transitions': const <Object?>[],
      'sessions_touched': const <String>[],
    };

    Map<String, Object?> sessionJson({
      required String key,
      required String state,
    }) => <String, Object?>{
      'key': key,
      'state': state,
      'source': 'claude-code',
      'session_id': 'abc',
      'project': 'demo',
      'last_event': 'x',
      'last_message': null,
      'last_occurred_at': nowMs,
      'created_at': nowMs,
      'updated_at': nowMs,
      'stale': false,
    };

    Future<ApiResponse> Function(ApiRequest) okHandler({
      int cursor = 1,
      List<Map<String, Object?>> sessions = const <Map<String, Object?>>[],
    }) =>
        (ApiRequest request) async => ApiResponse(
          statusCode: 200,
          body: jsonEncode(snapshotJson(cursor: cursor, sessions: sessions)),
        );

    test('앱 시작: build()가 즉시 1회를 지연 0으로 예약한다', () {
      httpHandler = okHandler();
      final container = buildContainer();
      addTearDown(container.dispose);

      container.read(syncControllerProvider); // build() 트리거

      expect(scheduled, hasLength(1));
      expect(scheduled.single.delay, Duration.zero);
    });

    test('완료 기준 (a): 성공하면 포그라운드 3초 간격으로 다음을 예약한다', () async {
      httpHandler = okHandler();
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled(); // 앱 시작 즉시 1회

      final state = container.read(syncControllerProvider);
      expect(state.phase, SyncPhase.idle);
      expect(state.lastSuccessAtMs, nowMs);
      expect(state.lastError, isNull);
      expect(scheduled, hasLength(1));
      expect(scheduled.single.delay, kSyncForegroundInterval);
    });

    test('완료 기준 (b): 비활성으로 전환하면 다음 폴링이 30초로 감속한다', () async {
      httpHandler = okHandler();
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled(); // 즉시 1회 -> 3초 예약
      expect(scheduled.single.delay, kSyncForegroundInterval);

      activity.add(false); // 비활성 전환 — 이 자체는 즉시 트리거가 아니다
      await pumpMicrotasks();
      expect(scheduled, hasLength(1), reason: '비활성 전환만으로는 즉시 트리거되지 않는다');

      await fireScheduled(); // 3초짜리 예약을 발화 -> 다음은 30초여야 한다
      expect(scheduled.single.delay, kSyncInactiveInterval);
    });

    test('TASK P-impl (2): 비활성인데 working 세션이 있으면 8초로 감속한다', () async {
      httpHandler = okHandler(
        sessions: <Map<String, Object?>>[
          sessionJson(key: 'claude-code:abc', state: 'working'),
        ],
      );
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled(); // 즉시 1회 -> 3초 예약(포그라운드는 항상 3초)
      expect(scheduled.single.delay, kSyncForegroundInterval);

      activity.add(false); // 비활성 전환
      await pumpMicrotasks();

      await fireScheduled(); // 3초짜리 예약을 발화
      expect(
        scheduled.single.delay,
        kSyncFastInactiveInterval,
        reason: '마지막 동기화 결과에 working 세션이 있으면 30초가 아니라 8초여야 한다',
      );
    });

    test('TASK P-impl (3): 맥이 깨어나면 즉시 1회만 트리거된다', () async {
      var callCount = 0;
      httpHandler = (ApiRequest request) async {
        callCount++;
        return ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson()));
      };
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled(); // 앱 시작 즉시 1회
      expect(callCount, 1);

      wake.add(null); // 깨어남 신호
      await pumpMicrotasks();
      expect(callCount, 2, reason: 'wake는 즉시 1회 트리거해야 한다');

      // 신호가 안 왔는데 저절로 또 트리거되면 안 된다.
      await pumpMicrotasks();
      expect(callCount, 2, reason: '추가 신호 없이는 다시 트리거되지 않는다');

      wake.add(null); // 두 번째 깨어남
      await pumpMicrotasks();
      expect(callCount, 3, reason: 'wake 신호마다 정확히 1회씩만 트리거된다');
    });

    test('완료 기준 (d): 백그라운드에서 포그라운드로 돌아오면 즉시 1회 트리거된다', () async {
      var callCount = 0;
      httpHandler = (ApiRequest request) async {
        callCount++;
        return ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson()));
      };
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled(); // 앱 시작 즉시 1회
      expect(callCount, 1);

      activity.add(false);
      await pumpMicrotasks();
      expect(callCount, 1, reason: '비활성 전환은 트리거가 아니다');

      activity.add(true); // 포커스 회복
      await pumpMicrotasks();
      expect(callCount, 2, reason: '포커스 회복은 즉시 1회 트리거다');
    });

    test('겹쳐 들어온 트리거는 사이클이 끝난 뒤 딱 한 번으로 뭉친다', () async {
      var callCount = 0;
      final firstCall = Completer<ApiResponse>();
      httpHandler = (ApiRequest request) async {
        callCount++;
        if (callCount == 1) return firstCall.future;
        return ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson()));
      };
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled(); // 첫 사이클 시작 — 응답 대기 중(completer 미완료)
      expect(callCount, 1);

      // 사이클이 도는 중에 여러 트리거가 몰린다.
      container.read(syncControllerProvider.notifier).triggerNow();
      container.read(syncControllerProvider.notifier).triggerNow();
      container.read(syncControllerProvider.notifier).triggerNow();

      firstCall.complete(
        ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson())),
      );
      await pumpMicrotasks();

      expect(callCount, 2, reason: '뭉쳐진 트리거는 사이클 하나로만 이어진다');
    });

    test('완료 기준 (e): 401은 재시도를 멈추고 설정 화면 유도를 켠다', () async {
      httpHandler = (ApiRequest request) async =>
          const ApiResponse(statusCode: 401, body: '{"error":"bad token"}');
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled();

      final state = container.read(syncControllerProvider);
      expect(state.phase, SyncPhase.stopped);
      expect(state.needsSetup, isTrue);
      expect(state.lastError?.kind, SyncErrorKind.auth);
      expect(scheduled, isEmpty, reason: '다음 폴링을 예약하지 않아야 재시도가 멈춘다');

      // 자동 트리거(포커스 회복)로도 다시 깨어나지 않는다.
      activity.add(false);
      activity.add(true);
      await pumpMicrotasks();

      expect(container.read(syncControllerProvider).phase, SyncPhase.stopped);
      expect(scheduled, isEmpty);
    });

    test('403도 401과 같은 재시도 중단 취급이다', () async {
      httpHandler = (ApiRequest request) async =>
          const ApiResponse(statusCode: 403, body: '{"error":"forbidden"}');
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled();

      final state = container.read(syncControllerProvider);
      expect(state.needsSetup, isTrue);
      expect(state.lastError?.kind, SyncErrorKind.auth);
    });

    test('force: true는 401 중단을 명시적으로 풀고 다시 시도하게 한다', () async {
      httpHandler = (ApiRequest request) async =>
          const ApiResponse(statusCode: 401, body: '{"error":"bad token"}');
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);
      await fireScheduled();
      expect(container.read(syncControllerProvider).needsSetup, isTrue);

      httpHandler = okHandler(); // 설정 화면에서 토큰을 고쳤다고 가정한다
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      await pumpMicrotasks();

      final state = container.read(syncControllerProvider);
      expect(state.needsSetup, isFalse);
      expect(state.phase, SyncPhase.idle);
    });

    test('완료 기준 (f): 네트워크 예외는 마지막 스냅샷을 지키고 오류를 노출한다', () async {
      httpHandler = okHandler(
        cursor: 5,
        sessions: <Map<String, Object?>>[
          sessionJson(key: 'claude-code:abc', state: 'working'),
        ],
      );
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);
      await fireScheduled();

      final afterSuccess = container.read(syncControllerProvider);
      expect(afterSuccess.sync.sessions, hasLength(1));
      expect(afterSuccess.sync.cursor, 5);
      expect(afterSuccess.lastError, isNull);

      httpHandler = (ApiRequest request) async =>
          throw const DashboardNetworkFailure('연결이 끊겼다');
      scheduled.clear();
      container.read(syncControllerProvider.notifier).triggerNow();
      await pumpMicrotasks();

      final afterFailure = container.read(syncControllerProvider);
      expect(
        afterFailure.sync.sessions,
        afterSuccess.sync.sessions,
        reason: '마지막 스냅샷을 지켜야 한다',
      );
      expect(afterFailure.sync.cursor, afterSuccess.sync.cursor);
      expect(afterFailure.lastError?.kind, SyncErrorKind.network);
      expect(afterFailure.phase, SyncPhase.backingOff);
      expect(afterFailure.needsSetup, isFalse, reason: '네트워크 예외는 재시도를 멈추지 않는다');
      // 실패했으니 다음 시도는 backoff(6초 = 3초*2^1)로 예약된다.
      expect(scheduled.single.delay, const Duration(seconds: 6));
    });

    test('성공한 커서를 configProvider(ConfigSaveFn)로 영속화한다', () async {
      httpHandler = okHandler(cursor: 42);
      final container = buildContainer(persistedCursor: null);
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled();

      expect(savedConfigs, hasLength(1));
      expect(savedConfigs.single.cursor, 42);
    });

    test('영속화된 커서로 build()가 SyncState를 복원한다(스냅샷을 다시 받지 않는다)', () {
      httpHandler = okHandler();
      final container = buildContainer(persistedCursor: 7);
      addTearDown(container.dispose);

      final state = container.read(syncControllerProvider);
      expect(state.sync.cursor, 7);
    });

    // 리뷰 지적 high 수정: seenWatermark 영속화·복원·트리거 조건 테스트는
    // `sync_controller_seen_watermark_test.dart`로 분리했다(이 그룹까지 한
    // 파일에 두면 `quality_check.py budget`의 1000줄 상한을 넘는다 — 바로
    // 위 UserAck-impl 분리와 같은 이유). 아래 콜드 부팅 폴백 테스트 (a)에는
    // 그 벽이 기존 설치(persistedCursor 있음, persistedSeenWatermark 없음)
    // 경로에서도 세워지는지를 확인하는 단언 하나만 남겨 뒀다.

    group('콜드 부팅 reset 폴백 (계약 sync.transition_object.apply_rule, 버그 B)', () {
      // 델타(reset:false) 응답 — 계약대로 `sessions`는 항상 빈 배열이다.
      Map<String, Object?> deltaJson({
        required int cursor,
        List<Map<String, Object?>> transitions = const <Map<String, Object?>>[],
        bool hasMore = false,
      }) => <String, Object?>{
        'protocol_version': kDashboardProtocolVersion,
        'reset': false,
        'cursor': cursor,
        'has_more': hasMore,
        'server_time': nowMs,
        'pruned_below_id': 0,
        'stall_ms': kDefaultStallMs,
        'mute_until': null,
        'sessions': const <Object?>[],
        'transitions': transitions,
        'sessions_touched': const <String>[],
      };

      Map<String, Object?> transitionJson({
        required int id,
        required String sessionKey,
        required String toState,
        int? occurredAt,
      }) => <String, Object?>{
        'id': id,
        'session_key': sessionKey,
        'to_state': toState,
        'from_state': null,
        'source': 'claude-code',
        'project': 'demo',
        'host': null,
        'message': null,
        'occurred_at': occurredAt ?? nowMs,
        'created_at': occurredAt ?? nowMs,
      };

      // `since` 쿼리 파라미터 유무로 스냅샷 요청과 델타 요청을 구분한다
      // (`DashboardApi.sync`의 `since: null` -> 쿼리에서 아예 빠짐, 정본
      // `dashboard_api.dart` 문서 참고).
      bool isSnapshotRequest(ApiRequest request) =>
          !request.url.queryParameters.containsKey('since');

      test(
        '(a) 커서 있는 콜드 부팅 + reset:false 델타 → 스냅샷 재요청 1회, 세션 맵이 채워진다',
        () async {
          var snapshotCalls = 0;
          var deltaCalls = 0;
          httpHandler = (ApiRequest request) async {
            if (isSnapshotRequest(request)) {
              snapshotCalls++;
              return ApiResponse(
                statusCode: 200,
                body: jsonEncode(
                  snapshotJson(
                    cursor: 168,
                    sessions: <Map<String, Object?>>[
                      sessionJson(key: 'claude-code:abc', state: 'waiting_input'),
                    ],
                  ),
                ),
              );
            }
            deltaCalls++;
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(
                deltaJson(
                  cursor: 168,
                  transitions: <Map<String, Object?>>[
                    transitionJson(
                      id: 168,
                      sessionKey: 'claude-code:abc',
                      toState: 'waiting_input',
                    ),
                  ],
                ),
              ),
            );
          };
          final container = buildContainer(persistedCursor: 168);
          addTearDown(container.dispose);
          container.read(syncControllerProvider);

          await fireScheduled(); // 앱 시작 즉시 1회 — 델타 -> 폴백 스냅샷까지 한 사이클 안에서

          expect(deltaCalls, 1);
          expect(snapshotCalls, 1, reason: '정보 부족(빈 sessions) 폴백이 정확히 1회 스냅샷을 재요청해야 한다');

          final state = container.read(syncControllerProvider);
          expect(
            state.sync.sessions,
            hasLength(1),
            reason: '델타만으로는 부팅 직후 빈 세션 맵이 채워지지 않는다 — 스냅샷이 채워야 한다',
          );
          expect(state.sync.sessions['claude-code:abc']?.state, 'waiting_input');
          expect(state.sync.cursor, 168);
          // 리뷰 지적 high: 이 기능 도입 이전부터 커서(168)만 갖고 있던
          // 기존 설치를 흉내낸다(persistedSeenWatermark 없음). 첫 응답은
          // 델타라 seenWatermark 트리거가 안 뜨고, 뒤이은 폴백 스냅샷에서
          // 딱 한 번 세워져야 한다 — isFirstBoot(cursor==null)를 트리거로
          // 썼다면 이 경로 전체가 firstBoot=false라 영영 안 세워진다.
          expect(state.sync.seenWatermark, 168);
        },
      );

      test('(b) 스냅샷 재요청은 이번 부팅에서 딱 1회다(여러 사이클을 돌려도 늘지 않는다)', () async {
        var snapshotCalls = 0;
        httpHandler = (ApiRequest request) async {
          if (isSnapshotRequest(request)) {
            snapshotCalls++;
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(snapshotJson(cursor: 168)),
            );
          }
          return ApiResponse(
            statusCode: 200,
            body: jsonEncode(deltaJson(cursor: 168)),
          );
        };
        final container = buildContainer(persistedCursor: 168);
        addTearDown(container.dispose);
        container.read(syncControllerProvider);

        await fireScheduled(); // 1번째 사이클: 델타 -> 폴백 스냅샷 1회
        expect(snapshotCalls, 1);

        // 계속 델타만 오는 후속 폴링 사이클들 — 가드가 이미 소진됐으니
        // 다시 스냅샷을 청하면 안 된다(무한 루프 금지).
        container.read(syncControllerProvider.notifier).triggerNow();
        await pumpMicrotasks();
        container.read(syncControllerProvider.notifier).triggerNow();
        await pumpMicrotasks();

        expect(snapshotCalls, 1, reason: '1회 가드는 이번 부팅(컨트롤러 인스턴스) 동안 다시 열리지 않는다');
      });

      test('(c) 델타의 catchup 알림은 스냅샷 병합 뒤에도 남는다', () async {
        httpHandler = (ApiRequest request) async {
          if (isSnapshotRequest(request)) {
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(
                snapshotJson(
                  cursor: 168,
                  sessions: <Map<String, Object?>>[
                    sessionJson(key: 'claude-code:abc', state: 'waiting_input'),
                  ],
                ),
              ),
            );
          }
          return ApiResponse(
            statusCode: 200,
            body: jsonEncode(
              deltaJson(
                cursor: 168,
                transitions: <Map<String, Object?>>[
                  transitionJson(
                    id: 168,
                    sessionKey: 'claude-code:abc',
                    toState: 'waiting_input', // push_states — 알림 대상
                  ),
                ],
              ),
            ),
          );
        };
        final container = buildContainer(persistedCursor: 167);
        addTearDown(container.dispose);
        container.read(syncControllerProvider);

        await fireScheduled();

        final state = container.read(syncControllerProvider);
        expect(
          state.sync.pendingAlerts,
          hasLength(1),
          reason: '스냅샷 reset이 델타가 만든 catchup 알림을 지우면 안 된다',
        );
        expect(state.sync.pendingAlerts.single.id, 168);
      });

      test(
        '(d) 커서 없는 첫 부팅은 스냅샷 요청이 여전히 1회뿐이다(폴백이 중복 요청을 만들지 않는다)',
        () async {
          var callCount = 0;
          httpHandler = (ApiRequest request) async {
            callCount++;
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(snapshotJson()),
            );
          };
          final container = buildContainer(persistedCursor: null);
          addTearDown(container.dispose);
          container.read(syncControllerProvider);

          await fireScheduled();

          expect(callCount, 1, reason: '첫 응답 자체가 이미 스냅샷이면 폴백을 또 부르면 안 된다');
        },
      );

      test('스냅샷 재조회가 실패해도 델타로 만든 부분 상태를 지키고 사이클은 성공 처리된다', () async {
        httpHandler = (ApiRequest request) async {
          if (isSnapshotRequest(request)) {
            throw const DashboardNetworkFailure('스냅샷 재조회 실패(가짜)');
          }
          return ApiResponse(
            statusCode: 200,
            body: jsonEncode(deltaJson(cursor: 168)),
          );
        };
        final container = buildContainer(persistedCursor: 168);
        addTearDown(container.dispose);
        container.read(syncControllerProvider);

        await fireScheduled();

        final state = container.read(syncControllerProvider);
        expect(state.phase, SyncPhase.idle, reason: '폴백 재조회 실패가 이번 사이클 자체를 실패로 만들면 안 된다');
        expect(state.lastError, isNull);
        expect(state.sync.cursor, 168, reason: '델타 기준 커서는 그대로 이어간다');
      });
    });

    group('U-fix: 서버 주소 미설정 게이팅', () {
      test('부팅 시 serverUrl이 없으면 아무것도 예약하지 않고 unconfigured다', () {
        httpHandler = okHandler();
        final container = buildContainer(serverUrl: null);
        addTearDown(container.dispose);

        final state = container.read(syncControllerProvider);

        expect(state.phase, SyncPhase.unconfigured);
        expect(scheduled, isEmpty, reason: '미설정이면 폴링을 예약하지 않는다');
      });

      test('미설정 상태에서는 triggerNow/활성 전환/wake 어느 것도 http를 부르지 않는다', () async {
        var callCount = 0;
        httpHandler = (ApiRequest request) async {
          callCount++;
          return ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson()));
        };
        final container = buildContainer(serverUrl: null);
        addTearDown(container.dispose);
        container.read(syncControllerProvider);

        container.read(syncControllerProvider.notifier).triggerNow();
        await pumpMicrotasks();
        activity.add(true);
        await pumpMicrotasks();
        wake.add(null);
        await pumpMicrotasks();

        expect(callCount, 0, reason: 'httpSendProvider는 0회 호출돼야 한다(U-fix 계약)');
        expect(scheduled, isEmpty);
        expect(
          container.read(syncControllerProvider).phase,
          SyncPhase.unconfigured,
        );
      });

      test(
        'configureAndStart()는 unconfigured를 벗어나 첫 sync를 발사하고 폴링을 연다',
        () async {
          var callCount = 0;
          httpHandler = (ApiRequest request) async {
            callCount++;
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(snapshotJson()),
            );
          };
          final container = buildContainer(serverUrl: null);
          addTearDown(container.dispose);
          container.read(syncControllerProvider);
          expect(
            container.read(syncControllerProvider).phase,
            SyncPhase.unconfigured,
          );

          container.read(syncControllerProvider.notifier).configureAndStart();
          await pumpMicrotasks();

          expect(callCount, 1, reason: '설정 저장 성공 뒤 첫 sync가 발사돼야 한다');
          final state = container.read(syncControllerProvider);
          expect(state.phase, SyncPhase.idle);
          expect(scheduled, hasLength(1), reason: '다음 폴링이 예약돼야 한다');
          expect(scheduled.single.delay, kSyncForegroundInterval);
        },
      );

      test('이미 설정된 상태에서 configureAndStart()는 아무것도 하지 않는다', () async {
        httpHandler = okHandler();
        final container = buildContainer(); // 기본값: serverUrl 있음
        addTearDown(container.dispose);
        container.read(syncControllerProvider);
        await fireScheduled(); // 앱 시작 즉시 1회 소화 -> idle, 3초 예약

        final before = container.read(syncControllerProvider);
        expect(before.phase, SyncPhase.idle);
        final scheduledBefore = scheduled.length;

        container.read(syncControllerProvider.notifier).configureAndStart();
        await pumpMicrotasks();

        expect(container.read(syncControllerProvider).phase, SyncPhase.idle);
        expect(
          scheduled,
          hasLength(scheduledBefore),
          reason: '이미 설정돼 있으면 새 트리거를 걸지 않는다',
        );
      });
    });

    // UserAck-impl: `ackSession`(POST /dashboard/sessions/{key}/ack) 테스트는
    // `sync_controller_ack_test.dart`로 분리했다 — 이 그룹까지 한 파일에
    // 넣으면 `quality_check.py budget`의 1000줄 상한을 넘는다(그 파일
    // 상단 문서에 이유를 적어 뒀다).
  });

  group('muteStateListenable (파생값 단언)', () {
    // 검증 지적(high): `state.sync.isMuted(state.sync.serverTime)`으로
    // 파생하는 이 값을 실제로 읽어 단언하는 테스트가 이전에 하나도
    // 없었다 — `sync_controller.dart`의 muted 판정을 아무렇게나 바꿔도
    // (예: 항상 false를 돌려줘도) 기존 테스트는 전부 green이었다.
    ProviderContainer buildFixedContainer(SyncControllerState state) =>
        ProviderContainer(
          overrides: [
            syncControllerProvider.overrideWith(
              () => _FixedSyncController(state),
            ),
          ],
        );

    test('muteUntil이 serverTime보다 미래면 muted:true, muteUntil을 그대로 돌려준다', () {
      final container = buildFixedContainer(
        const SyncControllerState(
          sync: SyncState(cursor: 1, serverTime: 1000, muteUntil: 5000),
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(muteStateListenable), (
        muted: true,
        muteUntil: 5000,
      ));
    });

    test('muteUntil이 serverTime을 이미 지났으면 muted:false다', () {
      final container = buildFixedContainer(
        const SyncControllerState(
          sync: SyncState(cursor: 1, serverTime: 9000, muteUntil: 5000),
        ),
      );
      addTearDown(container.dispose);

      final result = container.read(muteStateListenable);
      expect(result.muted, isFalse);
      expect(result.muteUntil, 5000, reason: '해제 라벨의 시각 계산은 값 자체를 그대로 넘긴다');
    });

    test('muteUntil이 없으면 muted:false, muteUntil:null이다', () {
      final container = buildFixedContainer(
        const SyncControllerState(sync: SyncState(cursor: 1, serverTime: 1000)),
      );
      addTearDown(container.dispose);

      expect(container.read(muteStateListenable), (
        muted: false,
        muteUntil: null,
      ));
    });
  });
}

/// `muteStateListenable` 테스트 전용 — `syncControllerProvider.overrideWith`로
/// 실제 사이클(스케줄·네트워크)을 전혀 타지 않고 고정 상태만 돌려준다
/// (`sessions_page_test.dart`의 `_FixedSyncController`와 같은 관용, 이
/// 파일은 무거운 실제 조립 컨테이너를 이미 쓰고 있어 그 픽스처를
/// 재사용하기보다 여기서 가볍게 따로 둔다).
class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

/// 대기 중인 스케줄 하나(`(delay, callback)`)의 기록.
class _Scheduled {
  _Scheduled(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
}

/// `Timer`의 계약(`cancel()`/`tick`/`isActive`)만 구현한 테스트용 대체물.
/// 실제 시간을 흘리지 않는다 — [_Scheduled]에 기록된 콜백은 테스트가 직접
/// 부른다.
class _FakeTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  // 이 컨트롤러는 항상 1회성(`Timer(delay, callback)`)만 예약한다 — 주기
  // 타이머(`Timer.periodic`)의 발화 횟수를 세는 이 값은 실제로 읽히지
  // 않지만, `Timer`가 abstract interface로 요구하는 세 멤버 중 하나라
  // 구현해야 한다.
  @override
  int get tick => 0;
}

/// `_runCycle`의 `await` 체인(전송 -> 리듀서 -> 커서 저장 -> 다음 예약)이
/// 전부 끝날 만큼 마이크로태스크 턴을 흘려보낸다. 실제 시간은 흐르지 않는다
/// (`Duration.zero` 타이머는 다음 이벤트 루프 턴에 곧바로 발화한다) —
/// `fake_async`/`clock`을 새 직접 의존성으로 들이지 않는다는 이 파일의
/// 설계 결정(파일 상단 문서 참고)의 실행부다.
Future<void> pumpMicrotasks([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

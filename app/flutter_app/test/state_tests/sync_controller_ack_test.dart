/// UserAck-impl: `SyncController.ackSession`(POST
/// `/dashboard/sessions/{key}/ack`, 정본 `client_actions.UserAck`)만 따로
/// 닫는 파일.
///
/// `sync_controller_test.dart`가 이미 갖춘 `httpSendProvider`/스케줄 시임
/// 가짜 조립을 이 파일에도 그대로 옮겨 놓았다 — 두 파일이 검증하는
/// 대상(폴링 주기·백오프 vs. 낙관적 ack 갱신)이 서로 다른 관심사라 파일
/// 하나로 합치면 `quality_check.py budget`의 1000줄 상한을 넘는다(house
/// rule). 조립 코드가 거의 그대로 겹치는 건 알고 있는 트레이드오프다 — 두
/// 파일을 억지로 하나로 합치는 것보다, 각 파일이 자기 관심사만 보며 상한
/// 안에 머무르는 쪽을 택했다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

void main() {
  group('UserAck-impl: ackSession (POST /dashboard/sessions/{key}/ack)', () {
    late List<_Scheduled> scheduled;
    late int nowMs;
    late Future<ApiResponse> Function(ApiRequest request) httpHandler;
    late DashboardConfigValues storedConfig;
    late StreamController<bool> activity;
    late StreamController<void> wake;

    Timer fakeSchedule(Duration delay, void Function() callback) {
      scheduled.add(_Scheduled(delay, callback));
      return _FakeTimer();
    }

    // `sync_controller_test.dart`의 `buildContainer`와 같은 조립이다 — 이
    // 파일은 커서 영속화·설정 미완료 분기를 검증하지 않으므로
    // `configLoadFn`/`configSaveFn`은 가장 단순한 형태로만 채운다.
    ProviderContainer buildContainer() {
      storedConfig = const DashboardConfigValues(
        serverUrl: 'https://example.test',
      );
      return ProviderContainer(
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
          dashboardConfigValuesProvider.overrideWithValue(storedConfig),
          configLoadFnProvider.overrideWithValue(() async => storedConfig),
          configSaveFnProvider.overrideWithValue((
            DashboardConfigValues values,
          ) async {
            storedConfig = values;
          }),
        ],
      );
    }

    setUp(() {
      scheduled = <_Scheduled>[];
      nowMs = 1000;
      httpHandler = (ApiRequest request) async =>
          throw StateError('이 테스트는 httpHandler를 아직 설정하지 않았다.');
      activity = StreamController<bool>.broadcast(sync: true);
      wake = StreamController<void>.broadcast(sync: true);
    });

    tearDown(() {
      activity.close();
      wake.close();
    });

    Future<void> fireScheduled() async {
      final next = scheduled.removeAt(0);
      next.callback();
      await pumpMicrotasks();
    }

    Map<String, Object?> snapshotJson({
      List<Map<String, Object?>> sessions = const <Map<String, Object?>>[],
    }) => <String, Object?>{
      'protocol_version': kDashboardProtocolVersion,
      'reset': true,
      'cursor': 1,
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

    // 아래 모든 테스트가 공유하는 준비 단계 — 스냅샷 사이클을 한 번 태워
    // `waiting_input` 세션 하나를 `state.sync.sessions`에 채운다. 그 뒤
    // httpHandler를 ack 전용 응답으로 갈아끼운다(폴링 사이클이 이 테스트
    // 도중 다시 돌 일은 없다 — `fireScheduled`를 더 부르지 않으므로).
    Future<ProviderContainer> bootWithWaitingSession() async {
      httpHandler = (ApiRequest request) async => ApiResponse(
        statusCode: 200,
        body: jsonEncode(
          snapshotJson(
            sessions: <Map<String, Object?>>[
              sessionJson(key: 'claude-code:abc', state: 'waiting_input'),
            ],
          ),
        ),
      );
      final container = buildContainer();
      container.read(syncControllerProvider);
      await fireScheduled();
      expect(
        container.read(syncControllerProvider).sync.sessions['claude-code:abc']
            ?.state,
        'waiting_input',
        reason: '준비 단계 자체가 잘못되면 아래 단언이 무의미하다',
      );
      return container;
    }

    test('탭 즉시 working으로 낙관 갱신하고, 응답의 state로 반영한다', () async {
      final container = await bootWithWaitingSession();
      addTearDown(container.dispose);

      final ackCompleter = Completer<ApiResponse>();
      httpHandler = (ApiRequest request) async {
        expect(request.method, 'POST');
        // `Uri.pathSegments`는 이미 퍼센트 디코딩된 값을 준다 — 세션
        // 키(`claude-code:abc`)가 경로 중간에 그대로, 잘리지 않고 한
        // 구간으로 들어갔는지가 여기서 드러난다.
        expect(request.url.pathSegments, [
          'dashboard',
          'sessions',
          'claude-code:abc',
          'ack',
        ]);
        return ackCompleter.future;
      };

      final future = container
          .read(syncControllerProvider.notifier)
          .ackSession('claude-code:abc');
      await pumpMicrotasks(1);

      // 서버 응답이 아직 안 왔는데도 화면은 이미 working이어야 한다 —
      // 낙관 갱신의 핵심.
      expect(
        container.read(syncControllerProvider).sync.sessions['claude-code:abc']
            ?.state,
        'working',
        reason: '응답을 기다리지 않고 즉시 working으로 보여야 한다',
      );

      ackCompleter.complete(
        ApiResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'ok': true,
            'state': 'working',
            'transition_id': 999,
          }),
        ),
      );
      await future;

      final after = container.read(syncControllerProvider);
      expect(after.sync.sessions['claude-code:abc']?.state, 'working');
      expect(after.lastError, isNull);
    });

    test('이미 처리된 세션이라 서버가 no-op을 돌려주면 낙관 갱신을 되돌린다', () async {
      final container = await bootWithWaitingSession();
      addTearDown(container.dispose);

      // 정본 guard: state != waiting_input이면 현재 상태를 그대로
      // 돌려주는 200 no-op(`transition_id: null`).
      httpHandler = (ApiRequest request) async => ApiResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'ok': true,
          'state': 'waiting_input',
          'transition_id': null,
        }),
      );

      await container
          .read(syncControllerProvider.notifier)
          .ackSession('claude-code:abc');

      final after = container.read(syncControllerProvider);
      expect(
        after.sync.sessions['claude-code:abc']?.state,
        'waiting_input',
        reason: 'no-op 응답의 state로 되돌려야 한다(별도 분기 없이 한 줄로)',
      );
      expect(after.lastError, isNull, reason: 'no-op은 오류가 아니다');
    });

    test(
      '세션이 사라져 서버가 state:null인 no-op을 돌려주면 낙관 갱신을 되돌린다'
      '(검증 리뷰 지적 medium 수정)',
      () async {
        final container = await bootWithWaitingSession();
        addTearDown(container.dispose);

        // 정본 guard: 세션이 아예 없어지면 {ok:true, state:null, transition_id:null}.
        // 예전에는 AckResultDto.state가 @Default('')라 이 null이 빈 문자열로 접혀
        // sessionStateDtoFromCode(state_chip.dart)의 미인식 코드 폴백을 타 화면에
        // 가짜 idle 배지가 영구히 남았다 - 지금은 previous로 되돌려야 한다.
        httpHandler = (ApiRequest request) async => ApiResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'ok': true,
            'state': null,
            'transition_id': null,
          }),
        );

        await container
            .read(syncControllerProvider.notifier)
            .ackSession('claude-code:abc');

        final after = container.read(syncControllerProvider);
        expect(
          after.sync.sessions['claude-code:abc']?.state,
          'waiting_input',
          reason: 'state:null은 previous로 되돌려야 한다 - 빈 문자열로 덮어쓰면 안 된다',
        );
        expect(after.lastError, isNull, reason: 'no-op은 오류가 아니다');
      },
    );

    test('요청 자체가 실패하면 되돌리고 lastError를 채운다(기존 관례)', () async {
      final container = await bootWithWaitingSession();
      addTearDown(container.dispose);

      httpHandler = (ApiRequest request) async =>
          throw const DashboardNetworkFailure('연결이 끊겼다(가짜)');

      await container
          .read(syncControllerProvider.notifier)
          .ackSession('claude-code:abc');

      final after = container.read(syncControllerProvider);
      expect(
        after.sync.sessions['claude-code:abc']?.state,
        'waiting_input',
        reason: '전송 실패는 응답 자체가 없으니 previous로 직접 되돌려야 한다',
      );
      expect(after.lastError?.kind, SyncErrorKind.network);
    });

    test('맵에 없는 세션 키로 부르면 아무 요청도 보내지 않는다', () async {
      httpHandler = (ApiRequest request) async =>
          ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson()));
      final container = buildContainer();
      addTearDown(container.dispose);
      container.read(syncControllerProvider);
      await fireScheduled();

      var callCount = 0;
      httpHandler = (ApiRequest request) async {
        callCount++;
        return ApiResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{'ok': true, 'state': 'working'}),
        );
      };

      await container
          .read(syncControllerProvider.notifier)
          .ackSession('claude-code:no-such-session');

      expect(callCount, 0, reason: '방어적 이른 반환 — 없는 세션에 낙관 갱신을 걸 수 없다');
    });
  });
}

/// 대기 중인 스케줄 하나(`(delay, callback)`)의 기록.
class _Scheduled {
  _Scheduled(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
}

/// `Timer`의 계약(`cancel()`/`tick`/`isActive`)만 구현한 테스트용 대체물.
/// 실제 시간을 흘리지 않는다 — [_Scheduled]에 기록된 콜백은 테스트가 직접
/// 부른다(`sync_controller_test.dart`의 같은 이름 클래스와 동일한 관용).
class _FakeTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// `_runCycle`의 `await` 체인이 전부 끝날 만큼 마이크로태스크 턴을
/// 흘려보낸다. 실제 시간은 흐르지 않는다(`sync_controller_test.dart`
/// 상단 문서의 설계 결정과 같다).
Future<void> pumpMicrotasks([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

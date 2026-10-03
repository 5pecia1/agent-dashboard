/// 0004 seen/삭제 UI: `SyncController.markSeen`(POST
/// `/dashboard/sessions/{key}/seen`)과 `SyncController.deleteSession`(DELETE
/// `/dashboard/sessions/{key}`)만 따로 닫는 파일.
///
/// `sync_controller_ack_test.dart` 상단 문서와 같은 이유로 조립 코드를
/// 그대로 옮겨 놓았다 — 관심사가 다른 컨트롤러 동작을 한 파일에 몰면
/// `quality_check.py budget`의 1000줄 상한을 넘는다.
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

  ProviderContainer buildContainer({int? persistedCursor}) {
    storedConfig = DashboardConfigValues(
      serverUrl: 'https://example.test',
      cursor: persistedCursor,
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
    List<Map<String, Object?>> seen = const <Map<String, Object?>>[],
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
    // 읽음 계약: seen은 session_object가 아니라 응답 최상위에서, 스냅샷·
    // 델타 공통으로 절대값을 동봉한다.
    'seen': seen,
  };

  Map<String, Object?> sessionJson({
    required String key,
    required String state,
    int? lastTransitionId,
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
    'last_transition_id': lastTransitionId,
  };

  Map<String, Object?> seenMarkerJson({
    required String key,
    int? seenTransitionId,
  }) => <String, Object?>{'key': key, 'seen_transition_id': seenTransitionId};

  // 스냅샷 사이클 한 번으로 세션 하나를 채운다 — 두 group이 공유한다.
  // [seenTransitionId]는(있으면) 이제 session_object가 아니라 응답 최상위
  // `seen` 배열의 항목 하나로 실려 간다(읽음 계약).
  Future<ProviderContainer> bootWithSession({
    required String key,
    required String state,
    int? lastTransitionId,
    int? seenTransitionId,
  }) async {
    httpHandler = (ApiRequest request) async => ApiResponse(
      statusCode: 200,
      body: jsonEncode(
        snapshotJson(
          sessions: <Map<String, Object?>>[
            sessionJson(key: key, state: state, lastTransitionId: lastTransitionId),
          ],
          seen: seenTransitionId == null
              ? const <Map<String, Object?>>[]
              : <Map<String, Object?>>[
                  seenMarkerJson(key: key, seenTransitionId: seenTransitionId),
                ],
        ),
      ),
    );
    final container = buildContainer();
    container.read(syncControllerProvider);
    await fireScheduled();
    expect(
      container.read(syncControllerProvider).sync.sessions[key]?.state,
      state,
      reason: '준비 단계 자체가 잘못되면 아래 단언이 무의미하다',
    );
    return container;
  }

  test('트레이 읽음 상한보다 새로운 전이는 읽지 않은 상태로 남는다', () async {
    final container = await bootWithSession(
      key: 'claude-code:abc',
      state: 'waiting_input',
      lastTransitionId: 30,
      seenTransitionId: 5,
    );
    addTearDown(container.dispose);
    httpHandler = (request) async {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      expect(body['last_transition_id'], 10);
      return ApiResponse(statusCode: 200, body: jsonEncode({'ok': true, 'seen_transition_id': 10}));
    };
    await container.read(syncControllerProvider.notifier).markSeenThrough('claude-code:abc', 10);
    final sync = container.read(syncControllerProvider).sync;
    expect(sync.seenTransitionIds['claude-code:abc'], 10);
    expect(sync.isSessionUnseen(sync.sessions['claude-code:abc']!), isTrue);
    expect(sync.sessions['claude-code:abc']!.state, 'waiting_input');
  });

  test('알림의 명시적 읽음 상한은 초기 세션 동기화 전에도 서버에 전달한다', () async {
    final container = buildContainer();
    addTearDown(container.dispose);
    container.read(syncControllerProvider);
    httpHandler = (request) async {
      expect(request.method, 'POST');
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      expect(body['last_transition_id'], 10);
      return ApiResponse(
        statusCode: 200,
        body: jsonEncode({'ok': true, 'seen_transition_id': 10}),
      );
    };
    await container
        .read(syncControllerProvider.notifier)
        .markSeenThrough('codex:banner', 10);
    final state = container.read(syncControllerProvider).sync;
    expect(state.sessions, isEmpty);
    expect(state.seenTransitionIds['codex:banner'], 10);
  });

  test('트레이 읽음 상한보다 새로운 전이는 읽지 않은 상태로 남는다', () async {
    final container = await bootWithSession(
      key: 'claude-code:abc',
      state: 'waiting_input',
      lastTransitionId: 30,
      seenTransitionId: 5,
    );
    addTearDown(container.dispose);
    httpHandler = (request) async {
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      expect(body['last_transition_id'], 10);
      return ApiResponse(
        statusCode: 200,
        body: jsonEncode({'ok': true, 'seen_transition_id': 10}),
      );
    };
    await container
        .read(syncControllerProvider.notifier)
        .markSeenThrough('claude-code:abc', 10);
    final sync = container.read(syncControllerProvider).sync;
    expect(sync.seenTransitionIds['claude-code:abc'], 10);
    expect(sync.isSessionUnseen(sync.sessions['claude-code:abc']!), isTrue);
    expect(sync.sessions['claude-code:abc']!.state, 'waiting_input');
  });

  test('초기 스냅샷 보강을 기다리는 동안 확인한 알림의 읽음 상한을 보존한다', () async {
    const key = 'codex:banner';
    final snapshot = Completer<ApiResponse>();
    var snapshotRequested = false;
    var seenRequests = 0;
    httpHandler = (request) async {
      if (request.method == 'POST') {
        seenRequests++;
        expect(request.url.pathSegments, [
          'dashboard',
          'sessions',
          key,
          'seen',
        ]);
        final body = jsonDecode(request.body!) as Map<String, Object?>;
        expect(body['last_transition_id'], 10);
        return ApiResponse(
          statusCode: 200,
          body: jsonEncode({'ok': true, 'seen_transition_id': 10}),
        );
      }
      if (request.url.queryParameters.containsKey('since')) {
        expect(request.url.queryParameters['since'], '1');
        return ApiResponse(
          statusCode: 200,
          body: jsonEncode({
            ...snapshotJson(
              seen: [seenMarkerJson(key: key, seenTransitionId: 5)],
            ),
            'reset': false,
            'cursor': 2,
          }),
        );
      }
      snapshotRequested = true;
      return snapshot.future;
    };
    final container = buildContainer(persistedCursor: 1);
    addTearDown(container.dispose);
    container.read(syncControllerProvider);
    await fireScheduled();
    expect(snapshotRequested, isTrue);
    expect(container.read(syncControllerProvider).sync.sessions, isEmpty);

    // 첫 델타는 이미 반영 준비가 끝났고 스냅샷은 아직 응답하지 않았다.
    // 이때 외부 창 이동이 완료되어 배너의 원래 전이까지만 읽음 처리한다.
    await container
        .read(syncControllerProvider.notifier)
        .markSeenThrough(key, 10);
    expect(
      container.read(syncControllerProvider).sync.seenTransitionIds[key],
      10,
    );

    snapshot.complete(
      ApiResponse(
        statusCode: 200,
        body: jsonEncode({
          ...snapshotJson(
            sessions: [
              sessionJson(
                key: key,
                state: 'waiting_input',
                lastTransitionId: 30,
              ),
            ],
            seen: [seenMarkerJson(key: key, seenTransitionId: 5)],
          ),
          'cursor': 30,
        }),
      ),
    );
    await pumpMicrotasks();

    final after = container.read(syncControllerProvider);
    expect(after.phase, SyncPhase.idle);
    expect(after.sync.seenTransitionIds[key], 10);
    expect(after.sync.sessions[key]!.lastTransitionId, 30);
    expect(after.sync.isSessionUnseen(after.sync.sessions[key]!), isTrue);
    expect(after.sync.sessions[key]!.state, 'waiting_input');
    expect(seenRequests, 1);
  });

  group('0004 seen: markSeen (POST /dashboard/sessions/{key}/seen)', () {
    test('상세 화면 진입 시 부르면 낙관 갱신 후 서버 값으로 확정한다', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'waiting_input',
        lastTransitionId: 9,
        seenTransitionId: null,
      );
      addTearDown(container.dispose);

      final seenCompleter = Completer<ApiResponse>();
      httpHandler = (ApiRequest request) async {
        expect(request.method, 'POST');
        expect(request.url.pathSegments, [
          'dashboard',
          'sessions',
          'claude-code:abc',
          'seen',
        ]);
        // 지금 화면이 아는 lastTransitionId를 그대로 실어 보낸다.
        final body = jsonDecode(request.body ?? '{}') as Map<String, Object?>;
        expect(body['last_transition_id'], 9);
        return seenCompleter.future;
      };

      final future = container
          .read(syncControllerProvider.notifier)
          .markSeen('claude-code:abc');
      await pumpMicrotasks(1);

      // 서버 응답을 기다리지 않고도 미확인 점이 즉시 꺼져야 한다(낙관 갱신).
      final optimistic = container.read(syncControllerProvider);
      expect(
        optimistic.sync.isSessionUnseen(
          optimistic.sync.sessions['claude-code:abc']!,
        ),
        isFalse,
        reason: '요청 완료 전에도 낙관 갱신으로 미확인 점이 꺼져야 한다',
      );

      seenCompleter.complete(
        ApiResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{'ok': true, 'seen_transition_id': 9}),
        ),
      );
      await future;

      final after = container.read(syncControllerProvider);
      expect(after.sync.seenTransitionIds['claude-code:abc'], 9);
      expect(after.lastError, isNull);
    });

    test('실패해도 무해하다 — lastError를 세우지 않고 낙관 갱신은 남는다', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'waiting_input',
        lastTransitionId: 5,
        seenTransitionId: null,
      );
      addTearDown(container.dispose);

      httpHandler = (ApiRequest request) async =>
          throw const DashboardNetworkFailure('연결이 끊겼다(가짜)');

      await container
          .read(syncControllerProvider.notifier)
          .markSeen('claude-code:abc');

      final after = container.read(syncControllerProvider);
      // 실패 무해 사양: ack와 달리 되돌리지 않는다 — 낙관 갱신(이미 화면이
      // 안다고 확신하는 값)이 그대로 남고, 오류 배지도 뜨지 않는다.
      expect(after.sync.seenTransitionIds['claude-code:abc'], 5);
      expect(after.lastError, isNull);
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
          body: jsonEncode(<String, Object?>{'ok': true, 'seen_transition_id': 1}),
        );
      };

      await container
          .read(syncControllerProvider.notifier)
          .markSeen('claude-code:no-such-session');

      expect(callCount, 0);
    });

    test(
      '깜빡임 방지(읽음 계약): 낙관 갱신 도중 도착한 옛 폴링 응답의 더 낮은 '
      'seen이 미확인 점을 되살리지 않는다',
      () async {
        final container = await bootWithSession(
          key: 'claude-code:abc',
          state: 'waiting_input',
          lastTransitionId: 9,
          seenTransitionId: null,
        );
        addTearDown(container.dispose);

        final seenCompleter = Completer<ApiResponse>();
        httpHandler = (ApiRequest request) async {
          if (request.method == 'POST') {
            // markSeen 자신의 요청 — 아직 응답하지 않고 붙들어 둔다.
            return seenCompleter.future;
          }
          // 그 사이 도는 정상 폴링 사이클 — 서버가 아직 이번 markSeen을
          // 반영하기 전에 만들어진(그래서 로컬 낙관 갱신보다 오래된) 응답을
          // 흉내낸다: seen이 3으로, 이미 로컬이 낙관적으로 올려 둔 9보다
          // 작다.
          return ApiResponse(
            statusCode: 200,
            body: jsonEncode(
              snapshotJson(
                sessions: <Map<String, Object?>>[
                  sessionJson(
                    key: 'claude-code:abc',
                    state: 'waiting_input',
                    lastTransitionId: 9,
                  ),
                ],
                seen: <Map<String, Object?>>[
                  seenMarkerJson(key: 'claude-code:abc', seenTransitionId: 3),
                ],
              ),
            ),
          );
        };

        final future = container
            .read(syncControllerProvider.notifier)
            .markSeen('claude-code:abc');
        await pumpMicrotasks(1);

        // 낙관 갱신이 먼저 9까지 올려 놓는다.
        expect(
          container
              .read(syncControllerProvider)
              .sync
              .seenTransitionIds['claude-code:abc'],
          9,
        );

        // 옛 폴링 응답(seen: 3)이 도착해도 MAX 병합이라 9 아래로 내려가지
        // 않는다.
        await fireScheduled();

        final midway = container.read(syncControllerProvider);
        expect(midway.sync.seenTransitionIds['claude-code:abc'], 9);
        expect(
          midway.sync.isSessionUnseen(
            midway.sync.sessions['claude-code:abc']!,
          ),
          isFalse,
          reason: '비행 중이던 옛 응답 때문에 미확인 점이 되살아나면 안 된다',
        );

        // markSeen 요청 자체도 정상적으로 확정된다.
        seenCompleter.complete(
          ApiResponse(
            statusCode: 200,
            body: jsonEncode(<String, Object?>{
              'ok': true,
              'seen_transition_id': 9,
            }),
          ),
        );
        await future;

        final after = container.read(syncControllerProvider);
        expect(after.sync.seenTransitionIds['claude-code:abc'], 9);
      },
    );
  });

  group(
    '0004 seen: ackSession이 성공하면 자기 자신의 전이 때문에 다시 미확인이 되지 않는다',
    () {
      test('전이가 실제로 생기면(transition_id 응답) seenTransitionId도 같이 오른다', () async {
        final container = await bootWithSession(
          key: 'claude-code:abc',
          state: 'waiting_input',
          lastTransitionId: 20,
          seenTransitionId: 20, // 이미 본 상태(0004 markSeen을 이미 호출함)
        );
        addTearDown(container.dispose);

        httpHandler = (ApiRequest request) async => ApiResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'ok': true,
            'state': 'working',
            'transition_id': 21,
          }),
        );

        await container
            .read(syncControllerProvider.notifier)
            .ackSession('claude-code:abc');

        final after = container.read(syncControllerProvider);
        final session = after.sync.sessions['claude-code:abc']!;
        // ack 자체가 만든 전이(21)가 다음 정상 폴링에서 lastTransitionId로
        // 반영되더라도, seenTransitionIds가 이미 같은 값으로 따라 올라가
        // 있어 "자기 응답 때문에 미확인 반짝임"이 없다.
        expect(after.sync.seenTransitionIds['claude-code:abc'], 21);
        final withLast = session.copyWith(lastTransitionId: 21);
        expect(after.sync.isSessionUnseen(withLast), isFalse);
      });
    },
  );

  group('삭제 UI: deleteSession (DELETE /dashboard/sessions/{key})', () {
    test('성공하면 낙관 제거가 그대로 유지된다', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'working',
      );
      addTearDown(container.dispose);

      final deleteCompleter = Completer<ApiResponse>();
      httpHandler = (ApiRequest request) async {
        expect(request.method, 'DELETE');
        expect(request.url.pathSegments, [
          'dashboard',
          'sessions',
          'claude-code:abc',
        ]);
        return deleteCompleter.future;
      };

      final future = container
          .read(syncControllerProvider.notifier)
          .deleteSession('claude-code:abc');
      await pumpMicrotasks(1);

      // 요청 완료 전에도 목록에서 이미 사라져야 한다(낙관 제거).
      expect(
        container.read(syncControllerProvider).sync.sessions.containsKey(
          'claude-code:abc',
        ),
        isFalse,
      );

      deleteCompleter.complete(ApiResponse(statusCode: 200, body: '{}'));
      final result = await future;

      expect(result, isTrue);
      final after = container.read(syncControllerProvider);
      expect(after.sync.sessions.containsKey('claude-code:abc'), isFalse);
      expect(after.lastError, isNull);
    });

    test('실패하면 롤백하고 lastError를 채운다', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'working',
      );
      addTearDown(container.dispose);

      httpHandler = (ApiRequest request) async =>
          throw const DashboardNetworkFailure('연결이 끊겼다(가짜)');

      final result = await container
          .read(syncControllerProvider.notifier)
          .deleteSession('claude-code:abc');

      expect(result, isFalse);
      final after = container.read(syncControllerProvider);
      expect(
        after.sync.sessions['claude-code:abc']?.state,
        'working',
        reason: '실패하면 지웠던 세션을 그대로 되살려야 한다',
      );
      expect(after.lastError?.kind, SyncErrorKind.network);
    });

    test('전송이 던지면 롤백하고 lastError에 그 요청과 원인을 사실로 남긴다', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'working',
      );
      addTearDown(container.dispose);

      // 실제 전송처럼 DashboardApiException이 아닌 예외를 던진다 — `_request`가
      // 요청과 원인을 TransportFault로 접고, 화면은 그 사실로 표시 언어의
      // 문장을 만든다(`sessions_page.dart`의 `syncErrorDetailText`).
      httpHandler = (ApiRequest request) =>
          Future<ApiResponse>.error(const _SocketFailure());

      final result = await container
          .read(syncControllerProvider.notifier)
          .deleteSession('claude-code:abc');

      expect(result, isFalse);
      final after = container.read(syncControllerProvider);
      expect(after.sync.sessions['claude-code:abc']?.state, 'working');
      expect(after.lastError?.kind, SyncErrorKind.network);
      expect(
        after.lastError?.fault,
        const TransportFault(
          method: 'DELETE',
          path: kSessionsPath,
          cause: _SocketFailure.text,
        ),
      );
    });

    test('404는 성공으로 접는다(이미 지워진 세션)', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'working',
      );
      addTearDown(container.dispose);

      httpHandler = (ApiRequest request) async =>
          ApiResponse(statusCode: 404, body: '{}');

      final result = await container
          .read(syncControllerProvider.notifier)
          .deleteSession('claude-code:abc');

      expect(result, isTrue);
      expect(
        container.read(syncControllerProvider).sync.sessions.containsKey(
          'claude-code:abc',
        ),
        isFalse,
      );
    });

    test('롤백은 그 사이 폴링이 같은 키를 이미 되살렸으면 덮어쓰지 않는다', () async {
      final container = await bootWithSession(
        key: 'claude-code:abc',
        state: 'working',
      );
      addTearDown(container.dispose);

      final deleteCompleter = Completer<ApiResponse>();
      httpHandler = (ApiRequest request) async {
        if (request.method == 'DELETE') return deleteCompleter.future;
        // 정상 폴링 주기 — 삭제 요청이 아직 안 끝난 사이 살아있는 세션이
        // 새 전이로 다시 나타난다(사양: "삭제된 세션 키가 델타 전이로
        // 다시 나타나는 것은 정상, 특별 취급 없음").
        return ApiResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'protocol_version': kDashboardProtocolVersion,
            'reset': false,
            'cursor': 6,
            'has_more': false,
            'server_time': nowMs,
            'pruned_below_id': 0,
            'stall_ms': kDefaultStallMs,
            'mute_until': null,
            'sessions': const <Object?>[],
            'transitions': <Map<String, Object?>>[
              <String, Object?>{
                'id': 6,
                'session_key': 'claude-code:abc',
                'to_state': 'waiting_input',
                'from_state': 'working',
                'source': 'claude-code',
                'project': 'demo',
                'occurred_at': nowMs,
                'created_at': nowMs,
              },
            ],
            'sessions_touched': const <String>['claude-code:abc'],
          }),
        );
      };

      final future = container
          .read(syncControllerProvider.notifier)
          .deleteSession('claude-code:abc');
      await pumpMicrotasks(1);

      expect(
        container.read(syncControllerProvider).sync.sessions.containsKey(
          'claude-code:abc',
        ),
        isFalse,
        reason: '낙관 제거가 먼저 반영돼야 한다',
      );

      // 삭제 응답을 기다리는 동안 다음 폴링 주기가 한 번 돈다.
      await fireScheduled();

      final revived =
          container.read(syncControllerProvider).sync.sessions['claude-code:abc'];
      expect(
        revived?.state,
        'waiting_input',
        reason: '폴링이 살아있는 세션을 다시 채웠어야 다음 단언이 의미가 있다',
      );

      // 이제 삭제 요청이 실패로 끝난다 — `_restoreSession`은 이미 채워진
      // (폴링이 방금 넣은 더 최신인) 키를 덮어쓰면 안 된다.
      deleteCompleter.complete(
        ApiResponse(statusCode: 500, body: '{"error":"boom"}'),
      );
      await future;

      final after =
          container.read(syncControllerProvider).sync.sessions['claude-code:abc'];
      expect(
        after?.state,
        'waiting_input',
        reason: '롤백이 폴링으로 이미 되살아난 최신 데이터를 덮어쓰면 안 된다',
      );
    });
  });
}

/// `dart:io`의 `SocketException`처럼 시임이 던지는, [DashboardApiException]이
/// 아닌 예외 흉내.
class _SocketFailure implements Exception {
  const _SocketFailure();

  static const String text = 'SocketException: Connection refused';

  @override
  String toString() => text;
}

/// 대기 중인 스케줄 하나(`(delay, callback)`)의 기록.
class _Scheduled {
  _Scheduled(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
}

/// `Timer`의 계약(`cancel()`/`tick`/`isActive`)만 구현한 테스트용 대체물.
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
/// 흘려보낸다. 실제 시간은 흐르지 않는다.
Future<void> pumpMicrotasks([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

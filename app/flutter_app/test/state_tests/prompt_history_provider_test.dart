import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/prompt_history_provider.dart';

final Uri _firstServer = Uri.parse('https://first.example.dev');
final Uri _secondServer = Uri.parse('https://second.example.dev');

class _Config extends Notifier<DashboardApiConfig> {
  @override
  DashboardApiConfig build() => DashboardApiConfig(baseUrl: _firstServer);
  void use(Uri url) => state = DashboardApiConfig(baseUrl: url);
}

final _configProvider = NotifierProvider<_Config, DashboardApiConfig>(
  _Config.new,
);

ApiResponse _page(
  List<int> ids, {
  bool hasMore = false,
  int? cursor,
  String event = 'UserPromptSubmit',
}) => ApiResponse(
  statusCode: 200,
  body: jsonEncode(<String, Object?>{
    'events': <Map<String, Object?>>[
      for (final id in ids)
        <String, Object?>{
          'id': id,
          'session_key': 'codex:session',
          'source': 'codex',
          'event': event,
          'message': '사용자 입력 $id',
          'received_at': id,
        },
    ],
    'has_more': hasMore,
    'next_before_id': cursor,
  }),
);

ProviderContainer _container(HttpSendFn send) => ProviderContainer(
  overrides: [
    dashboardApiConfigProvider.overrideWith(
      (ref) => ref.watch(_configProvider),
    ),
    httpSendProvider.overrideWithValue(send),
  ],
);

PromptHistoryState _value(ProviderContainer container) =>
    container.read(promptHistoryProvider).requireValue;

void main() {
  test('최초 조회는 전역 promptsOnly를 최대 천 개 읽고 다음 배치는 명시적으로 읽는다', () async {
    final requests = <ApiRequest>[];
    final container = _container((request) async {
      requests.add(request);
      final before =
          int.tryParse(request.url.queryParameters['before_id'] ?? '') ?? 1201;
      final ids = List<int>.generate(
        kHistoryPageSize,
        (index) => before - index - 1,
      );
      final hasMore = ids.last > 1;
      return _page(ids, hasMore: hasMore, cursor: hasMore ? ids.last : null);
    });
    addTearDown(container.dispose);

    final controller = container.read(promptHistoryProvider.notifier);
    await controller.refresh();

    expect(requests, hasLength(kPromptHistoryBatchPages));
    expect(_value(container).events, hasLength(kPromptHistoryBatchSize));
    expect(_value(container).hasMore, isTrue);
    expect(_value(container).nextBeforeId, 201);
    expect(
      requests.every(
        (request) =>
            request.url.queryParameters['kind'] == 'prompts' &&
            !request.url.queryParameters.containsKey('session_key'),
      ),
      isTrue,
    );

    await controller.loadOlder();

    expect(requests, hasLength(kPromptHistoryBatchPages + 1));
    expect(_value(container).events, hasLength(1200));
    expect(_value(container).hasMore, isFalse);
    expect(_value(container).nextBeforeId, isNull);
  });

  test('자동 초기 조회를 시작하며 오래된 서버의 assistant 결과는 보관하지 않는다', () async {
    var calls = 0;
    final container = _container((request) async {
      calls++;
      return _page([2], event: 'Stop');
    });
    addTearDown(container.dispose);

    container.read(promptHistoryProvider);
    await container.pump();
    await container.read(promptHistoryProvider.notifier).refresh();

    expect(calls, greaterThanOrEqualTo(1));
    expect(_value(container).events, isEmpty);
    expect(_value(container).scannedCount, 1);
  });

  test('다음 배치 실패는 이전 데이터와 커서를 보존하고 재시도는 같은 커서로 한다', () async {
    var fail = false;
    final beforeIds = <String?>[];
    final container = _container((request) async {
      beforeIds.add(request.url.queryParameters['before_id']);
      if (fail) throw StateError('failed request');
      final before = int.tryParse(beforeIds.last ?? '') ?? 100;
      return _page([before - 1], hasMore: true, cursor: before - 1);
    });
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);
    await controller.refresh();
    final previous = _value(container);

    fail = true;
    await controller.loadOlder();

    expect(_value(container).events, previous.events);
    expect(_value(container).nextBeforeId, previous.nextBeforeId);
    expect(_value(container).error, isA<DashboardNetworkFailure>());
    expect(_value(container).loadingMore, isFalse);
    expect(beforeIds.last, '${previous.nextBeforeId}');

    fail = false;
    await controller.loadOlder();
    expect(
      beforeIds[beforeIds.length - kPromptHistoryBatchPages],
      '${previous.nextBeforeId}',
    );
    expect(_value(container).events, hasLength(kPromptHistoryBatchPages * 2));
  });

  test('새로고침 중 실패해도 기존 데이터와 커서를 잃지 않는다', () async {
    var fail = false;
    final container = _container((request) async {
      if (fail) throw StateError('refresh failed');
      return _page([3, 2, 1]);
    });
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);
    await controller.refresh();
    final previous = _value(container);

    fail = true;
    await controller.refresh();

    expect(_value(container).events, previous.events);
    expect(_value(container).nextBeforeId, previous.nextBeforeId);
    expect(_value(container).refreshing, isFalse);
    expect(_value(container).error, isNotNull);
  });

  test('커서가 전진하지 않으면 루프를 멈추고 이전 배치를 보존한다', () async {
    var repeat = false;
    var requests = 0;
    final container = _container((request) async {
      requests++;
      final before =
          int.tryParse(request.url.queryParameters['before_id'] ?? '') ?? 100;
      final id = repeat ? before : before - 1;
      return _page([id], hasMore: true, cursor: id);
    });
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);
    await controller.refresh();
    final previous = _value(container);

    repeat = true;
    await controller.loadOlder();

    expect(requests, kPromptHistoryBatchPages + 1);
    expect(_value(container).events, previous.events);
    expect(_value(container).nextBeforeId, previous.nextBeforeId);
    expect(_value(container).error, isA<FormatException>());
  });

  test('서버 변경은 이전 데이터를 바로 비우고 늦게 온 이전 서버 응답을 버린다', () async {
    final oldRequest = Completer<ApiResponse>();
    final newRequest = Completer<ApiResponse>();
    var firstRequests = 0;
    final container = _container((request) async {
      if (request.url.host == _secondServer.host) return newRequest.future;
      firstRequests++;
      return firstRequests == 1 ? _page([9]) : oldRequest.future;
    });
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);
    await controller.refresh();
    expect(_value(container).events.single.id, 9);

    final oldRefresh = controller.refresh();
    container.read(_configProvider.notifier).use(_secondServer);
    await container.pump();

    expect(_value(container).events, isEmpty);
    expect(_value(container).refreshing, isTrue);
    oldRequest.complete(_page([8]));
    await oldRefresh;
    expect(_value(container).events, isEmpty);

    newRequest.complete(_page([2]));
    await controller.refresh();
    expect(_value(container).events.single.id, 2);
  });

  test('조회 중 dispose해도 늦은 응답은 상태를 쓰지 않는다', () async {
    final pending = Completer<ApiResponse>();
    final container = _container((request) => pending.future);
    final future = container.read(promptHistoryProvider.notifier).refresh();

    container.dispose();
    pending.complete(_page([1]));

    await expectLater(future, completes);
  });

  test('API 준비 실패 뒤 새로고침을 세 번 다시 해도 매번 끝나고 로딩 상태를 해제한다', () async {
    final container = ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(baseUrl: _firstServer),
        ),
        dashboardApiProvider.overrideWith(
          (_) => throw StateError('API preparation failed'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);

    Future<void>? previousAttempt;
    for (var attempt = 0; attempt < 3; attempt++) {
      final retry = controller.refresh();
      expect(identical(retry, previousAttempt), isFalse);
      await expectLater(retry, completes);
      previousAttempt = retry;
      expect(_value(container).events, isEmpty);
      expect(_value(container).error, isNotNull);
      expect(_value(container).refreshing, isFalse);
    }
  });

  test('새 서버 API 준비 실패는 이전 이력과 API를 비우고 재시도와 늦은 응답에서 재사용하지 않는다', () async {
    final oldRequest = Completer<ApiResponse>();
    var firstRequests = 0;
    final container = ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWith(
          (ref) => ref.watch(_configProvider),
        ),
        dashboardApiProvider.overrideWith((ref) {
          final config = ref.watch(dashboardApiConfigProvider);
          if (config.baseUrl == _secondServer) {
            throw StateError('New server API preparation failed');
          }
          return DashboardApi(
            config: config,
            send: (request) {
              firstRequests++;
              return firstRequests == 1
                  ? Future.value(_page([9]))
                  : oldRequest.future;
            },
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);
    await controller.refresh();
    expect(_value(container).events.single.id, 9);

    final oldRefresh = controller.refresh();
    container.read(_configProvider.notifier).use(_secondServer);
    await container.pump();
    expect(_value(container).events, isEmpty);
    expect(_value(container).error, isNotNull);
    expect(_value(container).refreshing, isFalse);
    oldRequest.complete(_page([8]));
    await oldRefresh;

    for (var attempt = 0; attempt < 3; attempt++) {
      await expectLater(controller.refresh(), completes);
      expect(_value(container).events, isEmpty);
      expect(_value(container).error, isNotNull);
      expect(_value(container).refreshing, isFalse);
    }
    expect(firstRequests, 2);
  });

  test('설정 준비 실패는 API를 호출하지 않고 재시도 세 번을 끝낸 뒤 설정 복구를 반영한다', () async {
    var configReady = false;
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWith((ref) {
          if (!configReady) throw StateError('Config preparation failed');
          return DashboardApiConfig(baseUrl: _firstServer);
        }),
        dashboardApiProvider.overrideWithValue(
          DashboardApi(
            config: DashboardApiConfig(baseUrl: _firstServer),
            send: (_) async {
              requests++;
              return _page([5]);
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(promptHistoryProvider.notifier);
    Future<void>? previousAttempt;
    for (var attempt = 0; attempt < 3; attempt++) {
      final retry = controller.refresh();
      expect(identical(retry, previousAttempt), isFalse);
      await expectLater(retry, completes);
      previousAttempt = retry;
      expect(_value(container).events, isEmpty);
      expect(_value(container).error, isNotNull);
      expect(_value(container).refreshing, isFalse);
    }
    expect(requests, 0);

    configReady = true;
    container.invalidate(dashboardApiConfigProvider);
    await container.pump();
    await controller.refresh();
    expect(_value(container).events.single.id, 5);
    expect(_value(container).error, isNull);
    expect(_value(container).refreshing, isFalse);
    expect(requests, greaterThan(0));
  });
}

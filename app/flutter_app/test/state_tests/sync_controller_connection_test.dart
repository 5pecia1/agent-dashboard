/// 설정 화면이 저장한 서버 주소·토큰이 재시작 없이 동기화에 쓰이는지를
/// 실제 `SyncController`·`DashboardApi`·`DashboardApiConfigController` 위에서
/// 닫는다(`config_provider.dart`, `sync_controller.dart`).
///
/// 결함: 부팅이 만든 API 설정이 `dashboardApiConfigProvider`의 값 override
/// 하나라서, 첫 실행에서 주소를 저장하면 첫 동기화가 값 없는 provider를 읽다
/// `ProviderException`으로 실패했고, 이미 연결된 앱이 주소나 토큰을 바꿔도
/// 다음 실행까지 옛 값으로 요청했다. 지금은 `DashboardApiConfigController`가
/// 지금 쓰는 값을 들고, 서버가 바뀐 사이클은 이전 서버의 상태를 버린다.
///
/// 타이머·시계·전송은 `sync_controller_test.dart`와 같은 시임으로 가짜를
/// 꽂는다. 전송은 호스트별로 응답하는 [FakeDashboardServer]다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import '../test_helpers/capture_logs.dart';
import '../test_helpers/fake_dashboard_server.dart';

const String _hostA = 'a.example.test';
const String _hostB = 'b.example.test';
const String _urlA = 'https://$_hostA';
const String _urlB = 'https://$_hostB';
const String _tokenA = 'token-a';
const String _tokenB = 'token-b';
const int _cursorA = 10;
const int _cursorB = 50;
const String _sessionA = 'claude-code:a1';
const String _sessionB = 'claude-code:b1';
const int _nowMs = 1000;

/// 대기 중인 스케줄 하나의 기록.
class _Scheduled {
  _Scheduled(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
}

/// 실제 시간을 흘리지 않는 `Timer` 대체물(`sync_controller_test.dart`와 같은
/// 관용).
class _FakeTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// 사이클의 `await` 체인이 끝나도록 마이크로태스크 턴을 흘린다.
Future<void> _pump([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 메모리에만 남는 설정 저장소 — 실제 파일을 건드리지 않는다.
class _MemoryStore {
  DashboardConfigValues values = DashboardConfigValues.empty;

  Future<DashboardConfigValues> load() async => values;

  Future<void> save(DashboardConfigValues next) async => values = next;
}

void main() {
  late List<_Scheduled> scheduled;
  late FakeDashboardServer server;
  late _MemoryStore store;

  setUp(() {
    scheduled = <_Scheduled>[];
    store = _MemoryStore();
    server = FakeDashboardServer(<String, FakeServerScript>{
      _hostA: const FakeServerScript(
        token: _tokenA,
        cursor: _cursorA,
        sessionKeys: <String>[_sessionA],
      ),
      _hostB: const FakeServerScript(
        token: _tokenB,
        cursor: _cursorB,
        sessionKeys: <String>[_sessionB],
      ),
    });
  });

  /// 운영 조립(`main.dart`의 `buildDashboardRoot`)과 같은 두 자리 — 시작 API
  /// 설정과, 지금 쓰는 값을 따라가는 `dashboardApiConfigProvider` — 를 그대로
  /// 쓴다. [initial]이 null이면 첫 실행이다.
  ProviderContainer buildContainer({
    DashboardApiConfig? initial,
    HttpSendFn? send,
  }) {
    final container = ProviderContainer(
      overrides: [
        syncScheduleFnProvider.overrideWithValue((delay, callback) {
          scheduled.add(_Scheduled(delay, callback));
          return _FakeTimer();
        }),
        syncNowMsFnProvider.overrideWithValue(() => _nowMs),
        syncActivityWatchFnProvider.overrideWithValue(
          () => const Stream<bool>.empty(),
        ),
        syncWakeWatchFnProvider.overrideWithValue(
          () => const Stream<void>.empty(),
        ),
        httpSendProvider.overrideWithValue(send ?? server.call),
        dashboardConfigValuesProvider.overrideWithValue(
          DashboardConfigValues(
            serverUrl: initial?.baseUrl.toString(),
            clientToken: initial?.clientToken,
          ),
        ),
        dashboardInitialApiConfigProvider.overrideWithValue(initial),
        dashboardApiConfigProviderOverride,
        configLoadFnProvider.overrideWithValue(store.load),
        configSaveFnProvider.overrideWithValue(store.save),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  DashboardApiConfig configFor(String url, String token) =>
      DashboardApiConfig(baseUrl: Uri.parse(url), clientToken: token);

  /// 부팅이 예약한 첫 사이클을 돌린다.
  Future<void> runBootCycle() async {
    scheduled.removeAt(0).callback();
    await _pump();
  }

  Set<String> sessionKeys(ProviderContainer container) =>
      container.read(syncControllerProvider).sync.sessions.keys.toSet();

  group('첫 실행 — 서버 주소 없이 부팅한 앱', () {
    test('연결을 저장한 뒤 configureAndStart가 새 연결로 첫 동기화를 하고 오류가 없다', () async {
      final container = buildContainer();
      final controller = container.read(syncControllerProvider.notifier);
      expect(
        container.read(syncControllerProvider).phase,
        SyncPhase.unconfigured,
      );
      expect(server.requests, isEmpty, reason: '미설정이면 네트워크 0회');

      final applied = container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: _tokenA);
      controller.configureAndStart();
      await _pump();

      expect(applied, configFor(_urlA, _tokenA));
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.url.host, _hostA);
      expect(request.url.path, kSyncPath);
      expect(request.headers['Authorization'], 'Bearer $_tokenA');
      expect(request.url.queryParameters, isNot(contains('since')));
      final state = container.read(syncControllerProvider);
      expect(state.phase, SyncPhase.idle);
      expect(state.lastError, isNull);
      expect(state.lastSuccessAtMs, _nowMs);
      expect(sessionKeys(container), {_sessionA});
      expect(scheduled, hasLength(1), reason: '다음 폴링이 예약된다');
    });

    test('연결을 저장하기 전에 시작하면 요청 없이 unexpected로 접히고 원문은 로그로만 남는다', () async {
      final container = buildContainer();
      final controller = container.read(syncControllerProvider.notifier);

      // 호출 순서 계약을 어기면(설정 화면은 항상 저장을 먼저 한다) 값 없는
      // provider를 읽는다 — 원문은 화면에 보이지 않는 unexpected다.
      final logged = await captureDebugPrint(() async {
        controller.configureAndStart();
        await _pump();
      });

      expect(server.requests, isEmpty);
      final state = container.read(syncControllerProvider);
      expect(state.phase, SyncPhase.backingOff);
      expect(state.lastError?.kind, SyncErrorKind.unexpected);
      expect(state.lastError?.fault, isNull);
      expect(logged, hasLength(1));
      expect(logged.single, contains('ProviderException'));
    });
  });

  group('이미 연결된 앱이 주소나 토큰을 바꿔 저장한다', () {
    test('서버 주소를 바꾸면 이전 서버의 세션·커서를 버리고 새 서버의 스냅샷으로 옮겨 간다', () async {
      final container = buildContainer(initial: configFor(_urlA, _tokenA));
      container.read(syncControllerProvider);
      await runBootCycle();
      expect(sessionKeys(container), {_sessionA});
      expect(container.read(syncControllerProvider).sync.cursor, _cursorA);

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlB, clientToken: _tokenB);
      expect(
        sessionKeys(container),
        isEmpty,
        reason: '느린 A 요청을 기다리지 않고 A 세션을 숨긴다',
      );
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      await _pump();

      final request = server.syncRequests.firstWhere(
        (request) => request.url.host == _hostB,
      );
      expect(request.url.host, _hostB, reason: '재시작 없이 새 서버로 나간다');
      expect(request.headers['Authorization'], 'Bearer $_tokenB');
      expect(
        request.url.queryParameters,
        isNot(contains('since')),
        reason: '이전 서버의 커서를 새 서버에 들고 가지 않는다',
      );
      final state = container.read(syncControllerProvider);
      expect(sessionKeys(container), {_sessionB}, reason: '두 서버의 세션이 섞이지 않는다');
      expect(state.sync.cursor, _cursorB);
      expect(state.lastError, isNull);
      expect(state.phase, SyncPhase.idle);
    });

    test('A에서 B를 거쳐 A로 돌아와도 옛 A 커서를 첫 요청에 쓰지 않는다', () async {
      final container = buildContainer(initial: configFor(_urlA, _tokenA));
      container.read(syncControllerProvider);
      await runBootCycle();
      expect(container.read(syncControllerProvider).sync.cursor, _cursorA);

      final connection = container.read(
        dashboardApiConfigControllerProvider.notifier,
      );
      connection.apply(serverUrl: _urlB, clientToken: _tokenB);
      connection.apply(serverUrl: _urlA, clientToken: _tokenA);
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      await _pump();

      final firstReturn = server.syncRequests.skip(1).first;
      expect(firstReturn.url.host, _hostA);
      expect(firstReturn.url.queryParameters, isNot(contains('since')));
    });

    test('기존 토큰의 늦은 401은 새 토큰의 재시도를 멈추지 않는다', () async {
      final oldResponse = Completer<ApiResponse>();
      final container = buildContainer(
        initial: configFor(_urlA, _tokenA),
        send: (request) {
          if (request.url.path == kSyncPath &&
              request.headers['Authorization'] == 'Bearer $_tokenA') {
            server.requests.add(request);
            return oldResponse.future;
          }
          return server.call(request);
        },
      );
      container.read(syncControllerProvider);
      scheduled.removeAt(0).callback();
      await _pump();

      server.servers[_hostA] = const FakeServerScript(
        token: _tokenB,
        cursor: _cursorA,
        sessionKeys: <String>[_sessionA],
      );
      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: _tokenB);
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      oldResponse.complete(
        const ApiResponse(statusCode: 401, body: '{"error":"unauthorized"}'),
      );
      await _pump(16);

      expect(container.read(syncControllerProvider).needsSetup, isFalse);
      expect(container.read(syncControllerProvider).lastError, isNull);
      expect(
        server.syncRequests.last.headers['Authorization'],
        'Bearer $_tokenB',
      );
      expect(sessionKeys(container), {_sessionA});
    });

    test('옛 서버의 지연된 삭제 실패는 새 서버에 세션이나 오류를 되돌리지 않는다', () async {
      final deletion = Completer<ApiResponse>();
      final container = buildContainer(
        initial: configFor(_urlA, _tokenA),
        send: (request) {
          if (request.method == 'DELETE') {
            server.requests.add(request);
            return deletion.future;
          }
          return server.call(request);
        },
      );
      container.read(syncControllerProvider);
      await runBootCycle();
      final deleteResult = container
          .read(syncControllerProvider.notifier)
          .deleteSession(_sessionA);
      await _pump();
      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlB, clientToken: _tokenB);
      expect(sessionKeys(container), isEmpty);
      deletion.complete(
        const ApiResponse(statusCode: 503, body: '{"error":"unavailable"}'),
      );
      expect(await deleteResult, isFalse);
      expect(sessionKeys(container), isEmpty);
      expect(container.read(syncControllerProvider).lastError, isNull);
      expect(
        server.requests.where((request) => request.method == 'DELETE'),
        hasLength(1),
      );
    });

    test('서버 주소를 바꾸면 이전 서버의 실패 횟수와 오래된 세션도 새 서버의 첫 실패에 이어지지 않는다', () async {
      const goneUrl = 'https://gone.example.test';
      final container = buildContainer(initial: configFor(_urlA, _tokenA));
      container.read(syncControllerProvider);
      await runBootCycle();
      server.servers.remove(_hostA); // 옛 서버가 사라진다(404)
      for (var i = 0; i < 3; i++) {
        scheduled.removeAt(0).callback();
        await _pump();
      }
      final stale = container.read(syncControllerProvider);
      expect(stale.consecutiveFailures, 3, reason: '옛 서버에서 연속으로 실패했다');
      expect(sessionKeys(container), {_sessionA}, reason: '마지막 스냅샷은 유지된다');

      // 새 서버도 응답하지 않는다(404) — 실패 횟수를 이어받으면 4가 된다.
      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: goneUrl, clientToken: _tokenB);
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      await _pump();

      final state = container.read(syncControllerProvider);
      expect(state.consecutiveFailures, 1);
      expect(state.lastError?.kind, SyncErrorKind.other);
      expect(sessionKeys(container), isEmpty, reason: '이전 서버의 세션은 버려진다');
      expect(state.sync.isFirstBoot, isTrue);
    });

    test('토큰만 바꾸면 같은 서버라 커서와 세션을 그대로 두고 새 토큰으로 요청한다', () async {
      final container = buildContainer(initial: configFor(_urlA, _tokenA));
      container.read(syncControllerProvider);
      await runBootCycle();
      server.servers[_hostA] = const FakeServerScript(
        token: 'rotated',
        cursor: _cursorA,
        sessionKeys: <String>[_sessionA],
      );

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: 'rotated');
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      await _pump();

      final request = server.syncRequests.last;
      expect(request.headers['Authorization'], 'Bearer rotated');
      expect(
        request.url.queryParameters['since'],
        '$_cursorA',
        reason: '같은 서버면 커서를 이어받는다',
      );
      expect(sessionKeys(container), {_sessionA});
      expect(container.read(syncControllerProvider).lastError, isNull);
    });

    test('401로 멈춘 앱이 고친 토큰을 저장하고 force로 다시 시작하면 복구된다', () async {
      final container = buildContainer(initial: configFor(_urlA, 'typo'));
      container.read(syncControllerProvider);
      await runBootCycle();
      expect(container.read(syncControllerProvider).needsSetup, isTrue);
      final callsWhileStopped = server.requests.length;

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: _tokenA);
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      await _pump();

      expect(server.requests.length, callsWhileStopped + 1);
      expect(
        server.syncRequests.last.headers['Authorization'],
        'Bearer $_tokenA',
      );
      final state = container.read(syncControllerProvider);
      expect(state.needsSetup, isFalse);
      expect(state.lastError, isNull);
      expect(sessionKeys(container), {_sessionA});
    });

    test('서버 주소를 바꾼 순간 이전 서버로 나가 있던 요청의 응답이 늦게 와도 새 서버의 상태에 섞이지 않는다', () async {
      final slowA = Completer<ApiResponse>();
      final fast = server.call;
      final container = ProviderContainer(
        overrides: [
          syncScheduleFnProvider.overrideWithValue((delay, callback) {
            scheduled.add(_Scheduled(delay, callback));
            return _FakeTimer();
          }),
          syncNowMsFnProvider.overrideWithValue(() => _nowMs),
          syncActivityWatchFnProvider.overrideWithValue(
            () => const Stream<bool>.empty(),
          ),
          syncWakeWatchFnProvider.overrideWithValue(
            () => const Stream<void>.empty(),
          ),
          httpSendProvider.overrideWithValue((request) {
            if (request.url.host == _hostA) {
              server.requests.add(request);
              return slowA.future;
            }
            return fast(request);
          }),
          dashboardConfigValuesProvider.overrideWithValue(
            const DashboardConfigValues(serverUrl: _urlA),
          ),
          dashboardInitialApiConfigProvider.overrideWithValue(
            configFor(_urlA, _tokenA),
          ),
          dashboardApiConfigProviderOverride,
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue(store.save),
        ],
      );
      addTearDown(container.dispose);
      container.read(syncControllerProvider);
      scheduled.removeAt(0).callback();
      await _pump();
      expect(server.syncRequests, hasLength(1), reason: '이전 서버로 나간 요청이 비행 중이다');

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlB, clientToken: _tokenB);
      container.read(syncControllerProvider.notifier).triggerNow(force: true);
      slowA.complete(
        ApiResponse(
          statusCode: 200,
          body: jsonEncode(
            fakeSyncBody(
              cursor: _cursorA,
              reset: true,
              sessionKeys: const <String>[_sessionA],
            ),
          ),
        ),
      );
      await _pump(16);

      expect(server.syncRequests.last.url.host, _hostB);
      expect(
        server.syncRequests.last.url.queryParameters,
        isNot(contains('since')),
      );
      expect(sessionKeys(container), {_sessionB});
      expect(container.read(syncControllerProvider).sync.cursor, _cursorB);
    });
  });
}

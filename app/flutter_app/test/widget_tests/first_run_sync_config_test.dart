/// 설정 화면이 저장한 서버 주소·토큰이 앱을 다시 켜지 않아도 쓰이는지를
/// 실제 앱 조립(`main.dart`의 [buildDashboardRoot] + [SolApp])과 실제
/// `SyncController`·`DashboardApi` 위에서 닫는다.
///
/// 결함: 첫 실행에는 서버 주소가 없어 부팅이 `dashboardApiConfigProvider`를
/// override하지 않았다. 설정 화면에서 주소와 토큰을 저장하면 push 등록과 첫
/// 동기화가 값 없는 provider를 읽다 `ProviderException`(스택 트레이스 두 벌과
/// 한국어 `StateError` 문장이 든 덤프)으로 실패했고, 그 덤프가 영어 화면의
/// 오류 줄에 그대로 보였다. 이미 연결된 앱이 주소나 토큰을 바꿔 저장해도 다음
/// 실행까지 옛 값으로 요청했다. 그래서 401로 멈춘 앱이 설정 화면에서 토큰을
/// 고쳐도 "다시 시도"가 옛 토큰으로 다시 401을 만났다.
///
/// 전송만 호스트별로 응답하는 [FakeDashboardServer]로 바꾼다 — 나머지는 운영
/// 조립 그대로다([buildDashboardRoot]의 override 목록에서 실제 전송만
/// 갈아 끼운다). 번역은 키를 그대로 돌려주는 가짜, 타이머는 기록만 하는
/// 가짜, 설정 저장소는 메모리다.
library;

import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/main.dart' show buildDashboardRoot;
import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/http_provider.dart'
    show httpSendProviderOverride;
import 'package:my_dashboard/src/state/push_provider.dart'
    show apnsTokenFnProvider, isApplePushHostProvider, webPushTokenFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/ui_lang_provider.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';
import '../test_helpers/fake_dashboard_server.dart';
// `Override`는 `flutter_riverpod` barrel에 없다 — 정본 위치에서 이름만
// 가져온다(`config_provider.dart`가 같은 이유로 같은 일을 했었다).
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

const String _hostA = 'a.example.test';
const String _hostB = 'b.example.test';
const String _urlA = 'https://$_hostA';
const String _urlB = 'https://$_hostB';
const String _tokenA = 'token-a';
const String _tokenB = 'token-b';
const String _sessionA = 'claude-code:a1';
const String _sessionB = 'claude-code:b1';

/// 세션 카드가 그리는 프로젝트 이름(`fakeSessionJson`의 `project-<id>`).
const String _projectA = 'project-a1';
const String _projectB = 'project-b1';

const String _unusableUrl = 'https://a.example.test:443x';

/// 기록만 하는 가짜 `Timer`(`sync_controller_test.dart`와 같은 관용).
class _FakeTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// 메모리에만 남는 설정 저장소 — 실제 파일/localStorage를 건드리지 않는다.
class _MemoryStore {
  _MemoryStore([this.values = DashboardConfigValues.empty]);

  DashboardConfigValues values;

  /// 이 Completer가 풀릴 때까지 저장을 붙잡는다("저장 중" 상태를 만든다).
  Completer<void>? saveGate;

  /// 값이 있으면 읽기가 그 오류로 실패한다(폼을 연 뒤에 저장소가 망가진 상태).
  Object? loadError;

  /// 값이 있으면 쓰기가 그 오류로 실패한다(권한 없음 등).
  Object? saveError;

  /// 실제로 값을 쓴 횟수.
  int saves = 0;

  Future<DashboardConfigValues> load() async {
    final error = loadError;
    if (error != null) throw error;
    return values;
  }

  Future<void> save(DashboardConfigValues next) async {
    await saveGate?.future;
    final error = saveError;
    if (error != null) throw error;
    values = next;
    saves += 1;
  }
}

/// 폼을 연 뒤 저장소를 읽지 못하는 상황의 오류(`config_store_io.dart`가
/// 던지는 값과 같은 모양).
const ConfigReadException _storageBroke = ConfigReadException(
  ConfigReadFailureKind.access,
  location: '/fixture/config.json',
  detail: 'Cannot open file: Permission denied (errno 13)',
);

/// 쓰기 실패(디스크 권한 등)를 흉내 내는 예외.
class _DiskFull implements Exception {
  const _DiskFull();
}

/// 부팅이 예약한 사이클을 테스트가 직접 발화한다.
class _Scheduler {
  final List<void Function()> callbacks = <void Function()>[];

  Timer call(Duration delay, void Function() callback) {
    callbacks.add(callback);
    return _FakeTimer();
  }

  void fireFirst() => callbacks.removeAt(0)();
}

/// 운영 조립의 override 목록에서 실제 전송만 [send]로 갈아 끼운 루트.
///
/// [buildDashboardRoot]는 실제 전송([httpSendProviderOverride])을 목록에
/// 넣고, 같은 provider를 두 번 override하면 Riverpod이 죽는다. 그래서 그
/// 항목만 빼고 가짜 전송을 넣어 같은 루트를 다시 감싼다 — 시작 API 설정,
/// 지금 쓰는 설정을 따르는 `dashboardApiConfigProvider` 등 나머지는 운영과
/// 같은 항목이다.
Widget _rootWithTransport(Widget root, HttpSendFn send) {
  final scope = root as ProviderScope;
  return ProviderScope(
    key: scope.key,
    overrides: [
      for (final override in scope.overrides)
        if (!identical(override, httpSendProviderOverride)) override,
      httpSendProvider.overrideWithValue(send),
    ],
    child: scope.child,
  );
}

class _App {
  _App({
    required this.stored,
    required this.server,
    this.send,
    this.extra = const <Override>[],
  }) : store = _MemoryStore(stored);

  final DashboardConfigValues stored;
  final FakeDashboardServer server;
  final HttpSendFn? send;
  final List<Override> extra;
  final _MemoryStore store;
  final _Scheduler scheduler = _Scheduler();

  Widget build() => _rootWithTransport(
    buildDashboardRoot(
      stored,
      app: const SolApp(),
      extensions: (_) => [
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, locale, argKeys, argVals) => key,
        ),
        stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
        isSessionStaleFnProvider.overrideWithValue(
          ({required int now, required int updatedAt, required int staleMs}) =>
              false,
        ),
        configLoadFnProvider.overrideWithValue(store.load),
        configSaveFnProvider.overrideWithValue(store.save),
        syncScheduleFnProvider.overrideWithValue(scheduler.call),
        syncNowMsFnProvider.overrideWithValue(() => 1000),
        syncActivityWatchFnProvider.overrideWithValue(
          () => const Stream<bool>.empty(),
        ),
        syncWakeWatchFnProvider.overrideWithValue(
          () => const Stream<void>.empty(),
        ),
        ...extra,
      ],
    ),
    send ?? server.call,
  );
}

/// 비동기 저장·동기화 체인이 끝나도록 프레임을 몇 번 흘린다. 세션 목록 전
/// 로딩 스피너가 끝나지 않는 애니메이션이라 `pumpAndSettle`을 쓰지 않는다.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 설정 화면은 지연 빌드되는 스크롤 목록이라 아래쪽 절까지 그리려면 높은
/// 뷰포트가 필요하다.
void _useTallViewport(WidgetTester tester) {
  final view = tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = const Size(500, 2000);
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SolApp)));

/// 설정 화면의 서버 주소·토큰 입력칸에 쓰고 저장한다. 입력칸 순서는 서버
/// 주소, 토큰이다(`setup_page.dart`의 서버 절).
Future<void> _saveConnection(
  WidgetTester tester, {
  required String serverUrl,
  required String token,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), serverUrl);
  await tester.enterText(fields.at(1), token);
  await tester.tap(find.text('action.save'));
  await _settle(tester);
}

Future<void> _openSetupFromSessions(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await _settle(tester);
}

FakeDashboardServer _twoServers() =>
    FakeDashboardServer(<String, FakeServerScript>{
      _hostA: const FakeServerScript(
        token: _tokenA,
        cursor: 10,
        sessionKeys: <String>[_sessionA],
      ),
      _hostB: const FakeServerScript(
        token: _tokenB,
        cursor: 50,
        sessionKeys: <String>[_sessionB],
      ),
    });

void main() {
  group('첫 실행 — 서버 주소 없이 부팅한 앱', () {
    testWidgets('설정 화면에서 주소와 토큰을 저장하면 재시작 없이 새 연결로 동기화하고 세션이 보인다', (
      tester,
    ) async {
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);

      expect(find.byType(SetupPage), findsOneWidget);
      expect(app.server.requests, isEmpty, reason: '서버 주소가 없는 동안 네트워크 0회');

      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);

      expect(tester.takeException(), isNull);
      expect(app.server.syncRequests, hasLength(1));
      final request = app.server.syncRequests.single;
      expect(request.url.host, _hostA, reason: '저장한 주소로 요청이 나간다');
      expect(request.headers['Authorization'], 'Bearer $_tokenA');
      expect(request.url.queryParameters, isNot(contains('since')));
      expect(find.byType(SessionsPage), findsOneWidget);
      expect(find.text(_projectA), findsOneWidget);
      expect(find.text('session.list.error.title'), findsNothing);
      final sync = _container(tester).read(syncControllerProvider);
      expect(sync.phase, SyncPhase.idle);
      expect(sync.lastError, isNull);
      expect(sync.lastSuccessAtMs, isNotNull);
      expect(app.store.values.serverUrl, _urlA, reason: '디스크에도 저장됐다');
      expect(app.store.values.clientToken, _tokenA);
    });

    // push 등록은 호스트마다 다른 분기(웹, macOS)가 `dashboardApiProvider`를
    // 읽는다. 둘 다 서버가 채널을 주지 않으면 토큰을 받지 않고 끝나므로 가짜
    // 토큰 함수는 불리면 안 된다.
    final pushHosts = <({String name, List<Override> overrides})>[
      (
        name: '웹',
        overrides: [
          isWasmRuntimeProvider.overrideWithValue(true),
          webPushTokenFnProvider.overrideWithValue(
            (config) async => throw StateError('서버가 채널을 주지 않으면 토큰을 받지 않는다'),
          ),
        ],
      ),
      (
        name: 'macOS',
        overrides: [
          isApplePushHostProvider.overrideWithValue(true),
          apnsTokenFnProvider.overrideWithValue(
            (config) async => throw StateError('서버가 채널을 주지 않으면 토큰을 받지 않는다'),
          ),
        ],
      ),
    ];
    for (final host in pushHosts) {
      testWidgets('${host.name} 호스트의 첫 저장은 push 등록도 새 연결로 보내고 처리되지 않은 오류가 없다', (
        tester,
      ) async {
        final app = _App(
          stored: DashboardConfigValues.empty,
          server: _twoServers(),
          extra: host.overrides,
        );
        await tester.pumpWidget(app.build());
        await _settle(tester);

        await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);

        // 예전에는 push 등록이 값 없는 `dashboardApiProvider`를 읽다 던졌고,
        // `unawaited`라 처리되지 않은 비동기 오류가 됐다(실제 macOS에서
        // 확인).
        expect(tester.takeException(), isNull);
        final pushConfig = app.server.requests.where(
          (request) => request.url.path == kPushConfigPath,
        );
        expect(pushConfig, hasLength(1));
        expect(pushConfig.single.url.host, _hostA);
        expect(pushConfig.single.headers['Authorization'], 'Bearer $_tokenA');
        expect(app.server.syncRequests, hasLength(1));
        expect(
          _container(tester).read(syncControllerProvider).lastError,
          isNull,
        );
      });
    }

    testWidgets('저장 직전에 설정을 읽지 못하면 아무것도 쓰지 않고 연결도 요청도 만들지 않는다', (tester) async {
      _useTallViewport(tester);
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      app.store.loadError = _storageBroke; // 폼은 열렸지만 저장소가 망가졌다

      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);

      // 0.1.4의 읽기 계약: 읽지 못한 값 위에는 쓰지 않는다. 쓰지 않았으니
      // 지금 쓰는 설정도 바꾸지 않는다.
      expect(tester.takeException(), isNull);
      expect(app.store.saves, 0);
      expect(find.text('setup.save_error'), findsOneWidget);
      expect(find.byType(SetupPage), findsOneWidget);
      final container = _container(tester);
      expect(container.read(dashboardApiConfigControllerProvider), isNull);
      expect(
        container.read(syncControllerProvider).phase,
        SyncPhase.unconfigured,
      );
      expect(app.server.requests, isEmpty);
    });

    testWidgets('디스크에 쓰지 못하면 지금 쓰는 설정도 요청도 바뀌지 않는다', (tester) async {
      _useTallViewport(tester);
      final app = _App(
        stored: const DashboardConfigValues(
          serverUrl: _urlA,
          clientToken: _tokenA,
        ),
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      app.scheduler.fireFirst();
      await _settle(tester);
      await _openSetupFromSessions(tester);
      app.store.saveError = const _DiskFull();
      final requestsBefore = app.server.requests.length;

      await _saveConnection(tester, serverUrl: _urlB, token: _tokenB);

      expect(tester.takeException(), isNull);
      expect(find.text('setup.save_error'), findsOneWidget);
      expect(app.store.values.serverUrl, _urlA, reason: '디스크는 그대로다');
      final container = _container(tester);
      expect(
        container.read(dashboardApiConfigControllerProvider)?.baseUrl,
        Uri.parse(_urlA),
        reason: '쓰기가 실패하면 실행 중인 연결도 그대로다',
      );
      expect(app.server.requests, hasLength(requestsBefore));
      app.scheduler.fireFirst(); // 다음 폴링은 여전히 옛 서버다
      await _settle(tester);
      expect(app.server.syncRequests.last.url.host, _hostA);
    });

    testWidgets('저장한 뒤 설정 화면에서 고른 언어는 로컬에만 두지 않고 서버에 보낸다', (tester) async {
      _useTallViewport(tester);
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);
      await _openSetupFromSessions(tester);

      await tester.tap(find.text('한국어'));
      await _settle(tester);

      // 부팅 스냅샷에는 서버 주소가 없다. 그 스냅샷으로 "미설정"을 판정하면
      // 선택이 로컬에만 남고, 다음 동기화가 서버의 값으로 되돌린다.
      final uiLang = app.server.requests.where(
        (request) => request.url.path == kUiLangPath,
      );
      expect(uiLang, hasLength(1));
      expect(uiLang.single.method, 'POST');
      expect(uiLang.single.url.host, _hostA);
      expect(tester.takeException(), isNull);
    });

    testWidgets('첫 언어 전송이 대기해도 동기화하고 서버 null이 로컬 선택을 지우지 않는다', (tester) async {
      _useTallViewport(tester);
      final server = _twoServers();
      final languagePost = Completer<ApiResponse>();
      String? serverLanguage;
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: server,
        send: (request) async {
          if (request.url.path == kUiLangPath && request.method == 'POST') {
            server.requests.add(request);
            serverLanguage =
                (jsonDecode(request.body!) as Map<String, dynamic>)['lang']
                    as String?;
            return languagePost.future;
          }
          return server.call(request);
        },
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      await tester.tap(find.text('English'));
      await _settle(tester);
      expect(_container(tester).read(uiLangControllerProvider), 'en');

      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);

      expect(server.syncRequests, hasLength(1), reason: '언어 POST가 아직 끝나지 않았다');
      expect(
        server.requests.where((request) => request.url.path == kUiLangPath),
        hasLength(1),
      );
      expect(serverLanguage, 'en');
      expect(_container(tester).read(uiLangControllerProvider), 'en');
      expect(
        _container(
          tester,
        ).read(uiLangControllerProvider.notifier).pendingServerWrite,
        isTrue,
      );
      languagePost.complete(
        const ApiResponse(statusCode: 200, body: '{"ok":true,"ui_lang":"en"}'),
      );
      await _settle(tester);
      expect(
        _container(
          tester,
        ).read(uiLangControllerProvider.notifier).pendingServerWrite,
        isFalse,
      );
      expect(app.store.values.uiLang, 'en');
    });

    testWidgets('상대 주소는 저장해도 요청을 보내지 않고 주소 오류를 보인다', (tester) async {
      _useTallViewport(tester);
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      await _saveConnection(tester, serverUrl: _hostA, token: _tokenA);
      expect(find.text('setup.server_url_invalid'), findsOneWidget);
      expect(app.server.requests, isEmpty);
      expect(app.store.values.serverUrl, _hostA);
    });

    testWidgets('첫 언어 전송 실패 뒤 서버 null이 선택을 지우지 않고 같은 값 저장에서 재시도한다', (
      tester,
    ) async {
      _useTallViewport(tester);
      final server = _twoServers();
      var failLanguagePost = true;
      var languagePosts = 0;
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: server,
        send: (request) async {
          if (request.url.path == kUiLangPath && request.method == 'POST') {
            server.requests.add(request);
            languagePosts += 1;
            if (failLanguagePost) {
              return const ApiResponse(
                statusCode: 503,
                body: '{"error":"retry"}',
              );
            }
            return const ApiResponse(
              statusCode: 200,
              body: '{"ok":true,"ui_lang":"en"}',
            );
          }
          return server.call(request);
        },
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      await tester.tap(find.text('English'));
      await _settle(tester);
      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);
      expect(server.syncRequests, hasLength(1));
      expect(_container(tester).read(uiLangControllerProvider), 'en');
      expect(
        _container(
          tester,
        ).read(uiLangControllerProvider.notifier).pendingServerWrite,
        isTrue,
      );

      failLanguagePost = false;
      await _openSetupFromSessions(tester);
      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);
      expect(languagePosts, 2);
      expect(
        server.syncRequests,
        hasLength(1),
        reason: '같은 연결 저장은 동기화를 늘리지 않는다',
      );
      expect(
        _container(
          tester,
        ).read(uiLangControllerProvider.notifier).pendingServerWrite,
        isFalse,
      );
      expect(_container(tester).read(uiLangControllerProvider), 'en');
    });

    testWidgets('쓸 수 없는 주소를 저장하면 알리고 연결도 요청도 없이 설정 화면에 머문다', (tester) async {
      _useTallViewport(tester); // 저장 결과 문구는 설정 화면의 맨 아래에 그려진다
      final app = _App(
        stored: DashboardConfigValues.empty,
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);

      await _saveConnection(tester, serverUrl: _unusableUrl, token: _tokenA);

      expect(tester.takeException(), isNull);
      expect(find.byType(SetupPage), findsOneWidget);
      expect(find.byType(SessionsPage), findsNothing);
      expect(find.text('setup.server_url_invalid'), findsOneWidget);
      expect(find.text('setup.save_success'), findsNothing);
      expect(app.server.requests, isEmpty);
      expect(
        _container(tester).read(syncControllerProvider).phase,
        SyncPhase.unconfigured,
      );
      expect(
        app.store.values.serverUrl,
        _unusableUrl,
        reason: '입력은 저장한다 — 다음 부팅의 설정 화면이 원래 문자열을 보여 준다',
      );
    });

    testWidgets('해석할 수 없던 저장 주소를 고쳐 저장하면 같은 세션 안에서 동기화가 시작된다', (tester) async {
      final app = _App(
        stored: const DashboardConfigValues(
          serverUrl: _unusableUrl,
          clientToken: _tokenA,
        ),
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      expect(find.byType(SetupPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        _unusableUrl,
        reason: '설정 화면은 디스크의 원래 문자열을 보여 준다',
      );
      expect(app.server.requests, isEmpty);

      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);

      expect(tester.takeException(), isNull);
      expect(app.server.syncRequests, hasLength(1));
      expect(app.server.syncRequests.single.url.host, _hostA);
      expect(find.text(_projectA), findsOneWidget);
    });
  });

  group('이미 연결된 앱이 설정 화면에서 바꿔 저장한다', () {
    const connected = DashboardConfigValues(
      serverUrl: _urlA,
      clientToken: _tokenA,
    );

    testWidgets('새 서버 인증 실패와 재시작 사이에도 옛 커서와 seen이 새 서버에 가지 않는다', (
      tester,
    ) async {
      final server = _twoServers();
      final app = _App(
        stored: const DashboardConfigValues(
          serverUrl: _urlA,
          clientToken: _tokenA,
          cursor: 900,
          seenWatermark: 900,
        ),
        server: server,
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      await _openSetupFromSessions(tester);
      await _saveConnection(tester, serverUrl: _urlB, token: 'typo');
      expect(app.store.values.serverUrl, _urlB);
      expect(app.store.values.cursor, isNull);
      expect(app.store.values.seenWatermark, isNull);
      expect(
        _container(tester).read(syncControllerProvider).needsSetup,
        isTrue,
      );

      server.servers[_hostB] = const FakeServerScript(
        token: 'typo',
        cursor: 5,
        sessionKeys: <String>[_sessionB],
      );
      server.requests.clear();
      final restarted = _App(stored: app.store.values, server: server);
      await tester.pumpWidget(restarted.build());
      await _settle(tester);
      restarted.scheduler.fireFirst();
      await _settle(tester);
      final firstRequest = server.syncRequests.first;
      expect(firstRequest.url.host, _hostB);
      expect(firstRequest.url.queryParameters, isNot(contains('since')));
      expect(_container(tester).read(syncControllerProvider).sync.cursor, 5);
      expect(restarted.store.values.seenWatermark, 5);
    });

    testWidgets('주소와 토큰을 바꾸면 재시작 없이 새 서버로 옮겨 가고 이전 서버의 세션이 남지 않는다', (
      tester,
    ) async {
      final app = _App(stored: connected, server: _twoServers());
      await tester.pumpWidget(app.build());
      await _settle(tester);
      app.scheduler.fireFirst(); // 부팅이 예약한 첫 사이클
      await _settle(tester);
      expect(find.text(_projectA), findsOneWidget);
      expect(app.server.syncRequests.single.url.host, _hostA);

      await _openSetupFromSessions(tester);
      await _saveConnection(tester, serverUrl: _urlB, token: _tokenB);

      expect(tester.takeException(), isNull);
      final request = app.server.syncRequests.firstWhere(
        (request) => request.url.host == _hostB,
      );
      expect(request.url.host, _hostB, reason: '저장 즉시 새 서버로 나간다');
      expect(request.headers['Authorization'], 'Bearer $_tokenB');
      expect(
        request.url.queryParameters,
        isNot(contains('since')),
        reason: '이전 서버의 커서를 새 서버에 들고 가지 않는다',
      );
      await tester.pageBack();
      await _settle(tester);
      expect(find.text(_projectB), findsOneWidget);
      expect(find.text(_projectA), findsNothing, reason: '두 서버의 세션이 섞이지 않는다');
      expect(app.store.values.serverUrl, _urlB);
      expect(app.store.values.seenWatermark, 50, reason: 'B의 첫 스냅샷으로 새로 세웠다');
    });

    testWidgets('401로 멈춘 앱이 설정 화면에서 토큰을 고쳐 저장하면 다시 시도를 누르지 않아도 복구된다', (
      tester,
    ) async {
      final app = _App(
        stored: const DashboardConfigValues(
          serverUrl: _urlA,
          clientToken: 'typo',
        ),
        server: _twoServers(),
      );
      await tester.pumpWidget(app.build());
      await _settle(tester);
      app.scheduler.fireFirst();
      await _settle(tester);
      expect(
        _container(tester).read(syncControllerProvider).needsSetup,
        isTrue,
        reason: '옛 토큰은 401이다',
      );
      expect(find.text('alert.banner.needs_setup.action'), findsOneWidget);

      await tester.tap(find.text('alert.banner.needs_setup.action'));
      await _settle(tester);
      await _saveConnection(tester, serverUrl: _urlA, token: _tokenA);

      expect(tester.takeException(), isNull);
      expect(
        app.server.syncRequests.last.headers['Authorization'],
        'Bearer $_tokenA',
        reason: '고친 토큰이 곧바로 쓰인다',
      );
      final sync = _container(tester).read(syncControllerProvider);
      expect(sync.needsSetup, isFalse);
      expect(sync.lastError, isNull);
      await tester.pageBack();
      await _settle(tester);
      expect(find.text('alert.banner.needs_setup.title'), findsNothing);
      expect(find.text(_projectA), findsOneWidget);
    });

    testWidgets('저장하는 동안 설정 화면을 닫아도 쓴 값은 지금 쓰는 설정에 반영되고 다음 폴링이 새 서버로 간다', (
      tester,
    ) async {
      final app = _App(stored: connected, server: _twoServers());
      await tester.pumpWidget(app.build());
      await _settle(tester);
      app.scheduler.fireFirst();
      await _settle(tester);
      await _openSetupFromSessions(tester);
      app.store.saveGate = Completer<void>(); // 디스크 쓰기가 끝나지 않은 상태

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _urlB);
      await tester.enterText(fields.at(1), _tokenB);
      await tester.tap(find.text('action.save'));
      await tester.pump();
      await tester.pageBack(); // 저장이 끝나기 전에 화면을 닫는다
      await _settle(tester);
      expect(find.byType(SetupPage), findsNothing);
      app.store.saveGate!.complete();
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(app.store.values.serverUrl, _urlB, reason: '디스크에는 쓰였다');
      expect(
        _container(tester).read(dashboardApiConfigControllerProvider)?.baseUrl,
        Uri.parse(_urlB),
        reason: '화면이 사라져도 지금 쓰는 설정은 디스크를 따른다',
      );
      app.scheduler.fireFirst(); // 다음 폴링
      await _settle(tester);
      expect(app.server.syncRequests.last.url.host, _hostB);
      expect(find.text(_projectB), findsOneWidget);
      expect(find.text(_projectA), findsNothing);
    });

    testWidgets('주소를 비워 저장해도 실행 중인 연결은 그대로 동기화한다', (tester) async {
      _useTallViewport(tester); // 저장 결과 문구는 설정 화면의 맨 아래에 그려진다
      final app = _App(stored: connected, server: _twoServers());
      await tester.pumpWidget(app.build());
      await _settle(tester);
      app.scheduler.fireFirst();
      await _settle(tester);
      await _openSetupFromSessions(tester);

      await _saveConnection(tester, serverUrl: '', token: '');

      expect(tester.takeException(), isNull);
      expect(
        app.store.values.serverUrl,
        isNull,
        reason: '저장은 비운다(다음 실행부터 저장된 값을 따른다)',
      );
      expect(find.text('setup.save_success'), findsOneWidget);
      final container = _container(tester);
      expect(
        container.read(dashboardApiConfigControllerProvider)?.baseUrl,
        Uri.parse(_urlA),
        reason: '실행 중인 연결은 끊기지 않는다',
      );
      app.scheduler.fireFirst(); // 다음 폴링은 여전히 옛 연결이다
      await _settle(tester);
      expect(app.server.syncRequests.last.url.host, _hostA);
      expect(container.read(syncControllerProvider).lastError, isNull);
    });
  });
}

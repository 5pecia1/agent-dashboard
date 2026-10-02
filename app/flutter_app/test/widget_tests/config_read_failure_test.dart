/// 부팅이 설정을 읽지 못했을 때의 화면과 대시보드 루트 넘겨주기
/// (`ui/config_read_failure.dart`, `main.dart`의 [buildDashboardRoot]).
///
/// 실제 FFI 없이 i18n을 키 그대로 돌려주는 가짜로 바꾼다. 대시보드 루트는
/// 운영과 같은 [buildDashboardRoot] 조립을 쓰고, `SolApp` 대신 읽은 값을
/// 보여 주는 탐침 위젯만 넣는다. 실제 파일을 쓰는 테스트는 임시
/// 디렉터리만 쓴다 — 실제 HOME의 설정 경로를 계산하지 않는다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/main.dart'
    show buildDashboardRoot, kDashboardRootKey;
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/config_store_io.dart'
    show loadDashboardConfigFile;
import 'package:my_dashboard/src/ui/config_read_failure.dart';
// `Override`는 `flutter_riverpod` barrel에 없다 — 정본 위치에서 이름만
// 가져온다(`config_provider.dart`가 같은 이유로 같은 일을 한다).
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

const String _fixtureToken = 'fixture-client-token-5d1e';

const ConfigReadException _accessFailure = ConfigReadException(
  ConfigReadFailureKind.access,
  location: '/fixture/home/.local/state/my-dashboard/config.json',
  detail: 'Cannot open file: Permission denied (errno 13)',
);

const ConfigReadException _corruptFailure = ConfigReadException(
  ConfigReadFailureKind.corrupt,
  location: '/fixture/home/.local/state/my-dashboard/config.json',
  detail: 'Unexpected end of input (offset 42)',
);

/// 웹 브리지(`config_store_web.dart`)가 브라우저가 막은 저장소에서 던지는
/// 값과 같은 모양.
const ConfigReadException _blockedWebStorage = ConfigReadException(
  ConfigReadFailureKind.access,
  location: 'localStorage[my-dashboard.config.v1]',
  detail: 'SecurityError: The operation is insecure.',
);

const ConfigReadException _corruptWebValue = ConfigReadException(
  ConfigReadFailureKind.corrupt,
  location: 'localStorage[my-dashboard.config.v1]',
  detail: 'Unexpected end of input (offset 42)',
);

const DashboardConfigValues _stored = DashboardConfigValues(
  serverUrl: 'https://dash.example.test',
  clientToken: _fixtureToken,
  cursor: 41,
  extra: <String, Object?>{
    'teamclaude': <String, Object?>{
      'url': 'https://tc.example.test',
      'api_key': 'fixture-teamclaude-key',
    },
  },
);

final List<Override> _keyEchoI18n = <Override>[
  i18nTranslateOverride.overrideWithValue((key, locale) => key),
  i18nTranslateArgsOverride.overrideWithValue(
    (key, locale, argKeys, argVals) => key,
  ),
];

/// 개인 빌드의 `withCompileTimeDefaults`와 같은 모양: 저장값이 없는
/// 필드에만 빌드에 구운 기본값을 채운다.
DashboardConfigValues _fillCompileDefaults(DashboardConfigValues stored) =>
    stored.copyWith(
      serverUrl: stored.serverUrl ?? 'https://default.example.test',
      clientToken: stored.clientToken ?? 'default-client-token',
    );

/// API override를 읽지 않고 부팅 스냅샷과 "저장된 설정으로 부팅했다"만
/// 보여 준다.
class _SnapshotProbe extends ConsumerWidget {
  const _SnapshotProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = ref.watch(dashboardConfigValuesProvider);
    final storedAtBoot = ref.watch(storedConfigAtBootProvider);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(
        'snapshot ${values.serverUrl} ${values.clientToken} '
        'stored-at-boot=$storedAtBoot',
      ),
    );
  }
}

/// 대시보드 루트 안에서 부팅이 채운 값을 그대로 보여 준다.
class _DashboardProbe extends ConsumerWidget {
  const _DashboardProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = ref.watch(dashboardConfigValuesProvider);
    final api = ref.watch(dashboardApiConfigProvider);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text('dashboard ${values.clientToken} ${api.baseUrl}'),
    );
  }
}

Widget _screen({
  required Object error,
  required ConfigLoadFn load,
  required void Function(DashboardConfigValues stored) onLoaded,
  bool web = false,
}) => ProviderScope(
  overrides: [..._keyEchoI18n, isWasmRuntimeProvider.overrideWithValue(web)],
  child: MaterialApp(
    home: ConfigReadFailureScreen(error: error, load: load, onLoaded: onLoaded),
  ),
);

/// 순서대로 실패 또는 값을 돌려주는 읽기. 목록이 끝나면 마지막 항목을
/// 계속 쓴다.
class _ScriptedLoad {
  _ScriptedLoad(this.outcomes);

  final List<Object> outcomes;
  int calls = 0;

  Future<DashboardConfigValues> call() async {
    final outcome =
        outcomes[calls < outcomes.length ? calls : outcomes.length - 1];
    calls += 1;
    if (outcome is DashboardConfigValues) return outcome;
    throw outcome;
  }
}

/// 읽기가 항상 실패하는 테스트의 넘겨주기 자리 — 불리지 않는다.
void _noHandover(DashboardConfigValues _) {}

void main() {
  group('buildBootRoot', () {
    test('읽기에 성공하면 대시보드 조립을 한 번 부르고 그 루트를 돌려준다', () async {
      final assembled = <DashboardConfigValues>[];
      final root = await buildBootRoot(
        load: () async => _stored,
        dashboard: (stored) {
          assembled.add(stored);
          return buildDashboardRoot(
            stored,
            app: const _DashboardProbe(),
            configure: _fillCompileDefaults,
          );
        },
        replaceRoot: (_) => fail('성공한 부팅은 루트를 바꿔 끼우지 않는다'),
      );

      expect(assembled, <DashboardConfigValues>[_stored]);
      expect(root, isA<ProviderScope>());
      expect(root.key, kDashboardRootKey);
    });

    test('데스크톱에서는 접근 오류도 실패 화면을 돌려주고 대시보드 조립과 기본값 채우기를 부르지 않는다', () async {
      var assembled = 0;
      var configured = 0;
      final root = await buildBootRoot(
        load: () async => throw _accessFailure,
        webRuntime: false,
        dashboard: (stored) {
          assembled += 1;
          return buildDashboardRoot(
            stored,
            app: const _DashboardProbe(),
            configure: (values) {
              configured += 1;
              return _fillCompileDefaults(values);
            },
          );
        },
        replaceRoot: (_) => fail('아직 읽지 못했다'),
      );

      expect(root, isA<ConfigReadFailureApp>());
      expect((root as ConfigReadFailureApp).error, same(_accessFailure));
      expect(assembled, 0);
      expect(configured, 0, reason: '기본값이 읽지 못한 저장소를 가리면 안 된다');
    });

    test('부팅이 저장된 설정 없이 시작하는 읽기 실패는 웹에서 브라우저가 막은 저장소뿐이다', () {
      expect(
        shouldBootWithoutStoredConfig(_blockedWebStorage, webRuntime: true),
        isTrue,
      );
      expect(
        shouldBootWithoutStoredConfig(_accessFailure, webRuntime: false),
        isFalse,
        reason: '데스크톱의 접근 오류는 실패 화면이 막는다',
      );
      expect(
        shouldBootWithoutStoredConfig(_corruptWebValue, webRuntime: true),
        isFalse,
        reason: '웹에서도 손상된 값은 실패 화면이 막는다',
      );
      expect(
        shouldBootWithoutStoredConfig(
          StateError('unexpected read failure'),
          webRuntime: true,
        ),
        isFalse,
        reason: '형식을 모르는 오류는 접근 오류로 보지 않는다',
      );
    });

    testWidgets('웹에서 브라우저가 저장소를 막으면 실패 화면 없이 빈 값에 빌드 기본값만 채워 시작한다', (
      tester,
    ) async {
      final assembled = <DashboardConfigValues>[];
      final root = await buildBootRoot(
        load: () async => throw _blockedWebStorage,
        webRuntime: true,
        dashboard: (stored) {
          assembled.add(stored);
          return buildDashboardRoot(
            stored,
            app: const _SnapshotProbe(),
            configure: _fillCompileDefaults,
          );
        },
        replaceRoot: (_) => fail('실패 화면을 거치지 않으므로 루트를 바꿔 끼우지 않는다'),
      );

      expect(root, isA<ProviderScope>());
      expect(root.key, kDashboardRootKey);
      expect(assembled, <DashboardConfigValues>[DashboardConfigValues.empty]);

      await tester.pumpWidget(root);
      expect(
        find.text(
          'snapshot https://default.example.test default-client-token '
          'stored-at-boot=false',
        ),
        findsOneWidget,
        reason: '개인 웹 빌드는 예전처럼 구운 기본값으로 뜬다',
      );
    });

    testWidgets('웹에서 저장소가 막힌 채 시작한 세션의 다시 읽기는 계속 실패해 아무것도 저장하지 않는다', (
      tester,
    ) async {
      final saves = <DashboardConfigValues>[];
      final root = await buildBootRoot(
        load: () async => throw _blockedWebStorage,
        webRuntime: true,
        dashboard: (stored) => buildDashboardRoot(
          stored,
          app: const _SnapshotProbe(),
          configure: _fillCompileDefaults,
          extensions: (_) => [
            configLoadFnProvider.overrideWithValue(
              () async => throw _blockedWebStorage,
            ),
            configSaveFnProvider.overrideWithValue(
              (values) async => saves.add(values),
            ),
          ],
        ),
        replaceRoot: (_) => fail('실패 화면을 거치지 않으므로 루트를 바꿔 끼우지 않는다'),
      );
      await tester.pumpWidget(root);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_SnapshotProbe)),
      );
      final patch = container.read(configPatchFnProvider);

      // 커서 저장(백그라운드)과 사람이 누른 저장이 모두 다시 읽기에서 막힌다.
      await expectLater(
        patch(
          backgroundConfigPatch(
            (current) => current.copyWith(cursor: 42),
            storedAtBoot: container.read(storedConfigAtBootProvider),
          ),
        ),
        throwsA(
          isA<ConfigReadException>().having(
            (error) => error.kind,
            'kind',
            ConfigReadFailureKind.access,
          ),
        ),
      );
      await expectLater(
        patch((current) => current.copyWith(themeMode: 'dark')),
        throwsA(isA<ConfigReadException>()),
      );
      expect(saves, isEmpty, reason: '부팅 스냅샷의 빌드 기본값을 저장소에 쓰지 않는다');
    });

    test('웹에서도 손상된 값이나 형식을 모르는 오류는 실패 화면을 돌려주고 기본값을 채우지 않는다', () async {
      for (final Object failure in <Object>[
        _corruptWebValue,
        StateError('unexpected read failure'),
      ]) {
        var assembled = 0;
        var configured = 0;
        final root = await buildBootRoot(
          load: () async => throw failure,
          webRuntime: true,
          dashboard: (stored) {
            assembled += 1;
            return buildDashboardRoot(
              stored,
              app: const _DashboardProbe(),
              configure: (values) {
                configured += 1;
                return _fillCompileDefaults(values);
              },
            );
          },
          replaceRoot: (_) => fail('아직 읽지 못했다'),
        );

        expect(root, isA<ConfigReadFailureApp>(), reason: '$failure');
        expect((root as ConfigReadFailureApp).error, same(failure));
        expect(assembled, 0);
        expect(configured, 0);
      }
    });

    testWidgets('웹 부팅이 손상된 값에서 멈추면 저장소 항목을 지우는 안내를 보이고 자동으로 다시 읽지 않는다', (
      tester,
    ) async {
      var loads = 0;
      final root = await buildBootRoot(
        load: () async {
          loads += 1;
          throw _corruptWebValue;
        },
        webRuntime: true,
        dashboard: (_) => fail('손상된 값으로는 대시보드를 조립하지 않는다'),
        replaceRoot: (_) => fail('아직 읽지 못했다'),
      );
      expect(root, isA<ConfigReadFailureApp>());

      // 실패 화면은 자기 ProviderScope를 갖는다. i18n 가짜와 웹 런타임만
      // 바깥에서 준다.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._keyEchoI18n,
            isWasmRuntimeProvider.overrideWithValue(true),
          ],
          child: root,
        ),
      );
      expect(find.text('config.read_failed.corrupt_hint_web'), findsOneWidget);
      expect(find.text('config.read_failed.corrupt_hint'), findsNothing);
      expect(find.text('config.read_failed.boot_note'), findsOneWidget);
      expect(
        find.text('${_corruptWebValue.location}\n${_corruptWebValue.detail}'),
        findsOneWidget,
      );

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(loads, 1, reason: '부팅의 첫 읽기 뒤로는 다시 시도를 눌러야 읽는다');
    });

    test('실패 화면 루트와 대시보드 루트는 서로 제자리 갱신되지 않는다', () {
      final dashboardRoot = buildDashboardRoot(
        _stored,
        app: const _DashboardProbe(),
      );
      final failureRoot = ConfigReadFailureApp(
        error: _accessFailure,
        load: () async => _stored,
        onLoaded: (_) {},
      );

      expect(Widget.canUpdate(failureRoot, dashboardRoot), isFalse);
      expect(
        Widget.canUpdate(ProviderScope(child: failureRoot), dashboardRoot),
        isFalse,
        reason: '대시보드 루트의 키가 키 없는 ProviderScope와도 구분한다',
      );
    });

    test('해석할 수 없는 저장 주소도 대시보드 루트 조립을 막지 않는다', () {
      const stored = DashboardConfigValues(
        serverUrl: 'https://api.example.test:443x',
        clientToken: _fixtureToken,
      );
      expect(
        () => buildDashboardRoot(stored, app: const _DashboardProbe()),
        returnsNormally,
      );
    });

    testWidgets('해석할 수 없는 저장 주소는 스냅샷에서 비워 API 없이 주소만 남는 상태를 만들지 않는다', (
      tester,
    ) async {
      const stored = DashboardConfigValues(
        serverUrl: 'https://api.example.test:443x',
        clientToken: _fixtureToken,
        cursor: 41,
      );
      await tester.pumpWidget(
        buildDashboardRoot(stored, app: const _SnapshotProbe()),
      );

      expect(
        find.text('snapshot null $_fixtureToken stored-at-boot=true'),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_SnapshotProbe)),
      );
      expect(
        () => container.read(dashboardApiConfigProvider),
        throwsA(anything),
        reason: '주소가 없으면 API override도 없다',
      );
    });

    testWidgets('저장된 설정이 있었는지는 빌드 기본값이 아니라 저장소에서 읽은 값으로 정한다', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildDashboardRoot(
          DashboardConfigValues.empty,
          app: const _SnapshotProbe(),
          configure: _fillCompileDefaults,
        ),
      );
      expect(
        find.text(
          'snapshot https://default.example.test default-client-token '
          'stored-at-boot=false',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        buildDashboardRoot(
          _stored,
          app: const _SnapshotProbe(),
          configure: _fillCompileDefaults,
        ),
      );
      expect(
        find.text(
          'snapshot https://dash.example.test $_fixtureToken stored-at-boot=true',
        ),
        findsOneWidget,
      );
    });
  });

  group('ConfigReadFailureScreen', () {
    testWidgets('제목, 아무것도 바꾸지 않았다는 안내, 종류별 안내, 위치와 OS 메시지를 보여 준다', (
      tester,
    ) async {
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: () async => throw _accessFailure,
          onLoaded: _noHandover,
        ),
      );

      expect(find.text('config.read_failed.title'), findsOneWidget);
      expect(find.text('config.read_failed.body'), findsOneWidget);
      expect(find.text('config.read_failed.access_hint'), findsOneWidget);
      expect(find.text('config.read_failed.corrupt_hint'), findsNothing);
      expect(find.text('config.read_failed.boot_note'), findsOneWidget);
      expect(
        find.text('${_accessFailure.location}\n${_accessFailure.detail}'),
        findsOneWidget,
      );
      expect(find.text('action.retry'), findsOneWidget);
    });

    testWidgets('다시 시도로 읽으면 대시보드로 한 번만 넘기고 그 뒤로는 다시 읽지 않는다', (tester) async {
      var loads = 0;
      final handedOver = <DashboardConfigValues>[];
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: () async {
            loads += 1;
            return _stored;
          },
          onLoaded: handedOver.add,
        ),
      );

      await tester.tap(find.text('action.retry'));
      await tester.pump();

      expect(loads, 1);
      expect(handedOver, <DashboardConfigValues>[_stored]);
      expect(find.text('config.read_failed.title'), findsNothing);

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(loads, 1, reason: '넘긴 뒤에는 자동 재시도도 멈춘다');
      expect(handedOver, hasLength(1));
    });

    testWidgets('접근 오류는 버튼 없이 주기마다 다시 읽고 같은 예외가 반복돼도 멈추지 않는다', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: () async {
            loads += 1;
            throw _accessFailure;
          },
          onLoaded: _noHandover,
        ),
      );
      expect(loads, 0);

      for (var expected = 1; expected <= 3; expected++) {
        await tester.pump(kConfigReadRetryInterval);
        expect(loads, expected);
      }
      expect(find.text('config.read_failed.title'), findsOneWidget);
    });

    testWidgets('손상된 설정은 자동으로 다시 읽지 않고 다시 시도를 눌러야 읽는다', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        _screen(
          error: _corruptFailure,
          load: () async {
            loads += 1;
            throw _corruptFailure;
          },
          onLoaded: _noHandover,
        ),
      );
      expect(find.text('config.read_failed.corrupt_hint'), findsOneWidget);
      expect(find.text('config.read_failed.access_hint'), findsNothing);

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(loads, 0, reason: '옮기는 중인 파일을 첫 실행으로 받아들이지 않는다');

      await tester.tap(find.text('action.retry'));
      await tester.pump();
      expect(loads, 1);
    });

    testWidgets('브라우저에서는 손상 안내가 옮길 파일 대신 저장소 항목을 지우는 길을 알린다', (tester) async {
      await tester.pumpWidget(
        _screen(
          error: _corruptFailure,
          load: () async => throw _corruptFailure,
          onLoaded: _noHandover,
          web: true,
        ),
      );

      expect(find.text('config.read_failed.corrupt_hint_web'), findsOneWidget);
      expect(find.text('config.read_failed.corrupt_hint'), findsNothing);
    });

    testWidgets('접근 오류를 고치는 사이 자동 재시도가 빈 값을 읽으면 넘기지 않고 다시 시도를 기다린다', (
      tester,
    ) async {
      // 경로에 놓인 디렉터리나 링크를 치우면 파일이 잠시 없다. 그 순간을 첫
      // 실행으로 넘기면 빈 설정(개인 빌드는 구운 기본값)으로 대시보드가 뜬다.
      final load = _ScriptedLoad(<Object>[DashboardConfigValues.empty]);
      final handedOver = <DashboardConfigValues>[];
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: load.call,
          onLoaded: handedOver.add,
        ),
      );

      await tester.pump(kConfigReadRetryInterval);
      expect(load.calls, 1);
      expect(handedOver, isEmpty);
      expect(
        find.text('config.read_failed.nothing_stored_hint'),
        findsOneWidget,
      );
      expect(find.text('config.read_failed.access_hint'), findsNothing);
      expect(find.text(_accessFailure.location), findsOneWidget);

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(load.calls, 1, reason: '사람이 누를 때까지 다시 읽지 않는다');

      await tester.tap(find.text('action.retry'));
      await tester.pump();
      expect(load.calls, 2);
      expect(
        handedOver,
        <DashboardConfigValues>[DashboardConfigValues.empty],
        reason: '사람이 누른 다시 시도가 빈 값을 읽으면 처음부터 시작한다',
      );
    });

    testWidgets('빈 값에서 멈춘 뒤 파일을 되돌리고 다시 시도하면 저장된 값으로 넘긴다', (tester) async {
      final load = _ScriptedLoad(<Object>[DashboardConfigValues.empty, _stored]);
      final handedOver = <DashboardConfigValues>[];
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: load.call,
          onLoaded: handedOver.add,
        ),
      );
      await tester.pump(kConfigReadRetryInterval);
      expect(handedOver, isEmpty);

      await tester.tap(find.text('action.retry'));
      await tester.pump();

      expect(handedOver, <DashboardConfigValues>[_stored]);
    });

    testWidgets('빈 값에서 멈춘 뒤 다시 시도가 접근 오류를 만나면 자동 재시도가 다시 돈다', (tester) async {
      final load = _ScriptedLoad(<Object>[
        DashboardConfigValues.empty,
        _accessFailure,
      ]);
      await tester.pumpWidget(
        _screen(error: _accessFailure, load: load.call, onLoaded: _noHandover),
      );
      await tester.pump(kConfigReadRetryInterval);
      expect(
        find.text('config.read_failed.nothing_stored_hint'),
        findsOneWidget,
      );

      await tester.tap(find.text('action.retry'));
      await tester.pump();
      expect(load.calls, 2);
      expect(find.text('config.read_failed.access_hint'), findsOneWidget);

      await tester.pump(kConfigReadRetryInterval);
      expect(load.calls, 3);
    });

    testWidgets('읽은 뒤 접근 오류가 손상으로 바뀌면 자동 재시도를 멈춘다', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: () async {
            loads += 1;
            throw _corruptFailure;
          },
          onLoaded: _noHandover,
        ),
      );

      await tester.pump(kConfigReadRetryInterval);
      expect(loads, 1);
      expect(find.text('config.read_failed.corrupt_hint'), findsOneWidget);

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(loads, 1);
    });

    testWidgets('형식을 모르는 오류는 형식 이름만 보이고 원문을 드러내지 않으며 자동으로 다시 읽지 않는다', (
      tester,
    ) async {
      var loads = 0;
      const unexpected = FormatException(
        'Unexpected character',
        '{"client_token":"$_fixtureToken" x',
        34,
      );
      await tester.pumpWidget(
        _screen(
          error: unexpected,
          load: () async {
            loads += 1;
            throw unexpected;
          },
          onLoaded: _noHandover,
        ),
      );

      expect(find.text('FormatException'), findsOneWidget);
      expect(find.textContaining(_fixtureToken), findsNothing);
      expect(find.text('config.read_failed.access_hint'), findsNothing);
      expect(find.text('config.read_failed.corrupt_hint'), findsNothing);

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(loads, 0);
    });

    testWidgets('대시보드 조립이 실패하면 화면이 남아 형식 이름을 보이고 자동 재시도를 멈춘다', (tester) async {
      var loads = 0;
      var handovers = 0;
      await tester.pumpWidget(
        _screen(
          error: _accessFailure,
          load: () async {
            loads += 1;
            return _stored;
          },
          onLoaded: (_) {
            handovers += 1;
            throw StateError('assembly failed for $_fixtureToken');
          },
        ),
      );

      await tester.pump(kConfigReadRetryInterval);
      expect(loads, 1);
      expect(handovers, 1);
      expect(find.text('config.read_failed.title'), findsOneWidget);
      expect(find.text('StateError'), findsOneWidget);
      expect(find.textContaining(_fixtureToken), findsNothing);

      await tester.pump(kConfigReadRetryInterval * 3);
      expect(loads, 1, reason: '같은 값을 다시 조립해도 결과가 같다');
    });
  });

  testWidgets('다시 읽기에 성공하면 넘겨받은 대시보드 루트가 읽은 값으로 새로 붙는다', (tester) async {
    var loads = 0;
    final roots = <Widget>[];
    final configured = <DashboardConfigValues>[];
    final first = await buildBootRoot(
      load: () async {
        loads += 1;
        if (loads == 1) throw _accessFailure;
        return _stored;
      },
      dashboard: (stored) => buildDashboardRoot(
        stored,
        app: const _DashboardProbe(),
        configure: (values) {
          configured.add(values);
          return _fillCompileDefaults(values);
        },
      ),
      replaceRoot: roots.add,
    );
    expect(first, isA<ConfigReadFailureApp>());
    expect(configured, isEmpty);

    // 실패 화면은 자기 ProviderScope를 갖는다. i18n 가짜만 바깥에서 준다.
    await tester.pumpWidget(
      ProviderScope(overrides: _keyEchoI18n, child: first),
    );
    expect(find.text('config.read_failed.title'), findsOneWidget);

    await tester.tap(find.text('action.retry'));
    await tester.pump();
    expect(roots, hasLength(1));
    expect(configured, <DashboardConfigValues>[_stored]);

    // `runApp`과 같은 방식으로 루트를 비교해 교체한다.
    await tester.pumpWidget(roots.single);

    expect(tester.takeException(), isNull);
    expect(
      find.text('dashboard $_fixtureToken https://dash.example.test'),
      findsOneWidget,
    );
    expect(find.text('config.read_failed.title'), findsNothing);
    await tester.pump(kConfigReadRetryInterval * 2);
    expect(loads, 2);
  });

  testWidgets('실제 파일: 설정 경로의 디렉터리를 치우는 사이 자동 재시도는 빈 값으로 넘기지 않는다', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('config-read-failure-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/state/config.json');
    Directory(file.path).createSync(recursive: true);
    final roots = <Widget>[];
    final assembled = <DashboardConfigValues>[];
    final first = await tester.runAsync(
      () => buildBootRoot(
        load: () => loadDashboardConfigFile(file),
        dashboard: (stored) {
          assembled.add(stored);
          return buildDashboardRoot(
            stored,
            app: const _DashboardProbe(),
            configure: _fillCompileDefaults,
          );
        },
        replaceRoot: roots.add,
      ),
    );
    expect(first, isA<ConfigReadFailureApp>());
    await tester.pumpWidget(
      ProviderScope(overrides: _keyEchoI18n, child: first!),
    );
    expect(find.text('config.read_failed.access_hint'), findsOneWidget);

    // 복구 1단계: 경로의 디렉터리를 치운다. 원래 파일은 아직 없다.
    Directory(file.path).deleteSync();
    await tester.pump(kConfigReadRetryInterval);
    await _settleRealIo(tester);

    expect(roots, isEmpty);
    expect(assembled, isEmpty, reason: '빌드 기본값으로 대시보드를 조립하지 않는다');
    expect(
      find.text('config.read_failed.nothing_stored_hint'),
      findsOneWidget,
    );
    expect(file.existsSync(), isFalse, reason: '아무것도 쓰지 않았다');

    // 복구 2단계: 원래 파일을 되돌리고 다시 시도한다.
    file.writeAsStringSync(jsonEncode(_stored.toJson()));
    await tester.tap(find.text('action.retry'));
    await tester.pump();
    await _settleRealIo(tester);

    expect(assembled, <DashboardConfigValues>[_stored]);
    await tester.pumpWidget(roots.single);
    expect(
      find.text('dashboard $_fixtureToken https://dash.example.test'),
      findsOneWidget,
    );
  });
}

/// 위젯 테스트의 가짜 시계 밖에서 실제 파일 입출력이 끝나도록 잠깐씩 실제
/// 시간을 흘리고 프레임을 그린다.
Future<void> _settleRealIo(WidgetTester tester) async {
  const turns = 20;
  const step = Duration(milliseconds: 10);
  for (var i = 0; i < turns; i++) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
  }
}

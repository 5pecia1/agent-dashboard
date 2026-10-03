/// 운영과 같은 부팅 조립(`main.dart`의 [buildDashboardRoot])에 실제
/// [SolApp]을 올려 두 부팅을 닫는다.
///
/// - 해석할 수 없는 저장 주소(`https://host:443x`)로 부팅해도 예외 없이 설정
///   화면에 닿는다. 예전에는 스냅샷에 주소가 남고 API override만 빠져,
///   `app.dart`의 push 등록 게이트(`serverUrl != null`)가 부팅마다 등록을
///   불렀다. 등록은 `dashboardApiProvider`를 읽다 던졌고, `unawaited`라
///   처리되지 않은 비동기 오류가 됐다.
/// - 웹에서 브라우저가 저장소를 막으면 부팅은 예전처럼 저장된 설정 없이
///   시작하지만([buildBootRoot]), 그 뒤의 읽기는 그대로 실패를 알린다.
/// - API 설정은 부팅 스냅샷으로 만든 시작값에서 출발해, 설정 화면이 저장하면
///   재시작 없이 바뀐다. 첫 실행이든 아니든 `dashboardApiConfigProvider`는 항상
///   지금 쓰는 값을 따르는 override다(`first_run_sync_config_test.dart`가
///   저장부터 동기화까지 닫는다).
///
/// 저장소 시임과 push 등록만 테스트 값으로 바꾼다 — 실제 파일도, 서버도 없다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/main.dart' show buildDashboardRoot;
import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart'
    show dashboardApiConfigProvider, dashboardApiProvider;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/config_read_failure.dart'
    show buildBootRoot, kConfigReadRetryInterval;
import 'package:my_dashboard/src/ui/setup_page.dart';

const String _unparseableUrl = 'https://dash.example.test:443x';

const DashboardConfigValues _stored = DashboardConfigValues(
  serverUrl: _unparseableUrl,
  clientToken: 'stored-client-token',
  cursor: 41,
);

/// 웹 브리지(`config_store_web.dart`)가 브라우저가 막은 저장소에서 던지는
/// 값과 같은 모양.
const ConfigReadException _blockedWebStorage = ConfigReadException(
  ConfigReadFailureKind.access,
  location: 'localStorage[my-dashboard.config.v1]',
  detail: 'SecurityError: The operation is insecure.',
);

/// 부팅 조립이 만든 루트의 컨테이너. [app] 자리에는 화면 없이 컨테이너만
/// 얻을 수 있는 빈 위젯을 올린다.
Future<ProviderContainer> _bootContainer(
  WidgetTester tester,
  DashboardConfigValues stored, {
  DashboardConfigValues Function(DashboardConfigValues)? configure,
}) async {
  await tester.pumpWidget(
    buildDashboardRoot(stored, app: const SizedBox(), configure: configure),
  );
  return ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
}

void main() {
  group('부팅 조립이 API 설정을 채우는 방식', () {
    testWidgets('서버 주소가 없는 첫 실행은 읽으면 던지지만, 저장한 값이 곧바로 API 설정이 된다', (
      tester,
    ) async {
      final container = await _bootContainer(
        tester,
        DashboardConfigValues.empty,
      );

      expect(container.read(dashboardApiConfigControllerProvider), isNull);
      expect(
        () => container.read(dashboardApiConfigProvider),
        throwsA(isA<Object>()),
        reason: '서버 주소가 없는 동안 아무도 읽지 않는다는 계약',
      );

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://saved.example.dev', clientToken: 'saved');

      final config = container.read(dashboardApiConfigProvider);
      expect(config.baseUrl, Uri.parse('https://saved.example.dev'));
      expect(config.clientToken, 'saved');
      expect(container.read(dashboardApiProvider).config, config);
    });

    testWidgets('저장된 주소로 부팅하면 그 주소와 토큰이 시작 API 설정이고 나중에 바꿀 수 있다', (
      tester,
    ) async {
      final container = await _bootContainer(
        tester,
        const DashboardConfigValues(
          serverUrl: 'https://saved.example.dev',
          clientToken: 'saved-token',
        ),
      );

      final initial = container.read(dashboardApiConfigProvider);
      expect(initial.baseUrl, Uri.parse('https://saved.example.dev'));
      expect(initial.clientToken, 'saved-token');

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://moved.example.dev', clientToken: 'moved');

      expect(
        container.read(dashboardApiConfigProvider).baseUrl,
        Uri.parse('https://moved.example.dev'),
      );
    });

    testWidgets('빌드에 구운 기본값(configure)이 저장된 값이 없는 첫 실행의 시작 API 설정이 된다', (
      tester,
    ) async {
      final container = await _bootContainer(
        tester,
        DashboardConfigValues.empty,
        configure: (stored) => stored.copyWith(
          serverUrl: 'https://default.example.dev',
          clientToken: 'default-token',
        ),
      );

      final config = container.read(dashboardApiConfigProvider);
      expect(config.baseUrl, Uri.parse('https://default.example.dev'));
      expect(config.clientToken, 'default-token');
      expect(
        container.read(dashboardConfigValuesProvider).serverUrl,
        'https://default.example.dev',
        reason: '스냅샷에 주소가 있으면 API 설정도 있다',
      );
    });

    testWidgets('해석할 수 없는 저장 주소로 부팅하면 API 설정이 없고 고친 주소를 저장하면 생긴다', (
      tester,
    ) async {
      final container = await _bootContainer(tester, _stored);

      expect(container.read(dashboardConfigValuesProvider).serverUrl, isNull);
      expect(container.read(dashboardApiConfigControllerProvider), isNull);

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://dash.example.test', clientToken: 't');

      expect(
        container.read(dashboardApiConfigProvider).baseUrl,
        Uri.parse('https://dash.example.test'),
      );
    });
  });

  testWidgets('해석할 수 없는 저장 주소로 부팅하면 push 등록 없이 설정 화면이 뜨고 원래 주소를 보여 준다', (
    tester,
  ) async {
    final registrations = <String?>[];
    final saves = <DashboardConfigValues>[];
    await tester.pumpWidget(
      buildDashboardRoot(
        _stored,
        app: const SolApp(),
        extensions: (_) => [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          configLoadFnProvider.overrideWithValue(() async => _stored),
          configSaveFnProvider.overrideWithValue(
            (values) async => saves.add(values),
          ),
          pushRegistrarProvider.overrideWithValue(({String? label}) async {
            registrations.add(label);
            return const PushRegistrationResult(
              availability: PushAvailability.notApplicable,
            );
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      registrations,
      isEmpty,
      reason: 'API가 없으면 부팅이 push 등록을 부르지 않는다',
    );
    expect(find.byType(SetupPage), findsOneWidget);
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(
      fields.first.controller!.text,
      _unparseableUrl,
      reason: '설정 화면은 디스크의 원래 문자열을 보여 고칠 수 있게 한다',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SetupPage)),
    );
    expect(
      container.read(syncControllerProvider).phase,
      SyncPhase.unconfigured,
      reason: '주소를 쓸 수 없으면 동기화도 네트워크를 타지 않는다',
    );
    expect(saves, isEmpty, reason: '부팅은 저장된 주소를 지우지 않는다');
  });

  testWidgets('웹에서 저장소가 막힌 채 부팅하면 설정 화면이 뜨지만 폼 대신 읽기 실패 안내를 보이고 아무것도 저장하지 않는다', (
    tester,
  ) async {
    final registrations = <String?>[];
    final saves = <DashboardConfigValues>[];
    var laterReads = 0;
    final root = await buildBootRoot(
      load: () async => throw _blockedWebStorage,
      webRuntime: true,
      dashboard: (stored) => buildDashboardRoot(
        stored,
        app: const SolApp(),
        extensions: (_) => [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          isWasmRuntimeProvider.overrideWithValue(true),
          configLoadFnProvider.overrideWithValue(() async {
            laterReads += 1;
            throw _blockedWebStorage;
          }),
          configSaveFnProvider.overrideWithValue(
            (values) async => saves.add(values),
          ),
          pushRegistrarProvider.overrideWithValue(({String? label}) async {
            registrations.add(label);
            return const PushRegistrationResult(
              availability: PushAvailability.notApplicable,
            );
          }),
        ],
      ),
      replaceRoot: (_) => fail('실패 화면을 거치지 않으므로 루트를 바꿔 끼우지 않는다'),
    );
    await tester.pumpWidget(root);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byType(SetupPage),
      findsOneWidget,
      reason: '공개 웹 빌드는 서버 주소가 없어 설정 화면에서 시작한다',
    );
    expect(find.text('config.read_failed.title'), findsOneWidget);
    expect(find.text('config.read_failed.access_hint'), findsOneWidget);
    expect(
      find.byType(TextField),
      findsNothing,
      reason: '시작한 뒤의 읽기는 빈 값으로 접지 않는다',
    );
    expect(find.text('action.save'), findsNothing);

    final readsBeforeRetry = laterReads;
    expect(readsBeforeRetry, greaterThan(0));
    await tester.pump(kConfigReadRetryInterval);
    await tester.pumpAndSettle();
    expect(laterReads, readsBeforeRetry + 1, reason: '접근 오류라 주기마다 다시 읽는다');
    expect(find.byType(TextField), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SetupPage)),
    );
    expect(
      container.read(syncControllerProvider).phase,
      SyncPhase.unconfigured,
    );
    expect(registrations, isEmpty);
    expect(saves, isEmpty, reason: '막힌 저장소 위에 아무것도 쓰지 않는다');
  });
}

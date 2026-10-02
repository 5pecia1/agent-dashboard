/// 설정 화면이 저장된 설정을 읽지 못할 때: 빈 폼 대신 읽기 실패 안내를
/// 보이고, 읽기에 성공할 때까지 아무것도 저장하지 않는다.
///
/// 예전에는 읽기 실패가 빈 폼으로 접혀 "저장"이 저장된 서버 주소와 토큰을
/// 지웠다. 시임 override만으로 닫는다 — 실제 파일도, 서버도 없다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/notification_probe_provider.dart'
    show notificationReprobeProvider;
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/ui_lang_provider.dart';
import 'package:my_dashboard/src/ui/config_read_failure.dart'
    show kConfigReadRetryInterval;
import 'package:my_dashboard/src/ui/setup_page.dart';
// `Override`는 `flutter_riverpod` barrel에 없다 — 정본 위치에서 이름만
// 가져온다(`config_provider.dart`가 같은 이유로 같은 일을 한다).
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

const ConfigReadException _accessFailure = ConfigReadException(
  ConfigReadFailureKind.access,
  location: '/fixture/config.json',
  detail: 'Cannot open file: Permission denied (errno 13)',
);

const ConfigReadException _corruptFailure = ConfigReadException(
  ConfigReadFailureKind.corrupt,
  location: '/fixture/config.json',
  detail: 'Unexpected end of input (offset 17)',
);

const DashboardConfigValues _stored = DashboardConfigValues(
  serverUrl: 'https://dash.example.test',
  clientToken: 'stored-client-token',
  cursor: 41,
  themeMode: 'system',
  extra: <String, Object?>{
    'teamclaude': <String, Object?>{
      'url': 'https://tc.example.test',
      'api_key': 'tc-key',
    },
    'grok': <String, Object?>{'enabled': true},
  },
);

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

/// 저장 성공 분기가 부르는 동기화 컨트롤러를 아무 일도 하지 않게 둔다
/// (`setup_resident_toggle_test.dart`와 같은 관용).
class _NoopSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

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

Widget _setupPage({
  required _ScriptedLoad load,
  required List<DashboardConfigValues> saves,
  List<Override> extra = const <Override>[],
}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue((key, locale) => key),
    i18nTranslateArgsOverride.overrideWithValue(
      (key, locale, argKeys, argVals) => key,
    ),
    isWasmRuntimeProvider.overrideWithValue(false),
    syncControllerProvider.overrideWith(_NoopSyncController.new),
    pushRegistrarProvider.overrideWithValue(
      ({String? label}) async => const PushRegistrationResult(
        availability: PushAvailability.notApplicable,
      ),
    ),
    configLoadFnProvider.overrideWithValue(load.call),
    configSaveFnProvider.overrideWithValue((values) async => saves.add(values)),
    ...extra,
  ],
  child: const MaterialApp(home: SetupPage()),
);

void main() {
  group('읽기 실패 안내', () {
    testWidgets('설정을 읽지 못하면 입력칸과 저장 버튼 없이 안내만 보이고 아무것도 저장하지 않는다', (
      tester,
    ) async {
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final load = _ScriptedLoad(<Object>[_corruptFailure]);
      await tester.pumpWidget(_setupPage(load: load, saves: saves));
      await tester.pumpAndSettle();

      expect(find.text('config.read_failed.title'), findsOneWidget);
      expect(find.text('config.read_failed.corrupt_hint'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('action.save'), findsNothing);
      expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
      expect(saves, isEmpty);
    });

    testWidgets('접근 오류가 풀리면 주기 뒤 폼이 저장된 값으로 열리고 저장은 토큰과 연동 설정을 그대로 둔다', (
      tester,
    ) async {
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final load = _ScriptedLoad(<Object>[_accessFailure, _stored]);
      await tester.pumpWidget(_setupPage(load: load, saves: saves));
      await tester.pumpAndSettle();
      expect(find.text('config.read_failed.title'), findsOneWidget);

      await tester.pump(kConfigReadRetryInterval);
      await tester.pumpAndSettle();

      expect(find.text('config.read_failed.title'), findsNothing);
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields[0].controller!.text, _stored.serverUrl);
      expect(fields[1].controller!.text, _stored.clientToken);

      await tester.enterText(
        find.byType(TextField).first,
        'https://new.example.test',
      );
      await tester.tap(find.text('action.save'));
      await tester.pumpAndSettle();

      expect(saves, hasLength(1));
      final saved = saves.single;
      expect(saved.serverUrl, 'https://new.example.test');
      expect(saved.clientToken, _stored.clientToken);
      expect(saved.cursor, _stored.cursor);
      expect(saved.extra, _stored.extra);
    });

    testWidgets('접근 오류를 고치는 사이 자동 재시도가 빈 값을 읽으면 폼을 열지 않고 다시 시도를 기다린다', (
      tester,
    ) async {
      // 경로에 놓인 디렉터리를 치우는 순간처럼 파일이 잠시 없다. 빌드 기본값이
      // 있으면 그 값으로 폼이 열리고 "저장"이 켜지던 결함의 회귀 가드다.
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final load = _ScriptedLoad(<Object>[
        _accessFailure,
        DashboardConfigValues.empty,
      ]);
      await tester.pumpWidget(
        _setupPage(
          load: load,
          saves: saves,
          extra: [
            configDefaultsFnProvider.overrideWithValue(
              (stored) => stored.copyWith(
                serverUrl: stored.serverUrl ?? 'https://default.example.test',
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('config.read_failed.access_hint'), findsOneWidget);

      await tester.pump(kConfigReadRetryInterval);
      await tester.pumpAndSettle();

      expect(load.calls, 2);
      expect(
        find.text('config.read_failed.nothing_stored_hint'),
        findsOneWidget,
      );
      expect(find.text(_accessFailure.location), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('action.save'), findsNothing);

      await tester.pump(kConfigReadRetryInterval * 3);
      await tester.pumpAndSettle();
      expect(load.calls, 2, reason: '사람이 누를 때까지 다시 읽지 않는다');

      await tester.tap(find.text('action.retry'));
      await tester.pumpAndSettle();

      expect(load.calls, 3);
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(
        fields[0].controller!.text,
        'https://default.example.test',
        reason: '사람이 누른 다시 시도는 처음부터 시작한다',
      );
      expect(saves, isEmpty);
    });

    testWidgets('빌드에 구운 기본값이 있어도 읽기에 실패하면 입력칸을 채우지 않는다', (tester) async {
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final load = _ScriptedLoad(<Object>[_corruptFailure]);
      await tester.pumpWidget(
        _setupPage(
          load: load,
          saves: saves,
          extra: [
            configDefaultsFnProvider.overrideWithValue(
              (stored) => stored.copyWith(
                serverUrl: stored.serverUrl ?? 'https://default.example.test',
                clientToken: stored.clientToken ?? 'default-client-token',
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('config.read_failed.title'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('https://default.example.test'), findsNothing);
      expect(saves, isEmpty);
    });
  });

  group('폼을 연 뒤 읽기가 실패하면 토글은 저장하지 않는다', () {
    testWidgets('테마는 저장하지 않고 선택을 되돌린 뒤 오류를 보인다', (tester) async {
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final load = _ScriptedLoad(<Object>[_stored, _accessFailure]);
      await tester.pumpWidget(_setupPage(load: load, saves: saves));
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.theme_mode_dark'));
      await tester.pumpAndSettle();

      expect(saves, isEmpty);
      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.system});
      expect(find.text('setup.theme_mode_error'), findsOneWidget);
    });

    testWidgets('상주 토글은 저장하지도 네이티브에 밀지도 않고 되돌린 뒤 오류를 보인다', (tester) async {
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final applied = <bool>[];
      final load = _ScriptedLoad(<Object>[_stored, _accessFailure]);
      await tester.pumpWidget(
        _setupPage(
          load: load,
          saves: saves,
          extra: [
            residentToggleSupportedProvider.overrideWithValue(true),
            residentModeApplyProvider.overrideWithValue((enabled) async {
              applied.add(enabled);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.resident_label'));
      await tester.pumpAndSettle();

      expect(saves, isEmpty);
      expect(applied, isEmpty);
      final toggle = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('setup.resident_label'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(toggle.value, isTrue, reason: '저장된 기본값(켜짐)으로 되돌린다');
      expect(find.text('setup.resident_error'), findsOneWidget);
    });

    testWidgets('서버 미설정 상태의 언어 선택은 저장하지 않고 오류를 보이며 선택과 화면 언어가 어긋나지 않는다', (
      tester,
    ) async {
      // 이 분기는 로컬이 정본이라 테마와 달리 선택을 되돌리지 않는다
      // (`setup_ui_lang_test.dart`) — 대신 화면 언어도 같은 값을 따른다.
      // 예전에는 선택만 새 언어이고 화면은 옛 언어로 남았다.
      _useTallViewport(tester);
      final saves = <DashboardConfigValues>[];
      final load = _ScriptedLoad(<Object>[
        DashboardConfigValues.empty,
        _accessFailure,
      ]);
      await tester.pumpWidget(
        _setupPage(
          load: load,
          saves: saves,
          extra: [
            dashboardConfigValuesProvider.overrideWithValue(
              DashboardConfigValues.empty,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(saves, isEmpty, reason: '읽지 못한 설정 위에 쓰지 않는다');
      expect(find.text('setup.ui_lang_error'), findsOneWidget);
      final element = tester.element(find.byType(SetupPage));
      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmented.selected, {'en'});
      expect(
        ProviderScope.containerOf(element).read(uiLangControllerProvider),
        'en',
        reason: '선택된 언어와 화면 언어가 같다 — 저장만 하지 못했다',
      );
    });
  });

  group('API가 설정되지 않은 세션의 서버 동작 버튼', () {
    // 서버 주소 없이(또는 해석할 수 없는 주소로) 부팅하면
    // `dashboardApiConfigProvider`가 override되지 않아 읽는 순간 던진다.
    // 그 오류가 `DashboardApiException`이 아니어도 화면 전체가 공유하는
    // 잠금(`_busy`)이 풀려야 한다.
    for (final (action, error) in <(String, String)>[
      ('setup.test_notification_action', 'setup.test_notification_error'),
      ('setup.mute_30_action', 'setup.mute_error'),
    ]) {
      testWidgets('$action을 눌러 실패해도 오류를 보이고 저장 버튼을 다시 연다', (tester) async {
        _useTallViewport(tester);
        final saves = <DashboardConfigValues>[];
        final load = _ScriptedLoad(<Object>[DashboardConfigValues.empty]);
        await tester.pumpWidget(
          _setupPage(
            load: load,
            saves: saves,
            extra: [
              notificationReprobeProvider.overrideWithValue(() async {}),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text(action));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(error), findsOneWidget);
        final save = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text('action.save'),
            matching: find.byType(FilledButton),
          ),
        );
        expect(save.onPressed, isNotNull, reason: '잠금이 풀려야 한다');
      });
    }
  });
}

/// 설정 화면의 테마 모드 선택(system/light/dark) 계약.
///
/// 상주 토글과 같은 태도: 저장 버튼을 기다리지 않고 곧바로 영속화
/// (`configSaveFnProvider`)하고 [themeModeControllerProvider]에 밀어
/// 넣는다 — `setup_resident_toggle_test.dart`와 같은 시임 override 관용.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

String _translate(String key, LocaleDto locale) => key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key;

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

class _MemoryConfigStore {
  _MemoryConfigStore([this.values = DashboardConfigValues.empty]);

  DashboardConfigValues values;
  final List<DashboardConfigValues> saves = <DashboardConfigValues>[];

  Future<DashboardConfigValues> load() async => values;

  Future<void> save(DashboardConfigValues next) async {
    values = next;
    saves.add(next);
  }
}

class _NoopSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub();
}

Widget _setupPage({required List<Override> extra}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue(_translate),
    i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
    isWasmRuntimeProvider.overrideWithValue(false),
    residentToggleSupportedProvider.overrideWithValue(false),
    syncControllerProvider.overrideWith(_NoopSyncController.new),
    ...extra,
  ],
  child: const MaterialApp(home: SetupPage()),
);

void main() {
  group('테마 모드 선택', () {
    testWidgets('기본값(저장 없음)은 시스템이 선택된 채로 열린다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.section.appearance'), findsOneWidget);
      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.system});
    });

    testWidgets('저장된 값이 있으면 그 값으로 열린다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(const DashboardConfigValues(themeMode: 'dark'));
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.dark});
    });

    testWidgets('다른 세그먼트를 고르면 즉시 영속화된다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(
        const DashboardConfigValues(serverUrl: 'https://a.test', cursor: 7),
      );
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.theme_mode_dark'));
      await tester.pumpAndSettle();

      expect(store.saves, hasLength(1));
      expect(store.saves.single.themeMode, 'dark');
      // 다른 값은 그대로 살아 있어야 한다 — 선택 하나가 서버 주소를 지우면 안 된다.
      expect(store.saves.single.serverUrl, 'https://a.test');
      expect(store.saves.single.cursor, 7);

      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.dark});
    });

    testWidgets('영속화가 실패하면 선택을 되돌리고 사유를 알린다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(
              () async => DashboardConfigValues.empty,
            ),
            configSaveFnProvider.overrideWithValue(
              (_) async => throw const FileSystemExceptionStub(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.theme_mode_dark'));
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.system}, reason: '화면만 바뀐 채 동작은 그대로인 상태로 두지 않는다');
      expect(find.text('setup.theme_mode_error'), findsOneWidget);
    });
  });
}

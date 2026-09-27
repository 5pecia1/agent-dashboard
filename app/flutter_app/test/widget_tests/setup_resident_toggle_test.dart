/// TASK D-app: 설정 화면이 새로 지는 계약 둘.
///
/// 1. **상주 토글**(A안 설계 ④) — 기본 켜짐, 바꾸면 곧바로 영속화되고
///    (`configSaveFnProvider`) 네이티브에 밀린다(`residentModeApplyProvider`).
///    저장 버튼을 기다리지 않는다: "창을 닫는 순간"의 동작이라 나중에
///    반영하면 이미 늦다.
/// 2. **저장이 push 재등록을 트리거한다**(배선 (4)) — 서버 주소·토큰이
///    바뀌면 이전 서버에 등록해 둔 토큰은 의미가 없다.
///
/// MethodChannel도, 실제 파일 저장도, 서버도 없이 시임 override만으로
/// 닫는다 — `setup_web_push_test.dart`와 같은 관용이다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';
// `Override`는 `flutter_riverpod` barrel에 없다 — 정본 위치에서 이름만
// 가져온다(`config_provider.dart`가 같은 이유로 같은 일을 한다).
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

/// 키의 마지막 dotted 세그먼트가 아니라 키 자체를 돌려주는 결정적 번역기
/// (`setup_web_push_test.dart`와 같은 관용).
String _translate(String key, LocaleDto locale) => key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key;

/// 설정 화면은 지연 빌드되는 스크롤 목록이라, 기본 800x600 뷰포트에서는
/// 화면 아래쪽 절이 아예 만들어지지 않는다.
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

/// 메모리에만 남는 가짜 설정 저장소 — 실제 `~/.local/state/`를 건드리지
/// 않는다(`config_provider_test.dart`가 같은 이유로 기본 브리지를 절대
/// 실행하지 않는 것과 같다).
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

/// U-fix: 저장 성공 분기가 `syncControllerProvider.notifier.configureAndStart()`
/// 를 부른다(`setup_page.dart` 참고). 이 파일은 `SetupPage`만 단독으로
/// 렌더링해서 `dashboardConfigValuesProvider`를 override하지 않으므로, 진짜
/// `SyncController.build()`가 그 provider를 읽으면 던진다 — 이 화면 테스트가
/// 검증하려는 것과 무관한 실패다. 그래서 아무 일도 하지 않는 가짜로 갈아
/// 끼운다(`app_wiring_test.dart`의 `_BootProbeController` 등과 같은 관용).
class _NoopSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

Widget _setupPage({
  required List<Override> extra,
  VoidCallback? onSaved,
}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue(_translate),
    i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
    isWasmRuntimeProvider.overrideWithValue(false),
    syncControllerProvider.overrideWith(_NoopSyncController.new),
    ...extra,
  ],
  child: MaterialApp(home: SetupPage(onSaved: onSaved)),
);

void main() {
  group('상주 토글 (A안 설계 ④)', () {
    testWidgets('상주 토글이 없는 호스트에는 그려지지 않는다 (웹/linux/windows)', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            residentToggleSupportedProvider.overrideWithValue(false),
            residentModeApplyProvider.overrideWithValue(
              (_) async => throw StateError('지원하지 않는 호스트에서 밀면 안 된다.'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.resident_label'), findsNothing);
      expect(find.text('setup.resident_note'), findsNothing);
    });

    testWidgets('macOS에서는 토글이 보이고 기본값이 켜짐이다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            residentToggleSupportedProvider.overrideWithValue(true),
            residentModeApplyProvider.overrideWithValue((_) async {}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.resident_label'), findsOneWidget);
      // 기존 상주 안내 문구가 토글 설명으로 흡수됐다 — 사라지지 않았다.
      expect(find.text('setup.resident_note'), findsOneWidget);

      final toggle = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('setup.resident_label'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(toggle.value, isTrue, reason: 'kResidentDefault = 켜짐');
    });

    testWidgets('토글을 끄면 즉시 영속화되고 네이티브에 밀린다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(
        const DashboardConfigValues(serverUrl: 'https://a.test', cursor: 7),
      );
      final applied = <bool>[];
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            residentToggleSupportedProvider.overrideWithValue(true),
            residentModeApplyProvider.overrideWithValue((enabled) async {
              applied.add(enabled);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(applied, isEmpty, reason: '화면을 띄운 것만으로 밀지 않는다');

      await tester.tap(find.text('setup.resident_label'));
      await tester.pumpAndSettle();

      expect(applied, <bool>[false]);
      expect(store.saves, hasLength(1));
      expect(store.saves.single.resident, isFalse);
      // 다른 값은 그대로 살아 있어야 한다 — 토글 하나가 서버 주소를 지우면 안 된다.
      expect(store.saves.single.serverUrl, 'https://a.test');
      expect(store.saves.single.cursor, 7);
    });

    testWidgets('저장된 값이 꺼짐이면 그 상태로 열리고, 다시 켜면 영속화된다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(
        const DashboardConfigValues(resident: false),
      );
      final applied = <bool>[];
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            residentToggleSupportedProvider.overrideWithValue(true),
            residentModeApplyProvider.overrideWithValue((enabled) async {
              applied.add(enabled);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final before = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('setup.resident_label'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(before.value, isFalse);

      await tester.tap(find.text('setup.resident_label'));
      await tester.pumpAndSettle();

      expect(applied, <bool>[true]);
      expect(store.saves.single.resident, isTrue);
    });

    testWidgets('영속화가 실패하면 토글을 되돌리고 사유를 알린다', (tester) async {
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
            residentToggleSupportedProvider.overrideWithValue(true),
            residentModeApplyProvider.overrideWithValue(
              (_) async => throw StateError('저장이 실패했으면 밀지 않는다.'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.resident_label'));
      await tester.pumpAndSettle();

      final after = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('setup.resident_label'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(after.value, isTrue, reason: '화면만 꺼진 채 동작은 그대로인 상태로 두지 않는다');
      expect(find.text('setup.resident_error'), findsOneWidget);
    });
  });

  group('저장이 push 재등록을 트리거한다 (배선 (4))', () {
    testWidgets('저장에 성공하면 pushRegistrar를 정확히 한 번 부른다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      var registerCalls = 0;
      String? seenLabel;
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            residentToggleSupportedProvider.overrideWithValue(false),
            pushRegistrarProvider.overrideWithValue(({String? label}) async {
              registerCalls += 1;
              seenLabel = label;
              return const PushRegistrationResult(
                availability: PushAvailability.notApplicable,
              );
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(registerCalls, 0, reason: '화면을 띄운 것만으로 등록하지 않는다');

      await tester.enterText(
        find.byType(TextField).first,
        'https://api.example.workers.dev',
      );
      await tester.enterText(find.byType(TextField).at(2), 'Sol의 맥');
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();

      expect(registerCalls, 1);
      expect(seenLabel, 'Sol의 맥', reason: '기기 이름을 그대로 넘긴다');
      expect(store.saves.single.serverUrl, 'https://api.example.workers.dev');
    });

    testWidgets('저장이 실패하면 재등록하지 않는다', (tester) async {
      _useTallViewport(tester);
      var registerCalls = 0;
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(
              () async => DashboardConfigValues.empty,
            ),
            configSaveFnProvider.overrideWithValue(
              (_) async => throw const FileSystemExceptionStub(),
            ),
            residentToggleSupportedProvider.overrideWithValue(false),
            pushRegistrarProvider.overrideWithValue(({String? label}) async {
              registerCalls += 1;
              return const PushRegistrationResult(
                availability: PushAvailability.notApplicable,
              );
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'https://a.test');
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();

      expect(registerCalls, 0);
      expect(find.text('setup.save_error'), findsOneWidget);
    });

    testWidgets('상주 토글 값도 저장 본문에 함께 실린다 (저장이 토글을 되돌리지 않는다)', (
      tester,
    ) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            residentToggleSupportedProvider.overrideWithValue(true),
            residentModeApplyProvider.overrideWithValue((_) async {}),
            pushRegistrarProvider.overrideWithValue(
              ({String? label}) async => const PushRegistrationResult(
                availability: PushAvailability.notApplicable,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.resident_label'));
      await tester.pumpAndSettle();
      expect(store.values.resident, isFalse);

      await tester.enterText(find.byType(TextField).first, 'https://a.test');
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();

      expect(store.values.resident, isFalse);
      expect(store.values.serverUrl, 'https://a.test');
    });
  });
}

/// 저장 실패를 흉내 내는 예외. `dart:io`의 `FileSystemException`을 쓰지
/// 않는 이유는 이 테스트가 파일 시스템과 무관해야 하기 때문이다 — 화면은
/// 예외의 종류가 아니라 "던졌다"만 본다.
class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub();
}

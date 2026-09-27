/// [AppVimNavigationScope]의 앱-전역 Vim 방향 이동(h/j/k/l)과 `app.dart`의
/// Ctrl+W 창 숨김 배선을 검증한다. 방향 이동은 예전에 `session_card.dart`가
/// 지역 [CallbackShortcuts]로 갖고 있던 것을 앱 루트로 올린 것이라, 여기서는
/// 카드가 아닌 일반 포커스 가능 컨트롤에서도 같은 동작이 성립하는지와
/// `EditableText`에 포커스가 있을 때는 이 키들이 내비게이션이 아니라 일반
/// 문자 입력으로 남는지를 본다. `app_wiring_test.dart`와 파일을 나눈 이유는
/// 같다(관심사 분리 + `quality_check.py budget` — 그 파일은 이미 950줄을
/// 넘어 이 그룹을 더하면 1000줄 예산을 넘는다).
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart'
    show kResidentChannelName, kResidentHideWindowMethod;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';

/// 방향 이동 테스트용 최소 앱 — 프로덕션 `SolApp`과 같은 위치
/// (`MaterialApp.builder`)에 스코프를 얹어 `DirectionalFocusIntent`가
/// `WidgetsApp`의 기본 `DirectionalFocusAction`을 타게 한다.
Widget _wrapScope(Widget home) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) =>
      AppVimNavigationScope(child: child ?? const SizedBox.shrink()),
  home: Scaffold(body: home),
);

/// 지금 primaryFocus가 들어 있는 [ElevatedButton]의 `ValueKey` 값.
/// 카드 테스트(`session_card_delete_seen_test.dart`의 `_focusedSessionKey`)와
/// 같은 실제-포커스 조상 검사다 — 단축키 맵을 들여다보지 않는다.
String? _focusedButtonKey() {
  final key = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<ElevatedButton>()
      ?.key;
  return key is ValueKey<String> ? key.value : null;
}

bool _focusIsInsideEditableText() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

class _EmptySyncController extends SyncController {
  @override
  SyncControllerState build() =>
      const SyncControllerState(sync: SyncState(cursor: 0));
}

void main() {
  group('앱-전역 Vim 방향 이동 (AppVimNavigationScope)', () {
    testWidgets('l은 포커스를 오른쪽 컨트롤로 옮기고 h는 다시 왼쪽으로 되돌린다', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapScope(
          Row(
            children: [
              ElevatedButton(
                key: const ValueKey<String>('left'),
                onPressed: () {},
                child: const Text('left'),
              ),
              ElevatedButton(
                key: const ValueKey<String>('right'),
                onPressed: () {},
                child: const Text('right'),
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedButtonKey(), 'left');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(_focusedButtonKey(), 'right');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(_focusedButtonKey(), 'left');
    });

    testWidgets('j는 포커스를 아래 컨트롤로 옮기고 k는 다시 위로 되돌린다', (tester) async {
      await tester.pumpWidget(
        _wrapScope(
          Column(
            children: [
              ElevatedButton(
                key: const ValueKey<String>('top'),
                onPressed: () {},
                child: const Text('top'),
              ),
              ElevatedButton(
                key: const ValueKey<String>('bottom'),
                onPressed: () {},
                child: const Text('bottom'),
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedButtonKey(), 'top');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(_focusedButtonKey(), 'bottom');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(_focusedButtonKey(), 'top');
    });

    testWidgets(
      'TextField에 포커스가 있으면 h/j/k/l은 일반 문자 입력으로 남고 포커스가 빠지지 않는다',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _wrapScope(
            Column(
              children: [
                TextField(controller: controller),
                ElevatedButton(
                  onPressed: () {},
                  child: const Text('below'),
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(_focusIsInsideEditableText(), isTrue);

        for (final key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.keyH,
          LogicalKeyboardKey.keyJ,
          LogicalKeyboardKey.keyK,
          LogicalKeyboardKey.keyL,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.pump();

        expect(
          _focusIsInsideEditableText(),
          isTrue,
          reason: '편집 중에는 Vim 키가 포커스를 다른 컨트롤로 옮기면 안 된다',
        );

        await tester.enterText(find.byType(TextField), 'hjkl');
        expect(controller.text, 'hjkl');
        expect(_focusIsInsideEditableText(), isTrue);
      },
    );
  });

  group('Ctrl+W 창 숨김 / Vim 스코프 배선 (SolApp)', () {
    testWidgets('앱 트리에 AppVimNavigationScope가 얹혀 있다', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue((key, locale) => key),
            i18nTranslateArgsOverride.overrideWithValue(
              (key, locale, argKeys, argVals) => key,
            ),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) =>
                  false,
            ),
            dashboardConfigValuesProvider.overrideWithValue(
              DashboardConfigValues.empty,
            ),
            configLoadFnProvider.overrideWithValue(
              () async => DashboardConfigValues.empty,
            ),
            syncControllerProvider.overrideWith(_EmptySyncController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SetupPage), findsOneWidget);

      expect(find.byType(AppVimNavigationScope), findsOneWidget);
    });

    testWidgets('Cmd+W를 누르면 app/resident 채널로 hideWindow가 정확히 1회 호출된다', (
      tester,
    ) async {
      const channel = MethodChannel(kResidentChannelName);
      final binding = TestDefaultBinaryMessengerBinding.instance;
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });

      // `hasResidentToggleHost`는 `defaultTargetPlatform`을 보는데 그 판정이
      // 두 시점에 걸린다 — 바인딩 설치(`SolApp.build`가 맵을 짤 때)와 호출
      // (`hideResidentWindow` 내부 가드). 그래서 override는 pump 이전부터 걸어
      // 둬야 바인딩 자체가 설치된다. 테스트 끝 invariant 검사가 foundation
      // 디버그 변수의 원복을 요구하므로 `addTearDown`이 아니라 본문 전체를
      // try/finally로 감싸 여기서 즉시 되돌린다. 부팅의 `applyResidentMode`
      // 호출(`setResident`)도 같은 채널로 기록되므로 메서드로 걸러 본다.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              i18nTranslateOverride.overrideWithValue((key, locale) => key),
              i18nTranslateArgsOverride.overrideWithValue(
                (key, locale, argKeys, argVals) => key,
              ),
              stateLabelKeyFnProvider.overrideWithValue(
                (s) => 'label.${s.name}',
              ),
              isSessionStaleFnProvider.overrideWithValue(
                ({
                  required int now,
                  required int updatedAt,
                  required int staleMs,
                }) => false,
              ),
              dashboardConfigValuesProvider.overrideWithValue(
                DashboardConfigValues.empty,
              ),
              configLoadFnProvider.overrideWithValue(
                () async => DashboardConfigValues.empty,
              ),
              syncControllerProvider.overrideWith(_EmptySyncController.new),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      final hideCalls = calls
          .where((call) => call.method == kResidentHideWindowMethod)
          .toList();
      expect(hideCalls, hasLength(1));
      expect(hideCalls.single.arguments, isNull);
    });

    testWidgets('macOS가 아니면 Cmd+W 바인딩이 설치되지 않아 채널 호출이 한 번도 없다', (
      tester,
    ) async {
      const channel = MethodChannel(kResidentChannelName);
      final binding = TestDefaultBinaryMessengerBinding.instance;
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });

      // 비macOS(웹 포함)에서는 바인딩이 아예 설치되지 않아야 한다 —
      // no-op `hideResidentWindow`가 브라우저 고유의 Ctrl+W(탭 닫기)만
      // 집어삼키는 결함 방지. 위젯 테스트가 브라우저 기본 동작까지 증명할
      // 수는 없으므로 "채널 호출 0회"를 프록시로 쓴다.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              i18nTranslateOverride.overrideWithValue((key, locale) => key),
              i18nTranslateArgsOverride.overrideWithValue(
                (key, locale, argKeys, argVals) => key,
              ),
              stateLabelKeyFnProvider.overrideWithValue(
                (s) => 'label.${s.name}',
              ),
              isSessionStaleFnProvider.overrideWithValue(
                ({
                  required int now,
                  required int updatedAt,
                  required int staleMs,
                }) => false,
              ),
              dashboardConfigValuesProvider.overrideWithValue(
                DashboardConfigValues.empty,
              ),
              configLoadFnProvider.overrideWithValue(
                () async => DashboardConfigValues.empty,
              ),
              syncControllerProvider.overrideWith(_EmptySyncController.new),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      expect(
        calls,
        isEmpty,
        reason: '바인딩이 없어야 채널에 hideWindow가 가지 않는다',
      );
    });
  });
}

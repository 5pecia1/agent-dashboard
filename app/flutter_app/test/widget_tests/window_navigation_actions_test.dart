import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';
import 'package:my_dashboard/src/ui/window_navigation_actions.dart';

const _session = SessionViewDto(
  key: 'codex:window-navigation',
  state: 'waiting_input',
  host: 'work-mac',
  project: '/work/demo',
  lastTransitionId: 10,
);
const _window = WindowCandidate(
  token: 'test-window',
  bundleId: 'test.editor',
  appName: 'Test Editor',
  title: 'demo',
);

void main() {
  const residentChannel = MethodChannel(kResidentChannelName);

  Future<
    ({
      ValueNotifier<bool> callerMounted,
      Completer<void> showWindow,
      List<int> seen,
    })
  >
  pumpFailedNavigation(WidgetTester tester) async {
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(residentChannel, null);
    });
    final callerMounted = ValueNotifier(true);
    final showWindow = Completer<void>();
    final seen = <int>[];
    var showCalls = 0;
    var focusCalls = 0;
    addTearDown(callerMounted.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(residentChannel, (call) async {
          expect(call.method, kResidentShowWindowMethod);
          showCalls++;
          await showWindow.future;
          return null;
        });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          windowConnectionsLoadFnProvider.overrideWithValue(
            () async => [
              WindowConnectionRule(
                key: WindowConnectionKey.fromSession(_session)!,
                bundleId: _window.bundleId,
                titlePattern: _window.title,
              ),
            ],
          ),
          windowScanProvider.overrideWithValue(
            ({String? bundleId}) async => WindowScan(
              trusted: true,
              complete: true,
              localHost: 'work-mac',
              windows: const [_window],
            ),
          ),
          windowFocusProvider.overrideWithValue((token) async {
            focusCalls++;
            expect(token, _window.token);
            return 'staleTarget';
          }),
          windowSeenProvider.overrideWithValue((key, cutoff) async {
            seen.add(cutoff);
          }),
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: callerMounted,
              builder: (context, mounted, child) => mounted
                  ? Consumer(
                      builder: (context, ref, child) => TextButton(
                        onPressed: () =>
                            openSessionWindow(context, ref, _session),
                        child: const Text('open'),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(focusCalls, 1);
    expect(showCalls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    return (callerMounted: callerMounted, showWindow: showWindow, seen: seen);
  }

  testWidgets(
    '창 복원을 기다리다 호출 화면이 사라지면 오류 창을 열지 않는다',
    (tester) async {
      final pending = await pumpFailedNavigation(tester);
      // Navigator remains alive while the Consumer that owns WidgetRef is removed.
      pending.callerMounted.value = false;
      await tester.pump();
      pending.showWindow.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(pending.seen, isEmpty);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    '호출 화면이 유지되면 전환 실패를 알리고 읽음 처리하지 않는다',
    (tester) async {
      final pending = await pumpFailedNavigation(tester);
      pending.showWindow.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('window.focus_failed'), findsOneWidget);
      expect(find.text('window.stale'), findsOneWidget);
      expect(find.text('window.show_session'), findsOneWidget);
      expect(pending.seen, isEmpty);
      await tester.tap(find.text('action.cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  for (final focusResult in [kWindowNavigationFocused, 'unconfirmed']) {
    testWidgets(
      '수동 선택은 모달 제거 프레임 이후 전환하고 확인된 이전 알림만 읽는다: $focusResult',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final currentSession = ValueNotifier(_session);
        addTearDown(currentSession.dispose);
        final focus = Completer<String>();
        final focused = <String>[];
        final seen = <(String, int)>[];
        final writes = <List<WindowConnectionRule>>[];
        final events = <String>[];
        var showCalls = 0;
        var dialogCompleted = false;
        ({bool mounted, bool overlayMounted})? dialogAtFocus;
        late BuildContext dialogContext;
        late ModalRoute<WindowCandidate> dialogRoute;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(residentChannel, (call) async {
              expect(call.method, kResidentShowWindowMethod);
              showCalls++;
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(residentChannel, null);
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              windowConnectionsLoadFnProvider.overrideWithValue(() async => []),
              windowConnectionsSaveFnProvider.overrideWithValue((rules) async {
                writes.add(List.of(rules));
                events.add('save');
              }),
              windowScanProvider.overrideWithValue(
                ({String? bundleId}) async => WindowScan(
                  trusted: true,
                  complete: true,
                  localHost: 'work-mac',
                  windows: const [_window],
                ),
              ),
              windowFocusProvider.overrideWithValue((token) {
                focused.add(token);
                events.add('focus');
                dialogAtFocus = (
                  mounted: dialogContext.mounted,
                  overlayMounted: dialogRoute.overlayEntries.any(
                    (entry) => entry.mounted,
                  ),
                );
                return focus.future;
              }),
              windowSeenProvider.overrideWithValue((key, cutoff) async {
                seen.add((key, cutoff));
                events.add('seen');
              }),
              i18nTranslateOverride.overrideWithValue((key, locale) => key),
              i18nTranslateArgsOverride.overrideWithValue(
                (key, locale, names, values) => '$key ${values.join(' ')}',
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<SessionViewDto>(
                  valueListenable: currentSession,
                  builder: (context, session, child) => Consumer(
                    builder: (context, ref, child) => TextButton(
                      onPressed: () => openSessionWindow(context, ref, session),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(showCalls, 1);
        expect(find.byType(WindowConnectionDialog), findsOneWidget);
        expect(focused, isEmpty);
        dialogContext = tester.element(find.byType(WindowConnectionDialog));
        dialogRoute = ModalRoute.of<WindowCandidate>(dialogContext)!;
        expect(dialogRoute.transitionDuration, Duration.zero);
        expect(dialogRoute.reverseTransitionDuration, Duration.zero);
        unawaited(dialogRoute.completed.then((_) => dialogCompleted = true));

        // The UI receives a later transition while the original click waits.
        currentSession.value = _session.copyWith(lastTransitionId: 30);
        await tester.pump();
        await tester.tap(find.widgetWithText(ListTile, _window.title));
        await tester.pump();
        await tester.tap(find.text('window.save_and_open'));
        // Flush save/pop futures without rendering the overlay removal frame.
        await tester.idle();
        expect(
          writes.single.single.key,
          WindowConnectionKey.fromSession(_session),
        );
        expect(events, ['save']);
        expect(focused, isEmpty);
        expect(seen, isEmpty);
        expect(dialogContext.mounted, isTrue);

        await tester.pump();
        expect(dialogCompleted, isTrue);
        expect(find.byType(WindowConnectionDialog), findsNothing);
        expect(focused, [_window.token]);
        expect(dialogAtFocus, (
          mounted: false,
          overlayMounted: false,
        ));
        expect(events, ['save', 'focus']);
        expect(
          seen,
          isEmpty,
          reason: 'The native focus result is still pending.',
        );

        focus.complete(focusResult);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (focusResult == kWindowNavigationFocused) {
          expect(seen, [(_session.key, 10)]);
          expect(events, ['save', 'focus', 'seen']);
          expect(showCalls, 1);
          expect(find.byType(AlertDialog), findsNothing);
        } else {
          expect(seen, isEmpty);
          expect(events, ['save', 'focus']);
          expect(showCalls, 2);
          expect(find.text('window.focus_failed'), findsOneWidget);
          await tester.tap(find.text('action.cancel'));
          await tester.pumpAndSettle();
        }
      },
      variant: TargetPlatformVariant({TargetPlatform.macOS}),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';

const _session = SessionViewDto(
  key: 'codex:card-navigation',
  sessionId: 'card-navigation',
  source: 'codex',
  state: 'working',
  host: 'work-mac',
  project: '/work/demo',
  lastTransitionId: 10,
);
const _window = WindowCandidate(
  token: 'editor-window',
  bundleId: 'test.editor',
  appName: 'Editor',
  title: 'demo',
);
const _residentChannel = MethodChannel(kResidentChannelName);
const _viewportHeight = 700.0;

class _FixedSync extends SyncController {
  _FixedSync(this.session);
  final SessionViewDto session;

  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(cursor: 10, sessions: {session.key: session}),
  );
}

class _NavigationFixture {
  final focused = <String>[];
  final seen = <(String, int)>[];
  final routes = <String>[];
  final scopes = <String?>[];

  Future<void> pump(
    WidgetTester tester, {
    bool supported = true,
    bool connected = true,
    bool english = false,
    SessionViewDto session = _session,
    Future<String> Function(String)? focus,
    double width = 800,
  }) async {
    tester.view.physicalSize = Size(width, _viewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_residentChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_residentChannel, null);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue(
            (key, locale) => english
                ? switch (key) {
                    'waitingInput' => 'Waiting for input',
                    'session.source.codex' => 'Codex',
                    _ => key,
                  }
                : key,
          ),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((state) => state.name),
          isSessionStaleFnProvider.overrideWithValue(
            ({
              required int now,
              required int updatedAt,
              required int staleMs,
            }) => false,
          ),
          dashboardConfigValuesProvider.overrideWithValue(
            const DashboardConfigValues(),
          ),
          syncControllerProvider.overrideWith(() => _FixedSync(session)),
          windowNavigationSupportedProvider.overrideWithValue(supported),
          windowConnectionsLoadFnProvider.overrideWithValue(
            () async => [
              if (connected)
                WindowConnectionRule(
                  key: WindowConnectionKey.fromSession(_session)!,
                  bundleId: _window.bundleId,
                  titlePattern: _window.title,
                ),
            ],
          ),
          windowScanProvider.overrideWithValue(({String? bundleId}) async {
            scopes.add(bundleId);
            return WindowScan(
              trusted: true,
              complete: true,
              localHost: _session.host!,
              windows: const [_window],
            );
          }),
          windowFocusProvider.overrideWithValue((token) async {
            focused.add(token);
            return focus == null
                ? kWindowNavigationFocused
                : await focus(token);
          }),
          windowSeenProvider.overrideWithValue((key, cutoff) async {
            seen.add((key, cutoff));
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SessionsPage(),
          onGenerateRoute: (settings) {
            routes.add(settings.name!);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const Scaffold(body: Text('Details destination')),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<TestGesture> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(find.byType(SessionCard)));
  await tester.pumpAndSettle();
  addTearDown(mouse.removePointer);
  return mouse;
}

void main() {
  testWidgets('카드를 누르면 저장된 작업 창으로 이동하고 성공 후 읽는다', (tester) async {
    final fixture = _NavigationFixture();
    final focus = Completer<String>();
    await fixture.pump(tester, focus: (_) => focus.future);
    await tester.tap(find.text('demo'));
    await tester.pumpAndSettle();

    expect(fixture.focused, [_window.token]);
    expect(fixture.scopes, [_window.bundleId]);
    expect(fixture.routes, isEmpty);
    expect(fixture.seen, isEmpty);
    focus.complete(kWindowNavigationFocused);
    await tester.pumpAndSettle();
    expect(fixture.seen, [(_session.key, 10)]);
  });

  for (final width in [320.0, 800.0]) {
    testWidgets('폭 $width 카드의 상세 버튼은 마우스를 올려야 보이고 상세만 연다', (tester) async {
      final fixture = _NavigationFixture();
      await fixture.pump(tester, width: width);
      final details = find.byTooltip('window.show_session');
      expect(details, findsNothing);
      final mouse = await _hover(tester);
      expect(details, findsOneWidget);
      expect(find.byTooltip('session.card.delete_tooltip'), findsOneWidget);
      expect(
        tester.getRect(find.text('demo')).overlaps(tester.getRect(details)),
        isFalse,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(details, findsNothing);
      await mouse.moveTo(tester.getCenter(find.byType(SessionCard)));
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();

      expect(fixture.routes, [sessionDetailRouteName(_session.key)]);
      expect(fixture.focused, isEmpty);
      expect(fixture.scopes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('창 연결이 없으면 선택창을 열고 취소하면 읽지 않는다', (tester) async {
    final fixture = _NavigationFixture();
    await fixture.pump(tester, connected: false);
    await _hover(tester);
    await tester.tap(find.text('demo'));
    await tester.pumpAndSettle();

    expect(find.byType(WindowConnectionDialog), findsOneWidget);
    expect(fixture.routes, isEmpty);
    expect(fixture.focused, isEmpty);
    await tester.tap(find.text('action.cancel'));
    await tester.pumpAndSettle();
    expect(fixture.seen, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('좁은 영어 카드의 동작 버튼이 상태와 소스 배지를 가리지 않는다', (tester) async {
    final fixture = _NavigationFixture();
    await fixture.pump(
      tester,
      width: 320,
      english: true,
      session: _session.copyWith(state: 'waiting_input'),
    );
    await _hover(tester);
    final details = tester.getRect(find.byTooltip('window.show_session'));
    expect(
      tester.getRect(find.text('Waiting for input')).overlaps(details),
      isFalse,
    );
    expect(tester.getRect(find.text('Codex')).overlaps(details), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('작업 창 전환에 실패하면 안내하고 읽음 처리하지 않는다', (tester) async {
    final fixture = _NavigationFixture();
    await fixture.pump(tester, focus: (_) async => kWindowNavigationFailed);
    await tester.tap(find.text('demo'));
    await tester.pumpAndSettle();

    expect(find.text('window.focus_failed'), findsOneWidget);
    expect(fixture.seen, isEmpty);
    expect(fixture.routes, isEmpty);
  });

  testWidgets('작업 창 이동을 지원하지 않으면 카드 클릭으로 상세를 연다', (tester) async {
    final fixture = _NavigationFixture();
    await fixture.pump(tester, supported: false);
    await tester.tap(find.text('demo'));
    await tester.pumpAndSettle();

    expect(fixture.routes, [sessionDetailRouteName(_session.key)]);
    expect(fixture.focused, isEmpty);
    expect(fixture.scopes, isEmpty);
  });

  testWidgets(
    'macOS에서 마우스를 올린 카드의 상세 보기와 삭제 버튼 골든',
    tags: ['golden'],
    skip: !Platform.isMacOS,
    (tester) async {
      final fixture = _NavigationFixture();
      await fixture.pump(tester);
      await _hover(tester);
      await expectLater(
        find.byType(SessionCard),
        matchesGoldenFile(
          '../goldens/session_card_hover_${Platform.operatingSystem}.png',
        ),
      );
    },
  );
}

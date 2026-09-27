import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/push_signal.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/platform/tray.dart';
import 'package:my_dashboard/src/state/background_activity_provider.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/state/notification_click_inbox.dart';
import 'package:my_dashboard/src/state/notify_provider.dart';
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';

const _server = 'https://notification.example.test';
const _config = DashboardConfigValues(serverUrl: _server);
const _tap = NotificationTap(
  sessionKey: 'codex:notification',
  project: '/work/project',
  host: 'work-mac',
  transitionId: 10,
  serverUrl: _server,
);
const _session = SessionViewDto(
  key: 'codex:notification',
  source: 'codex',
  sessionId: 'notification',
  state: 'waiting_input',
  project: '/work/project',
  host: 'work-mac',
  lastTransitionId: 30,
);
const _window = WindowCandidate(
  token: 'fixture-window',
  bundleId: 'test.editor',
  appName: 'Fixture Editor',
  title: 'project',
);
const _residentChannel = MethodChannel(kResidentChannelName);
const _settleTimeout = Duration(seconds: 3);
const _settleInterval = Duration(milliseconds: 100);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(_settleInterval, EnginePhase.sendSemanticsUpdate, _settleTimeout);
}

class _ProbeSync extends SyncController {
  _ProbeSync({required this.withSession});

  final bool withSession;
  int refreshes = 0;
  final detailReads = <String>[];
  SyncControllerState get snapshot => state;

  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(cursor: 0, sessions: {if (withSession) _session.key: _session}),
  );

  @override
  void triggerNow({bool force = false}) => refreshes++;

  @override
  Future<void> markSeen(String key) async => detailReads.add(key);
}

class _Harness {
  _Harness({bool withSession = false}) : sync = _ProbeSync(withSession: withSession);

  final inbox = NotificationClickInbox();
  final signals = StreamController<PushSignal>.broadcast();
  final _ProbeSync sync;
  final focused = <String>[];
  final seen = <(String, int)>[];
  final writes = <List<WindowConnectionRule>>[];
  final residentCalls = <String>[];
  final httpRequests = <ApiRequest>[];

  Future<void> pump(WidgetTester tester, {bool supportsWindows = true}) async {
    tester.view.physicalSize = const Size(1100, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(signals.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _residentChannel,
      (call) async {
        residentCalls.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _residentChannel,
        null,
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => '$key ${values.join(' ')}',
          ),
          stateLabelKeyFnProvider.overrideWithValue((state) => 'label.${state.name}'),
          isSessionStaleFnProvider.overrideWithValue(
            ({required int now, required int updatedAt, required int staleMs}) => false,
          ),
          dashboardConfigValuesProvider.overrideWithValue(_config),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse(_server)),
          ),
          configLoadFnProvider.overrideWithValue(() async => _config),
          configSaveFnProvider.overrideWithValue((_) async {}),
          configPatchFnProvider.overrideWithValue((_) async {}),
          httpSendProvider.overrideWithValue((request) async {
            httpRequests.add(request);
            expect(request.url.path, kEventsPath);
            return const ApiResponse(
              statusCode: 200,
              body: '{"events":[],"has_more":false,"next_before_id":null}',
            );
          }),
          syncControllerProvider.overrideWith(() => sync),
          notificationClickInboxProvider.overrideWithValue(inbox),
          pushSignalWatchProvider.overrideWithValue(() => signals.stream),
          pushRegistrarProvider.overrideWithValue(
            ({String? label}) async =>
                const PushRegistrationResult(availability: PushAvailability.notApplicable),
          ),
          localNotifyFnProvider.overrideWithValue((_) async => fail('발신할 알림이 없다')),
          traySupportedProvider.overrideWithValue(false),
          residentModeApplyProvider.overrideWithValue((_) async {}),
          backgroundActivityApplyFnProvider.overrideWithValue((_) async {}),
          backgroundActivityLifecycleWatchFnProvider.overrideWithValue(
            () => const Stream<AppLifecycleState>.empty(),
          ),
          windowNavigationSupportedProvider.overrideWithValue(supportsWindows),
          windowConnectionsLoadFnProvider.overrideWithValue(
            () async => [
              WindowConnectionRule(
                key: WindowConnectionKey(host: _tap.host!, project: _tap.project!),
                bundleId: _window.bundleId,
                titlePattern: _window.title,
              ),
            ],
          ),
          windowConnectionsSaveFnProvider.overrideWithValue((rules) async {
            writes.add(List.of(rules));
          }),
          windowScanProvider.overrideWithValue(
            ({String? bundleId}) async => WindowScan(
              trusted: true,
              complete: true,
              localHost: _tap.host!,
              windows: const [_window],
            ),
          ),
          windowFocusProvider.overrideWithValue((token) async {
            focused.add(token);
            expect(find.byType(WindowConnectionDialog), findsNothing);
            return kWindowNavigationFocused;
          }),
          windowSeenProvider.overrideWithValue((key, cutoff) async {
            seen.add((key, cutoff));
          }),
        ],
        child: const SolApp(),
      ),
    );
    await _settle(tester);
  }
}

void main() {
  testWidgets('부팅 전에 누른 배너는 첫 화면 이후 연결된 창으로 한 번 이동한다', (tester) async {
    final harness = _Harness();
    harness.inbox.add(_tap);
    expect(harness.focused, isEmpty);
    await harness.pump(tester);

    expect(harness.focused, [_window.token]);
    expect(harness.seen, [(_session.key, 10)]);
    expect(harness.sync.snapshot.sync.sessions, isEmpty);
    expect(harness.sync.detailReads, isEmpty);
    expect(harness.residentCalls, isEmpty);
    expect(harness.httpRequests, isEmpty);
    expect(find.byType(SessionDeepLinkPage), findsNothing);
    expect(find.byType(SessionDetailPage), findsNothing);
    await tester.pump();
    expect(harness.focused, [_window.token]);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('일반 push 재조회 신호는 세션 키가 있어도 창이나 상세를 열지 않는다', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    harness.signals.add(const PushSignal(type: 'refresh', sessionKey: 'codex:notification'));
    await _settle(tester);

    expect(harness.sync.refreshes, 1);
    expect(harness.focused, isEmpty);
    expect(harness.seen, isEmpty);
    expect(harness.residentCalls, isEmpty);
    expect(find.byType(WindowConnectionDialog), findsNothing);
    expect(find.byType(SessionDeepLinkPage), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets(
    '서버 출처 없는 APNs 클릭은 저장된 연결도 확인받고 읽음을 바꾸지 않는다',
    (tester) async {
      final harness = _Harness();
      await harness.pump(tester);
      harness.signals.add(
        PushSignal(
          type: kPushSignalNotificationClick,
          sessionKey: _tap.sessionKey,
          project: _tap.project,
          host: _tap.host,
          transitionId: _tap.transitionId,
        ),
      );
      await _settle(tester);

      expect(harness.sync.refreshes, 1);
      expect(find.byType(WindowConnectionDialog), findsOneWidget);
      expect(harness.residentCalls, [kResidentShowWindowMethod]);
      expect(harness.focused, isEmpty);
      expect(harness.seen, isEmpty);
      await tester.tap(find.widgetWithText(ListTile, _window.title));
      await tester.pump();
      await tester.tap(find.text('window.save_and_open'));
      await _settle(tester);

      expect(harness.focused, [_window.token]);
      expect(harness.seen, isEmpty);
      expect(harness.sync.detailReads, isEmpty);
      expect(find.byType(SessionDeepLinkPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets('외부 창 이동을 지원하지 않는 호스트는 기존 세션 상세를 연다', (tester) async {
    final harness = _Harness(withSession: true);
    await harness.pump(tester, supportsWindows: false);
    harness.signals.add(
      const PushSignal(type: kPushSignalNotificationClick, sessionKey: 'codex:notification'),
    );
    await _settle(tester);

    expect(harness.sync.refreshes, 1);
    expect(find.byType(SessionDeepLinkPage), findsOneWidget);
    expect(find.byType(SessionDetailPage), findsOneWidget);
    expect(harness.sync.detailReads, [_session.key]);
    expect(harness.focused, isEmpty);
    expect(harness.seen, isEmpty);
    expect(harness.residentCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

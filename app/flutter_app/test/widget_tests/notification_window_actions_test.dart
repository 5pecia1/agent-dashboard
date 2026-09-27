import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/state/notification_target_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/notification_click_actions.dart';

const _tap = NotificationTap(
  sessionKey: 'codex:old',
  project: '/work/project',
  host: 'mac',
  transitionId: 10,
  serverUrl: 'https://dashboard.example.test',
);
const _window = WindowCandidate(
  token: 'window',
  bundleId: 'editor',
  appName: 'Editor',
  title: 'project',
);

void main() {
  late List<String> focus;
  late List<int> seen;
  late List<String> residentCalls;
  late String result;
  late List<WindowConnectionRule> rules;
  const resident = MethodChannel(kResidentChannelName);

  setUp(() {
    focus = [];
    seen = [];
    residentCalls = [];
    result = 'focused';
    rules = [
      WindowConnectionRule(
        key: WindowConnectionKey(host: 'mac', project: '/work/project'),
        bundleId: 'editor',
        titlePattern: 'project',
      ),
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      resident,
      (call) async {
        residentCalls.add(call.method);
        return null;
      },
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      resident,
      null,
    );
  });

  Future<void> pump(WidgetTester tester, NotificationTap tap) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://dashboard.example.test')),
          ),
          notificationSessionLookupProvider.overrideWithValue((_) async => null),
          windowConnectionsLoadFnProvider.overrideWithValue(() async => rules),
          windowConnectionsSaveFnProvider.overrideWithValue((_) async {}),
          windowScanProvider.overrideWithValue(
            ({String? bundleId}) async =>
                WindowScan(trusted: true, complete: true, localHost: 'mac', windows: [_window]),
          ),
          windowFocusProvider.overrideWithValue((token) async {
            focus.add(token);
            return result;
          }),
          windowSeenProvider.overrideWithValue((key, cutoff) async {
            expect(key, 'codex:old');
            seen.add(cutoff);
          }),
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, keys, values) => '$key ${values.join(' ')}',
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => openNotificationWindow(context, ref, tap),
                child: const Text('tap'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('tap'));
    await tester.pumpAndSettle();
  }

  testWidgets('알림 세션이 캐시에 없어도 연결 창으로 바로 가며 대시보드를 소환하지 않는다', (tester) async {
    await pump(tester, _tap);
    expect(focus, ['window']);
    expect(seen, [10]);
    expect(residentCalls, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('연결 창 전환에 실패하면 읽지 않고 안내한다', (tester) async {
    result = 'unconfirmed';
    await pump(tester, _tap);
    expect(focus, ['window']);
    expect(seen, isEmpty);
    expect(residentCalls, [kResidentShowWindowMethod]);
    expect(find.text('window.focus_failed'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('프로젝트 확인 선택창을 취소하면 이동과 읽음이 없다', (tester) async {
    rules = [];
    await pump(tester, _tap);
    expect(find.textContaining('/work/project'), findsOneWidget);
    expect(find.textContaining('window.alert_host'), findsOneWidget);
    await tester.tap(find.text('action.cancel'));
    await tester.pumpAndSettle();
    expect(focus, isEmpty);
    expect(seen, isEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('이전 서버 알림에는 현재 세션을 여는 버튼을 제공하지 않는다', (tester) async {
    await pump(
      tester,
      const NotificationTap(
        sessionKey: 'codex:old',
        project: '/work/project',
        host: 'mac',
        transitionId: 10,
        serverUrl: 'https://other.example.test',
      ),
    );
    expect(focus, isEmpty);
    expect(seen, isEmpty);
    expect(find.text('notification.server_changed'), findsOneWidget);
    expect(find.text('window.show_session'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('세션 없는 테스트 알림은 앱만 보여준다', (tester) async {
    await pump(tester, const NotificationTap());
    expect(residentCalls, [kResidentShowWindowMethod]);
    expect(focus, isEmpty);
    expect(seen, isEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
}

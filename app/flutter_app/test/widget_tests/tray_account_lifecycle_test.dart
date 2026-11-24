import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/main.dart' show buildDashboardRoot;
import 'package:my_dashboard/agent_dashboard.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/tray_native.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:tray_manager/tray_manager.dart';

class _Dashboard extends ConsumerStatefulWidget {
  const _Dashboard();
  @override
  ConsumerState<_Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<_Dashboard> {
  @override
  void initState() {
    super.initState();
    unawaited(installTray(ref));
  }

  @override
  Widget build(BuildContext context) => const SizedBox();

  @override
  void dispose() {
    uninstallTray(ref);
    super.dispose();
  }
}

class _Sessions extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();

  void receive(String serverState, int count) {
    state = SyncControllerState(
      sync: SyncState(
        seenWatermark: 0,
        sessions: {
          for (var i = 1; i <= count; i++)
            'example:$i': SessionViewDto(
              key: 'example:$i',
              state: serverState,
              lastTransitionId: i,
            ),
        },
      ),
    );
  }
}

void main() {
  const channel = MethodChannel('tray_manager');
  late List<MethodCall> calls;
  late List<_Sessions> controllers;
  Completer<void>? holdIcon;

  Widget signedIn(String account) => KeyedSubtree(
    key: ValueKey(account),
    child: buildDashboardRoot(
      DashboardConfigValues.empty,
      session: DashboardHostSession(
        origin: Uri.parse('https://example.test'),
        accessToken: ({rejectedToken}) async => 'fixture',
        syncScope: () => account,
        wrapApp: (child) => child,
        connectionSettings: (_, language) => const SizedBox(),
      ),
      app: const _Dashboard(),
      extensions: (_) => [
        syncControllerProvider.overrideWith(() {
          final c = _Sessions();
          controllers.add(c);
          return c;
        }),
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, locale, keys, values) => key,
        ),
        stateLabelKeyFnProvider.overrideWithValue((s) => s.name),
        traySupportedProvider.overrideWithValue(true),
      ],
    ),
  );

  String lastTitle() =>
      (calls.lastWhere((c) => c.method == 'setTitle').arguments
              as Map<Object?, Object?>)['title']
          as String;

  Future<String> icon(String path) async {
    final data = await rootBundle.load('assets/$path');
    return base64Encode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  // setIcon loads through Flutter's asset channel before the plugin call.
  // Wait for that actual response as well as the asynchronous tray operation.
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(
      done(),
      isTrue,
      reason: calls.map((c) => c.method).toList().toString(),
    );
  }

  setUp(() {
    controllers = [];
    calls = [];
    holdIcon = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setIcon' && holdIcon != null) {
            await holdIcon!.future;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    '로그인 직후와 다른 계정으로 다시 로그인한 뒤 모두 새 세션의 숫자와 색을 그린다',
    (tester) async {
      final waiting = await tester.runAsync(
        () => icon('tray_icon_attention_waiting.png'),
      );
      final stalled = await tester.runAsync(
        () => icon('tray_icon_attention_stalled.png'),
      );
      await tester.pumpWidget(signedIn('first'));
      await waitFor(tester, () => calls.any((c) => c.method == 'setTitle'));
      controllers.single.receive(kDashboardStateWaitingInput, 2);
      await waitFor(tester, () => lastTitle() == '2');
      Map<Object?, Object?> lastIcon() =>
          calls.lastWhere((c) => c.method == 'setIcon').arguments
              as Map<Object?, Object?>;
      expect(lastIcon()['base64Icon'], waiting);
      expect(lastIcon()['isTemplate'], false);
      await tester.pumpWidget(const SizedBox());
      await waitFor(tester, () => calls.any((c) => c.method == 'destroy'));
      expect(trayManager.hasListeners, isFalse);
      await tester.pumpWidget(signedIn('second'));
      await waitFor(tester, () => lastTitle().isEmpty);
      controllers.last.receive(kDashboardStateStalled, 1);
      await waitFor(tester, () => lastTitle() == '1');
      expect(lastIcon()['base64Icon'], stalled);
      expect(lastIcon()['isTemplate'], false);
      await tester.pumpWidget(const SizedBox());
      await waitFor(
        tester,
        () => calls.where((c) => c.method == 'destroy').length == 2,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    '아이콘을 준비하는 도중 계정이 바뀌어도 폐기된 위젯에 리스너를 연결하지 않는다',
    (tester) async {
      holdIcon = Completer<void>();
      await tester.pumpWidget(signedIn('old'));
      await waitFor(tester, () => calls.any((c) => c.method == 'setIcon'));
      await tester.pumpWidget(signedIn('new'));
      holdIcon!.complete();
      holdIcon = null;
      await waitFor(tester, () => calls.any((c) => c.method == 'setTitle'));
      controllers.last.receive(kDashboardStateWaitingInput, 1);
      await waitFor(tester, () => lastTitle() == '1');
      final destroy = calls.indexWhere((c) => c.method == 'destroy');
      expect(destroy, greaterThanOrEqualTo(0));
      expect(
        calls.take(destroy).where((c) => c.method == 'setContextMenu'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await waitFor(
        tester,
        () => calls.where((c) => c.method == 'destroy').length == 2,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

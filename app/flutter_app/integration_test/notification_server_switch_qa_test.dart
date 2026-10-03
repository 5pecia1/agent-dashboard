/// 실물 실행 QA: 서버 A의 높은 전이 ID를 알린 뒤 서버 B의 낮은 전이 ID도
/// 실제 macOS 알림 센터에 전달되는지 확인한다. `app.main()`의 동기화,
/// `AlertNotifier`, `notifyProvider`, 네이티브 플러그인 경로를 그대로 탄다.
///
/// 각 서버는 계약의 sync 응답을 실제 루프백 소켓으로 보낸다. A 901,
/// B 6, B 6 재전송, B 7 순으로 전이를 내고 macOS가 전달한 알림의
/// ID·본문·payload를 읽는다. ID 6에는 B로 전환하기 전에 이 QA가 만든
/// 오래된 알림을 미리 놓아, 새 발신이 같은 OS ID를 교체하는지도 본다.
///
/// `await-old-source-click` 기록이 뜨면 실행자가 macOS 알림 센터에서
/// A 901 알림을 클릭한다. 그 클릭은 앱의 실제 플러그인 콜백과 inbox를
/// 지나며, 서버를 바꾼 뒤의 안내 대화상자를 검사한다. OS 배너 표시와
/// 창의 실제 포커스는 실행자가 화면으로 별도 확인한다.
///
/// 실행 전제: 별도 번들 ID의 QA 앱, 알림 권한 허용, 새 임시 HOME.
/// `sync_qa_support.dart`의 가드·출력 환경 변수를 그대로 사용한다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show StandardMethodCodec;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/src/app.dart' show rootNavigatorKey;
import 'package:my_dashboard/src/data/dashboard_api.dart'
    show kSessionsPath, kSyncPath;
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/platform/local_notifications_native.dart'
    show
        NotificationBackend,
        currentNotificationBackend,
        probeNotificationSupport;
import 'package:my_dashboard/src/state/alert_notify_provider.dart'
    show alertNotifierProvider;
import 'package:my_dashboard/src/state/push_provider.dart'
    show apnsRegisteredProvider;
import 'package:my_dashboard/src/state/sync_controller.dart'
    show syncControllerProvider;
import 'package:my_dashboard/src/ui/setup_page.dart' show SetupPage;

import 'sync_qa_support.dart';

const String _kScenario = 'notification_server_switch';
const String _kQaBundleIdVariable = 'MY_DASHBOARD_QA_BUNDLE_ID';
const String _kQaBundleId = 'io.github.5pecia1.mydashboard.qa64';
const String _kMacOsExecutableDirectory = 'MacOS';
const String _kInfoPlistName = 'Info.plist';
const String _kPlistBuddy = '/usr/libexec/PlistBuddy';
const String _kBundleIdPlistKey = 'Print :CFBundleIdentifier';
const String _kTokenA = 'qa-alert-token-a';
const String _kTokenB = 'qa-alert-token-b';
const int _kSnapshotA = 900;
const int _kAlertA = 901;
const int _kSnapshotB = 5;
const int _kAlertBFirst = 6;
const int _kAlertBSecond = 7;
const Set<int> _kScopedNotificationIds = <int>{
  _kAlertA,
  _kAlertBFirst,
  _kAlertBSecond,
};
const int _kServerPortAuto = 0;
const int _kProtocolVersion = 1;
const int _kPrunedBelowId = 0;
const int _kStallMs = 600000;
const int _kSetupUrlField = 0;
const int _kSetupTokenField = 1;
const Duration _kNativeWait = Duration(seconds: 25);
const Duration _kClickWait = Duration(minutes: 10);
const Duration _kPermissionWait = Duration(minutes: 3);
const Duration _kPermissionPoll = Duration(seconds: 2);
const Duration _kClickDrain = Duration(seconds: 1);
const Duration _kRequestWait = Duration(seconds: 10);
const Timeout _kScenarioTimeout = Timeout(Duration(minutes: 14));

const QaSession _kSessionA = QaSession(
  id: 'notification-a',
  message: 'QA notification session A',
);
const QaSession _kSessionB = QaSession(
  id: 'notification-b',
  message: 'QA notification session B',
);
const String _kAAlertMessage = 'QA A alert 901: old server';
const String _kBFirstMessage = 'QA B alert 6: new server';
const String _kBSecondMessage = 'QA B alert 7: later event';
const String _kStaleCollisionTitle = 'QA stale ID 6';
const String _kStaleCollisionBody = 'QA stale collision before B';
const Map<String, String> _kSave = <String, String>{
  kEnglish: 'Save',
  kKorean: '저장',
};
const Map<String, String> _kChangedServerNotice = <String, String>{
  kEnglish:
      'This alert came from a previous server connection. '
      'Check the current session.',
  kKorean: '이 알림은 이전 서버 연결에서 온 알림입니다. 현재 세션을 확인해 주세요.',
};

final Finder _setupFields = find.descendant(
  of: find.byType(SetupPage),
  matching: find.byType(TextField),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  // 실물 권한 버튼과 OS 알림 클릭은 테스트의 합성 탭이 아닌 실제 입력이다.
  binding.shouldPropagateDevicePointerEvents = true;
  final qa = QaRun.fromEnvironment(const <String>[_kScenario]);

  testWidgets(
    '서버를 바꿔도 낮은 전이 ID를 새 알림으로 보내고 중복은 억제하며 이전 서버 알림 클릭을 거부한다',
    (tester) async {
      final semantics = tester.ensureSemantics();
      _ScriptedSyncServer? a;
      _ScriptedSyncServer? b;
      try {
        a = await _ScriptedSyncServer.start(
          qa,
          name: 'A',
          token: _kTokenA,
          language: qa.language,
          snapshotCursor: _kSnapshotA,
          session: _kSessionA,
        );
        b = await _ScriptedSyncServer.start(
          qa,
          name: 'B',
          token: _kTokenB,
          language: qa.language,
          snapshotCursor: _kSnapshotB,
          session: _kSessionB,
        );
        qa.writeConfig(
          serverUrl: a.baseUrl,
          token: _kTokenA,
          uiLang: qa.language,
        );
        await _runScenario(tester, qa, a, b);
      } finally {
        // 위젯 테스트의 종료 검사는 addTearDown보다 먼저 실행된다.
        semantics.dispose();
        await a?.close();
        await b?.close();
        await qa.closeServers();
        qa.note('end', <String, Object?>{
          'a_requests': a?.requests,
          'b_requests': b?.requests,
          'config': qa.storedConfig(),
        });
        expect(
          tester.takeException(),
          isNull,
          reason: 'no framework exception',
        );
      }
    },
    timeout: _kScenarioTimeout,
  );
}

Future<void> _runScenario(
  WidgetTester tester,
  QaRun qa,
  _ScriptedSyncServer a,
  _ScriptedSyncServer b,
) async {
  await _assertQaBundle(qa);
  await bootApp(tester, qa);
  await _awaitNotificationPermission(tester, qa);
  expect(
    currentNotificationBackend,
    NotificationBackend.flutterLocalNotifications,
    reason: 'the QA app needs an authorized native notification backend',
  );
  expect(
    appContainer(tester).read(apnsRegisteredProvider),
    isFalse,
    reason: 'the loopback server has no APNs registration; use local fallback',
  );
  final plugin = FlutterLocalNotificationsPlugin();
  final existing = await _scopedNotifications(plugin);
  if (existing.isNotEmpty) {
    // 번들 ID를 확인한 뒤 QA64의 이 세 ID만 정리한다. 이전 실패 실행의
    // 항목이 다음 실행을 가리지 않게 하되, 다른 알림은 건드리지 않는다.
    qa.note('previous-qa-alerts', <String, Object?>{
      'delivered': existing.map(_notificationRecord).toList(),
    });
    for (final id in _kScopedNotificationIds) {
      await plugin.cancel(id: id);
    }
    final clock = Stopwatch()..start();
    while ((await _scopedNotifications(plugin)).isNotEmpty &&
        clock.elapsed < _kNativeWait) {
      await tester.pump(kPoll);
    }
    expect(
      await _scopedNotifications(plugin),
      isEmpty,
      reason: 'scoped QA alerts must be cleared before the scenario',
    );
  }
  await pumpUntil(
    tester,
    'A snapshot on screen',
    () => a.syncRequests.isNotEmpty && shows(find.text(_kSessionA.message)),
    timeout: _kRequestWait,
  );
  expect(_since(a.syncRequests.first), isNull);
  expectScreenLanguage(tester, qa);
  await qa.capture(tester, 'a-snapshot');

  a.addAlert(
    id: _kAlertA,
    fromState: 'working',
    toState: 'waiting_input',
    message: _kAAlertMessage,
  );
  _triggerSync(tester);
  final aAlert = await _waitForNativeAlert(tester, plugin, _kAlertA);
  _expectAlert(
    aAlert,
    id: _kAlertA,
    origin: a.baseUrl,
    session: _kSessionA,
    message: _kAAlertMessage,
  );
  expect(
    appContainer(tester).read(alertNotifierProvider).debugWatermark,
    _kAlertA,
  );
  qa.note('a-alert-delivered', _notificationRecord(aAlert));

  // QA가 만든 옛 OS 항목으로 ID 충돌을 재현한다. B 6 자체는 이후
  // 프로덕션의 AlertNotifier -> native show 경로에서만 발신한다.
  await plugin.show(
    id: _kAlertBFirst,
    title: _kStaleCollisionTitle,
    body: _kStaleCollisionBody,
    notificationDetails: const NotificationDetails(
      macOS: DarwinNotificationDetails(),
    ),
    payload: NotificationTap(
      sessionKey: _kSessionA.key,
      project: '${QaSession.projectRoot}${_kSessionA.id}',
      host: QaSession.host,
      transitionId: _kAlertBFirst,
      serverUrl: a.baseUrl.toString(),
    ).encode(),
  );
  final stale = await _waitForNativeAlert(tester, plugin, _kAlertBFirst);
  expect(stale.body, _kStaleCollisionBody);
  qa.note('collision-preseed-delivered', _notificationRecord(stale));
  final nativeCalls = _NativeNotificationCallSpy.install();
  addTearDown(nativeCalls.dispose);

  tester.testTextInput.register();
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await pumpUntil(
    tester,
    'setup with A connection',
    () =>
        shows(_setupFields) &&
        _fieldText(tester, _kSetupUrlField) == '${a.baseUrl}',
  );
  await tester.enterText(_setupFields.at(_kSetupUrlField), '${b.baseUrl}');
  await tester.enterText(_setupFields.at(_kSetupTokenField), _kTokenB);
  await tester.pump();
  qa.note('switch-save-tapped', <String, Object?>{'to': '${b.baseUrl}'});
  await tester.tap(
    find.descendant(
      of: find.byType(SetupPage),
      matching: find.widgetWithText(FilledButton, _kSave[qa.language]!),
    ),
  );
  await pumpUntil(
    tester,
    'B first snapshot',
    () => b.syncRequests.isNotEmpty,
    timeout: _kRequestWait,
  );
  expect(
    _since(b.syncRequests.first),
    isNull,
    reason: 'A cursor must not enter the B namespace',
  );
  expect(b.syncRequests.first['authorization'], 'Bearer $_kTokenB');
  await tester.pageBack();
  await pumpUntil(
    tester,
    'B session replaces A session',
    () =>
        shows(find.text(_kSessionB.message)) &&
        !shows(find.text(_kSessionA.message)),
  );
  expectScreenLanguage(tester, qa);
  await qa.capture(tester, 'b-snapshot');
  expect(
    appContainer(tester).read(syncControllerProvider).sync.seenWatermark,
    _kSnapshotB,
    reason: 'the seen floor must belong to B after the switch',
  );
  final aRequestsAfterSwitch = a.syncRequests.length;

  b.addAlert(
    id: _kAlertBFirst,
    fromState: 'working',
    toState: 'waiting_input',
    message: _kBFirstMessage,
  );
  _triggerSync(tester);
  final bFirst = await _waitForNativeAlert(
    tester,
    plugin,
    _kAlertBFirst,
    matchingBody: _kBFirstMessage,
  );
  _expectAlert(
    bFirst,
    id: _kAlertBFirst,
    origin: b.baseUrl,
    session: _kSessionB,
    message: _kBFirstMessage,
  );
  expect(
    bFirst.body,
    isNot(_kStaleCollisionBody),
    reason: 'B must replace the old item with OS ID 6',
  );
  expect(
    appContainer(tester).read(alertNotifierProvider).debugWatermark,
    _kAlertBFirst,
    reason: 'notifier watermark resets for the new server',
  );
  expect(
    nativeCalls.operationsFor(_kAlertBFirst),
    <String>['cancel', 'show'],
    reason: 'B 6 must cancel the stale OS ID before showing a fresh alert',
  );
  qa.note('b-first-alert-delivered', _notificationRecord(bFirst));

  final requestsBeforeDuplicate = b.syncRequests.length;
  b.replayLatestOnce = true;
  _triggerSync(tester);
  await pumpUntil(
    tester,
    'B duplicate served by the real HTTP path',
    () =>
        b.syncRequests.length > requestsBeforeDuplicate &&
        b.syncRequests
            .skip(requestsBeforeDuplicate)
            .any(
              (request) =>
                  (request['served_ids'] as List<int>?)?.contains(
                    _kAlertBFirst,
                  ) ??
                  false,
            ),
    timeout: _kRequestWait,
  );
  await pumpFor(tester, kSettle);
  final afterDuplicate = await _scopedNotifications(plugin);
  expect(
    afterDuplicate.where((item) => item.id == _kAlertBFirst),
    hasLength(1),
  );
  _expectAlert(
    afterDuplicate.singleWhere((item) => item.id == _kAlertBFirst),
    id: _kAlertBFirst,
    origin: b.baseUrl,
    session: _kSessionB,
    message: _kBFirstMessage,
  );
  expect(
    appContainer(tester).read(alertNotifierProvider).debugWatermark,
    _kAlertBFirst,
  );
  expect(
    nativeCalls.operationsFor(_kAlertBFirst),
    <String>['cancel', 'show'],
    reason: 'replayed B 6 must not call the native notification channel again',
  );
  qa.note('b-duplicate-observed', <String, Object?>{
    'delivered': afterDuplicate.map(_notificationRecord).toList(),
    'native_operations_for_id_6': nativeCalls.operationsFor(_kAlertBFirst),
  });

  b.addAlert(
    id: _kAlertBSecond,
    fromState: 'waiting_input',
    toState: 'stalled',
    message: _kBSecondMessage,
  );
  _triggerSync(tester);
  final bSecond = await _waitForNativeAlert(tester, plugin, _kAlertBSecond);
  _expectAlert(
    bSecond,
    id: _kAlertBSecond,
    origin: b.baseUrl,
    session: _kSessionB,
    message: _kBSecondMessage,
  );
  expect(nativeCalls.operationsFor(_kAlertBSecond), <String>['cancel', 'show']);
  final delivered = await _scopedNotifications(plugin);
  expect(delivered.map((item) => item.id).toSet(), <int>{
    _kAlertA,
    _kAlertBFirst,
    _kAlertBSecond,
  });
  expect(
    a.syncRequests.length,
    aRequestsAfterSwitch,
    reason: 'A is no longer polled after B became active',
  );
  expect(
    appContainer(tester).read(syncControllerProvider).sync.seenWatermark,
    _kSnapshotB,
    reason: 'new B transitions do not move the one-time seen floor',
  );
  qa.note('b-second-alert-delivered', <String, Object?>{
    'delivered': delivered.map(_notificationRecord).toList(),
    'a_requests_after_switch': aRequestsAfterSwitch,
    'a_requests_now': a.syncRequests.length,
  });
  await qa.capture(tester, 'b-alerts');
  final bSeenBeforeOldClick = Map<String, int>.of(
    appContainer(tester).read(syncControllerProvider).sync.seenTransitionIds,
  );
  final aRequestsBeforeOldClick = a.requests.length;
  expect(
    b.requests.where(_isSeenOrAckRequest),
    isEmpty,
    reason: 'no B read or ack action before the old alert click',
  );

  // 실행자는 여기서 알림 센터의 A 901을 클릭한다. 테스트는 콜백을 직접
  // 호출하지 않고 프로덕션의 플러그인 -> inbox -> UI 경로를 기다린다.
  qa.note('await-old-source-click', <String, Object?>{
    'id': _kAlertA,
    'body': _kAAlertMessage,
    'expected_dialog': _kChangedServerNotice[qa.language],
  });
  await pumpUntil(
    tester,
    'old-source notification rejection after real OS click',
    () => shows(find.text(_kChangedServerNotice[qa.language]!)),
    timeout: _kClickWait,
  );
  await pumpFor(tester, _kClickDrain);
  expect(
    b.requests.where(_isSeenOrAckRequest),
    isEmpty,
    reason: 'old A alert must not mark any B session seen or acknowledged',
  );
  expect(
    appContainer(tester).read(syncControllerProvider).sync.seenTransitionIds,
    bSeenBeforeOldClick,
    reason: 'old A alert must not change B read markers in memory',
  );
  expect(
    a.requests.length,
    aRequestsBeforeOldClick,
    reason: 'old A alert must not send any request to its former server',
  );
  expect(find.text(_kSessionA.message), findsNothing);
  final currentSessions = appContainer(
    tester,
  ).read(syncControllerProvider).sync.sessions;
  expect(currentSessions.containsKey(_kSessionB.key), isTrue);
  expect(currentSessions.containsKey(_kSessionA.key), isFalse);
  expectScreenLanguage(tester, qa);
  await qa.capture(tester, 'old-source-click-rejected');
  qa.note('old-source-click-rejected', <String, Object?>{
    'current_server': '${b.baseUrl}',
    'b_seen_or_ack_requests': b.requests.where(_isSeenOrAckRequest).toList(),
    'b_seen_after_click': appContainer(
      tester,
    ).read(syncControllerProvider).sync.seenTransitionIds,
  });
}

bool _isSeenOrAckRequest(Map<String, Object?> request) {
  final path = request['path'];
  return path is String &&
      path.startsWith('$kSessionsPath/') &&
      (path.endsWith('/seen') || path.endsWith('/ack'));
}

/// QA 번들 ID 검증 뒤에만 보여 주는 임시 권한 창. 테스트가 설정을 자동으로
/// 열지 않는다. 실행자가 앱 안의 버튼을 실제로 눌러 이 QA 앱 자신의
/// 알림 설정으로 이동하고 허용한 뒤, 플러그인 권한을 다시 읽는다.
Future<void> _awaitNotificationPermission(WidgetTester tester, QaRun qa) async {
  if (currentNotificationBackend ==
      NotificationBackend.flutterLocalNotifications) {
    return;
  }
  final native = FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin
      >();
  expect(native, isNotNull, reason: 'macOS notification plugin is required');
  final navigator = rootNavigatorKey.currentState;
  expect(
    navigator?.overlay,
    isNotNull,
    reason: 'QA dialog needs the app navigator',
  );
  BuildContext? dialogContext;
  qa.note('notification-permission-needed', <String, Object?>{
    'backend': currentNotificationBackend.name,
    'bundle_id': _kQaBundleId,
  });
  unawaited(
    showDialog<void>(
      context: navigator!.overlay!.context,
      barrierDismissible: false,
      builder: (context) {
        dialogContext = context;
        return AlertDialog(
          title: const Text('QA notification permission'),
          content: const Text(
            'Allow notifications for this QA app, then return here. '
            'The test will continue when the native plugin confirms access.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () async {
                try {
                  final opened = await native!.openAppNotificationSettings();
                  qa.note('qa-notification-settings-opened', <String, Object?>{
                    'opened': opened,
                  });
                } on Exception catch (error) {
                  qa.note('qa-notification-settings-error', <String, Object?>{
                    'error': '$error',
                  });
                }
              },
              child: const Text('Open QA notification settings'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  final granted = await native!.requestPermissions(
                    alert: true,
                    badge: true,
                    sound: true,
                  );
                  qa.note(
                    'qa-notification-permission-requested',
                    <String, Object?>{'granted': granted},
                  );
                } on Exception catch (error) {
                  qa.note('qa-notification-permission-error', <String, Object?>{
                    'error': '$error',
                  });
                }
              },
              child: const Text('Request QA notification permission'),
            ),
          ],
        );
      },
    ),
  );
  await pumpUntil(
    tester,
    'QA notification permission dialog',
    () => shows(find.text('Open QA notification settings')),
  );
  await qa.capture(tester, 'notification-permission-needed');

  final clock = Stopwatch()..start();
  var nextProbe = Duration.zero;
  bool? lastEnabled;
  while (currentNotificationBackend !=
      NotificationBackend.flutterLocalNotifications) {
    if (clock.elapsed >= _kPermissionWait) {
      fail(
        'QA notification permission was not granted within $_kPermissionWait',
      );
    }
    if (clock.elapsed >= nextProbe) {
      bool? enabled;
      try {
        enabled = (await native!.checkPermissions())?.isEnabled;
      } on Exception catch (error) {
        qa.note('qa-notification-permission-check-error', <String, Object?>{
          'error': '$error',
        });
      }
      if (enabled != lastEnabled) {
        qa.note('qa-notification-permission-status', <String, Object?>{
          'enabled': enabled,
        });
        lastEnabled = enabled;
      }
      if (enabled == true) {
        await probeNotificationSupport();
        qa.note('qa-notification-reprobed', <String, Object?>{
          'backend': currentNotificationBackend.name,
        });
      }
      nextProbe = clock.elapsed + _kPermissionPoll;
    }
    await tester.pump(kPoll);
  }
  if (dialogContext case final context? when context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
    await tester.pump();
  }
  qa.note('notification-permission-ready', <String, Object?>{
    'backend': currentNotificationBackend.name,
  });
}

/// HOME 격리만으로는 OS 알림 저장소가 격리되지 않는다. 실행 중인 앱의
/// Info.plist를 직접 읽어 별도 QA 번들 ID인지 확인한 뒤에만 알림을 만진다.
Future<void> _assertQaBundle(QaRun qa) async {
  final expected = Platform.environment[_kQaBundleIdVariable];
  expect(
    expected,
    _kQaBundleId,
    reason: 'QA requires $_kQaBundleIdVariable=$_kQaBundleId',
  );
  final executable = File(Platform.resolvedExecutable);
  expect(
    executable.parent.uri.pathSegments.where((part) => part.isNotEmpty).last,
    _kMacOsExecutableDirectory,
    reason: 'QA must run inside the macOS app bundle',
  );
  final plist = File('${executable.parent.parent.path}/$_kInfoPlistName');
  expect(
    plist.existsSync(),
    isTrue,
    reason: 'the running QA app must have an Info.plist',
  );
  final result = await Process.run(_kPlistBuddy, <String>[
    '-c',
    _kBundleIdPlistKey,
    plist.path,
  ]);
  expect(
    result.exitCode,
    0,
    reason:
        'could not read the running app bundle identifier: ${result.stderr}',
  );
  final actual = (result.stdout as String).trim();
  expect(
    actual,
    _kQaBundleId,
    reason: 'native notification QA may touch only the isolated QA app',
  );
  qa.note('qa-bundle-verified', <String, Object?>{
    'bundle_id': actual,
    'executable': executable.path,
  });
}

String _fieldText(WidgetTester tester, int index) =>
    tester.widget<TextField>(_setupFields.at(index)).controller!.text;

String? _since(Map<String, Object?> request) =>
    (request['query'] as Map<String, String>?)?['since'];

void _triggerSync(WidgetTester tester) =>
    appContainer(tester).read(syncControllerProvider.notifier).triggerNow();

Future<List<ActiveNotification>> _scopedNotifications(
  FlutterLocalNotificationsPlugin plugin,
) async {
  final all = await plugin.getActiveNotifications();
  return all
      .where((item) => _kScopedNotificationIds.contains(item.id))
      .toList(growable: false);
}

Future<ActiveNotification> _waitForNativeAlert(
  WidgetTester tester,
  FlutterLocalNotificationsPlugin plugin,
  int id, {
  String? matchingBody,
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < _kNativeWait) {
    final matches = (await _scopedNotifications(plugin))
        .where(
          (item) =>
              item.id == id &&
              (matchingBody == null ||
                  item.body?.contains(matchingBody) == true),
        )
        .toList(growable: false);
    if (matches.length == 1) return matches.single;
    await tester.pump(kPoll);
  }
  fail('native delivered notification $id not seen within $_kNativeWait');
}

void _expectAlert(
  ActiveNotification item, {
  required int id,
  required Uri origin,
  required QaSession session,
  required String message,
}) {
  expect(item.id, id);
  expect(item.body, contains(message));
  final tap = NotificationTap.decode(item.payload);
  expect(tap, isNotNull, reason: 'native payload must be decodable');
  expect(tap!.transitionId, id);
  expect(tap.sessionKey, session.key);
  expect(tap.project, '${QaSession.projectRoot}${session.id}');
  expect(tap.host, QaSession.host);
  expect(tap.serverUrl, NotificationTap.safeServerUrl('$origin'));
}

Map<String, Object?> _notificationRecord(ActiveNotification item) =>
    <String, Object?>{
      'id': item.id,
      'title': item.title,
      'body': item.body,
      'payload': item.payload,
    };

/// 테스트 바인딩의 공개 BinaryMessenger delegate로 모든 채널 호출을 실제
/// 네이티브 플러그인에 그대로 전달하며 ID별 cancel/show 순서만 기록한다.
/// 응답을 만들거나 운영 AlertNotifier/로컬 발신 Provider를 대체하지 않는다.
class _NativeNotificationCallSpy {
  _NativeNotificationCallSpy._(this._messenger);

  static const String _channel = 'dexterous.com/flutter/local_notifications';
  static const String _show = 'show';
  static const String _cancel = 'cancel';
  static const StandardMethodCodec _codec = StandardMethodCodec();

  final TestDefaultBinaryMessenger _messenger;
  final Map<int, List<String>> _operations = <int, List<String>>{};

  static _NativeNotificationCallSpy install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final spy = _NativeNotificationCallSpy._(messenger);
    messenger.setMockMessageHandler(_channel, (ByteData? message) {
      if (message != null) {
        final call = _codec.decodeMethodCall(message);
        final args = call.arguments;
        // macOS SDK 22.3은 cancel 인자를 정수로, show 인자를 id 필드가
        // 든 맵으로 보낸다. 두 모양을 실제 채널 인코딩에서 읽는다.
        final int? id = switch (args) {
          int value => value,
          Map<Object?, Object?> value when value['id'] is int =>
            value['id'] as int,
          _ => null,
        };
        if ((_show == call.method || _cancel == call.method) && id != null) {
          spy._operations.putIfAbsent(id, () => <String>[]).add(call.method);
        }
      }
      return messenger.delegate.send(_channel, message);
    });
    return spy;
  }

  List<String> operationsFor(int id) =>
      List<String>.unmodifiable(_operations[id] ?? const <String>[]);

  void dispose() => _messenger.setMockMessageHandler(_channel, null);
}

/// 서버의 응답 필드는 `contracts/dashboard-protocol.v1.json`에서 직접 만든다.
/// 테스트 대상의 DTO 직렬화 함수를 응답 생성 오라클로 재사용하지 않는다.
class _ScriptedSyncServer {
  _ScriptedSyncServer._(
    this._socket,
    this._qa, {
    required this.name,
    required this.token,
    required this.language,
    required this.snapshotCursor,
    required this.session,
  });

  static Future<_ScriptedSyncServer> start(
    QaRun qa, {
    required String name,
    required String token,
    required String language,
    required int snapshotCursor,
    required QaSession session,
  }) async {
    final socket = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      _kServerPortAuto,
    );
    final server = _ScriptedSyncServer._(
      socket,
      qa,
      name: name,
      token: token,
      language: language,
      snapshotCursor: snapshotCursor,
      session: session,
    );
    socket.listen((request) => unawaited(server._answer(request)));
    qa.note('scripted-server-started', <String, Object?>{
      'name': name,
      'url': '${server.baseUrl}',
    });
    return server;
  }

  final HttpServer _socket;
  final QaRun _qa;
  final String name;
  final String token;
  final String language;
  final int snapshotCursor;
  final QaSession session;
  final List<Map<String, Object?>> _alerts = <Map<String, Object?>>[];
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  bool replayLatestOnce = false;

  Uri get baseUrl => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _socket.port,
  );

  List<Map<String, Object?>> get syncRequests => requests
      .where((request) => request['path'] == kSyncPath)
      .toList(growable: false);

  void addAlert({
    required int id,
    required String fromState,
    required String toState,
    required String message,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _alerts.add(<String, Object?>{
      'id': id,
      'session_key': session.key,
      'from_state': fromState,
      'to_state': toState,
      'source': QaSession.source,
      'project': '${QaSession.projectRoot}${session.id}',
      'host': QaSession.host,
      'message': message,
      'occurred_at': now,
      'created_at': now,
    });
    _qa.note('scripted-alert-added', <String, Object?>{
      'server': name,
      'id': id,
      'message': message,
    });
  }

  Future<void> _answer(HttpRequest request) async {
    final entry = <String, Object?>{
      't_ms': _qa.elapsedMs,
      'server': name,
      'method': request.method,
      'path': request.uri.path,
      'query': request.uri.queryParameters,
      'authorization': request.headers.value(HttpHeaders.authorizationHeader),
    };
    requests.add(entry);
    final response = request.response..persistentConnection = false;
    try {
      if (request.uri.path != kSyncPath) {
        entry['status'] = HttpStatus.notFound;
        response.statusCode = HttpStatus.notFound;
        response.write('{"error":"not found"}');
      } else if (entry['authorization'] != 'Bearer $token') {
        entry['status'] = HttpStatus.unauthorized;
        response.statusCode = HttpStatus.unauthorized;
        response.write('{"error":"unauthorized"}');
      } else {
        final since = int.tryParse(request.uri.queryParameters['since'] ?? '');
        final snapshot = since == null;
        final replay = replayLatestOnce;
        replayLatestOnce = false;
        final sent = snapshot
            ? <Map<String, Object?>>[]
            : _alerts
                  .where(
                    (alert) =>
                        (alert['id']! as int) > since ||
                        (replay && alert == _alerts.last),
                  )
                  .toList(growable: false);
        final cursor = snapshot
            ? snapshotCursor
            : sent.isEmpty
            ? since
            : sent
                  .map((alert) => alert['id']! as int)
                  .reduce((left, right) => left > right ? left : right);
        final now = DateTime.now().millisecondsSinceEpoch;
        final body = <String, Object?>{
          'protocol_version': _kProtocolVersion,
          'reset': snapshot,
          'cursor': cursor,
          'has_more': false,
          'server_time': now,
          'pruned_below_id': _kPrunedBelowId,
          'stall_ms': _kStallMs,
          'mute_until': null,
          'ui_lang': language,
          'seen': const <Object?>[],
          'hook_skew': const <Object?>[],
          'sessions': snapshot
              ? <Object?>[session.toJson(now)]
              : const <Object?>[],
          'transitions': sent,
          'sessions_touched': snapshot || sent.isEmpty
              ? const <String>[]
              : <String>[session.key],
        };
        entry['status'] = HttpStatus.ok;
        entry['reset'] = snapshot;
        entry['cursor'] = cursor;
        entry['served_ids'] = sent.map((alert) => alert['id']! as int).toList();
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(body));
      }
      _qa.note('scripted-request', entry);
      await response.close();
    } on Exception catch (error) {
      _qa.note('scripted-response-error', <String, Object?>{
        'server': name,
        'error': '$error',
      });
    }
  }

  Future<void> close() => _socket.close(force: true);
}

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/platform/local_notifications_native.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/state/notify_bridge_io.dart' as bridge;
import 'package:my_dashboard/src/state/notify_provider.dart';

const _notifications = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);
const _resident = MethodChannel(kResidentChannelName);
const _transitionId = 0x8000002a;
const _osNotificationId = 42;
const _tap = NotificationTap(
  sessionKey: 'codex:s1',
  project: '/work/my-dashboard',
  host: 'work-mac',
  transitionId: _transitionId,
  serverUrl: 'https://example.test',
);

Map<String, Object?> _response({String? payload, int id = _osNotificationId}) =>
    {'notificationId': id, 'notificationResponseType': 0, 'payload': payload};

Future<void> _sendResponse({String? payload, int id = _osNotificationId}) {
  final done = Completer<void>();
  ui.channelBuffers.push(
    _notifications.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        'didReceiveNotificationResponse',
        _response(payload: payload, id: id),
      ),
    ),
    (_) => done.complete(),
  );
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<MethodCall> residentCalls;
  Map<String, Object?>? launchResponse;
  bool granted = true;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    resetNotificationTapStateForTest();
    calls = [];
    residentCalls = [];
    launchResponse = null;
    granted = true;
    messenger.setMockMethodCallHandler(_notifications, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => granted,
        'getNotificationAppLaunchDetails' => {
          'notificationLaunchedApp': launchResponse != null,
          'notificationResponse': launchResponse,
        },
        'checkPermissions' => {'isEnabled': false},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(_resident, (call) async {
      residentCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    resetNotificationTapStateForTest();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_notifications, null);
    messenger.setMockMethodCallHandler(_resident, null);
  });

  test('Linux 대상에서는 알림 프로브와 발신이 네이티브 채널을 호출하지 않는다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    await probeNotificationSupport();
    await bridge.showLocalNotification(
      const NotifyPayload(id: _transitionId, title: '대기', body: '입력 필요'),
    );

    expect(supportsLocalNotifications, isFalse);
    expect(currentNotificationBackend, NotificationBackend.none);
    expect(calls, isEmpty);
  });

  test('일반 배너 클릭은 대상과 원본 전이를 전달하고 대시보드를 앞으로 띄우지 않는다', () async {
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);
    await probeNotificationSupport();

    await _sendResponse(payload: _tap.encode());

    expect(received.single.sessionKey, _tap.sessionKey);
    expect(received.single.project, _tap.project);
    expect(received.single.host, _tap.host);
    expect(received.single.transitionId, _transitionId);
    expect(residentCalls, isEmpty);
  });

  test('핸들러 등록 후 냉시작 정보를 조회해도 바로 전달하고 재프로브는 반복하지 않는다', () async {
    launchResponse = _response(payload: _tap.encode());
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);

    await probeNotificationSupport();
    await probeNotificationSupport();

    expect(received, hasLength(1));
    expect(received.single.transitionId, _transitionId);
    expect(
      calls.where((call) => call.method == 'getNotificationAppLaunchDetails'),
      hasLength(1),
    );
  });

  test('냉시작 조회와 일반 클릭이 겹쳐도 같은 클릭을 두 번 전달하지 않는다', () async {
    final launch = Completer<Map<String, Object?>>();
    final querying = Completer<void>();
    messenger.setMockMethodCallHandler(_notifications, (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'getNotificationAppLaunchDetails') {
        querying.complete();
        return launch.future;
      }
      return null;
    });
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);
    final probing = probeNotificationSupport();
    await querying.future;

    await _sendResponse(payload: _tap.encode());
    launch.complete({
      'notificationLaunchedApp': true,
      'notificationResponse': _response(payload: _tap.encode()),
    });
    await probing;

    expect(received, hasLength(1));
  });

  test('이미 전달한 일반 클릭은 사용자가 같은 배너를 다시 눌러 재시도할 수 있다', () async {
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);
    await probeNotificationSupport();

    await _sendResponse(payload: _tap.encode());
    await _sendResponse(payload: _tap.encode());

    expect(received, hasLength(2));
  });

  test('등록 전 냉시작 뒤의 마지막 일반 클릭 하나만 보존한다', () async {
    launchResponse = _response(payload: _tap.encode());
    await probeNotificationSupport();
    await _sendResponse(payload: _tap.encode());
    await _sendResponse(payload: 'claude-code:second-session', id: 43);
    final received = <NotificationTap>[];

    registerNotificationTapHandler(received.add);

    expect(received.map((tap) => tap.sessionKey), [
      'claude-code:second-session',
    ]);
    expect(received.last.legacy, isTrue);
    expect(received.last.transitionId, isNull);
  });

  test('현재 발신 권한이 거부되어도 이미 받은 냉시작 알림을 전달한다', () async {
    granted = false;
    launchResponse = _response(payload: _tap.encode());
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);

    await probeNotificationSupport();

    expect(received.single.sessionKey, 'codex:s1');
    expect(currentNotificationBackend, NotificationBackend.none);
  });

  test('이전 배너에는 OS id가 있어도 전이 id를 추정하지 않는다', () async {
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);
    await probeNotificationSupport();

    await _sendResponse(payload: 'codex:old-session');
    await _sendResponse(
      payload: '{"version":77,"session_key":"codex:invalid"}',
    );

    expect(received, hasLength(1));
    expect(received.single.legacy, isTrue);
    expect(received.single.transitionId, isNull);
  });

  test('자기 테스트와 일시 알림의 빈 payload는 대상 없는 클릭으로 전달한다', () async {
    final received = <NotificationTap>[];
    registerNotificationTapHandler(received.add);
    await probeNotificationSupport();

    await _sendResponse();
    await _sendResponse(payload: '');

    expect(received, hasLength(2));
    expect(received.every((tap) => tap.sessionKey == null), isTrue);
    expect(residentCalls, isEmpty);
  });

  test('콜백 등록을 기다리는 동안 마지막 클릭 하나만 보존한다', () async {
    await probeNotificationSupport();
    for (var id = 1; id <= 100; id++) {
      await _sendResponse(payload: 'codex:session-$id', id: id);
    }
    final received = <NotificationTap>[];

    registerNotificationTapHandler(received.add);

    expect(received, hasLength(1));
    expect(received.last.sessionKey, 'codex:session-100');
  });

  test('발신 payload에 원래 대상과 서버를 저장하고 OS id만 32비트로 제한한다', () async {
    await probeNotificationSupport();
    calls.clear();

    await showNotification(
      title: '대기 알림',
      body: '입력 필요',
      sessionKey: _tap.sessionKey,
      project: _tap.project,
      host: _tap.host,
      id: _transitionId,
      serverUrl: _tap.serverUrl,
    );

    expect(calls.map((call) => call.method), <String>['cancel', 'show']);
    expect(calls.first.arguments, _osNotificationId);
    final shown =
        calls.singleWhere((call) => call.method == 'show').arguments as Map;
    final payload = NotificationTap.decode(shown['payload'] as String)!;
    expect(shown['id'], _osNotificationId);
    expect(payload.transitionId, _transitionId);
    expect(payload.project, _tap.project);
    expect(payload.host, _tap.host);
    expect(payload.serverUrl, _tap.serverUrl);
  });

  test('실제 발신 provider는 설정된 서버 주소만 전달하고 인증 토큰은 담지 않는다', () async {
    final container = ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(
            baseUrl: Uri.parse('https://example.test/dashboard'),
            clientToken: 'must-not-enter-notification',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await probeNotificationSupport();
    calls.clear();

    await container.read(localNotifyFnProvider)(
      const NotifyPayload(
        id: _transitionId,
        title: '작업 알림',
        body: '입력 필요',
        sessionKey: 'codex:s1',
        project: '/work/my-dashboard',
        host: 'work-mac',
      ),
    );

    final shown =
        calls.singleWhere((call) => call.method == 'show').arguments as Map;
    final raw = shown['payload'] as String;
    final payload = NotificationTap.decode(raw)!;
    expect(payload.serverUrl, 'https://example.test/dashboard');
    expect(payload.project, '/work/my-dashboard');
    expect(payload.host, 'work-mac');
    expect(raw, isNot(contains('must-not-enter-notification')));
  });

  test('비동기 발신 도중 주소가 바뀌어도 배너에 원래 서버를 기록한다', () async {
    final container = ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(baseUrl: Uri.parse('https://new.example.test')),
        ),
      ],
    );
    addTearDown(container.dispose);
    await probeNotificationSupport();
    calls.clear();

    await container.read(localNotifyFnProvider)(
      const NotifyPayload(
        id: _transitionId,
        title: '이전 서버 알림',
        body: '입력 필요',
        sessionKey: 'codex:old',
        serverUrl: 'https://old.example.test',
      ),
    );

    final shown = calls.singleWhere((call) => call.method == 'show').arguments as Map;
    final tap = NotificationTap.decode(shown['payload'] as String)!;
    expect(tap.serverUrl, 'https://old.example.test');
  });
}

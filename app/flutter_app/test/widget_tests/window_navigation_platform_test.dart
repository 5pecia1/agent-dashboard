import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/platform/window_navigation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kWindowNavigationChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('macOS 이외의 플랫폼에서는 네이티브 채널을 호출하지 않는다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });

    expect(supportsWindowNavigation, isFalse);
    expect((await scanWindows())['complete'], isFalse);
    expect(await focusWindow('token'), kWindowFocusUnconfirmed);
    await openWindowAccessibilitySettings();
    expect(calls, 0);
  });

  test('조회 결과와 창 토큰을 같은 채널 계약으로 전달한다', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case kWindowScanMethod:
          return <String, Object?>{
            'trusted': true,
            'complete': true,
            'localHost': 'dev.local',
            'windows': <Object?>[
              <String, Object?>{
                'token': 'opaque-token',
                'bundleId': 'com.microsoft.VSCode',
                'appName': 'Code',
                'title': 'my-dashboard',
                'minimized': true,
              },
            ],
          };
        case kWindowFocusMethod:
          return 'focused';
        default:
          return null;
      }
    });

    final snapshot = await scanWindows();
    expect(snapshot['trusted'], isTrue);
    expect(snapshot['localHost'], 'dev.local');
    expect((snapshot['windows']! as List<Object?>), hasLength(1));
    expect(await focusWindow('opaque-token'), 'focused');
    await openWindowAccessibilitySettings();
    expect(calls.map((call) => call.method), <String>[
      kWindowScanMethod,
      kWindowFocusMethod,
      kWindowOpenSettingsMethod,
    ]);
    expect(calls[1].arguments, <String, Object?>{
      kWindowTokenArgument: 'opaque-token',
    });
  });

  test('권한 실패나 플러그인 부재를 성공으로 해석하지 않는다', () async {
    for (final error in <Exception>[
      MissingPluginException(),
      PlatformException(code: 'unavailable'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => throw error);
      final snapshot = await scanWindows();
      expect(snapshot['trusted'], isFalse);
      expect(snapshot['complete'], isFalse);
      expect(snapshot['windows'], isEmpty);
      expect(await focusWindow('token'), kWindowFocusUnconfirmed);
      await openWindowAccessibilitySettings();
    }
  });

  test('대상 앱이 정해진 조회는 bundleId를 전달하고 전체 조회는 생략한다', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'trusted': true,
        'complete': true,
        'localHost': 'dev.local',
        'windows': <Object?>[],
      };
    });

    await scanWindows(bundleId: ' com.microsoft.VSCode ');
    await scanWindows();
    await scanWindows(bundleId: '  ');

    expect(calls.map((call) => call.method), everyElement(kWindowScanMethod));
    expect(calls[0].arguments, <String, Object?>{
      kWindowBundleIdArgument: 'com.microsoft.VSCode',
    });
    expect(calls[1].arguments, isNull);
    expect(calls[2].arguments, isNull);
  });

  test('빈 토큰으로 창 전환을 요청하지 않는다', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return 'focused';
    });
    expect(await focusWindow(''), kWindowFocusUnconfirmed);
    expect(calls, 0);
  });
}

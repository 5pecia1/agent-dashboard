/// [resolveProbeResult]의 분기표를 실제 플러그인/프로세스 호출 없이
/// 검증한다 — 순수 함수라 `PrimaryProbeOutcome`과 `osascriptSucceeded`만
/// 주면 된다. 이 파일에서는 실제 알림/osascript를 호출하지 않는다.
/// 프로브·발신·클릭의 채널 통합 검증은 `local_notification_tap_test.dart`가
/// 대상 플랫폼과 네이티브 채널을 대역으로 설정해 담당한다.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/platform/local_notifications_native.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveProbeResult', () {
    test('granted면 1차 백엔드이고 권한 거부가 아니다', () {
      final result = resolveProbeResult(
        PrimaryProbeOutcome.granted,
        osascriptSucceeded: false,
      );
      expect(result.backend, NotificationBackend.flutterLocalNotifications);
      expect(result.permissionDenied, isFalse);
    });

    test(
      'granted면 osascript 결과와 무관하게 1차 백엔드다(애초에 시도되지 않아야 하는 값이지만 방어적으로 확인)',
      () {
        final result = resolveProbeResult(
          PrimaryProbeOutcome.granted,
          osascriptSucceeded: true,
        );
        expect(result.backend, NotificationBackend.flutterLocalNotifications);
        expect(result.permissionDenied, isFalse);
      },
    );

    test('denied면 osascript로 접지 않는다 — backend는 none, permissionDenied는 true', () {
      final result = resolveProbeResult(
        PrimaryProbeOutcome.denied,
        osascriptSucceeded: true,
      );
      expect(
        result.backend,
        NotificationBackend.none,
        reason: '거부된 권한을 osascript로 우회하지 않는다',
      );
      expect(result.permissionDenied, isTrue);
    });

    test('denied면 osascript가 실패해도 그대로 none + permissionDenied다', () {
      final result = resolveProbeResult(
        PrimaryProbeOutcome.denied,
        osascriptSucceeded: false,
      );
      expect(result.backend, NotificationBackend.none);
      expect(result.permissionDenied, isTrue);
    });

    test('unavailable(플러그인 고장)이고 osascript가 성공하면 2차 백엔드로 접힌다', () {
      final result = resolveProbeResult(
        PrimaryProbeOutcome.unavailable,
        osascriptSucceeded: true,
      );
      expect(result.backend, NotificationBackend.osascript);
      expect(result.permissionDenied, isFalse);
    });

    test('unavailable이고 osascript도 실패하면 none이고 권한 거부는 아니다', () {
      final result = resolveProbeResult(
        PrimaryProbeOutcome.unavailable,
        osascriptSucceeded: false,
      );
      expect(result.backend, NotificationBackend.none);
      expect(
        result.permissionDenied,
        isFalse,
        reason: '플러그인 고장은 권한 거부와 다르다 — 설정 화면에 잘못된 배너를 띄우면 안 된다',
      );
    });
  });

  group('bringWindowToFront', () {
    const channel = MethodChannel(kResidentChannelName);
    final binding = TestDefaultBinaryMessengerBinding.instance;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('기존 상주 채널의 showWindow 메서드를 정확히 한 번 호출한다', () async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await bringWindowToFront();

      expect(calls, hasLength(1));
      expect(calls.single.method, kResidentShowWindowMethod);
      expect(calls.single.arguments, isNull);
    });

    test('hideResidentWindow는 같은 채널의 hideWindow 메서드를 정확히 한 번 호출한다', () async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await hideResidentWindow();

      expect(calls, hasLength(1));
      expect(calls.single.method, kResidentHideWindowMethod);
      expect(calls.single.arguments, isNull);
    });
  });
}

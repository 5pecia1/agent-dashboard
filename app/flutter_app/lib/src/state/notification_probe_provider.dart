/// macOS 알림 프로브 결과(권한 거부/폴백 여부)와 재프로브·시스템 설정
/// 열기 동작을 화면(`setup_page.dart`)에 노출하는 시임.
///
/// `capability_provider.dart`/`resident_provider.dart`와 같은 3계층:
/// 함수 타입/값 -> `Provider` -> 얇은 함수(`platform/local_notifications_*.dart`).
/// `desktopFeatureStatus`(ChangeNotifier)를 구독해 화면이 실시간으로
/// 반응하게 만드는 방식도 `capabilityCheckFnProvider`와 동일하다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/platform/feature_status.dart';
import 'package:my_dashboard/src/platform/local_notifications_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/local_notifications_web.dart'
    as bridge;

/// 알림 프로브를 다시 부르는 함수 모양. 부팅 시퀀스가 최소 한 번 부르고,
/// 설정 화면의 "테스트 알림" 버튼이 다시 부른다(재호출 계약은
/// `local_notifications_native.dart` 파일 상단 문서 참고) — 사용자가
/// 시스템 설정에서 권한을 켠 뒤 앱을 재시작하지 않고도 복구되게 한다.
typedef NotificationReprobeFn = Future<void> Function();

/// 테스트는 이 Provider를 override해 실제 플러그인/프로세스 호출 없이
/// 재프로브 호출 여부만 본다.
final Provider<NotificationReprobeFn> notificationReprobeProvider =
    Provider<NotificationReprobeFn>((ref) => bridge.probeNotificationSupport);

/// macOS 알림 권한이 사용자/시스템에 의해 명시적으로 거부됐는가.
/// true면 알림은 전혀 나가지 않는다(osascript로도 접지 않는다) — 설정
/// 화면이 이 값을 읽어 경고 배너를 띄운다.
final Provider<bool> notificationPermissionDeniedProvider = Provider<bool>((ref) {
  desktopFeatureStatus.addListener(ref.invalidateSelf);
  ref.onDispose(() => desktopFeatureStatus.removeListener(ref.invalidateSelf));
  return desktopFeatureStatus.notifyPermissionDenied;
});

/// 지금 선택된 백엔드가 osascript 폴백인가. true면 알림은 뜨지만 탭해도
/// 앱으로 돌아오지 않는다(완료 기준 (d)) — 설정 화면이 이 값을 읽어 한
/// 줄 고지한다.
final Provider<bool> notificationUsesOsascriptFallbackProvider = Provider<bool>((ref) {
  desktopFeatureStatus.addListener(ref.invalidateSelf);
  ref.onDispose(() => desktopFeatureStatus.removeListener(ref.invalidateSelf));
  return bridge.currentNotificationBackend == bridge.NotificationBackend.osascript;
});

/// macOS 시스템 설정의 알림 패널을 여는 함수 모양("시스템 설정 열기" 버튼).
typedef OpenNotificationSettingsFn = Future<void> Function();

/// 테스트는 이 Provider를 override해 실제 `open` 프로세스 호출 없이 버튼
/// 동작만 본다.
final Provider<OpenNotificationSettingsFn> openNotificationSettingsProvider =
    Provider<OpenNotificationSettingsFn>((ref) => bridge.openNotificationSettings);

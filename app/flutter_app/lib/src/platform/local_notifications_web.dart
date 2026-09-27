/// `local_notifications_native.dart`의 웹 거울 — 항상 no-op이다.
///
/// 완료 기준 (d)와 같은 자리: 웹 런타임에는 macOS 전용 알림 백엔드
/// (`flutter_local_notifications`의 Darwin 구현/`osascript`) 자체가 없다.
/// 알림은 `notify_bridge_web.dart`를 거쳐 이미 no-op으로 접히지만, 이
/// 파일이 따로 필요한 이유는 호출 지점이 다르다 —
/// `feature_setup.dart`의 부팅 시퀀스는 `notify_provider.dart`의
/// io/web 분기 밖에서 조건부 임포트로 `probeNotificationSupport`를
/// 부른다. 이 파일이 없으면 그 조건부 임포트가 `dart:io`를 쓰는
/// `local_notifications_native.dart`를 웹 컴파일 타깃에도 끌고 들어가
/// 빌드가 깨진다.
library;

import 'package:my_dashboard/src/data/notification_tap.dart';

export 'package:my_dashboard/src/data/notification_tap.dart'
    show NotificationTap, NotificationTapHandler;

/// [local_notifications_native.dart]와 이름/모양을 맞춘 거울. 웹에서는
/// 절대 [NotificationBackend.flutterLocalNotifications]나
/// [NotificationBackend.osascript]가 되지 않는다.
enum NotificationBackend { flutterLocalNotifications, osascript, none }

/// 웹은 항상 [NotificationBackend.none]이다.
NotificationBackend get currentNotificationBackend => NotificationBackend.none;

/// no-op. 핸들러를 저장하지 않는다 — 부를 대상이 없다.
void registerNotificationTapHandler(NotificationTapHandler handler) {}

/// no-op. `desktopFeatureStatus.notifyLocal`은 기본값 false로 남는다.
Future<void> probeNotificationSupport() async {}

/// no-op. `id`는 `local_notifications_native.dart`와 시그니처를 맞추기
/// 위한 거울일 뿐 여기서는 쓰이지 않는다(조건부 임포트 쌍이라 반드시
/// 동일해야 한다).
Future<void> showNotification({
  required String title,
  required String body,
  String? sessionKey,
  int? id,
  String? project,
  String? host,
  String? serverUrl,
}) async {}

/// no-op. 웹에는 macOS 시스템 설정이 없다 — 배너 자체가 `notifyPermissionDenied`
/// 가 항상 false인 웹에서는 뜨지 않으므로 이 함수가 실제로 불릴 일은 없다.
Future<void> openNotificationSettings() async {}

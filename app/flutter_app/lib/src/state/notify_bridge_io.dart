/// `notify_provider.dart`의 데스크톱(macOS) 브리지.
///
/// T16 이전에는 이 파일이 `osascript display notification`을 직접
/// 불렀다. 이제는 백엔드 선택/클릭 딥링크를 다루는
/// `platform/local_notifications_native.dart`(1차: `flutter_local_notifications`,
/// 2차 폴백: `osascript`)로 그대로 위임한다 — `notifyProvider`가 물리는
/// 중재 시임(억제/owner 판정)은 그대로 이 파일 앞에 있고, 이 파일은
/// "억제되지 않았을 때 실제로 어떻게 띄우는가"만 계속 책임진다.
///
/// macOS가 아닌 데스크톱(linux/windows)에서는 아직 알림 백엔드가 없다 —
/// 조용히 no-op으로 접는다(`local_notifications_native.dart`의
/// `probeNotificationSupport`가 같은 분기를 프로브 단계에서 이미 정한다).
/// 웹은 이 파일이 아니라 `notify_bridge_web.dart`가 맡는다.
library;

import 'package:my_dashboard/src/platform/local_notifications_native.dart' as local_notifications;
import 'package:my_dashboard/src/state/notify_provider.dart' show NotifyPayload;

Future<void> showLocalNotification(NotifyPayload payload, {String? serverUrl}) async {
  if (!local_notifications.supportsLocalNotifications) return;
  await local_notifications.showNotification(
    title: payload.title,
    body: payload.body,
    sessionKey: payload.sessionKey,
    id: payload.id,
    project: payload.project,
    host: payload.host,
    serverUrl: serverUrl,
  );
}

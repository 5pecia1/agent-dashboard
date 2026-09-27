/// `notify_provider.dart`의 웹 브리지 — 항상 no-op이다.
///
/// 완료 기준 (d): 웹 런타임에서는 알림이 이 경로로 절대 나가지 않는다.
/// 알림은 push 서비스워커(`push_provider.dart`가 구독을 등록하는 FCM
/// 채널)로만 흐른다. `notify_provider.dart`의 중재 규칙이 이미 웹이면
/// [notifyProvider]를 호출조차 못 하게 접지만, 그 규칙이 없더라도 이 함수
/// 자체가 아무 일도 하지 않아야 한다는 게 이 파일의 존재 이유다.
library;

import 'package:my_dashboard/src/state/notify_provider.dart' show NotifyPayload;

Future<void> showLocalNotification(NotifyPayload payload, {String? serverUrl}) async {}

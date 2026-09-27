/// push 쪽에서 **앱으로 들어오는** 신호의 어휘 (TASK D-app 배선 (4)).
///
/// 지금까지 push 배선은 한 방향뿐이었다 — 앱이 토큰을 등록하는 쪽
/// (`web_push.dart`/`apns_push.dart`). 반대 방향, 즉 "알림이 도착했다/
/// 사용자가 알림을 눌렀다"를 앱에게 알려주는 통로가 비어 있었다
/// (`sync_controller.dart` 상단이 "그 사건을 알려줄 이벤트 소스가 아예
/// 없다"고 정직하게 남겨 둔 자리다). 이 파일이 그 통로의 값이다.
///
/// 두 호스트가 같은 값으로 모인다:
///
/// * **웹** — `web/push_sw.js`가 `BroadcastChannel('dashboard')`로 던지는
///   `{type:'notification-click', refresh, link, session_key, transition_id}`
///   메시지(`push_signal_web.dart`).
/// * **macOS** — `FirebaseMessaging.onMessageOpenedApp` / 냉시작
///   `getInitialMessage()`가 주는 `RemoteMessage.data`
///   (`apns_push_native.dart`가 [emitPushSignal]로 흘려 넣는다).
///
/// 받는 쪽(`app.dart`의 `_AppHome`)은 재조회 힌트와 사용자의 클릭을 구분한다.
/// 클릭 시 macOS는 연결된 작업 창으로 이동하고, 웹은 세션 상세를 연다.
library;

import 'package:flutter/foundation.dart' show immutable;

/// 서비스 워커 -> 페이지 통로 이름. `web/push_sw.js`의
/// `BROADCAST_CHANNEL_NAME`과 반드시 같다(`web_push.dart`의
/// [kPushBroadcastChannel]과 같은 값이지만, 이 파일은 그쪽에 의존하지
/// 않는다 — 등록 경로와 수신 경로는 서로 독립이어야 한다).
const String kPushSignalChannelName = 'dashboard';

/// `push_sw.js`의 `postMessage({type: ...})`. 지금은 하나뿐이다.
const String kPushSignalNotificationClick = 'notification-click';

/// 정본 `push.data_keys`. 서비스 워커와 `RemoteMessage.data`가 공유한다.
const String kPushSignalSessionKeyField = 'session_key';
const String kPushSignalLinkField = 'link';
const String kPushSignalTypeField = 'type';
const String kPushSignalRefreshField = 'refresh';
const String kPushSignalTransitionIdField = 'transition_id';
const String kPushSignalProjectField = 'project';
const String kPushSignalHostField = 'host';

/// 정본 `push.data_keys.link.format`이 `/?session=<session_key>`이므로,
/// `session_key`가 비어 온 신호에서도 이 쿼리 파라미터로 세션을 복구한다.
const String kPushLinkSessionQueryParam = 'session';

/// push 쪽에서 들어온 신호 하나.
@immutable
class PushSignal {
  const PushSignal({
    required this.type,
    this.sessionKey,
    this.link = '',
    this.refresh = true,
    this.transitionId,
    this.project,
    this.host,
  });

  /// [kPushSignalNotificationClick] 등. 모르는 값도 그대로 담는다 —
  /// 받는 쪽이 무시하면 그만이고, 조용히 버리면 진단이 어려워진다.
  final String type;

  /// 신호가 직접 말한 `<source>:<session_id>`. 비어 있을 수 있다.
  final String? sessionKey;

  /// 알림이 열려던 클라이언트 상대 경로(`/?session=<key>`).
  final String link;

  /// 이 신호를 받으면 sync를 즉시 재조회해야 하는가. push는 깨우기
  /// 힌트이므로 기본값은 true다(정본 `push` 절).
  final bool refresh;

  /// 클릭한 배너를 발생시킨 전이. 없으면 최신 전이를 대신 읽음 처리하지 않는다.
  final int? transitionId;

  /// 발신자가 제공한 경우에만 보존하는 알림 발생 당시의 프로젝트·호스트.
  final String? project;
  final String? host;

  /// 실제로 열 세션. [sessionKey]가 비었으면 [link]에서 복구한다.
  String? get resolvedSessionKey {
    final direct = sessionKey;
    if (direct != null && direct.isNotEmpty) return direct;
    return sessionKeyFromPushLink(link);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PushSignal &&
          other.type == type &&
          other.sessionKey == sessionKey &&
          other.link == link &&
          other.refresh == refresh &&
          other.transitionId == transitionId &&
          other.project == project &&
          other.host == host;

  @override
  int get hashCode => Object.hash(type, sessionKey, link, refresh, transitionId, project, host);

  @override
  String toString() => 'PushSignal($type, session: $resolvedSessionKey)';
}

/// `/?session=<session_key>` 모양의 링크에서 세션 키를 꺼낸다. 그 모양이
/// 아니거나 파싱에 실패하면 null(호출자는 딥링크를 하지 않는다).
String? sessionKeyFromPushLink(String link) {
  if (link.isEmpty) return null;
  final Uri uri;
  try {
    uri = Uri.parse(link);
  } on FormatException {
    return null;
  }
  final value = uri.queryParameters[kPushLinkSessionQueryParam];
  return (value != null && value.isNotEmpty) ? value : null;
}

/// `push_sw.js`의 메시지나 `RemoteMessage.data`처럼 **키가 문자열인 느슨한
/// 맵** 하나를 [PushSignal]로 옮긴다. 두 호스트 구현과 테스트가 공유하는
/// 유일한 번역 지점이다 — 모르는 키는 무시하고, 던지지 않는다.
PushSignal pushSignalFromMap(Map<String, Object?> raw) {
  String? stringOf(String key) {
    final Object? value = raw[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  final Object? refreshRaw = raw[kPushSignalRefreshField];
  final Object? transitionRaw = raw[kPushSignalTransitionIdField];
  final transitionId = transitionRaw is int
      ? transitionRaw
      : transitionRaw is String
      ? int.tryParse(transitionRaw, radix: 10)
      : null;
  return PushSignal(
    type: stringOf(kPushSignalTypeField) ?? kPushSignalNotificationClick,
    sessionKey: stringOf(kPushSignalSessionKeyField),
    link: stringOf(kPushSignalLinkField) ?? '',
    // 서비스 워커가 말하지 않았으면 재조회한다 — push는 힌트고 정합성은
    // 언제나 sync가 담보한다.
    refresh: refreshRaw is bool ? refreshRaw : true,
    transitionId: transitionId != null && transitionId > 0 ? transitionId : null,
    project: stringOf(kPushSignalProjectField),
    host: stringOf(kPushSignalHostField),
  );
}

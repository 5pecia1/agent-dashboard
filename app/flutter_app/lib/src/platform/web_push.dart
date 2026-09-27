/// 웹 푸시(FCM) 어휘 — 플랫폼 구현 둘과 `state/push_provider.dart`가 공유한다.
///
/// 값만 있고 실행 경로는 없다. 실제 구현은 조건부 import로 갈린다:
/// `web_push_native.dart`(데스크톱: 전부 "해당 없음")와
/// `web_push_web.dart`(`dart:js_interop`).
///
/// 이 파일이 따로 있는 이유는 순환 import를 피하기 위해서다 — 두 구현이
/// 결과 타입을 알아야 하는데, 그 타입을 `push_provider.dart`에 두면
/// provider -> 구현 -> provider로 돈다.
///
/// **웹 자산과의 계약**: 아래 세 경로 상수는 `web/` 아래 실제 파일 이름과
/// 짝이다. 한쪽만 바꾸면 조용히 깨진다(브라우저는 등록 실패를 예외가 아니라
/// 거절된 Promise로 돌려주고, 우리는 그걸 [WebPushTokenStatus.failed]로
/// 접는다). `app/scripts/web_push_smoke.py`가 같은 상수를 문자열로 다시 적어
/// 실제 브라우저에서 확인한다.
library;

import 'package:flutter/foundation.dart' show immutable;

/// 푸시 표시 전담 서비스 워커. `web/push_sw.js`.
const String kPushServiceWorkerUrl = 'push_sw.js';

/// 그 워커의 scope. app shell SW(scope `/`)와 겹치지 않게 **일부러** 실제
/// 문서가 하나도 없는 경로를 쓴다 — `web/push_sw.js` 상단 주석 참고.
const String kPushServiceWorkerScope = 'push-scope/';

/// Firebase 웹 SDK를 감싼 우리 ESM 어댑터. `web/push_token_bridge.js`.
const String kPushBridgeModuleUrl = 'push_token_bridge.js';

/// 서비스 워커 -> 페이지 신호 통로. `web/push_sw.js`의 같은 이름과 짝이다.
const String kPushBroadcastChannel = 'dashboard';

/// 서버 `dashboard_devices.transport`의 채널 id.
const String kPushTransportFcm = 'fcm';

/// 웹 클라이언트가 스스로 신고하는 `dashboard_devices.platform`.
const String kPushPlatformWeb = 'web';

/// 토큰 취득 시도 하나의 결과 종류.
///
/// 문자열 이름이 `web/push_token_bridge.js`의 `STATUS`와 1:1이다 — 그
/// 파일과 [webPushTokenStatusFromWire]가 유일한 번역 지점이다.
enum WebPushTokenStatus {
  /// 토큰을 받았다.
  acquired,

  /// 알림 권한이 아직 `granted`가 아니다. **여기서 프롬프트를 띄우지
  /// 않는다** — 설정 화면의 명시적 버튼이 [requestWebPushPermission]을
  /// 부른 뒤 다시 시도한다.
  permissionRequired,

  /// 이 브라우저/런타임이 웹 푸시를 지원하지 않거나 서버가 자격증명을
  /// 반만 줬다. 실패가 아니라 "할 수 없음"이다 — 폴링 전용으로 남는다.
  unsupported,

  /// 지원은 되는데 이번 시도가 실패했다(등록 거절, getToken 오류 등).
  failed,
}

/// `push_token_bridge.js`가 돌려준 `status` 문자열을 enum으로 옮긴다.
/// 모르는 값은 [WebPushTokenStatus.failed]다 — 조용히 성공으로 접지 않는다.
WebPushTokenStatus webPushTokenStatusFromWire(String wire) => switch (wire) {
  'acquired' => WebPushTokenStatus.acquired,
  'permission-required' => WebPushTokenStatus.permissionRequired,
  'unsupported' => WebPushTokenStatus.unsupported,
  _ => WebPushTokenStatus.failed,
};

/// 토큰 취득 시도 하나의 결과.
@immutable
class WebPushTokenResult {
  const WebPushTokenResult(this.status, {this.token, this.detail = ''});

  const WebPushTokenResult.acquired(String this.token)
    : status = WebPushTokenStatus.acquired,
      detail = '';

  const WebPushTokenResult.unsupported([this.detail = ''])
    : status = WebPushTokenStatus.unsupported,
      token = null;

  const WebPushTokenResult.failed([this.detail = ''])
    : status = WebPushTokenStatus.failed,
      token = null;

  final WebPushTokenStatus status;

  /// [WebPushTokenStatus.acquired]일 때만 채워진다.
  final String? token;

  /// 진단용 사유. 사용자에게 그대로 보여주지 않는다(i18n 대상이 아니다).
  final String detail;

  bool get isAcquired =>
      status == WebPushTokenStatus.acquired &&
      (token != null && token!.isNotEmpty);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebPushTokenResult &&
          other.status == status &&
          other.token == token &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(status, token, detail);

  @override
  String toString() =>
      'WebPushTokenResult($status${detail.isEmpty ? '' : ', $detail'})';
}

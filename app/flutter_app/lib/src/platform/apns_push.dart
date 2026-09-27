/// APNs 경유 FCM 등록(macOS 상주 앱) 어휘 — 플랫폼 구현 둘과
/// `state/push_provider.dart`가 공유한다.
///
/// `web_push.dart`와 정확히 같은 자리·같은 모양이다(값만 있고 실행 경로는
/// 없다). 실제 구현은 조건부 import로 갈린다: `apns_push_native.dart`
/// (macOS: `firebase_core` + `firebase_messaging`)와 `apns_push_web.dart`
/// (웹: 전부 "해당 없음"). 이 파일이 따로 있는 이유도 같다 — 결과 타입을
/// `push_provider.dart`에 두면 provider -> 구현 -> provider로 순환한다.
///
/// **채널은 여전히 FCM 하나다.** Apple 대상이라고 APNs로 직접 쏘지 않는다 —
/// 서버는 같은 FCM HTTP v1 엔드포인트·자격증명을 쓰고, `transport` 값만
/// [kPushTransportFcmApns]로 갈린다(정본 `push.channels.fcm-apns`,
/// dashboard-server `push/transport.ts`의 `TRANSPORT_IDS`). 그래서 이 앱이 서버에
/// 등록하는 것도 APNs device token이 아니라 **FCM 등록 토큰**이다 — APNs는
/// 그 토큰을 만들기 위해 Firebase SDK가 내부적으로 거치는 경로일 뿐이다.
///
/// **웹은 이 경로를 절대 타지 않는다.** `push_token_bridge.js` + 벤더링한
/// Firebase JS SDK가 웹의 유일한 경로고, `firebase_messaging` 플러그인은
/// 웹에서 초기화조차 하지 않는다(서비스 워커가 셋으로 늘어나는 것을 막는
/// 계약 — `web/push_sw.js` 상단 주석과 `app/scripts/web_push_smoke.py`).
library;

import 'package:flutter/foundation.dart' show immutable;

/// 서버 `dashboard_devices.transport`의 Apple 대상 값(정본
/// `push.channels.fcm-apns`).
const String kPushTransportFcmApns = 'fcm-apns';

/// macOS 클라이언트가 스스로 신고하는 `dashboard_devices.platform`.
/// 서버는 이 값으로 메시지 포장을 고른다(`push/fcm.ts`의 `buildFcmMessage`).
const String kPushPlatformMacos = 'macos';

/// Firebase Apple 앱 설정(`apple_config`)에서 반드시 있어야 하는 키들 —
/// `FirebaseOptions`의 required 파라미터와 1:1이다. 하나라도 없으면
/// 초기화를 시도하지 않고 [ApnsTokenStatus.unsupported]로 돌아선다.
const List<String> kAppleConfigRequiredKeys = <String>[
  'apiKey',
  'appId',
  'messagingSenderId',
  'projectId',
];

/// 토큰 취득 시도 하나의 결과 종류. [WebPushTokenStatus]와 의미가 1:1이라
/// `push_provider.dart`가 두 경로를 같은 [PushAvailability]로 접을 수 있다.
enum ApnsTokenStatus {
  /// FCM 등록 토큰을 받았다(APNs 등록까지 성공했다는 뜻이다).
  acquired,

  /// 사용자가 알림 권한을 주지 않았다. 실패가 아니라 "지금은 못 한다"다 —
  /// 로컬 알림 폴백이 그대로 살아 있어야 한다(설계 ②).
  permissionRequired,

  /// 이 호스트/빌드가 APNs 대상이 아니다: 웹이거나, macOS가 아니거나,
  /// 서버가 `apple_config`를 주지 않았거나, `aps-environment` entitlement가
  /// 아직 꺼져 있어 APNs 토큰 자체가 없다(설계 ⑤ — Sol이 Xcode에서 켜기
  /// 전까지는 이 값이 정상이다).
  unsupported,

  /// 지원·권한은 있는데 이번 시도가 실패했다(Firebase 초기화 오류,
  /// getToken 오류 등).
  failed,
}

/// 토큰 취득 시도 하나의 결과.
@immutable
class ApnsTokenResult {
  const ApnsTokenResult(this.status, {this.token, this.detail = ''});

  const ApnsTokenResult.acquired(String this.token)
    : status = ApnsTokenStatus.acquired,
      detail = '';

  const ApnsTokenResult.unsupported([this.detail = ''])
    : status = ApnsTokenStatus.unsupported,
      token = null;

  const ApnsTokenResult.permissionRequired([this.detail = ''])
    : status = ApnsTokenStatus.permissionRequired,
      token = null;

  const ApnsTokenResult.failed([this.detail = ''])
    : status = ApnsTokenStatus.failed,
      token = null;

  final ApnsTokenStatus status;

  /// [ApnsTokenStatus.acquired]일 때만 채워진다. FCM 등록 토큰이다 —
  /// 화면에 그대로 노출하지 않는다(자격증명에 준하는 값이다).
  final String? token;

  /// 진단용 사유. 사용자에게 그대로 보여주지 않는다(i18n 대상이 아니다).
  final String detail;

  bool get isAcquired =>
      status == ApnsTokenStatus.acquired && (token != null && token!.isNotEmpty);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApnsTokenResult &&
          other.status == status &&
          other.token == token &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(status, token, detail);

  @override
  String toString() =>
      'ApnsTokenResult($status${detail.isEmpty ? '' : ', $detail'})';
}

/// `apple_config` 맵이 [FirebaseOptions]를 만들 수 있을 만큼 채워져 있는지.
///
/// 순수 함수라 플러그인 없이 테스트할 수 있다 — 실제 `FirebaseOptions`
/// 생성은 `apns_push_native.dart`가 하고(그 파일만 firebase를 import한다),
/// 이 판정은 양쪽 구현과 provider가 공유한다.
bool isAppleConfigComplete(Map<String, Object?> appleConfig) {
  for (final key in kAppleConfigRequiredKeys) {
    final Object? value = appleConfig[key];
    if (value is! String || value.isEmpty) return false;
  }
  return true;
}

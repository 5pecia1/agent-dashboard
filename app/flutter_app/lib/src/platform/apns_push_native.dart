/// `apns_push.dart`의 데스크톱 구현 — macOS에서 APNs 경유 FCM 등록 토큰을
/// 실제로 받아 온다 (TASK D-app, A안 설계 ②③).
///
/// 초기화와 등록 흐름:
///
/// 1. **호스트 확인.** macOS가 아니면(linux/windows) 아무것도 하지 않고
///    [ApnsTokenStatus.unsupported]. 웹은 이 파일이 아예 로드되지 않는다.
/// 2. **자격증명 확인.** 서버 `GET /dashboard/push-config`의 `apple_config`가
///    [FirebaseOptions]를 만들 수 있을 만큼 채워져 있어야 한다
///    ([isAppleConfigComplete]). **설계 ③의 핵심**: 옵션을
///    `GoogleService-Info.plist`로 빌드에 굽지 않고 서버가 준 값으로 코드
///    주입한다 — 프로젝트를 바꾸거나 키를 회전해도 앱을 다시 빌드하지 않는다.
/// 3. **Firebase 초기화.** 앱당 한 번. 이미 초기화돼 있으면 재사용한다.
/// 4. **클릭 복원.** 열린 배너 구독과 냉시작 클릭 조회를 먼저 설치한다.
///    이미 누른 알림은 이후 권한·토큰 등록의 성공 여부와 무관하게 처리한다.
/// 5. **권한 요청.** 승인되지 않으면 [ApnsTokenStatus.permissionRequired]로
///    돌아선다 — 그러면 호출자가 로컬 알림 폴백을 그대로 유지한다(설계 ②).
/// 6. **포그라운드 배너 억제.** presentation options를 전부 false로 둔다
///    (설계 ②) — 앱이 떠 있는 동안은 화면 자체가 상태를 보여주므로 배너가
///    겹치면 안 된다.
/// 7. **토큰.** APNs device token(`getAPNSToken`)이 먼저 있어야 FCM 등록
///    토큰(`getToken`)이 나온다. `aps-environment` entitlement가 아직
///    비활성이면(설계 ⑤ — Sol이 Xcode에서 팀 지정과 함께 켜기 전) APNs
///    토큰이 null이고, 그건 **정상 분기**다: [ApnsTokenStatus.unsupported]로
///    접어 로컬 알림 폴백으로 남는다.
///
/// **이 파일은 예외를 던지지 않는다.** 모든 실패가 [ApnsTokenResult]다 —
/// `web_push_web.dart`와 같은 이유(푸시는 깨우기 힌트고 정합성은 폴링이
/// 담보한다, 정본 `push` 절).
///
/// `flutter test`(VM 타깃)는 [acquireApnsToken]을 실행하지 않는다 —
/// `push_provider.dart`의 `apnsTokenFnProvider` 시임을 override해 값으로만
/// 분기를 태운다(그래서 이 테스트들은 Firebase 자격증명도, 실기기도 필요
/// 없다). 실제 APNs 수신 확인은 자격증명·서명 뒤 '사용자 확인' 항목이다.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/platform/apns_push.dart';
import 'package:my_dashboard/src/platform/push_signal.dart';
import 'package:my_dashboard/src/platform/push_signal_native.dart' show emitPushSignal;

/// 이 호스트가 APNs 경로 대상인가. macOS 데스크톱만 true다.
///
/// **`Platform.isMacOS`가 아니라 `defaultTargetPlatform`을 보는 이유**:
/// `feature_status.dart`의 `hasDesktopHost`와 같은 판정 기준을 쓴다. 그
/// 상수가 그렇듯 위젯 테스트에서는 이 값이 android로 고정되므로
/// (`flutter_test` 기본값), macOS 호스트에서 `flutter test`를 돌려도
/// 부팅 경로가 실제 Firebase/서버로 내려가지 않는다 — 테스트 결과가
/// 호스트 OS에 따라 갈리지 않게 하는 것이 이 선택의 핵심이다. APNs 분기
/// 자체는 `push_provider.dart`의 `isApplePushHostProvider`를 override해
/// 값으로 태운다(실제 macOS 앱에서는 이 값이 그대로 true다).
bool get hasApplePushHost => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

final ApnsNotificationOpenHandler _notificationOpens = ApnsNotificationOpenHandler(
  onSignal: emitPushSignal,
);

/// APNs 경유 FCM 등록 토큰을 받아 온다.
Future<ApnsTokenResult> acquireApnsToken(PushConfigDto config) async {
  if (!hasApplePushHost) {
    return const ApnsTokenResult.unsupported('이 호스트에는 APNs가 없다');
  }
  if (!isAppleConfigComplete(config.appleConfig)) {
    return const ApnsTokenResult.unsupported('push-config의 apple_config가 비었거나 필수 키가 없다');
  }

  final FirebaseOptions options;
  try {
    options = _optionsFrom(config.appleConfig);
  } on Object catch (error) {
    return ApnsTokenResult.failed('apple_config를 FirebaseOptions로 못 옮겼다: $error');
  }

  try {
    await _ensureFirebaseApp(options);
  } on Object catch (error) {
    return ApnsTokenResult.failed('Firebase 초기화 실패: $error');
  }

  final FirebaseMessaging messaging;
  try {
    messaging = FirebaseMessaging.instance;
  } on Object catch (error) {
    return ApnsTokenResult.failed('FirebaseMessaging을 얻지 못했다: $error');
  }

  // 이미 표시된 배너의 클릭은 새 토큰 등록 성공 여부와 무관하다. 권한이
  // 취소됐거나 APNs 토큰을 아직 못 받아도 초기 클릭을 먼저 복원한다.
  try {
    await _notificationOpens.start(
      openedMessages: FirebaseMessaging.onMessageOpenedApp,
      getInitialMessage: messaging.getInitialMessage,
    );
  } on Object {
    // 수신 API를 사용할 수 없어도 토큰 등록은 별도로 진행한다.
  }

  try {
    final settings = await messaging.requestPermission();
    if (!_isAuthorized(settings.authorizationStatus)) {
      return ApnsTokenResult.permissionRequired(
        'authorizationStatus=${settings.authorizationStatus.name}',
      );
    }

    // 설계 ②: 포그라운드에서는 배너를 억제한다.
    await messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );

    final apnsToken = await messaging.getAPNSToken();
    if (apnsToken == null || apnsToken.isEmpty) {
      // 설계 ⑤: entitlement가 아직 비활성인 로컬 ad-hoc 빌드의 정상 상태다.
      return const ApnsTokenResult.unsupported(
        'APNs device token이 없다 (aps-environment entitlement 미활성 또는 등록 미완료)',
      );
    }

    final token = await messaging.getToken();
    if (token == null || token.isEmpty) {
      return const ApnsTokenResult.failed('getToken이 빈 토큰을 돌려줬다');
    }

    return ApnsTokenResult.acquired(token);
  } on Object catch (error) {
    return ApnsTokenResult.failed('APNs 등록 실패: $error');
  }
}

// ─── 내부 ────────────────────────────────────────────────────────────────

/// 서버가 준 맵을 [FirebaseOptions]로 옮긴다. 필수 네 키는 이미
/// [isAppleConfigComplete]가 확인했으므로 여기서는 캐스팅만 한다 —
/// 선택 키는 없으면 null로 남긴다(SDK 기본값을 쓴다).
FirebaseOptions _optionsFrom(Map<String, Object?> appleConfig) {
  String required(String key) => appleConfig[key]! as String;
  String? optional(String key) {
    final Object? value = appleConfig[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  return FirebaseOptions(
    apiKey: required('apiKey'),
    appId: required('appId'),
    messagingSenderId: required('messagingSenderId'),
    projectId: required('projectId'),
    databaseURL: optional('databaseURL'),
    storageBucket: optional('storageBucket'),
    // Apple 전용 키들. Firebase 콘솔이 주는 plist에는 있고 웹 설정에는 없다.
    iosClientId: optional('iosClientId'),
    iosBundleId: optional('iosBundleId'),
    appGroupId: optional('appGroupId'),
  );
}

/// 기본 앱을 한 번만 초기화한다. 이미 있으면(hot restart, 설정 저장 후
/// 재등록) 그대로 재사용한다 — 같은 이름으로 다시 부르면 SDK가 던진다.
Future<void> _ensureFirebaseApp(FirebaseOptions options) async {
  if (Firebase.apps.isNotEmpty) return;
  await Firebase.initializeApp(options: options);
}

/// macOS에서 "알림을 받아도 되는" 상태 둘. `provisional`은 조용한 배너
/// 권한이라 우리 소유권 규칙(설계 ②)에서는 승인과 같게 취급한다 — 그
/// 상태에서도 배너는 APNs가 띄우므로 로컬 알림이 겹치면 안 된다.
bool _isAuthorized(AuthorizationStatus status) =>
    status == AuthorizationStatus.authorized || status == AuthorizationStatus.provisional;

/// Firebase가 준비된 뒤 열린 배너 수신을 설치하고 초기 클릭을 한 번 읽는다.
/// 등록 재시도나 동시 호출로 동일한 초기 클릭을 여러 번 전달하지 않는다.
class ApnsNotificationOpenHandler {
  ApnsNotificationOpenHandler({required this.onSignal});

  final void Function(PushSignal signal) onSignal;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  Future<void>? _initialRead;

  Future<void> start({
    required Stream<RemoteMessage> openedMessages,
    required Future<RemoteMessage?> Function() getInitialMessage,
  }) {
    try {
      _openedSubscription ??= openedMessages.listen(
        (message) => onSignal(pushSignalFromRemoteMessage(message)),
        onError: (Object error) {
          // 클릭 수신 실패가 토큰 등록 경로의 예외로 전파되지 않게 한다.
        },
      );
    } on Object {
      // 스트림 구독 실패와 무관하게 OS에 남아 있는 초기 클릭을 읽는다.
    }
    return _initialRead ??= _emitInitialMessage(getInitialMessage);
  }

  Future<void> _emitInitialMessage(Future<RemoteMessage?> Function() getInitialMessage) async {
    try {
      final initial = await getInitialMessage();
      if (initial != null) onSignal(pushSignalFromRemoteMessage(initial));
    } on Object {
      // 초기 클릭 조회 실패가 새 알림의 등록을 막지 않는다.
    }
  }

  Future<void> dispose() async {
    await _openedSubscription?.cancel();
    _openedSubscription = null;
  }
}

/// `RemoteMessage.data`(정본 `push.data_keys`)를 공용 [PushSignal]로 옮긴다.
PushSignal pushSignalFromRemoteMessage(RemoteMessage message) =>
    pushSignalFromMap(<String, Object?>{
      ...message.data,
      // 클릭 콜백에서 받은 메시지이므로 서버의 임의 type을 따르지 않는다.
      kPushSignalTypeField: kPushSignalNotificationClick,
    });

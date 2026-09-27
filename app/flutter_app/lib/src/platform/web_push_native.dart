/// `web_push.dart`의 데스크톱(비-웹) 구현 — 전부 "해당 없음"이다.
///
/// macOS 앱은 FCM 기기 토큰을 웹 SDK로 받지 않는다(네이티브 트랙이 따로
/// `DashboardApi.registerDevice`를 부른다). `state/push_provider.dart`가
/// [isWasmRuntimeProvider]로 이미 이 경로를 걸러내므로 정상 흐름에서는 이
/// 함수들이 호출되지 않는다 — 그래도 호출되면 브라우저 API를 찾다 죽는 대신
/// [WebPushTokenStatus.unsupported]로 조용히 접는다.
library;

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/platform/web_push.dart';

Future<WebPushTokenResult> acquireWebPushToken(PushConfigDto config) async =>
    const WebPushTokenResult.unsupported('데스크톱 호스트에는 브라우저 푸시가 없다');

/// 데스크톱에는 띄울 프롬프트가 없다. 설정 화면 버튼이 눌려도 아무 일도
/// 일어나지 않아야 한다(false = 권한을 받지 못했다).
Future<bool> requestWebPushPermission() async => false;

/// 데스크톱에는 브라우저 알림 권한이라는 개념이 없다.
String currentWebPushPermission() => 'unsupported';

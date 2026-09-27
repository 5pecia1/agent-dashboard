/// T17f 완료 기준 (d)의 통합 테스트(best-effort): 자격증명이 **반만** 설정된
/// 실제 `wrangler dev` 서버를 상대로, 앱이 브라우저를 건드리지도 않고
/// 폴링 전용(`PushAvailability.unavailable`)으로 남는지 확인한다.
///
/// 왜 값 테스트(`test/state_tests/push_provider_test.dart`)만으로 부족한가:
/// 거기서는 `client_ready:false` 응답을 우리가 손으로 지어낸다. 여기서는
/// 서버가 실제로 무엇을 보내는지까지 함께 고정한다 — dashboard-server의
/// `GET /dashboard/push-config`는 FCM 채널이 살아 있어도(FCM_SERVICE_ACCOUNT
/// 있음) 웹 설정이 없으면 `{"channels":["fcm"],"fcm":{"web_config":null,
/// "vapid_key":null,"client_ready":false}}`를 준다. 그 모양을
/// `PushConfigDto.fromServer`가 잘못 읽으면(예: `web_config`를 못 알아보면)
/// 앱은 자격증명이 있다고 착각하고 `getToken()`까지 내려가 권한 프롬프트를
/// 띄운다. 그 사고를 막는 것이 이 파일이다.
///
/// `sync_controller_live_server_test.dart`와 같은 관용이다 — 서버는 이
/// 테스트가 띄우지 않고, 환경변수가 없으면 건너뛴다(기본 `flutter test`
/// 실행에서 이 파일 하나 때문에 스위트가 깨지면 안 된다).
///
/// 실행 방법 (수동, best-effort):
/// ```
/// cd dashboard-server
/// SA='{"project_id":"dummy-project","client_email":"dummy@example.com","private_key":"-----BEGIN PRIVATE KEY-----\nNOTREAL\n-----END PRIVATE KEY-----\n"}'
/// npx wrangler dev --port 8791 --var "FCM_SERVICE_ACCOUNT:$SA" &
/// TEST_SERVER_BASE_URL=http://127.0.0.1:8791 TEST_AUTH_TOKEN=dev-token \
///   flutter test test/integration_tests/push_config_live_server_test.dart
/// ```
/// (FIREBASE_WEB_CONFIG·FCM_WEB_VAPID_KEY를 **주지 않는 것**이 이 시나리오의
/// 핵심이다 — 그래야 서버가 `client_ready:false`를 말한다.)
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/http_provider.dart';
import 'package:my_dashboard/src/state/push_provider.dart';

void main() {
  test(
    '완료 기준 (d): client_ready:false 서버 상대로 브라우저를 건드리지 않고 폴링 전용으로 남는다',
    () async {
      final baseUrlString = Platform.environment['TEST_SERVER_BASE_URL'];
      final authToken = Platform.environment['TEST_AUTH_TOKEN'];
      if (baseUrlString == null || authToken == null) {
        markTestSkipped(
          'TEST_SERVER_BASE_URL/TEST_AUTH_TOKEN 환경변수가 없다 — 파일 헤더의 '
          '실행 방법대로 wrangler dev를 띄우고 돌리는 best-effort 통합 '
          '테스트라 기본 `flutter test` 실행에서는 건너뛴다.',
        );
        return;
      }

      final container = ProviderContainer(
        overrides: [
          // 웹 런타임인 척한다 — 데스크톱 분기로 새면 서버를 아예 안 부른다.
          isWasmRuntimeProvider.overrideWithValue(true),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(
              baseUrl: Uri.parse(baseUrlString),
              clientToken: authToken,
            ),
          ),
          // 진짜 소켓(`http_transport_io.dart`)을 그대로 쓴다.
          httpSendProviderOverride,
          // 이 시임까지 내려가면 실패다 — 실제 웹에서는 이 지점이
          // Firebase `getToken()`이고, 권한 프롬프트를 띄울 수 있다.
          webPushTokenFnProvider.overrideWithValue(
            (_) async => throw StateError(
              'client_ready:false인데 브라우저 토큰 취득까지 내려갔다.',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // 서버가 안 떠 있으면 건너뛴다(연결 실패는 이 테스트의 관심사가 아니다).
      try {
        await container.read(dashboardApiProvider).diagnostics();
      } on DashboardNetworkFailure catch (error) {
        markTestSkipped('$baseUrlString에 연결할 수 없다: ${error.message}');
        return;
      } on DashboardApiException {
        // 인증/스키마 문제는 아래 본 검사에서 그대로 드러난다.
      }

      final config = await container.read(dashboardApiProvider).pushConfig();
      expect(config.channels, contains('fcm'), reason: '서버는 fcm 채널이 살아 있다고 말해야 한다');
      expect(config.clientReady, isFalse, reason: '웹 설정이 없으므로 서버가 false를 말한다');
      expect(config.firebaseConfig, isEmpty);
      expect(config.vapidKey, isNull);
      expect(config.canSubscribeOnWeb, isFalse);

      final result = await container.read(pushRegistrarProvider)();
      expect(result.availability, PushAvailability.unavailable);
      expect(result.token, isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

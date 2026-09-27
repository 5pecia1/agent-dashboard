/// `apns_push.dart`의 웹 구현 — 전부 "해당 없음"이다.
///
/// **이 파일이 존재하는 이유가 곧 계약이다.** 웹에는 APNs가 없고, 웹의
/// 푸시 경로는 이미 `web_push_web.dart` + `web/push_token_bridge.js` +
/// 벤더링한 Firebase JS SDK로 완결돼 있다. `firebase_messaging` 플러그인을
/// 웹에서 초기화하면 SDK 인스턴스와 서비스 워커 등록이 둘로 늘어나
/// `web/push_sw.js` 상단이 못박은 "등록은 정확히 둘(`/`, `/push-scope/`)"
/// 계약이 깨진다.
///
/// 그래서 이 파일은 `firebase_core`/`firebase_messaging`을 **import하지
/// 않는다** — 조건부 import(`push_provider.dart`)가 웹 컴파일 타깃에서
/// 고르는 쪽이 이 파일이므로, 플러그인 Dart 코드는 웹 번들의 실행 경로에
/// 아예 들어오지 않는다(`app/scripts/web_push_smoke.py`가 실제 브라우저에서
/// 그 사실을 확인한다).
library;

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/platform/apns_push.dart';

/// 웹은 절대 APNs 대상이 아니다.
bool get hasApplePushHost => false;

/// 호출되면 안 되는 자리지만(`push_provider.dart`가 [hasApplePushHost]로
/// 이미 걸러낸다), 호출돼도 브라우저에 없는 API를 찾다 죽는 대신 조용히
/// 접는다 — `web_push_native.dart`의 거울과 같은 관용이다.
Future<ApnsTokenResult> acquireApnsToken(PushConfigDto config) async =>
    const ApnsTokenResult.unsupported('웹 호스트에는 APNs가 없다');

/// 세션 상세로 가는 라우트 하나를 웹 해시(`#/session/<key>`)와 macOS 알림
/// 클릭 딥링크(`app.dart`의 `handleNotificationTap`) 양쪽이 공유하게 만드는
/// 얇은 라우팅 계층 (T-wire).
///
/// 이 스캐폴드는 지금도 Navigator 1.0(`MaterialApp.onGenerateRoute`)만
/// 쓴다 — `go_router` 같은 Router 2.0 패키지를 새로 얹지 않는다. 새
/// 의존성을 정당화할 근거가 없어서다: Navigator 1.0에서도 `initialRoute`는
/// 기본적으로 `WidgetsBinding.instance.platformDispatcher.defaultRouteName`을
/// 쓰는데, 웹 빌드에서 이 값은 `usePathUrlStrategy()`를 부르지 않는 한(이
/// 앱은 부르지 않는다) URL의 해시 프래그먼트를 그대로 반영한다 — 예:
/// 주소가 `.../#/session/claude_code:s1`이면 초기 라우트 이름이
/// `/session/claude_code:s1`이 된다. 그래서 "웹 해시 호환"은 이 파일이
/// 라우트 *이름* 인코딩/디코딩과 `onGenerateRoute` 팩토리만 갖추면 별도
/// 패키지 없이 충족된다.
///
/// `MaterialApp.navigatorKey`(`app.dart`의 [rootNavigatorKey])로 잡은
/// 루트 네비게이터의 `pushNamed`도 정확히 이 `onGenerateRoute`를 통해
/// 라우트를 만든다 — `handleNotificationTap`이 이 파일의
/// [sessionDetailRouteName]으로 `pushNamed`하면, 사용자가 세션 카드를 눌러
/// 들어가는 경로와 알림을 눌러 들어가는 경로가 코드 레벨에서 완전히 같은
/// 라우트 팩토리를 탄다(두 경로를 따로 유지보수할 필요가 없다).
library;

import 'package:flutter/material.dart';

import 'package:my_dashboard/src/ui/session_detail_page.dart' show SessionDeepLinkPage;

const String _kSessionRoutePrefix = '/session/';

/// [sessionKey]로 가는 라우트 이름. `sessionKey`는 `<source>:<session_id>`
/// 모양이라 `:`를 포함할 수 있으므로 URL 세그먼트로 안전하게 퍼센트
/// 인코딩한다 — [sessionKeyFromRouteName]이 짝을 이뤄 디코딩한다.
String sessionDetailRouteName(String sessionKey) =>
    '$_kSessionRoutePrefix${Uri.encodeComponent(sessionKey)}';

/// [sessionDetailRouteName]의 역함수. `routeName`이 그 모양이 아니거나
/// 세션 키 세그먼트가 비었거나 퍼센트 디코딩에 실패하면 null(호출자는 이
/// 라우트를 자기 것으로 처리하지 않는다).
String? sessionKeyFromRouteName(String? routeName) {
  if (routeName == null || !routeName.startsWith(_kSessionRoutePrefix)) {
    return null;
  }
  final encoded = routeName.substring(_kSessionRoutePrefix.length);
  if (encoded.isEmpty) return null;
  try {
    return Uri.decodeComponent(encoded);
  } catch (_) {
    return null;
  }
}

/// `MaterialApp.onGenerateRoute`에 그대로 물리는 라우트 팩토리. 지금은
/// 세션 상세 하나만 다룬다 — 그 이름 모양이 아니면 null을 돌려줘 호출자
/// (`app.dart`의 [SolApp])가 그 밖의(홈 등) 라우트를 직접 처리하게 한다.
Route<void>? generateAppRoute(RouteSettings settings) {
  final sessionKey = sessionKeyFromRouteName(settings.name);
  if (sessionKey == null) return null;
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => SessionDeepLinkPage(sessionKey: sessionKey),
  );
}

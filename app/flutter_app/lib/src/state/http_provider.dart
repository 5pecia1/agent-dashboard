/// `httpSendProvider`(`dashboard_api.dart`, T12)에 꽂는 실제 전송 구현.
///
/// 시임 자체(typedef [HttpSendFn] + `Provider<HttpSendFn>`)는 이미
/// `dashboard_api.dart`에 있다 — 그 파일이 남긴 계약 그대로, 테스트는
/// [httpSendProvider]를 가짜 핸들러로 override하고, **앱 부팅**만
/// [httpSendProviderOverride]로 진짜 전송을 꽂는다. 이 파일이 새 Provider를
/// 열지 않는 건 3계층 패턴을 어기는 게 아니라 이미 열려 있는 계층 위에
/// 얹는 것이다 — `capability_provider.dart`의 3계층 중 "얇은 함수" 자리에
/// 해당하는 것이 [http_transport_io.dart]/[http_transport_web.dart]의
/// `sendHttpRequest`다.
library;

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/http_transport_io.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/state/http_transport_web.dart'
    as bridge;

/// 앱 부팅이 `ProviderScope(overrides: [httpSendProviderOverride, ...])`에
/// 넣는 override. 데스크톱은 `dart:io`의 `HttpClient`, 웹은 `fetch`를 쓴다 —
/// 둘 다 이 파일 밖(`http_transport_*.dart`)에 있고, 이 파일은 조건부
/// import로 맞는 쪽을 고르기만 한다.
// 반환 타입(`Override`)은 `package:riverpod/misc.dart`에 있고
// `flutter_riverpod`의 barrel export에는 없다 — 타입 추론에만 맡기면(값
// 선언에 타입 이름을 직접 쓰지 않으면) 그 패키지를 새로 import하지 않아도
// 된다.
final httpSendProviderOverride = httpSendProvider.overrideWithValue(
  bridge.sendHttpRequest,
);

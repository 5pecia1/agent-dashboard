/// `http_provider.dart`의 웹 브리지 — 브라우저 `fetch`.
///
/// 응답 헤더는 비운 채 돌린다 — `DashboardApi`는 상태 코드와 본문만 읽고
/// (`dashboard_api.dart`의 `_statusFailure`/`_decodeObject` 참고) 헤더를
/// 쓰지 않으므로, `Headers`를 순회해 Dart 맵으로 옮기는 비용을 들이지
/// 않는다.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/data/dashboard_api.dart' show ApiRequest, ApiResponse;

Future<ApiResponse> sendHttpRequest(ApiRequest request) async {
  final headers = web.Headers();
  // tear-off(`headers.append`)이 아니라 클로저다 — `web.Headers`는 extension
  // type이고, dart2js/dart2wasm은 external extension type 멤버의 tear-off를
  // 금지한다("Tear-offs of external extension type interop member 'append'
  // are disallowed"). VM 타깃 분석에서는 안 잡히고 웹 컴파일에서만 터진다.
  request.headers.forEach((key, value) => headers.append(key, value));
  final init = web.RequestInit(
    method: request.method,
    headers: headers,
    body: request.body?.toJS,
    redirect: request.followRedirects ? 'follow' : 'error',
  );
  final response = await web.window
      .fetch(request.url.toString().toJS, init)
      .toDart;
  final text = await response.text().toDart;
  return ApiResponse(
    statusCode: response.status,
    body: text.toDart,
    headers: const <String, String>{},
  );
}

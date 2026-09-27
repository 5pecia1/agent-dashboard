/// `http_provider.dart`의 데스크톱 브리지 — `dart:io`의 `HttpClient`.
///
/// 타임아웃은 여기서 걸지 않는다 — `DashboardApi._request`가 이미
/// `send(request).timeout(config.timeout)`으로 감싼다(`dashboard_api.dart`).
/// 이 함수는 전송 한 번을 그대로 옮기는 것만 책임진다. 연결 실패 등은
/// 예외로 던진다 — `DashboardApi`가 [DashboardNetworkFailure]로 접는다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/data/dashboard_api.dart' show ApiRequest, ApiResponse;

final HttpClient _client = HttpClient();

Future<ApiResponse> sendHttpRequest(ApiRequest request) async {
  final httpRequest = await _client.openUrl(request.method, request.url);
  httpRequest.followRedirects = request.followRedirects;
  request.headers.forEach(httpRequest.headers.set);
  final body = request.body;
  if (body != null) {
    httpRequest.write(body);
  }
  final httpResponse = await httpRequest.close();
  final responseBody = await httpResponse.transform(utf8.decoder).join();
  final headers = <String, String>{};
  httpResponse.headers.forEach((name, values) {
    headers[name] = values.join(', ');
  });
  return ApiResponse(
    statusCode: httpResponse.statusCode,
    body: responseBody,
    headers: headers,
  );
}

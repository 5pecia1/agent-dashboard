import 'dart:async';
import 'dart:convert';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';

const Duration kDevinUsageTimeout = Duration(seconds: 10);

class DevinUsageFailure implements Exception {
  const DevinUsageFailure(this.labelKey, {this.statusCode});
  final String labelKey;
  final int? statusCode;
  @override
  String toString() => labelKey;
}

/// `SeatManagementService/GetUserStatus` 한 가지만 호출하는 읽기 전용
/// 클라이언트. Connect unary의 JSON 변형(POST + `application/json` 본문)을
/// 쓰고, 인증은 헤더가 아니라 본문 `metadata.api_key`에 실어 보낸다.
/// `metadata`에는 서버가 요구하는 클라이언트 식별 필드(ide/extension의
/// 이름·버전)도 함께 넣는다 — devin_usage_models.dart의
/// kDevinClientName 문서 참고.
class DevinUsageApi {
  const DevinUsageApi(this.send, {this.timeout = kDevinUsageTimeout});
  final HttpSendFn send;
  final Duration timeout;

  Future<DevinQuota> userStatus(DevinConnection connection) async {
    final json = await _post(connection);
    try {
      return DevinQuota.fromUserStatus(json);
    } on FormatException {
      throw const DevinUsageFailure('devin.invalid_response');
    }
  }

  Future<Map<String, dynamic>> _post(DevinConnection connection) async {
    try {
      final response = await send(
        ApiRequest(
          method: 'POST',
          url: connection.userStatusUrl,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Connect-Protocol-Version': '1',
          },
          body: jsonEncode({
            'metadata': {
              'api_key': connection.apiKey,
              // 서버가 요구하는 클라이언트 식별 필드 — 없거나 비면
              // invalid_argument로 거절한다(실측 확인).
              'ide_name': kDevinClientName,
              'ide_version': kDevinClientVersion,
              'extension_name': kDevinClientName,
              'extension_version': kDevinClientVersion,
            },
          }),
          followRedirects: false,
        ),
      ).timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const DevinUsageFailure('devin.unauthorized');
      }
      if (!response.isSuccess) {
        // Connect 오류 본문의 code로 인증 실패를 구분한다. 이 서버는
        // 잘못된 키에 401이 아니라 400 + invalid_argument(실측 확인)를
        // 돌려주므로 그 조합도 키 문제로 안내한다.
        final code = _connectErrorCode(response.body);
        if (code == 'unauthenticated' ||
            code == 'permission_denied' ||
            (response.statusCode == 400 && code == 'invalid_argument')) {
          throw const DevinUsageFailure('devin.unauthorized');
        }
        throw DevinUsageFailure(
          'devin.server_error',
          statusCode: response.statusCode,
        );
      }
      final Object? json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return json;
    } on DevinUsageFailure {
      rethrow;
    } on TimeoutException {
      throw const DevinUsageFailure('devin.timeout');
    } on FormatException {
      throw const DevinUsageFailure('devin.invalid_response');
    } catch (_) {
      // 전송 예외나 서버 본문에는 URL·키가 포함될 수 있으므로 표시하지 않는다.
      throw const DevinUsageFailure('devin.network_error');
    }
  }

  static String? _connectErrorCode(String body) {
    try {
      final Object? json = jsonDecode(body);
      if (json is Map<String, dynamic> && json['code'] is String) {
        return json['code'] as String;
      }
    } on FormatException {
      // Connect가 아닌 오류 페이지(프록시 등) — 코드 없음으로 접는다.
    }
    return null;
  }
}

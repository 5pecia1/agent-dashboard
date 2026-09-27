import 'dart:async';
import 'dart:convert';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';

const Duration kTeamClaudeTimeout = Duration(seconds: 10);

class TeamClaudeFailure implements Exception {
  const TeamClaudeFailure(this.labelKey, {this.statusCode});
  final String labelKey;
  final int? statusCode;
  @override
  String toString() => labelKey;
}

class TeamClaudeApi {
  const TeamClaudeApi(this.send, {this.timeout = kTeamClaudeTimeout});
  final HttpSendFn send;
  final Duration timeout;

  Future<TeamClaudeSnapshot> status(TeamClaudeConnection connection) async {
    final json = await _get(connection.statusUrl, connection.apiKey);
    Map<String, dynamic>? quota;
    try {
      quota = await _get(connection.quotaUrl, connection.apiKey);
    } on TeamClaudeFailure catch (error) {
      // 구형 서버의 미지원 경로만 부분 집계로 허용한다. 일시 장애와 인증
      // 실패는 컨트롤러까지 전달해 직전의 완전한 결과를 보존한다.
      if (error.statusCode != 404) rethrow;
    }
    try {
      return TeamClaudeSnapshot.fromJson(json, quota: quota);
    } on FormatException {
      throw const TeamClaudeFailure('teamclaude.invalid_response');
    }
  }

  Future<Map<String, dynamic>> _get(Uri url, String apiKey) async {
    try {
      final response = await send(
        ApiRequest(
          method: 'GET',
          url: url,
          headers: {'Accept': 'application/json', 'X-Api-Key': apiKey},
          followRedirects: false,
        ),
      ).timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TeamClaudeFailure('teamclaude.unauthorized');
      }
      if (!response.isSuccess) {
        throw TeamClaudeFailure(
          'teamclaude.server_error',
          statusCode: response.statusCode,
        );
      }
      final Object? json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return json;
    } on TeamClaudeFailure {
      rethrow;
    } on TimeoutException {
      throw const TeamClaudeFailure('teamclaude.timeout');
    } on FormatException {
      throw const TeamClaudeFailure('teamclaude.invalid_response');
    } catch (_) {
      // 전송 예외나 서버 본문에는 URL·키가 포함될 수 있으므로 표시하지 않는다.
      throw const TeamClaudeFailure('teamclaude.network_error');
    }
  }
}

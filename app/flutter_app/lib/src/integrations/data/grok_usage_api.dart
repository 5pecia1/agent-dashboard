import 'dart:async';
import 'dart:convert';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/grok_bot_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';

const Duration kGrokUsageTimeout = Duration(seconds: 10);

class GrokUsageFailure implements Exception {
  const GrokUsageFailure(this.labelKey, {this.statusCode});
  final String labelKey;
  final int? statusCode;
  @override
  String toString() => labelKey;
}

/// Grok CLI가 사용량 화면에 쓰는 청구 조회.
/// 첫 응답에서 주간 사용률이 나오면 그대로 반환하고, 없으면 `/billing`을 한 번 더 읽는다.
class GrokUsageApi {
  const GrokUsageApi(this.send, {this.timeout = kGrokUsageTimeout});
  final HttpSendFn send;
  final Duration timeout;

  Future<GrokUsageReading> fetch({
    required Uri base,
    required GrokSession session,
  }) async {
    final credits = await _get(grokBillingUri(base, credits: true), session);
    final fromCredits = grokUsageReadingFromJson(
      credits,
      accountLabel: session.accountLabel,
    );
    if (fromCredits != null) return fromCredits;
    final plain = await _get(grokBillingUri(base, credits: false), session);
    final monthly = grokUsageReadingFromJson(
      plain,
      accountLabel: session.accountLabel,
    );
    if (monthly == null) throw const GrokUsageFailure('grok.no_usage');
    return monthly;
  }

  /// Grok Bot 앱이 주간 포함 사용량을 읽을 때 쓰는 Connect JSON 조회.
  Future<GrokUsageReading> fetchBot({required String accessToken}) async {
    final json = await _postBot(accessToken);
    final reading = grokBotReadingFromJson(json);
    if (reading == null) throw const GrokUsageFailure('grok.bot_no_usage');
    return reading;
  }

  Future<Map<String, dynamic>> _postBot(String accessToken) async {
    try {
      final response = await send(
        ApiRequest(
          method: 'POST',
          url: Uri.parse(kGrokBotUsageEndpoint),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $accessToken',
            'Connect-Protocol-Version': '1',
          },
          body: '{}',
          followRedirects: false,
        ),
      ).timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const GrokUsageFailure('grok.bot_unauthorized');
      }
      if (!response.isSuccess) {
        throw GrokUsageFailure(
          'grok.bot_server_error',
          statusCode: response.statusCode,
        );
      }
      final Object? json = jsonDecode(response.body);
      if (json is! Map) {
        throw const GrokUsageFailure('grok.bot_invalid_response');
      }
      return Map<String, dynamic>.from(json);
    } on GrokUsageFailure {
      rethrow;
    } on TimeoutException {
      throw const GrokUsageFailure('grok.bot_timeout');
    } on FormatException {
      throw const GrokUsageFailure('grok.bot_invalid_response');
    } catch (_) {
      throw const GrokUsageFailure('grok.bot_network_error');
    }
  }

  Future<Map<String, dynamic>> _get(Uri url, GrokSession session) async {
    try {
      final response = await send(
        ApiRequest(
          method: 'GET',
          url: url,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer ${session.accessToken}',
            'X-XAI-Token-Auth': kGrokClientTokenAuth,
            if (session.userId != null) 'x-userid': session.userId!,
          },
          followRedirects: false,
        ),
      ).timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const GrokUsageFailure('grok.unauthorized');
      }
      if (!response.isSuccess) {
        throw GrokUsageFailure(
          'grok.server_error',
          statusCode: response.statusCode,
        );
      }
      final Object? json = jsonDecode(response.body);
      if (json is! Map) throw const GrokUsageFailure('grok.invalid_response');
      return Map<String, dynamic>.from(json);
    } on GrokUsageFailure {
      rethrow;
    } on TimeoutException {
      throw const GrokUsageFailure('grok.timeout');
    } on FormatException {
      throw const GrokUsageFailure('grok.invalid_response');
    } catch (_) {
      throw const GrokUsageFailure('grok.network_error');
    }
  }
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart' as catalog;

void main() {
  test('기존 두 연결을 공개 앱에서 반복 저장하고 복원해도 키가 남는다', () {
    const legacy = <String, Object?>{
      'server_url': 'https://dashboard.example',
      'client_token': 'fixture-client',
      'cursor': 9,
      'teamclaude': <String, String>{
        'url': 'https://team.example',
        'api_key': 'fixture-team',
      },
      'devin': <String, String>{
        'url': 'https://devin.example',
        'api_key': 'fixture-devin',
      },
      'future': <String, Object?>{
        'value': <int>[1, 2],
      },
    };
    var values = DashboardConfigValues.fromJson(legacy);
    for (var round = 0; round < 3; round++) {
      values = DashboardConfigValues.fromJson(
        jsonDecode(jsonEncode(values.copyWith(cursor: 10).toJson()))
            as Map<String, Object?>,
      );
      expect(values.teamClaude!.apiKey, 'fixture-team');
      expect(values.devin!.apiKey, 'fixture-devin');
      expect(values.extra['future'], legacy['future']);
    }
    final disconnected = values.withTeamClaude(null);
    expect(disconnected.teamClaude, isNull);
    expect(disconnected.devin!.apiKey, 'fixture-devin');
    expect(disconnected.clientToken, 'fixture-client');
    expect(disconnected.cursor, 10);
  });

  test('연동 codec이 이해하지 못하는 연결도 저장 왕복에서 제거하지 않는다', () {
    final raw = <String, Object?>{
      'teamclaude': {'future_auth': 'fixture'},
      'devin': false,
    };
    final values = DashboardConfigValues.fromJson(raw);
    expect(values.teamClaude, isNull);
    expect(values.devin, isNull);
    expect(values.toJson()['teamclaude'], raw['teamclaude']);
    expect(values.toJson()['devin'], raw['devin']);
  });

  test('사용량 번역의 영어와 한국어 키 및 자리표시자가 일치한다', () {
    expect(catalog.ko.keys.toSet(), catalog.en.keys.toSet());
    final placeholder = RegExp(r'\{[^}]+\}');
    for (final key in catalog.en.keys) {
      final en = placeholder
          .allMatches(catalog.en[key]!)
          .map((m) => m.group(0))
          .toSet();
      final ko = placeholder
          .allMatches(catalog.ko[key]!)
          .map((m) => m.group(0))
          .toSet();
      expect(ko, en, reason: key);
    }
  });
}

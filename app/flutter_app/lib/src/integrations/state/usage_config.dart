import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';

/// Interpret the existing connection keys while preserving other settings.
/// Older installations can use the public app without a config migration.
extension UsageDashboardConfig on DashboardConfigValues {
  TeamClaudeConnection? get teamClaude {
    final raw = extra['teamclaude'];
    if (raw is! Map || raw['url'] is! String || raw['api_key'] is! String) {
      return null;
    }
    try {
      return TeamClaudeConnection.parse(
        raw['url'] as String,
        raw['api_key'] as String,
      );
    } on FormatException {
      return null;
    }
  }

  DevinConnection? get devin {
    final raw = extra['devin'];
    if (raw is! Map || raw['url'] is! String || raw['api_key'] is! String) {
      return null;
    }
    try {
      return DevinConnection.parse(
        raw['url'] as String,
        raw['api_key'] as String,
      );
    } on FormatException {
      return null;
    }
  }

  DashboardConfigValues withTeamClaude(TeamClaudeConnection? connection) {
    final retained = Map<String, Object?>.from(extra);
    if (connection == null) {
      retained.remove('teamclaude');
    } else {
      retained['teamclaude'] = {
        'url': connection.baseUrl,
        'api_key': connection.apiKey,
      };
    }
    return copyWith(extra: Map.unmodifiable(retained));
  }

  bool get grokEnabled {
    final raw = extra['grok'];
    if (raw is! Map) return false;
    return raw['enabled'] == true;
  }

  bool get grokBotEnabled {
    final raw = extra['grok'];
    if (raw is! Map) return false;
    return raw['bot'] == true;
  }

  DashboardConfigValues withGrok(bool enabled) => _grokFlags(cli: enabled);

  DashboardConfigValues withGrokBot(bool enabled) => _grokFlags(bot: enabled);

  /// CLI와 Grok Bot은 따로 켜고, 둘 다 꺼질 때만 `grok` 키를 지운다.
  /// 토큰은 이 맵에 넣지 않는다.
  DashboardConfigValues _grokFlags({bool? cli, bool? bot}) {
    final nextCli = cli ?? grokEnabled;
    final nextBot = bot ?? grokBotEnabled;
    final retained = Map<String, Object?>.from(extra);
    if (!nextCli && !nextBot) {
      retained.remove('grok');
    } else {
      retained['grok'] = {
        if (nextCli) 'enabled': true,
        if (nextBot) 'bot': true,
      };
    }
    return copyWith(extra: Map.unmodifiable(retained));
  }

  DashboardConfigValues withDevin(DevinConnection? connection) {
    final retained = Map<String, Object?>.from(extra);
    if (connection == null) {
      retained.remove('devin');
    } else {
      retained['devin'] = {
        'url': connection.baseUrl,
        'api_key': connection.apiKey,
      };
    }
    return copyWith(extra: Map.unmodifiable(retained));
  }
}

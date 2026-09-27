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

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_api.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/state/http_transport_io.dart';

void main() {
  final url = Platform.environment['TEAMCLAUDE_TEST_URL'];
  test(
    '실제 TeamClaude 서버에서 제공자와 요금제 용량 및 주간 사용률을 조회한다',
    () async {
      final settingsPath = Platform.environment['TEAMCLAUDE_SETTINGS_PATH'];
      if (settingsPath == null) {
        fail('TEAMCLAUDE_SETTINGS_PATH is required for this opt-in check');
      }
      final settings =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      final env = settings['env'] as Map<String, dynamic>;
      final customHeaders = env['ANTHROPIC_CUSTOM_HEADERS'] as String;
      final header = customHeaders
          .split('\n')
          .firstWhere(
            (line) =>
                RegExp(r'^x-api-key\s*:', caseSensitive: false).hasMatch(line),
          );
      final connection = TeamClaudeConnection.parse(url!, header);
      final snapshot = await const TeamClaudeApi(
        sendHttpRequest,
      ).status(connection);
      final claude = snapshot.forProvider(kTeamClaudeProvider);
      final codex = snapshot.forProvider(kTeamCodexProvider);
      expect(claude, isNotEmpty);
      expect(claude.any((account) => account.capacityWeight != null), isTrue);
      expect(codex, isNotEmpty);
      expect(
        codex.any(
          (account) =>
              account.plan != null &&
              account.limits[TeamClaudeBucket.weekly]?.utilization != null,
        ),
        isTrue,
      );
    },
    skip: url == null ? 'TEAMCLAUDE_TEST_URL not configured' : false,
  );
}

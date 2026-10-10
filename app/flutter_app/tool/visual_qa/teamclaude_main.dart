/// 실제 앱 화면·번역·테마를 고정 데이터로 확인한다. 개인 설정은 읽거나 쓰지 않는다.
library;

import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart';

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';

const _connection = TeamClaudeConnection(
  baseUrl: 'https://teamclaude.example.test',
  apiKey: 'demo-only',
);
const _status = {
  'accounts': [
    {
      'name': '개인 Max 계정',
      'provider': 'anthropic',
      'quota': {
        'unified5h': 0.3,
        'unified7d': 0.95,
        'unified7dFable': 0.58,
        'unified7dReset': 1789545600077,
      },
    },
    {
      'name': '팀 공용 계정',
      'provider': 'anthropic',
      'quota': {'unified5h': 0.5, 'unified7d': 0.98},
    },
    {
      'name': '개발용 Codex',
      'provider': 'codex',
      'quota': {'planType': 'pro', 'unified7d': 0.34},
    },
    {
      'name': '보조 Codex',
      'provider': 'codex',
      'quota': {'planType': 'pro', 'unified7d': 0.98},
    },
    {
      'name': '개인 경량 계정',
      'provider': 'codex',
      'quota': {'planType': 'prolite', 'unified7d': 0.01},
    },
  ],
};
const _quota = {
  'accounts': [
    {
      'name': '개인 Max 계정',
      'tier': {'weight': 20, 'rateLimitTier': 'default_claude_max_20x'},
    },
    {
      'name': '팀 공용 계정',
      'tier': {'weight': 1, 'seatTier': 'team_standard'},
      'buckets': {
        'weeklyFable': {'source': 'unified7d'},
      },
    },
  ],
};

const _devinConnection = DevinConnection(
  baseUrl: 'https://devin.example.test',
  apiKey: 'demo-only',
);
const _devinUserStatus = {
  'userStatus': {
    'planStatus': {
      'planInfo': {
        'planName': 'Max',
        'billingStrategy': 'BILLING_STRATEGY_QUOTA',
        'hideDailyQuota': true,
        'devinInfo': {'accountDisplayName': '데모 계정'},
      },
      'dailyQuotaRemainingPercent': 100,
      'weeklyQuotaRemainingPercent': 48,
      'planEnd': '2026-10-14T14:21:06Z',
      'overageBalanceMicros': '7462105',
      'dailyQuotaResetAtUnix': '1789545600',
      'weeklyQuotaResetAtUnix': '1789891200',
    },
  },
};

class _DemoSync extends SyncController {
  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(
      cursor: 1,
      sessions: {
        for (var i = 0; i < 12; i++)
          'demo:$i': SessionViewDto(
            key: 'demo:$i',
            state: i % 3 == 0 ? 'waiting_input' : 'working',
            source: i.isEven ? 'claude-code' : 'codex',
            sessionId: 'demo-session-$i',
            project:
                '/workspace/${['dashboard-demo', 'api-demo', 'worker-demo', 'library-demo'][i % 4]}',
            host: 'MacBook',
            lastMessage: 'TeamClaude 사용률 UI를 개발하고 있습니다.',
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
      },
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  var config = const DashboardConfigValues(
    serverUrl: 'https://dashboard.example.test',
  ).withTeamClaude(_connection);
  runApp(
    ProviderScope(
      overrides: [
        ...usageDashboardUiOverrides,
        extensionTranslationProvider.overrideWithValue(usageTranslation),
        localeProvider.overrideWithValue(LocaleDto.ko),
        dashboardConfigValuesProvider.overrideWithValue(config),
        configLoadFnProvider.overrideWithValue(() async => config),
        configSaveFnProvider.overrideWithValue((value) async {
          config = value;
        }),
        teamClaudeInitialConnectionProvider.overrideWithValue(_connection),
        devinInitialConnectionProvider.overrideWithValue(_devinConnection),
        httpSendProvider.overrideWithValue(
          (request) async => ApiResponse(
            statusCode: 200,
            body: jsonEncode(
              request.url.path == kTeamClaudeStatusPath
                  ? _status
                  : request.url.path == kDevinUserStatusPath
                  ? _devinUserStatus
                  : _quota,
            ),
          ),
        ),
        syncControllerProvider.overrideWith(_DemoSync.new),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,
        home: const SessionsPage(),
      ),
    ),
  );
}

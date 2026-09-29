import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/platform/tray_usage.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';

import '../unit_tests/devin_usage_test.dart' show userStatusExhaustedFixture;

const _teamConnection = TeamClaudeConnection(
  baseUrl: 'https://team.test',
  apiKey: 'private-team-key',
);
const _devinConnection = DevinConnection(
  baseUrl: 'https://devin.test',
  apiKey: 'private-devin-key',
);
const _labels = {
  'tray.usage_title': 'Usage',
  'tray.usage_no_data': 'No usage data',
  'tray.usage_loading': 'Loading usage…',
  'tray.usage_refresh_failed': 'Refresh failed',
  'tray.usage_cached': 'Last successful reading',
  'teamclaude.title': 'TeamClaude',
  'teamclaude.claude': 'Claude',
  'teamclaude.codex': 'Codex',
  'teamclaude.five_hour': '5 hours',
  'teamclaude.weekly': 'Weekly',
  'teamclaude.fable': 'Fable',
  'teamclaude.no_accounts': 'No accounts',
  'teamclaude.unknown_plan': 'Unknown plan',
  'teamclaude.partial_compact': '{known}/{total}',
  'devin.title': 'Devin',
  'devin.weekly': 'Weekly',
  'devin.daily': 'Daily',
  'devin.acu': '{used} / {limit} ACU',
  'grok.title': 'Grok',
  'grok.weekly': 'Weekly',
  'grok.bot_metric': 'Grok Bot',
};

Future<List<String>> _render(
  WidgetTester tester, {
  TeamClaudeState teamClaude = const TeamClaudeState(),
  DevinUsageState devin = const DevinUsageState(),
  GrokUsageState grok = const GrokUsageState(),
}) async {
  late List<String> result;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localeProvider.overrideWithValue(LocaleDto.en),
        i18nTranslateOverride.overrideWithValue((key, locale) => _labels[key]!),
        i18nTranslateArgsOverride.overrideWithValue((
          key,
          locale,
          names,
          values,
        ) {
          var label = _labels[key]!;
          for (var i = 0; i < names.length; i++) {
            label = label.replaceAll('{${names[i]}}', values[i]);
          }
          return label;
        }),
      ],
      child: Consumer(
        builder: (context, ref, child) {
          result = buildTrayUsageLabels(
            ref,
            teamClaude: teamClaude,
            devin: devin,
            grok: grok,
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

TeamClaudeAccount _account({
  String provider = kTeamClaudeProvider,
  String? plan,
  double? weight,
  double? fiveHour,
  double? weekly,
  double? fable,
}) => TeamClaudeAccount(
  name: 'private-account-name',
  provider: provider,
  plan: plan,
  capacityWeight: weight,
  limits: {
    TeamClaudeBucket.fiveHour: TeamClaudeLimit(utilization: fiveHour),
    TeamClaudeBucket.weekly: TeamClaudeLimit(utilization: weekly),
    TeamClaudeBucket.fable: TeamClaudeLimit(utilization: fable),
  },
);

void main() {
  testWidgets('연결하지 않은 사용량 원천은 메뉴에 표시하지 않는다', (tester) async {
    expect(await _render(tester), isEmpty);
  });

  testWidgets('Grok 주간 사용률을 한 줄로 표시한다', (tester) async {
    final labels = await _render(
      tester,
      grok: const GrokUsageState(
        enabled: true,
        reading: GrokUsageReading(
          usedPercent: 75.4,
          window: GrokUsageWindow.weekly,
          plan: 'SuperGrok',
        ),
      ),
    );
    expect(labels, ['Usage', 'Grok SuperGrok · Weekly 75%']);
  });

  testWidgets('Grok Bot 사용률은 같은 줄에 붙고 실패는 따로 남긴다', (tester) async {
    final labels = await _render(
      tester,
      grok: const GrokUsageState(
        cliEnabled: true,
        botEnabled: true,
        reading: GrokUsageReading(
          usedPercent: 75.4,
          window: GrokUsageWindow.weekly,
          plan: 'SuperGrok',
        ),
        botReading: GrokUsageReading(
          usedPercent: 40,
          window: GrokUsageWindow.weekly,
          plan: 'SuperGrok',
        ),
        botErrorKey: 'grok.bot_unauthorized',
      ),
    );
    expect(labels, [
      'Usage',
      'Grok SuperGrok · Weekly 75% · Grok Bot 40%',
      'Grok Bot · Refresh failed · Last successful reading',
    ]);
    final botOnly = await _render(
      tester,
      grok: const GrokUsageState(
        botEnabled: true,
        botReading: GrokUsageReading(
          usedPercent: 60,
          window: GrokUsageWindow.weekly,
        ),
      ),
    );
    expect(botOnly, ['Usage', 'Grok · Grok Bot 60%']);
  });

  testWidgets('Claude는 요금제 용량 가중 사용률을 표시하고 없는 Fable 값은 만들지 않는다', (
    tester,
  ) async {
    final labels = await _render(
      tester,
      teamClaude: TeamClaudeState(
        connection: _teamConnection,
        snapshot: TeamClaudeSnapshot(
          accounts: [
            _account(weight: 1, fiveHour: 0.1, weekly: 0.1),
            _account(weight: 3, fiveHour: 0.3, weekly: 0.7),
          ],
        ),
      ),
    );
    expect(labels, contains('Claude · 5 hours 25% · Weekly 55%'));
    expect(labels.join(), isNot(contains('Fable')));
    expect(labels.join(), isNot(contains('Devin')));
    expect(labels.join(), isNot(contains('private-')));
  });

  testWidgets('미관측 값과 알 수 없는 용량을 제외한 부분 집계 수를 보존한다', (tester) async {
    final labels = await _render(
      tester,
      teamClaude: TeamClaudeState(
        connection: _teamConnection,
        snapshot: TeamClaudeSnapshot(
          accounts: [
            _account(weight: 1, fiveHour: 0.2, fable: 0.4),
            _account(fiveHour: 0.8, weekly: 0.9),
          ],
        ),
      ),
    );
    expect(
      labels,
      contains(
        'Claude · 5 hours 20% (1/2) · Weekly No usage data (0/2) · Fable 40% (1/2)',
      ),
    );
  });

  testWidgets('Codex 요금제를 한 줄에 표시하고 각 주간 평균과 부분 집계를 구별한다', (tester) async {
    final labels = await _render(
      tester,
      teamClaude: TeamClaudeState(
        connection: _teamConnection,
        snapshot: TeamClaudeSnapshot(
          accounts: [
            _account(provider: kTeamCodexProvider, plan: 'plus', weekly: 0.1),
            _account(provider: kTeamCodexProvider, plan: 'plus', weekly: 0.9),
            _account(provider: kTeamCodexProvider, plan: 'plus'),
            _account(provider: kTeamCodexProvider, plan: 'pro', weekly: 0.2),
            _account(provider: kTeamCodexProvider, plan: 'prolite', weekly: 1),
            _account(provider: kTeamCodexProvider, weekly: 0.8),
          ],
        ),
      ),
    );
    expect(labels.where((label) => label.startsWith('Codex')), [
      'Codex · Unknown plan Weekly No usage data · plus Weekly 50% (2/3) · pro Weekly 20% · prolite Weekly 100%',
    ]);
    expect(labels.join(), isNot(contains('80%')));
  });

  testWidgets('Devin 잔량을 사용률로 바꾸고 숨긴 일간 한도를 표시하지 않는다', (tester) async {
    final labels = await _render(
      tester,
      devin: const DevinUsageState(
        connection: _devinConnection,
        quota: DevinQuota(
          accountName: 'private-account-name',
          planName: 'Max',
          weeklyRemainingPercent: 70,
          dailyRemainingPercent: 15,
          hideDailyQuota: true,
          acuConsumed: 12,
        ),
      ),
    );
    expect(labels, ['Usage', 'Devin Max · Weekly 30%']);
    expect(labels.join(), isNot(contains('private-')));
  });

  testWidgets('Devin 주간 소진은 잔량 키 생략 응답도 100%로 표시한다', (tester) async {
    final labels = await _render(
      tester,
      devin: DevinUsageState(
        connection: _devinConnection,
        quota: DevinQuota.fromUserStatus(userStatusExhaustedFixture()),
      ),
    );
    expect(labels, ['Usage', 'Devin Max · Weekly 100%']);
  });

  testWidgets('Devin 백분율 필드가 없으면 ACU 누적치와 한도를 표시한다', (tester) async {
    final labels = await _render(
      tester,
      devin: const DevinUsageState(
        connection: _devinConnection,
        quota: DevinQuota(acuConsumed: 12.25, acuLimit: 50),
      ),
    );
    expect(labels, ['Usage', 'Devin · 12.3 / 50 ACU']);
  });

  testWidgets('Devin 일간 백분율을 숨겨도 홈 화면과 같이 ACU로 전환하지 않는다', (tester) async {
    final labels = await _render(
      tester,
      devin: const DevinUsageState(
        connection: _devinConnection,
        quota: DevinQuota(
          dailyRemainingPercent: 15,
          hideDailyQuota: true,
          acuConsumed: 12.25,
          acuLimit: 50,
        ),
      ),
    );
    expect(labels, ['Usage', 'Devin · No usage data']);
  });

  testWidgets('Devin 한도가 없는 ACU와 값이 전혀 없는 응답을 구별한다', (tester) async {
    expect(
      await _render(
        tester,
        devin: const DevinUsageState(
          connection: _devinConnection,
          quota: DevinQuota(acuConsumed: 5),
        ),
      ),
      ['Usage', 'Devin · 5.0 / — ACU'],
    );
    expect(
      await _render(
        tester,
        devin: const DevinUsageState(
          connection: _devinConnection,
          quota: DevinQuota(),
        ),
      ),
      ['Usage', 'Devin · No usage data'],
    );
  });

  testWidgets('초기 조회 중과 연결된 빈 응답을 구별한다', (tester) async {
    expect(
      await _render(
        tester,
        teamClaude: const TeamClaudeState(
          connection: _teamConnection,
          loading: true,
        ),
        devin: const DevinUsageState(
          connection: _devinConnection,
          loading: true,
        ),
      ),
      ['Usage', 'TeamClaude · Loading usage…', 'Devin · Loading usage…'],
    );
    expect(
      await _render(
        tester,
        teamClaude: const TeamClaudeState(
          connection: _teamConnection,
          snapshot: TeamClaudeSnapshot(accounts: []),
        ),
      ),
      ['Usage', 'Claude · No accounts', 'Codex · No accounts'],
    );
  });

  testWidgets('성공한 조회 시각이 있어도 트레이에는 사용량만 표시한다', (tester) async {
    final labels = await _render(
      tester,
      teamClaude: TeamClaudeState(
        connection: _teamConnection,
        snapshot: TeamClaudeSnapshot(
          accounts: [_account(weight: 1, fiveHour: 0.4, weekly: 0.6)],
        ),
        updatedAt: DateTime(2026, 9, 25, 23, 7),
      ),
      devin: DevinUsageState(
        connection: _devinConnection,
        quota: const DevinQuota(weeklyRemainingPercent: 30),
        updatedAt: DateTime(2026, 9, 26, 8, 2),
      ),
    );
    expect(labels, [
      'Usage',
      'Claude · 5 hours 40% · Weekly 60%',
      'Codex · No accounts',
      'Devin · Weekly 70%',
    ]);
    expect(labels.join(), isNot(contains('Updated')));
    expect(labels.join(), isNot(contains('2026-09')));
  });

  testWidgets('조회 실패 후 캐시와 원천별 오류는 보존하고 마지막 조회 시각은 표시하지 않는다', (tester) async {
    final labels = await _render(
      tester,
      teamClaude: TeamClaudeState(
        connection: _teamConnection,
        snapshot: TeamClaudeSnapshot(
          accounts: [_account(weight: 1, fiveHour: 0.4, weekly: 0.6)],
        ),
        updatedAt: DateTime(2026, 9, 25, 23, 7),
        errorKey: 'teamclaude.network_error',
        loading: true,
      ),
      devin: DevinUsageState(
        connection: _devinConnection,
        quota: const DevinQuota(weeklyRemainingPercent: 30),
        updatedAt: DateTime(2026, 9, 26, 8, 2),
        errorKey: 'devin.unauthorized',
      ),
    );
    expect(labels, contains('Claude · 5 hours 40% · Weekly 60%'));
    expect(labels, contains('Devin · Weekly 70%'));
    expect(
      labels,
      contains('TeamClaude · Refresh failed · Last successful reading'),
    );
    expect(
      labels,
      contains('Devin · Refresh failed · Last successful reading'),
    );
    expect(labels.join(), isNot(contains('Loading usage')));
    expect(labels.join(), isNot(contains('Updated')));
    expect(labels.join(), isNot(contains('2026-09')));
  });

  testWidgets('최초 조회 실패는 캐시가 있다고 표시하지 않는다', (tester) async {
    final labels = await _render(
      tester,
      devin: const DevinUsageState(
        connection: _devinConnection,
        errorKey: 'devin.unauthorized',
      ),
    );
    expect(labels, [
      'Usage',
      'Devin · No usage data',
      'Devin · Refresh failed',
    ]);
  });
}

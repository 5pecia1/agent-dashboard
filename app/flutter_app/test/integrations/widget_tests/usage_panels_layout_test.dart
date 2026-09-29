import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues, dashboardConfigValuesProvider;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/usage_panels.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_panel.dart';

import '../unit_tests/devin_usage_test.dart' as devin;
import '../unit_tests/teamclaude_test.dart' as teamclaude;

class _FixedTeamClaude extends TeamClaudeController {
  _FixedTeamClaude(this.initial);
  final TeamClaudeState initial;
  @override
  TeamClaudeState build() => initial;
  @override
  void setActive(bool active) {}
}

class _FixedDevin extends DevinUsageController {
  _FixedDevin(this.initial);
  final DevinUsageState initial;
  @override
  DevinUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

class _FixedGrok extends GrokUsageController {
  _FixedGrok(this.initial);
  final GrokUsageState initial;
  @override
  GrokUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

const _grokReading = GrokUsageReading(
  usedPercent: 40,
  window: GrokUsageWindow.weekly,
  plan: 'SuperGrok',
);

class _FixedSync extends SyncController {
  @override
  SyncControllerState build() =>
      const SyncControllerState(sync: SyncState(cursor: 1));
}

Widget _app({
  required bool teamClaude,
  required bool devinConfigured,
  required bool grok,
  required double textScale,
}) {
  return ProviderScope(
    overrides: [
      ...usageDashboardUiOverrides,
      i18nTranslateOverride.overrideWithValue((key, locale) => key),
      i18nTranslateArgsOverride.overrideWithValue(
        (key, locale, argKeys, argVals) =>
            key == 'teamclaude.partial_compact' ? argVals.join('/') : key,
      ),
      stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
      isSessionStaleFnProvider.overrideWithValue(
        ({required int now, required int updatedAt, required int staleMs}) =>
            false,
      ),
      syncControllerProvider.overrideWith(_FixedSync.new),
      dashboardConfigValuesProvider.overrideWithValue(
        const DashboardConfigValues(),
      ),
      teamClaudeControllerProvider.overrideWith(
        () => _FixedTeamClaude(
          teamClaude
              ? TeamClaudeState(
                  connection: teamclaude.connection,
                  snapshot: TeamClaudeSnapshot.fromJson(
                    teamclaude.statusFixture(),
                    quota: teamclaude.quotaFixture(),
                  ),
                )
              : const TeamClaudeState(),
        ),
      ),
      devinUsageControllerProvider.overrideWith(
        () => _FixedDevin(
          devinConfigured
              ? DevinUsageState(
                  connection: devin.connection,
                  quota: DevinQuota.fromUserStatus(devin.userStatusFixture()),
                )
              : const DevinUsageState(),
        ),
      ),
      grokUsageControllerProvider.overrideWith(
        () => _FixedGrok(
          grok
              ? const GrokUsageState(enabled: true, reading: _grokReading)
              : const GrokUsageState(),
        ),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const SessionsPage(),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double textScale,
  bool teamClaude = true,
  bool devin = true,
  bool grok = false,
}) async {
  final view = tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 1200);
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
  await tester.pumpWidget(
    _app(
      teamClaude: teamClaude,
      devinConfigured: devin,
      grok: grok,
      textScale: textScale,
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('폭 800 배율 1.0에서 두 패널이 같은 높이에 있고 Devin이 너무 좁지 않다', (
    tester,
  ) async {
    await _pump(tester, width: 800, textScale: 1.0);
    final tc = find.byType(TeamClaudePanel);
    final dv = find.byType(DevinQuotaPanel);
    expect(tc, findsOneWidget);
    expect(dv, findsOneWidget);
    expect(
      tester.getTopLeft(tc).dy,
      tester.getTopLeft(dv).dy,
      reason: '같은 행이면 두 패널의 상단 Y가 같아야 한다',
    );
    expect(
      tester.getBottomLeft(tc).dy,
      closeTo(tester.getBottomLeft(dv).dy, 1),
      reason: '같은 행이면 두 패널의 하단 Y가 같아야 한다',
    );
    expect(
      tester.getTopLeft(tc).dx,
      lessThan(tester.getTopLeft(dv).dx),
      reason: 'TeamClaude가 왼쪽, Devin이 오른쪽이어야 한다',
    );
    final widths = usageLineWidths(
      flexes: const [kTeamClaudeUsageFlex, kCompactUsageFlex],
      minWidths: [teamClaudeOuterMinWidth(), compactUsageOuterMinWidth(1)],
      width: 800,
    );
    expect(tester.getSize(dv).width, closeTo(widths[1], 1));
    expect(tester.getSize(tc).width, closeTo(widths[0], 1));
    expect(widths[1], greaterThan(250), reason: 'Devin은 지표 한 칸보다 넓다');
    expect(
      widths[0] / widths[1],
      lessThan(2),
      reason: 'TeamClaude가 Devin의 두 배를 넘지 않는다',
    );
    final claudeLabel = find.text('teamclaude.claude');
    final codexLabel = find.text('teamclaude.codex');
    expect(
      tester.getTopLeft(claudeLabel).dy,
      tester.getTopLeft(codexLabel).dy,
      reason: 'TeamClaude 안에서 Claude와 Codex 섹션이 같은 행이어야 한다',
    );
    expect(find.text('teamclaude.five_hour'), findsOneWidget);
    expect(find.text('teamclaude.weekly'), findsWidgets);
    expect(find.text('teamclaude.fable'), findsOneWidget);
    expect(
      tester.getRect(find.text('teamclaude.fable')).right,
      lessThanOrEqualTo(tester.getTopLeft(codexLabel).dx),
      reason: 'Claude 지표가 Codex 열로 넘치면 안 된다',
    );
    final fraction = find.text('1/2');
    expect(fraction, findsOneWidget);
    expect(
      tester.getCenter(fraction).dy,
      closeTo(tester.getCenter(find.text('58%')).dy, 1),
      reason: '부분 집계 축약은 퍼센트와 같은 세로 줄에 있어야 한다',
    );
    expect(
      tester.getRect(codexLabel).right,
      lessThanOrEqualTo(tester.getRect(tc).right),
    );
  });

  testWidgets('최소 폭의 합보다 좁으면 두 패널이 세로로 쌓인다', (tester) async {
    final width = teamClaudeOuterMinWidth() + compactUsageOuterMinWidth(1) - 1;
    await _pump(tester, width: width, textScale: 1.0);
    expect(
      tester.getTopLeft(find.byType(DevinQuotaPanel)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(TeamClaudePanel)).dy,
      ),
      reason: '최소 폭이 들어가지 않으면 Devin 패널은 TeamClaude 아래에 와야 한다',
    );
  });

  testWidgets('폭 760에서는 바깥 행과 안쪽 Claude/Codex 행이 모두 가로다', (tester) async {
    await _pump(tester, width: 760, textScale: 1.0);
    expect(
      tester.getTopLeft(find.byType(TeamClaudePanel)).dy,
      tester.getTopLeft(find.byType(DevinQuotaPanel)).dy,
    );
    expect(
      tester.getTopLeft(find.text('teamclaude.claude')).dy,
      tester.getTopLeft(find.text('teamclaude.codex')).dy,
      reason: '760에서는 TeamClaude 내용 폭이 440 이상이라 내부도 가로다',
    );
  });

  testWidgets('폭 600에서는 두 패널이 세로로 쌓인다', (tester) async {
    await _pump(tester, width: 600, textScale: 1.0);
    final tc = find.byType(TeamClaudePanel);
    final dv = find.byType(DevinQuotaPanel);
    expect(tester.getTopLeft(dv).dy, greaterThan(tester.getTopLeft(tc).dy));
    expect(
      tester.getTopLeft(dv).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(tc).dy),
      reason: 'Devin 패널은 TeamClaude 패널 아래에 와야 한다',
    );
  });

  testWidgets('폭 800이어도 글자 배율 2.0이면 세로로 쌓인다', (tester) async {
    await _pump(tester, width: 800, textScale: 2.0);
    expect(
      tester.getTopLeft(find.byType(DevinQuotaPanel)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(TeamClaudePanel)).dy,
      ),
    );
  });

  testWidgets('Devin만 설정되면 Devin 패널이 전체 폭을 쓰고 TeamClaude는 그리지 않는다', (
    tester,
  ) async {
    await _pump(tester, width: 800, textScale: 1.0, teamClaude: false);
    expect(
      find.byType(TeamClaudePanel, skipOffstage: false),
      findsNothing,
      reason: '미설정 패널은 위젯 트리 자체에 없어야 한다',
    );
    final dv = find.byType(DevinQuotaPanel);
    expect(dv, findsOneWidget);
    expect(
      tester.getSize(dv).width,
      greaterThan(700),
      reason: '남은 한 패널은 빈 절반을 남기지 않고 전체 폭을 써야 한다',
    );
  });

  testWidgets('TeamClaude만 설정되면 TeamClaude 패널이 전체 폭을 쓰고 Devin은 그리지 않는다', (
    tester,
  ) async {
    await _pump(tester, width: 800, textScale: 1.0, devin: false);
    expect(
      find.byType(DevinQuotaPanel, skipOffstage: false),
      findsNothing,
      reason: '미설정 패널은 위젯 트리 자체에 없어야 한다',
    );
    final tc = find.byType(TeamClaudePanel);
    expect(tc, findsOneWidget);
    expect(tester.getSize(tc).width, greaterThan(700));
  });

  testWidgets('둘 다 설정되지 않으면 아무 패널도 그리지 않는다', (tester) async {
    await _pump(
      tester,
      width: 800,
      textScale: 1.0,
      teamClaude: false,
      devin: false,
    );
    expect(find.byType(TeamClaudePanel, skipOffstage: false), findsNothing);
    expect(find.byType(DevinQuotaPanel, skipOffstage: false), findsNothing);
    expect(find.byType(GrokQuotaPanel, skipOffstage: false), findsNothing);
  });

  testWidgets('세 카드가 넓으면 남는 폭을 나눠 갖고 Devin과 Grok은 같다', (tester) async {
    const width = 1400.0;
    await _pump(tester, width: width, textScale: 1.0, grok: true);
    final widths = usageLineWidths(
      flexes: const [
        kTeamClaudeUsageFlex,
        kCompactUsageFlex,
        kCompactUsageFlex,
      ],
      minWidths: [
        teamClaudeOuterMinWidth(),
        compactUsageOuterMinWidth(1),
        compactUsageOuterMinWidth(1),
      ],
      width: width,
    );
    expect(
      tester.getSize(find.byType(TeamClaudePanel)).width,
      closeTo(widths[0], 1),
    );
    expect(
      tester.getSize(find.byType(DevinQuotaPanel)).width,
      closeTo(widths[1], 1),
    );
    expect(
      tester.getSize(find.byType(GrokQuotaPanel)).width,
      closeTo(widths[2], 1),
    );
    expect(widths[1], closeTo(widths[2], 0.1));
    expect(widths[0] / widths[1], lessThan(2));
    expect(
      tester.getBottomLeft(find.byType(TeamClaudePanel)).dy,
      closeTo(tester.getBottomLeft(find.byType(DevinQuotaPanel)).dy, 1),
    );
    expect(
      tester.getBottomLeft(find.byType(DevinQuotaPanel)).dy,
      closeTo(tester.getBottomLeft(find.byType(GrokQuotaPanel)).dy, 1),
    );
  });

  testWidgets('세 카드의 최소 폭이 들어가면 한 줄이고 작은 카드는 TeamClaude보다 좁다', (tester) async {
    final width = teamClaudeOuterMinWidth() + compactUsageOuterMinWidth(1) * 2;
    await _pump(tester, width: width, textScale: 1.0, grok: true);
    final tc = tester.getTopLeft(find.byType(TeamClaudePanel)).dy;
    final dv = tester.getTopLeft(find.byType(DevinQuotaPanel)).dy;
    final gk = tester.getTopLeft(find.byType(GrokQuotaPanel)).dy;
    expect(dv, tc);
    expect(gk, tc);
    expect(
      tester.getSize(find.byType(DevinQuotaPanel)).width,
      compactUsageOuterMinWidth(1),
    );
    expect(
      tester.getSize(find.byType(GrokQuotaPanel)).width,
      compactUsageOuterMinWidth(1),
    );
    expect(
      tester.getSize(find.byType(TeamClaudePanel)).width,
      greaterThan(tester.getSize(find.byType(DevinQuotaPanel)).width),
    );
  });

  testWidgets('세 카드의 합이 넘으면 마지막 카드만 다음 줄로 간다', (tester) async {
    final width =
        teamClaudeOuterMinWidth() + compactUsageOuterMinWidth(1) * 2 - 1;
    await _pump(tester, width: width, textScale: 1.0, grok: true);
    expect(
      tester.getTopLeft(find.byType(DevinQuotaPanel)).dy,
      tester.getTopLeft(find.byType(TeamClaudePanel)).dy,
    );
    expect(
      tester.getTopLeft(find.byType(GrokQuotaPanel)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(TeamClaudePanel)).dy,
      ),
    );
  });

  testWidgets('Devin과 Grok만 켜지면 좁은 폭에서도 한 줄이다', (tester) async {
    final width = compactUsageOuterMinWidth(1) * 2;
    await _pump(
      tester,
      width: width,
      textScale: 1.0,
      teamClaude: false,
      grok: true,
    );
    expect(
      tester.getTopLeft(find.byType(DevinQuotaPanel)).dy,
      tester.getTopLeft(find.byType(GrokQuotaPanel)).dy,
    );
    expect(find.byType(TeamClaudePanel, skipOffstage: false), findsNothing);
  });
}

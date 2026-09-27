import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_setup.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

import '../unit_tests/teamclaude_test.dart'
    show statusFixture, quotaFixture, connection;

class _FixedController extends TeamClaudeController {
  _FixedController(this.initial);
  final TeamClaudeState initial;
  @override
  TeamClaudeState build() => initial;
  @override
  void setActive(bool active) {}
}

class _FixedSync extends SyncController {
  _FixedSync([this.grouped = false]);
  final bool grouped;
  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(
      cursor: 1,
      sessions: {
        for (var i = 0; i < 12; i++)
          'session-$i': SessionViewDto(
            key: 'session-$i',
            state: i.isEven ? 'waiting_input' : 'working',
            source: i.isEven ? 'claude-code' : 'codex',
            project: '/workspace/project-${grouped ? i % 4 : i}',
            sessionId: 'session-$i',
            host: 'a-very-long-hostname.example',
            lastMessage: 'A longer message showing work in progress',
            stale: i.isEven,
          ),
      },
    ),
  );
}

void main() {
  for (final (width, scale, grouped) in [
    (360.0, 1.0, false),
    (900.0, 1.0, false),
    (1440.0, 1.0, false),
    (900.0, 2.0, false),
    (1440.0, 1.0, true),
  ]) {
    testWidgets(
      '폭 $width 글자 배율 $scale 프로젝트 그룹 $grouped 에서 여러 프로젝트를 한 화면에 표시한다',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = TeamClaudeState(
          connection: connection,
          snapshot: TeamClaudeSnapshot.fromJson(
            statusFixture(),
            quota: quotaFixture(),
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...usageDashboardUiOverrides,
              i18nTranslateOverride.overrideWithValue(
                (key, locale) => switch (key) {
                  'state.waiting_input' => 'Waiting for input',
                  'state.working' => 'Working',
                  _ => key.split('.').last,
                },
              ),
              i18nTranslateArgsOverride.overrideWithValue(
                (key, locale, names, values) => key.split('.').last,
              ),
              teamClaudeControllerProvider.overrideWith(
                () => _FixedController(state),
              ),
              syncControllerProvider.overrideWith(() => _FixedSync(grouped)),
              stateLabelKeyFnProvider.overrideWithValue(
                (s) => s == SessionStateDto.waitingInput
                    ? 'state.waiting_input'
                    : 'state.working',
              ),
              isSessionStaleFnProvider.overrideWithValue(
                ({required now, required updatedAt, required staleMs}) => false,
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const SessionsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final firstCard = tester.widget<SessionCard>(
          find.byType(SessionCard).first,
        );
        expect(firstCard.compact, width > 600 && scale <= 1.2);
        if (width >= 900 && scale <= 1.2) {
          // 부분 집계는 퍼센트 옆 축약이라 별도 줄이 없다 — 실측 209.
          expect(
            tester.getSize(find.byType(TeamClaudePanel)).height,
            lessThan(220),
          );
          expect(
            tester.getSize(find.byType(SessionCard).first).height,
            lessThanOrEqualTo(kSessionCardCompactExtent),
          );
          expect(
            find.byType(SessionCard).hitTestable().evaluate().length,
            greaterThanOrEqualTo(8),
          );
          expect(
            tester.getTopLeft(find.text('claude')).dy,
            tester
                .getTopLeft(
                  find.descendant(
                    of: find.byType(TeamClaudePanel),
                    matching: find.text('codex'),
                  ),
                )
                .dy,
          );
        } else {
          expect(
            tester.getTopLeft(find.text('claude')).dy,
            lessThan(
              tester
                  .getTopLeft(
                    find.descendant(
                      of: find.byType(TeamClaudePanel),
                      matching: find.text('codex'),
                    ),
                  )
                  .dy,
            ),
          );
        }
      },
    );
  }
  testWidgets('좁은 화면에도 네 지표가 보이고 각 제공자는 독립적으로 펼쳐진다', (tester) async {
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = TeamClaudeState(
      connection: connection,
      snapshot: TeamClaudeSnapshot.fromJson(
        statusFixture(),
        quota: quotaFixture(),
      ),
      updatedAt: DateTime(2026, 9, 13),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          i18nTranslateOverride.overrideWithValue(
            (key, locale) => key.split('.').last,
          ),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => key == 'teamclaude.partial_compact'
                ? values.join('/')
                : key.split('.').last,
          ),
          teamClaudeControllerProvider.overrideWith(
            () => _FixedController(state),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(child: TeamClaudePanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('95%'), findsOneWidget);
    // 명시 Fable 값은 첫 계정(scopedWeekly.fable 0.58)뿐 — 'team'은
    // 요약 별칭만 있어 Fable 집계에 들어가지 않으므로 부분 표시가 뜬다.
    expect(find.text('fable'), findsOneWidget);
    expect(find.text('58%'), findsOneWidget);
    // 부분 집계는 별도 줄 대신 퍼센트 옆 '1/2' 축약으로 보이고, 전체
    // 문구는 툴팁에 남는다.
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('partial'), findsNothing);
    expect(
      tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .any((w) => w.message == 'partial'),
      isTrue,
    );
    expect(find.text('reset_days'), findsOneWidget);
    expect(find.text('reset_clock'), findsOneWidget);
    expect(find.text('pro'), findsOneWidget);
    expect(find.text('prolite'), findsOneWidget);
    expect(find.text('34%'), findsOneWidget);
    expect(find.text('1%'), findsOneWidget);
    expect(find.text('name-says-codex'), findsNothing);
    await tester.tap(find.text('claude'));
    await tester.pumpAndSettle();
    expect(find.text('name-says-codex'), findsOneWidget);
    expect(find.text('name-says-claude'), findsNothing);
    expect(find.text('shared_weekly'), findsNothing);
    expect(find.text('fable_shared_note'), findsNothing);
    await tester.tap(find.text('claude'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('codex'));
    await tester.pumpAndSettle();
    expect(find.text('name-says-claude'), findsOneWidget);
    expect(find.text('name-says-codex'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('명시 Fable 데이터가 없는 계정은 Fable 지표와 공용 한도 문구를 모두 숨긴다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = TeamClaudeState(
      connection: connection,
      snapshot: TeamClaudeSnapshot.fromJson(
        {
          'accounts': [
            {
              'name': 'raven-seat',
              'provider': 'anthropic',
              'quota': {
                'unified5h': 1,
                'unified7d': 0.37,
                'unified7dSonnet': null,
                'unified7dFable': null,
                'scopedWeekly': <String, dynamic>{},
              },
            },
          ],
        },
        quota: {
          'accounts': [
            {
              'name': 'raven-seat',
              'tier': {
                'weight': 1,
                'rateLimitTier': 'default_raven',
                'seatTier': 'team_standard',
              },
              'buckets': {
                'weeklyShared': {'source': 'unified7d'},
                'weeklySonnet': {'source': 'unified7d'},
                'weeklyFable': {'source': 'unified7d'},
              },
            },
          ],
        },
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          i18nTranslateOverride.overrideWithValue(
            (key, locale) => key.split('.').last,
          ),
          // 계정별 지표는 label 인자가 보이게 하여 버킷 렌더를 검증한다.
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => key == 'teamclaude.limit_value'
                ? values.first
                : key.split('.').last,
          ),
          teamClaudeControllerProvider.overrideWith(
            () => _FixedController(state),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(child: TeamClaudePanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('fable'), findsNothing);
    await tester.tap(find.text('claude'));
    await tester.pumpAndSettle();
    expect(find.text('raven-seat'), findsOneWidget);
    expect(find.text('five_hour'), findsWidgets);
    expect(find.text('weekly'), findsWidgets);
    expect(find.text('fable'), findsNothing);
    expect(find.text('shared_weekly'), findsNothing);
    expect(find.text('fable_shared_note'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('미설정 패널은 보이지 않고 저장 직후 새 키로 조회하며 해제하면 사라진다', (tester) async {
    tester.view.physicalSize = const Size(600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var saved = const DashboardConfigValues(
      serverUrl: 'https://dash.test',
      clientToken: 'dash-key',
      cursor: 4,
      themeMode: 'dark',
    );
    final requests = <ApiRequest>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          i18nTranslateOverride.overrideWithValue(
            (key, locale) => key.split('.').last,
          ),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => key.split('.').last,
          ),
          configLoadFnProvider.overrideWithValue(() async => saved),
          configSaveFnProvider.overrideWithValue((value) async {
            saved = value;
          }),
          httpSendProvider.overrideWithValue((request) async {
            requests.add(request);
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(
                request.url.path == kTeamClaudeStatusPath
                    ? statusFixture()
                    : quotaFixture(),
              ),
            );
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [TeamClaudeSetup(), TeamClaudePanel()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('claude'), findsNothing);
    await tester.tap(find.text('title'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('teamclaude-url')),
      'https://tc.test/teamclaude/dashboard',
    );
    await tester.enterText(
      find.byKey(const ValueKey('teamclaude-key')),
      'X-Api-Key: typed-key',
    );
    await tester.tap(find.text('connect'));
    await tester.pumpAndSettle();
    expect(saved.teamClaude!.apiKey, 'typed-key');
    expect(saved.serverUrl, 'https://dash.test');
    expect(saved.clientToken, 'dash-key');
    expect(saved.cursor, 4);
    expect(saved.themeMode, 'dark');
    expect(requests.first.url.toString(), 'https://tc.test/teamclaude/status');
    expect(requests.first.headers['X-Api-Key'], 'typed-key');
    expect(find.text('claude'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('teamclaude-key')))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.text('disconnect'));
    await tester.pumpAndSettle();
    expect(saved.teamClaude, isNull);
    expect(find.text('claude'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

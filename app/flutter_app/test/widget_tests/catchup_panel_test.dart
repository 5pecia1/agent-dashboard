import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show stateLabelKeyFnProvider;
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/catchup_panel.dart';

Future<void> _pumpPanel(WidgetTester tester, List<TransitionDto> alerts) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: CatchupPanel(pendingAlerts: alerts, nowMs: 1757300000000),
          ),
        ),
      ),
    );

void main() {
  testWidgets('전이의 display_title이 행 이름에 얹힌다 — "{프로젝트} · {제목}"', (
    tester,
  ) async {
    await _pumpPanel(tester, [
      TransitionDto(
        id: 1,
        sessionKey: 'claude-code:s1',
        toState: 'waiting_input',
        project: '/repo/my-dashboard',
        displayTitle: '작업 A',
        occurredAt: 1757300000000,
      ),
      TransitionDto(
        id: 2,
        sessionKey: 'claude-code:s2',
        toState: 'waiting_input',
        project: '/repo/my-dashboard',
        displayTitle: '작업 B',
        occurredAt: 1757300000000,
      ),
    ]);
    await tester.pump();

    await tester.tap(find.text('catchup.toggle_expand'));
    await tester.pump();

    expect(find.text('my-dashboard · 작업 A'), findsOneWidget);
    expect(find.text('my-dashboard · 작업 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('제목 없는 전이는 원래대로 전체 프로젝트 경로를 보인다', (tester) async {
    await _pumpPanel(tester, [
      TransitionDto(
        id: 1,
        sessionKey: 'claude-code:s1',
        toState: 'waiting_input',
        project: '/repo/my-dashboard',
        occurredAt: 1757300000000,
      ),
    ]);
    await tester.pump();
    await tester.tap(find.text('catchup.toggle_expand'));
    await tester.pump();

    expect(find.text('/repo/my-dashboard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('120자 제목도 좁은 폭에서 레이아웃 예외 없이 그린다', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    await _pumpPanel(tester, [
      TransitionDto(
        id: 1,
        sessionKey: 'claude-code:s1',
        toState: 'waiting_input',
        project: '/repo/my-dashboard',
        displayTitle: '가' * 120,
        occurredAt: 1757300000000,
      ),
    ]);
    await tester.pump();
    await tester.tap(find.text('catchup.toggle_expand'));
    await tester.pump();

    expect(find.text('my-dashboard · ${'가' * 120}', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

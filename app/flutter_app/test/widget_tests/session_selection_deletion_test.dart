import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import '../test_helpers/session_deletion_harness.dart';

Future<void> _pump(WidgetTester tester, SessionDeletionHarness harness) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(theme: AppTheme.light(), home: const SessionsPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('서로 다른 프로젝트의 세션을 고르면 확인한 키만 삭제한다', (tester) async {
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);

    await tester.tap(find.byKey(const ValueKey('session-selection-enter')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('select-session-$deletionFirstKey')),
          )
          .semanticLabel,
      contains('#first'),
    );
    await tester.tap(find.byKey(const ValueKey(deletionFirstKey)));
    await tester.tap(
      find.byKey(const ValueKey('select-session-$deletionOtherKey')),
    );
    await tester.pumpAndSettle();
    expect(find.text('session.selection.count 2'), findsOneWidget);
    expect(find.byTooltip('session.card.delete_tooltip'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('session-selection-delete')));
    await tester.pumpAndSettle();
    expect(find.text('session.selection.delete_body 2'), findsOneWidget);
    expect(find.text(deletionProject), findsOneWidget);
    expect(find.text(deletionOtherProject), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('action.cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('session.selection.count 2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-selection-delete')));
    await tester.pumpAndSettle();
    harness.controller.addSession(deletionSession('grok:new'));
    await tester.pump();
    await tester.tap(find.text('session.selection.delete_action').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.single.body!), {
      'keys': [deletionFirstKey, deletionOtherKey],
    });
    expect(
      harness.state.sync.sessions.keys,
      containsAll([deletionSecondKey, 'grok:new']),
    );
    expect(
      find.byKey(const ValueKey('session-selection-delete')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('API 설정을 읽지 못해도 확인창을 닫고 같은 선택으로 다시 시도할 수 있다', (tester) async {
    final requests = <ApiRequest>[];
    DashboardApiConfig? config;
    final harness = SessionDeletionHarness(
      readConfig: () =>
          config ?? (throw StateError('Missing server configuration')),
      send: (request) async {
        requests.add(request);
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);
    await tester.tap(find.byKey(const ValueKey('session-selection-enter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('select-project-$deletionProject')));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(find.text('session.selection.count 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-selection-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('session.selection.delete_action').last);
      await tester.pumpAndSettle();
      if (attempt == 0) {
        expect(find.byType(AlertDialog), findsNothing);
        expect(requests, isEmpty);
        expect(harness.state.sync.sessions, hasLength(3));
        expect(harness.state.lastError, isNotNull);
        config = DashboardApiConfig(
          baseUrl: Uri.parse('https://original.example.test'),
        );
        harness.container.invalidate(dashboardApiConfigProvider);
      }
    }
    expect(jsonDecode(requests.single.body!), {
      'keys': [deletionFirstKey, deletionSecondKey],
    });
    expect(harness.state.sync.sessions.keys, [deletionOtherKey]);
  });

  testWidgets('프로젝트 선택과 현재 목록 전체 선택을 전환한다', (tester) async {
    final harness = SessionDeletionHarness(
      send: (_) async => const ApiResponse(statusCode: 200, body: '{}'),
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);
    await tester.tap(find.byKey(const ValueKey('session-selection-enter')));
    await tester.pumpAndSettle();

    final projectKey = ValueKey('select-project-$deletionProject');
    expect(
      tester.widget<Checkbox>(find.byKey(projectKey)).semanticLabel,
      contains(deletionProject),
    );
    await tester.tap(find.byKey(projectKey));
    await tester.pumpAndSettle();
    expect(find.text('session.selection.count 2'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('select-session-$deletionFirstKey')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byKey(projectKey)).value, isNull);
    await tester.tap(find.byKey(projectKey));
    await tester.pumpAndSettle();
    expect(find.text('session.selection.count 2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-selection-all')));
    await tester.pumpAndSettle();
    expect(find.text('session.selection.count 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-selection-all')));
    await tester.pumpAndSettle();
    expect(find.text('session.selection.count 0'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('session-selection-delete')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('서버 연결이 바뀌면 이전 선택을 사용하지 않는다', (tester) async {
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);
    await tester.tap(find.byKey(const ValueKey('session-selection-enter')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('select-session-$deletionFirstKey')),
    );
    await tester.pumpAndSettle();
    harness.changeConnection();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('session-selection-delete')),
      findsNothing,
    );
    expect(requests, isEmpty);
  });

  testWidgets('좁은 화면과 큰 글자에서도 선택 동작이 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = SessionDeletionHarness(
      send: (_) async => const ApiResponse(statusCode: 200, body: '{}'),
    );
    addTearDown(harness.container.dispose);
    harness.controller.clearAlerts();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue(
              (key, locale) => switch (key) {
                'session.selection.enter' => '세션 선택',
                'session.selection.select_all' => '모두 선택',
                'session.selection.delete_action' => '선택 삭제',
                _ => key,
              },
            ),
            i18nTranslateArgsOverride.overrideWithValue(
              (key, locale, keys, values) => switch (key) {
                'session.group.count' => '${values.single}개',
                'session.selection.count' => '${values.single}개 선택',
                _ => key,
              },
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const SessionsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-selection-enter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-selection-all')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('session-selection-delete')),
    );
    await tester.tap(find.byKey(const ValueKey('session-selection-delete')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

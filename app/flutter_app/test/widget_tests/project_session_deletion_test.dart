import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/delete_project_sessions_dialog.dart';
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
  testWidgets('좁은 화면과 글자 두 배에서도 확인창의 버튼을 사용할 수 있다', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = SessionDeletionHarness(
      send: (_) async => const ApiResponse(statusCode: 200, body: '{}'),
    );
    addTearDown(harness.container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue(
              (key, locale) => switch (key) {
                'session.group.delete_title' => 'Delete project sessions?',
                'session.group.delete_action' => 'Delete all',
                'action.cancel' => 'Cancel',
                _ => key,
              },
            ),
            i18nTranslateArgsOverride.overrideWithValue(
              (key, locale, keys, values) =>
                  'Delete the selected session records and saved history. Active sessions may reappear after new activity.',
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
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, child) => TextButton(
                  onPressed: () => showDeleteProjectSessionsDialog(
                    context,
                    ref,
                    project: deletionProject,
                    sessions: [
                      deletionSession(deletionFirstKey),
                      deletionSession(deletionSecondKey),
                    ],
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete all'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('프로젝트 삭제 확인창은 경로와 호스트와 개수를 보여주며 취소하면 요청이 없다', (tester) async {
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    expect(find.text(deletionProject), findsOneWidget);
    expect(
      find.text('session.group.delete_hosts linux-host, mac-host'),
      findsOneWidget,
    );
    expect(find.text('session.group.delete_body 2'), findsOneWidget);
    await tester.tap(find.text('action.cancel'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(harness.state.sync.sessions, hasLength(3));
  });

  testWidgets('확인창 이후 생긴 세션과 다른 경로는 남고 삭제 중에는 중복 실행할 수 없다', (tester) async {
    final requests = <ApiRequest>[];
    final response = Completer<ApiResponse>();
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        if (requests.length == 1) return response.future;
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    const newKey = 'grok:new-session';
    harness.controller.addSession(deletionSession(newKey));
    await tester.pump();
    await tester.tap(find.text('session.group.delete_action'));
    await tester.pump();
    expect(find.text('session.group.deleting'), findsOneWidget);
    final cancel = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'action.cancel'),
    );
    expect(cancel.onPressed, isNull);
    expect(requests, hasLength(1));
    response.complete(const ApiResponse(statusCode: 200, body: '{}'));
    await tester.pumpAndSettle();
    expect(requests.map((r) => r.url.pathSegments.last), [
      deletionFirstKey,
      deletionSecondKey,
    ]);
    expect(
      harness.state.sync.sessions.keys,
      containsAll([newKey, deletionOtherKey]),
    );
    expect(find.text('session.group.delete_success 2'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('일부 실패 시 성공과 실패 개수를 표시하고 실패한 세션은 복구된다', (tester) async {
    final harness = SessionDeletionHarness(
      send: (request) async => ApiResponse(
        statusCode: request.url.pathSegments.last == deletionSecondKey
            ? 500
            : 200,
        body: '{}',
      ),
    );
    addTearDown(harness.container.dispose);
    await _pump(tester, harness);
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('session.group.delete_action'));
    await tester.pumpAndSettle();
    expect(find.text('session.group.delete_partial 1 / 1'), findsOneWidget);
    expect(
      harness.state.sync.sessions.keys,
      containsAll([deletionSecondKey, deletionOtherKey]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('프로젝트 정보가 없는 묶음에는 모두 삭제를 표시하지 않는다', (tester) async {
    final harness = SessionDeletionHarness(
      send: (_) async => const ApiResponse(statusCode: 200, body: '{}'),
    );
    addTearDown(harness.container.dispose);
    harness.controller.addSession(
      deletionSession('generic:unknown-a', project: ''),
    );
    harness.controller.addSession(
      deletionSession('generic:unknown-b', project: ''),
    );
    await _pump(tester, harness);
    expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
    expect(find.text('session.group.unknown_project'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

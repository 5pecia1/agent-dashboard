/// [SessionDetailPage]의 0004 두 배선 — 화면 진입 시 정확히 1회의
/// `markSeen` 호출, 그리고 AppBar 삭제 아이콘 -> 확인 다이얼로그 ->
/// [SyncController.deleteSession] -> 성공 시 목록으로 pop. `session_card_
/// delete_seen_test.dart`와 파일을 나눈 이유는 그 파일들과 같다(관심사
/// 분리 + `quality_check.py budget`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';

class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

const _session = SessionViewDto(
  key: 'claude-code:s1',
  state: 'waiting_input',
  source: 'claude-code',
  sessionId: 's1',
  project: 'my-dashboard',
  host: 'dev-mac',
  lastOccurredAt: 5000,
  updatedAt: 5000,
  lastTransitionId: 9,
);

Widget _wrap({
  required Future<ApiResponse> Function(ApiRequest request) httpHandler,
  Widget Function(BuildContext)? homeBuilder,
}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue((key, locale) => key),
    i18nTranslateArgsOverride.overrideWithValue(
      (key, locale, argKeys, argVals) => key,
    ),
    stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
    isSessionStaleFnProvider.overrideWithValue(
      ({required int now, required int updatedAt, required int staleMs}) =>
          false,
    ),
    syncControllerProvider.overrideWith(
      () => _FixedSyncController(
        const SyncControllerState(
          sync: SyncState(
            sessions: <String, SessionViewDto>{'claude-code:s1': _session},
          ),
        ),
      ),
    ),
    dashboardApiConfigProvider.overrideWithValue(
      DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
    ),
    httpSendProvider.overrideWithValue((ApiRequest request) {
      if (request.url.path == kEventsPath) {
        return Future<ApiResponse>.value(
          const ApiResponse(
            statusCode: 200,
            body: '{"events":[],"has_more":false,"next_before_id":null}',
          ),
        );
      }
      return httpHandler(request);
    }),
  ],
  child: MaterialApp(
    home: homeBuilder != null
        ? Builder(builder: homeBuilder)
        : const SessionDetailPage(session: _session),
  ),
);

void main() {
  group('0004 seen: 화면 진입 시 markSeen', () {
    testWidgets('POST /dashboard/sessions/{key}/seen을 정확히 1회 부른다', (
      tester,
    ) async {
      final requests = <ApiRequest>[];
      await tester.pumpWidget(
        _wrap(
          httpHandler: (request) async {
            requests.add(request);
            return const ApiResponse(
              statusCode: 200,
              body: '{"ok":true,"seen_transition_id":9}',
            );
          },
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.pathSegments, [
        'dashboard',
        'sessions',
        'claude-code:s1',
        'seen',
      ]);
    });

    testWidgets('실패해도 화면은 죽지 않고 오류를 드러내지 않는다(실패 무해)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          httpHandler: (request) async =>
              throw const DashboardNetworkFailure('가짜 네트워크 실패'),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('session.detail.title'), findsOneWidget);
    });
  });

  group('삭제 UI: 상세 화면 AppBar', () {
    testWidgets('삭제 아이콘 -> 확인 -> 성공하면 이전 화면으로 pop한다', (tester) async {
      await tester.pumpWidget(
        _wrap(
          homeBuilder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SessionDetailPage(session: _session),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          httpHandler: (request) async =>
              const ApiResponse(statusCode: 200, body: '{}'),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('session.detail.title'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('session.delete.dialog_title'), findsOneWidget);

      await tester.tap(find.text('session.delete.confirm_action'));
      await tester.pumpAndSettle();

      expect(find.text('session.detail.title'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets(
      '다이얼로그가 열리면 삭제 버튼에 포커스가 있고, Enter로 확정하면 DELETE가 정확히 1회 나간다',
      (tester) async {
        final requests = <ApiRequest>[];
        await tester.pumpWidget(
          _wrap(
            homeBuilder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SessionDetailPage(session: _session),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            httpHandler: (request) async {
              requests.add(request);
              return const ApiResponse(statusCode: 200, body: '{}');
            },
          ),
        );
        await tester.pump();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        expect(find.text('session.delete.dialog_title'), findsOneWidget);

        final deleteButton = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FilledButton>();
        expect(
          deleteButton,
          isNotNull,
          reason: '다이얼로그가 열리는 순간 primaryFocus가 파괴적 삭제 버튼 안에 있어야 한다',
        );
        expect(
          find.descendant(
            of: find.byWidget(deleteButton!),
            matching: find.text('session.delete.confirm_action'),
          ),
          findsOneWidget,
          reason: '취소(TextButton)가 아니라 삭제(FilledButton) 버튼이어야 한다',
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(find.text('session.delete.dialog_title'), findsNothing);
        expect(
          requests.where((request) => request.method == 'DELETE'),
          hasLength(1),
          reason: 'Enter 한 번이 삭제 확정 한 번 — seen POST와 섞이면 안 된다',
        );
        expect(find.byType(SessionDetailPage), findsNothing);
      },
    );

    testWidgets('삭제 아이콘 -> 취소하면 화면에 그대로 남는다', (tester) async {
      var deleteCalls = 0;
      await tester.pumpWidget(
        _wrap(
          httpHandler: (request) async {
            if (request.method == 'DELETE') deleteCalls++;
            return const ApiResponse(statusCode: 200, body: '{}');
          },
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('action.cancel'));
      await tester.pumpAndSettle();

      expect(find.text('session.detail.title'), findsOneWidget);
      expect(deleteCalls, 0);
    });

    testWidgets('삭제가 실패하면 화면에 남고, 다시 지울 수 있는 상태를 유지한다', (tester) async {
      await tester.pumpWidget(
        _wrap(
          httpHandler: (request) async {
            if (request.method == 'DELETE') {
              return const ApiResponse(statusCode: 500, body: '{"error":"boom"}');
            }
            return const ApiResponse(statusCode: 200, body: '{}');
          },
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('session.delete.confirm_action'));
      await tester.pumpAndSettle();

      expect(
        find.text('session.detail.title'),
        findsOneWidget,
        reason: '삭제 실패 시 이 화면에서 pop하면 안 된다(컨트롤러가 이미 롤백 + lastError로 처리)',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

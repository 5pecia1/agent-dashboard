/// 세션 상세의 **실제 진입 경로** 회귀 테스트 — 목록의 [SessionCard] 탭 ->
/// `pushNamed` -> [SessionDeepLinkPage] -> [SessionDetailPage].
///
/// `session_detail_page_delete_seen_test.dart`는 상세 페이지를 라우트에 직접
/// 올려 시험한다. 그 경로는 [SessionDeepLinkPage]를 거치지 않아 다음 레이스를
/// 못 잡는다: `deleteSession`이 응답 전에 세션을 상태에서 지우면(낙관 삭제)
/// [SessionDeepLinkPage]가 상세 페이지를 "not found"로 갈아끼우고, dispose된
/// `State`의 `context.mounted`가 false라 성공 후 pop이 스킵된다 — 네트워크가
/// 한 프레임이라도 넘기면 실사용에서 재현되는 결함이었다. 그래서 이 파일은
/// DELETE 응답에 지연을 둔 채 실제 라우트로 검증한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

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

/// DELETE 응답을 실제 네트워크처럼 한 프레임 이상 늦춘다 — 지연이 없으면
/// `deleteSession`의 `await`가 마이크로태스크로 끝나 dispose 레이스가
/// 재현되지 않는다.
const _deleteResponseDelay = Duration(milliseconds: 100);

const _frameStep = Duration(milliseconds: 50);

Widget _wrap() => ProviderScope(
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
            cursor: 1,
            sessions: <String, SessionViewDto>{'claude-code:s1': _session},
          ),
        ),
      ),
    ),
    dashboardApiConfigProvider.overrideWithValue(
      DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
    ),
    httpSendProvider.overrideWithValue(
      (ApiRequest request) async {
        if (request.method == 'DELETE') {
          await Future<void>.delayed(_deleteResponseDelay);
        }
        if (request.url.path == kEventsPath) {
          return const ApiResponse(
            statusCode: 200,
            body: '{"events":[],"has_more":false,"next_before_id":null}',
          );
        }
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    ),
  ],
  child: MaterialApp(
    onGenerateRoute: (settings) =>
        generateAppRoute(settings) ??
        MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const SessionsPage(),
        ),
  ),
);

/// 이 앱은 주기 타이머가 돌아 `pumpAndSettle`이 끝나지 않으므로 고정 길이
/// 프레임만 돌린다.
Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(_frameStep);
  }
}

/// 목록에서 세션 카드를 탭해 실제 라우트로 상세에 들어간다.
Future<void> _enterSessionDetail(WidgetTester tester) async {
  await tester.tap(find.byType(SessionCard));
  await _pumpFrames(tester, 10);
  expect(find.byType(SessionDeepLinkPage), findsOneWidget);
}

void main() {
  testWidgets('세션 카드로 들어간 상세에서 AppBar 뒤로가기를 누르면 목록으로 돌아간다', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await _pumpFrames(tester, 10);

    await _enterSessionDetail(tester);

    final back = find.byType(BackButton);
    expect(back, findsOneWidget);
    await tester.tap(back);
    await _pumpFrames(tester, 30);

    expect(find.byType(SessionDeepLinkPage), findsNothing);
    expect(find.byType(SessionsPage), findsOneWidget);
  });

  testWidgets('삭제 응답이 늦어도 성공하면 상세 라우트가 pop되어 목록이 보인다', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await _pumpFrames(tester, 10);

    await _enterSessionDetail(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await _pumpFrames(tester, 10);
    expect(find.text('session.delete.dialog_title'), findsOneWidget);

    await tester.tap(find.text('session.delete.confirm_action'));
    // 낙관 삭제로 "not found"가 잠깐 보일 수 있는 구간 + 지연된 응답 완료까지
    await _pumpFrames(tester, 30);

    expect(find.byType(SessionDeepLinkPage), findsNothing);
    expect(find.byType(SessionsPage), findsOneWidget);
    expect(
      find.byType(SessionCard),
      findsNothing,
      reason: '삭제된 세션은 목록에도 없어야 한다',
    );
  });

  testWidgets('삭제가 실패하면 상세 라우트에 남고 세션이 복원된다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
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
                  cursor: 1,
                  sessions: <String, SessionViewDto>{'claude-code:s1': _session},
                ),
              ),
            ),
          ),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          ),
          httpSendProvider.overrideWithValue(
            (ApiRequest request) async {
              if (request.method == 'DELETE') {
                await Future<void>.delayed(_deleteResponseDelay);
                return const ApiResponse(
                  statusCode: 500,
                  body: '{"error":"boom"}',
                );
              }
              if (request.url.path == kEventsPath) {
                return const ApiResponse(
                  statusCode: 200,
                  body:
                      '{"events":[],"has_more":false,"next_before_id":null}',
                );
              }
              return const ApiResponse(statusCode: 200, body: '{}');
            },
          ),
        ],
        child: MaterialApp(
          onGenerateRoute: (settings) =>
              generateAppRoute(settings) ??
              MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => const SessionsPage(),
              ),
        ),
      ),
    );
    await _pumpFrames(tester, 10);

    await _enterSessionDetail(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await _pumpFrames(tester, 10);
    await tester.tap(find.text('session.delete.confirm_action'));
    await _pumpFrames(tester, 30);

    expect(
      find.byType(SessionDetailPage),
      findsOneWidget,
      reason: '삭제 실패 시 pop하면 안 된다 — 롤백된 세션이 상세로 다시 보인다',
    );
    expect(tester.takeException(), isNull);
  });
}

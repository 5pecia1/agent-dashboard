/// [SessionCard]의 0004 두 표시 — 미확인 점(`_UnseenDot`)과 hover 삭제(×)
/// — 그리고 그 삭제가 여는 확인 다이얼로그([showDeleteSessionDialog])의
/// 위젯 테스트. `session_card_test.dart`와 파일을 나눈 이유는 그 파일과
/// 같다(관심사 분리 + `quality_check.py budget`).
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/app.dart' show AppVimNavigationScope;
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

/// `_UnseenDot`은 `session_card.dart`의 private 클래스라 `find.byType`으로
/// 못 찾는다 — 런타임 타입 이름 문자열로 찾는다(private여도 리플렉션 없이
/// `runtimeType.toString()`은 항상 읽을 수 있다).
Finder _findByPrivateTypeName(String name) =>
    find.byWidgetPredicate((widget) => '${widget.runtimeType}' == name);

Widget _wrap({
  required SessionViewDto session,
  required SyncControllerState state,
  VoidCallback? onTap,
  Future<ApiResponse> Function(ApiRequest request)? httpHandler,
}) => _wrapWith(
  state: state,
  httpHandler: httpHandler,
  body: SessionCard(session: session, onTap: onTap),
);

Widget _wrapWith({
  required Widget body,
  required SyncControllerState state,
  Future<ApiResponse> Function(ApiRequest request)? httpHandler,
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
    syncControllerProvider.overrideWith(() => _FixedSyncController(state)),
    dashboardApiConfigProvider.overrideWithValue(
      DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
    ),
    if (httpHandler != null)
      httpSendProvider.overrideWithValue(
        (ApiRequest request) => httpHandler(request),
      ),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) =>
        AppVimNavigationScope(child: child ?? const SizedBox.shrink()),
    home: Scaffold(body: body),
  ),
);

/// 카드 중앙으로 마우스 포인터를 올린다(데스크톱 hover 흉내).
Future<TestGesture> _hoverOverCard(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(SessionCard)));
  await tester.pumpAndSettle();
  return gesture;
}

String? _focusedSessionKey() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<SessionCard>()
    ?.session
    .key;

const _session = SessionViewDto(
  key: 'claude-code:s1',
  state: 'working',
  source: 'claude-code',
  sessionId: 's1',
  project: 'my-dashboard',
  host: 'dev-mac',
  lastOccurredAt: 5000,
  updatedAt: 5000,
);

void main() {
  group('0004 seen: 미확인 점(_UnseenDot)', () {
    testWidgets('lastTransitionId > seenWatermark면 점이 보인다', (tester) async {
      final session = _session.copyWith(lastTransitionId: 5);
      await tester.pumpWidget(
        _wrap(
          session: session,
          state: const SyncControllerState(sync: SyncState(seenWatermark: 0)),
        ),
      );
      await tester.pump();

      expect(_findByPrivateTypeName('_UnseenDot'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lastTransitionId가 없으면 점이 없다', (tester) async {
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(sync: SyncState(seenWatermark: 0)),
        ),
      );
      await tester.pump();

      expect(_findByPrivateTypeName('_UnseenDot'), findsNothing);
    });

    testWidgets('seenTransitionIds의 값이 lastTransitionId 이상이면 점이 없다', (
      tester,
    ) async {
      final session = _session.copyWith(lastTransitionId: 5);
      await tester.pumpWidget(
        _wrap(
          session: session,
          state: const SyncControllerState(
            sync: SyncState(
              seenWatermark: 0,
              seenTransitionIds: <String, int>{'claude-code:s1': 5},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_findByPrivateTypeName('_UnseenDot'), findsNothing);
    });

    testWidgets('첫 도입 미확인 벽 — seenTransitionIds에 값이 없어도 seenWatermark 이하면 점이 없다', (
      tester,
    ) async {
      final session = _session.copyWith(lastTransitionId: 30);
      await tester.pumpWidget(
        _wrap(
          session: session,
          state: const SyncControllerState(
            sync: SyncState(seenWatermark: 30),
          ),
        ),
      );
      await tester.pump();

      expect(_findByPrivateTypeName('_UnseenDot'), findsNothing);
    });
  });

  group('삭제 UI: hover ×는 데스크톱 마우스에서만 나타난다', () {
    testWidgets('마우스가 카드 위에 없으면 삭제 아이콘이 없다', (tester) async {
      await tester.pumpWidget(
        _wrap(session: _session, state: const SyncControllerState()),
      );
      await tester.pump();

      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('마우스를 올리면 삭제 아이콘이 나타나고, 벗어나면 사라진다', (tester) async {
      await tester.pumpWidget(
        _wrap(session: _session, state: const SyncControllerState()),
      );
      await tester.pump();

      final gesture = await _hoverOverCard(tester);

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(
        find.byTooltip('session.card.delete_tooltip'),
        findsOneWidget,
        reason: '카드 hover 삭제 버튼은 상세 화면 AppBar와 다른 키를 쓴다(호출 맥락이 다름)',
      );

      // 포인터 자체를 치워 hover를 끈다 — 카드가 화면 전체를 채울 수도
      // 있어(테스트 뷰포트 안에 "카드 밖" 좌표가 없을 수 있다) 좌표를
      // 옮기는 대신 장치 자체를 제거한다: `MouseTracker`는 연결이 끊긴
      // 포인터를 모든 `MouseRegion`에서 즉시 `onExit`로 접는다.
      await gesture.removePointer();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });

  group('삭제 UI: 확인 다이얼로그', () {
    testWidgets('hover 삭제 아이콘을 탭하면 프로젝트명 + 문구 + 취소/삭제 버튼을 보여준다', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(session: _session, state: const SyncControllerState()),
      );
      await tester.pump();
      final gesture = await _hoverOverCard(tester);
      addTearDown(gesture.removePointer);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('session.delete.dialog_title'), findsOneWidget);
      expect(find.text('session.delete.dialog_body'), findsOneWidget);
      // 프로젝트명(basename)은 i18n이 아니라 실제 세션 데이터 — projectBasename
      // 결과 그대로 노출돼야 한다.
      expect(find.text('my-dashboard'), findsWidgets);
      expect(find.text('action.cancel'), findsOneWidget);
      expect(find.text('session.delete.confirm_action'), findsOneWidget);
    });

    testWidgets('취소를 누르면 삭제 요청이 나가지 않는다', (tester) async {
      var apiCalls = 0;
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(
            sync: SyncState(
              sessions: <String, SessionViewDto>{'claude-code:s1': _session},
            ),
          ),
          httpHandler: (request) async {
            apiCalls++;
            return const ApiResponse(statusCode: 200, body: '{}');
          },
        ),
      );
      await tester.pump();
      final gesture = await _hoverOverCard(tester);
      addTearDown(gesture.removePointer);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text('action.cancel'));
      await tester.pumpAndSettle();

      expect(find.text('session.delete.dialog_title'), findsNothing);
      expect(apiCalls, 0);
    });

    testWidgets('삭제를 확정하면 DELETE /dashboard/sessions/{key}가 정확히 1회 나간다', (
      tester,
    ) async {
      final requests = <ApiRequest>[];
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(
            sync: SyncState(
              sessions: <String, SessionViewDto>{'claude-code:s1': _session},
            ),
          ),
          httpHandler: (request) async {
            requests.add(request);
            return const ApiResponse(statusCode: 200, body: '{}');
          },
        ),
      );
      await tester.pump();
      final gesture = await _hoverOverCard(tester);
      addTearDown(gesture.removePointer);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text('session.delete.confirm_action'));
      await tester.pumpAndSettle();

      expect(find.text('session.delete.dialog_title'), findsNothing);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.pathSegments, [
        'dashboard',
        'sessions',
        'claude-code:s1',
      ]);
    });
  });

  group('삭제 UI: 카드의 다른 제스처와 겹치지 않는다', () {
    testWidgets('hover ×를 탭해도 카드 자체의 onTap(상세 이동)은 트리거되지 않는다', (
      tester,
    ) async {
      var navigated = 0;
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(
            sync: SyncState(
              sessions: <String, SessionViewDto>{'claude-code:s1': _session},
            ),
          ),
          onTap: () => navigated++,
          httpHandler: (request) async =>
              const ApiResponse(statusCode: 200, body: '{}'),
        ),
      );
      await tester.pump();
      final gesture = await _hoverOverCard(tester);
      addTearDown(gesture.removePointer);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      // 다이얼로그 위 "삭제" 버튼까지 탭해도 그 아래 깔린 카드의 onTap으로
      // 번지면 안 된다.
      await tester.tap(find.text('session.delete.confirm_action'));
      await tester.pumpAndSettle();

      expect(navigated, 0);
    });

    testWidgets('삭제 아이콘이 없는 자리(카드 본문)를 탭하면 여전히 상세로 이동한다', (
      tester,
    ) async {
      var navigated = 0;
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(),
          onTap: () => navigated++,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('my-dashboard'));
      await tester.pump();

      expect(navigated, 1);
    });
  });

  group('키보드: 포커스된 카드의 Backspace/Delete 삭제', () {
    testWidgets('Backspace를 누르면 확인 다이얼로그가 열리고, 확정 전에는 요청이 없다가 확정하면 DELETE가 정확히 1회 나간다', (
      tester,
    ) async {
      final requests = <ApiRequest>[];
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(
            sync: SyncState(
              sessions: <String, SessionViewDto>{'claude-code:s1': _session},
            ),
          ),
          onTap: () {},
          httpHandler: (request) async {
            requests.add(request);
            return const ApiResponse(statusCode: 200, body: '{}');
          },
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:s1');

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      expect(find.text('session.delete.dialog_title'), findsOneWidget);
      expect(requests, isEmpty);

      await tester.tap(find.text('session.delete.confirm_action'));
      await tester.pumpAndSettle();

      expect(find.text('session.delete.dialog_title'), findsNothing);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.pathSegments, [
        'dashboard',
        'sessions',
        'claude-code:s1',
      ]);
    });

    testWidgets('forward Delete 키를 눌러도 같은 확인 다이얼로그가 열린다', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(
            sync: SyncState(
              sessions: <String, SessionViewDto>{'claude-code:s1': _session},
            ),
          ),
          onTap: () {},
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:s1');

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(find.text('session.delete.dialog_title'), findsOneWidget);
    });
  });

  group('키보드: h/j/k/l은 포커스를 방향대로 옮긴다', () {
    testWidgets('l은 포커스를 오른쪽 카드로 옮기고 h는 다시 왼쪽 카드로 되돌린다', (
      tester,
    ) async {
      const left = SessionViewDto(
        key: 'claude-code:left',
        state: 'working',
        source: 'claude-code',
        sessionId: 'left',
        project: 'left-proj',
        host: 'dev-mac',
        lastOccurredAt: 5000,
        updatedAt: 5000,
      );
      const right = SessionViewDto(
        key: 'claude-code:right',
        state: 'working',
        source: 'claude-code',
        sessionId: 'right',
        project: 'right-proj',
        host: 'dev-mac',
        lastOccurredAt: 5000,
        updatedAt: 5000,
      );
      await tester.pumpWidget(
        _wrapWith(
          state: const SyncControllerState(),
          body: Row(
            children: [
              Expanded(child: SessionCard(session: left, onTap: () {})),
              Expanded(child: SessionCard(session: right, onTap: () {})),
            ],
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:left');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:right');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:left');
    });

    testWidgets('j는 포커스를 아래 카드로 옮기고 k는 다시 위 카드로 되돌린다', (
      tester,
    ) async {
      const top = SessionViewDto(
        key: 'claude-code:top',
        state: 'working',
        source: 'claude-code',
        sessionId: 'top',
        project: 'top-proj',
        host: 'dev-mac',
        lastOccurredAt: 5000,
        updatedAt: 5000,
      );
      const bottom = SessionViewDto(
        key: 'claude-code:bottom',
        state: 'working',
        source: 'claude-code',
        sessionId: 'bottom',
        project: 'bottom-proj',
        host: 'dev-mac',
        lastOccurredAt: 5000,
        updatedAt: 5000,
      );
      await tester.pumpWidget(
        _wrapWith(
          state: const SyncControllerState(),
          body: Column(
            children: [
              SessionCard(session: top, onTap: () {}),
              SessionCard(session: bottom, onTap: () {}),
            ],
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:top');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:bottom');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:top');
    });
  });

  group('키보드: 기존 활성화 제스처가 유지된다', () {
    testWidgets('포커스된 카드에서 Enter를 누르면 카드의 onTap이 트리거된다', (
      tester,
    ) async {
      var navigated = 0;
      await tester.pumpWidget(
        _wrap(
          session: _session,
          state: const SyncControllerState(),
          onTap: () => navigated++,
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedSessionKey(), 'claude-code:s1');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(navigated, 1);
    });
  });
}

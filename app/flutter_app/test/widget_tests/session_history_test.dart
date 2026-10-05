import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/ui/widgets/session_history.dart';

const _sessionKey = 'claude-code:s1';
const _narrowViewport = Size(360, 800);

ApiResponse _page(
  List<Map<String, dynamic>> events, {
  bool hasMore = false,
  int? nextBeforeId,
}) => ApiResponse(
  statusCode: 200,
  body: jsonEncode(<String, dynamic>{
    'events': events,
    'has_more': hasMore,
    'next_before_id': nextBeforeId,
  }),
);

Map<String, dynamic> _eventJson(
  int id, {
  String event = 'Notification',
  String sessionKey = _sessionKey,
  String? message,
  String? displayTitle,
}) => <String, dynamic>{
  'id': id,
  'session_key': sessionKey,
  'source': 'claude-code',
  'event': event,
  'message': message,
  'display_title': displayTitle,
  'received_at': 1757300000000 - id,
};

DashboardApiConfig _config(String host) =>
    DashboardApiConfig(baseUrl: Uri.parse('https://$host'), clientToken: 'tok');

Widget _wrap({
  required Future<ApiResponse> Function(ApiRequest request) handler,
  String sessionKey = _sessionKey,
  Key? key,
  DashboardApiConfig? config,
}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue((key, locale) => key),
    i18nTranslateArgsOverride.overrideWithValue(
      (key, locale, argKeys, argVals) => key,
    ),
    dashboardApiConfigProvider.overrideWithValue(
      config ?? _config('example.test'),
    ),
    httpSendProvider.overrideWithValue(handler),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [SessionHistory(key: key, sessionKey: sessionKey)],
      ),
    ),
  ),
);

void main() {
  testWidgets('첫 페이지를 열고 "이전 기록 더 보기"가 커서로 다음 페이지를 붙인다', (tester) async {
    final requests = <ApiRequest>[];
    await tester.pumpWidget(
      _wrap(
        handler: (request) async {
          requests.add(request);
          if (!request.url.queryParameters.containsKey('before_id')) {
            return _page(
              <Map<String, dynamic>>[
                _eventJson(3, message: '최신 이벤트'),
                _eventJson(2, message: '이전 이벤트'),
              ],
              hasMore: true,
              nextBeforeId: 2,
            );
          }
          return _page(<Map<String, dynamic>>[
            _eventJson(1, message: '가장 오래된 이벤트'),
          ]);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('session.history.title'), findsOneWidget);
    expect(find.text('최신 이벤트', findRichText: true), findsOneWidget);
    expect(find.text('이전 이벤트', findRichText: true), findsOneWidget);
    expect(requests.single.url.queryParameters['session_key'], _sessionKey);
    expect(requests.single.url.queryParameters['limit'], '$kHistoryPageSize');
    expect(requests.single.url.queryParameters['kind'], 'all');

    await tester.tap(find.text('session.history.older'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests.last.url.queryParameters['before_id'], '2');
    expect(find.text('가장 오래된 이벤트', findRichText: true), findsOneWidget);
    expect(find.text('session.history.older'), findsNothing);
  });

  testWidgets('"내 발언" 필터는 클라이언트 추림이 아니라 서버에 kind=prompts로 나간다', (
    tester,
  ) async {
    final requests = <ApiRequest>[];
    await tester.pumpWidget(
      _wrap(
        handler: (request) async {
          requests.add(request);
          if (request.url.queryParameters['kind'] == 'prompts') {
            return _page(<Map<String, dynamic>>[
              _eventJson(1, event: 'UserPromptSubmit', message: '오래된 발언'),
            ]);
          }
          return _page(<Map<String, dynamic>>[
            _eventJson(3, message: '기계 이벤트'),
          ]);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('기계 이벤트', findRichText: true), findsOneWidget);

    await tester.tap(find.text('session.history.prompts'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests.last.url.queryParameters['kind'], 'prompts');
    expect(
      requests.last.url.queryParameters.containsKey('before_id'),
      isFalse,
      reason: '필터를 바꾸면 새 필터의 첫 페이지부터 다시 읽는다',
    );
    expect(find.text('오래된 발언', findRichText: true), findsOneWidget);
    expect(find.text('session.history.user_prompt'), findsOneWidget);
    expect(find.text('기계 이벤트', findRichText: true), findsNothing);
  });

  testWidgets('이어 읽기가 실패해도 받아 둔 행을 지키고 재시도는 같은 커서로 간다', (
    tester,
  ) async {
    final requests = <ApiRequest>[];
    var failOlder = true;
    await tester.pumpWidget(
      _wrap(
        handler: (request) async {
          requests.add(request);
          if (!request.url.queryParameters.containsKey('before_id')) {
            return _page(
              <Map<String, dynamic>>[_eventJson(2, message: '남아 있어야 한다')],
              hasMore: true,
              nextBeforeId: 2,
            );
          }
          if (failOlder) {
            return const ApiResponse(statusCode: 500, body: '{"error":"boom"}');
          }
          return _page(<Map<String, dynamic>>[
            _eventJson(1, message: '뒤 페이지'),
          ]);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('남아 있어야 한다', findRichText: true), findsOneWidget);

    await tester.tap(find.text('session.history.older'));
    await tester.pumpAndSettle();

    expect(find.text('session.history.error'), findsOneWidget);
    expect(
      find.text('남아 있어야 한다', findRichText: true),
      findsOneWidget,
      reason: '이어 읽기 실패가 이미 받은 행을 지우면 안 된다',
    );

    failOlder = false;
    await tester.tap(find.text('action.retry'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(3));
    expect(
      requests.last.url.queryParameters['before_id'],
      '2',
      reason: '재시도는 실패한 것과 같은 커서로 다시 간다',
    );
    expect(find.text('뒤 페이지', findRichText: true), findsOneWidget);
  });

  testWidgets('새로고침은 커서 없이(before_id 없이) 최신부터 다시 읽는다', (tester) async {
    final requests = <ApiRequest>[];
    await tester.pumpWidget(
      _wrap(
        handler: (request) async {
          requests.add(request);
          if (!request.url.queryParameters.containsKey('before_id')) {
            return _page(
              <Map<String, dynamic>>[_eventJson(3)],
              hasMore: true,
              nextBeforeId: 3,
            );
          }
          return _page(<Map<String, dynamic>>[_eventJson(1)]);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('session.history.older'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(requests, hasLength(3));
    expect(
      requests.last.url.queryParameters.containsKey('before_id'),
      isFalse,
      reason: '새로고침은 가장 최근 페이지부터 다시 시작한다',
    );
  });

  testWidgets('필터를 바꾼 뒤 늦게 도착한 옛 필터 응답은 버린다(Completer)', (tester) async {
    final pending = <ApiRequest, Completer<ApiResponse>>{};
    await tester.pumpWidget(
      _wrap(
        handler: (request) {
          final completer = Completer<ApiResponse>();
          pending[request] = completer;
          return completer.future;
        },
      ),
    );
    await tester.pump();
    expect(pending, hasLength(1));
    final staleRequest = pending.keys.single;

    await tester.tap(find.text('session.history.prompts'));
    await tester.pump();
    expect(pending, hasLength(2));

    pending[staleRequest]!.complete(
      _page(<Map<String, dynamic>>[_eventJson(9, message: '옛 응답 행')]),
    );
    await tester.pump();
    expect(find.text('옛 응답 행', findRichText: true), findsNothing);

    final freshRequest = pending.keys
        .firstWhere((request) => request != staleRequest);
    expect(freshRequest.url.queryParameters['kind'], 'prompts');
    pending[freshRequest]!.complete(
      _page(<Map<String, dynamic>>[
        _eventJson(1, event: 'UserPromptSubmit', message: '새 발언'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('새 발언', findRichText: true), findsOneWidget);
    expect(find.text('옛 응답 행', findRichText: true), findsNothing);
  });

  testWidgets('요청이 진행 중일 때 dispose돼도 안전하다', (tester) async {
    final completer = Completer<ApiResponse>();
    await tester.pumpWidget(_wrap(handler: (_) => completer.future));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    completer.complete(
      _page(<Map<String, dynamic>>[_eventJson(1)]),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('세션이 바뀌면 옛 세션의 행과 늦은 응답을 버린다(ValueKey로 State 교체)', (
    tester,
  ) async {
    final completers = <String, Completer<ApiResponse>>{};
    Future<ApiResponse> handler(ApiRequest request) {
      final key = request.url.queryParameters['session_key']!;
      return (completers[key] ??= Completer<ApiResponse>()).future;
    }

    await tester.pumpWidget(
      _wrap(handler: handler, sessionKey: _sessionKey, key: const ValueKey(_sessionKey)),
    );
    await tester.pump();
    completers[_sessionKey]!.complete(
      _page(<Map<String, dynamic>>[_eventJson(1, message: '세션A 행')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('세션A 행', findRichText: true), findsOneWidget);

    const otherKey = 'codex:s2';
    await tester.pumpWidget(
      _wrap(handler: handler, sessionKey: otherKey, key: const ValueKey(otherKey)),
    );
    await tester.pump();
    expect(find.text('세션A 행', findRichText: true), findsNothing);
    expect(completers.containsKey(otherKey), isTrue);

    completers[otherKey]!.complete(
      _page(<Map<String, dynamic>>[
        _eventJson(1, sessionKey: otherKey, message: '세션B 행'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('세션B 행', findRichText: true), findsOneWidget);
    expect(find.text('세션A 행', findRichText: true), findsNothing);
  });

  testWidgets('서버 설정이 바뀌면 진행 중인 옛 응답을 버리고 새 설정으로 다시 읽는다', (
    tester,
  ) async {
    final requests = <ApiRequest>[];
    final completers = <Completer<ApiResponse>>[];
    Future<ApiResponse> handler(ApiRequest request) {
      requests.add(request);
      final completer = Completer<ApiResponse>();
      completers.add(completer);
      return completer.future;
    }

    await tester.pumpWidget(_wrap(handler: handler, config: _config('a.test')));
    await tester.pump();
    expect(requests.single.url.host, 'a.test');

    await tester.pumpWidget(_wrap(handler: handler, config: _config('b.test')));
    await tester.pump();
    expect(requests, hasLength(2));
    expect(requests.last.url.host, 'b.test');

    completers[0].complete(
      _page(<Map<String, dynamic>>[_eventJson(9, message: '옛 서버 행')]),
    );
    await tester.pump();
    expect(find.text('옛 서버 행', findRichText: true), findsNothing);

    completers[1].complete(
      _page(<Map<String, dynamic>>[_eventJson(1, message: '새 서버 행')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('새 서버 행', findRichText: true), findsOneWidget);
    expect(find.text('옛 서버 행', findRichText: true), findsNothing);
  });

  testWidgets('서버 설정 변경은 이미 표시된 행도 즉시 비운다', (tester) async {
    final completers = <Completer<ApiResponse>>[];
    Future<ApiResponse> handler(ApiRequest request) {
      final completer = Completer<ApiResponse>();
      completers.add(completer);
      return completer.future;
    }

    await tester.pumpWidget(_wrap(handler: handler, config: _config('a.test')));
    completers[0].complete(
      _page(<Map<String, dynamic>>[
        _eventJson(1, event: 'UserPromptSubmit', message: '서버A 발언'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('서버A 발언', findRichText: true), findsOneWidget);

    await tester.pumpWidget(_wrap(handler: handler, config: _config('b.test')));
    await tester.pump();
    expect(completers, hasLength(2));
    expect(
      find.text('서버A 발언', findRichText: true),
      findsNothing,
      reason: '새 설정의 응답이 오기 전이라도 옛 서버의 행이 남아 있으면 안 된다',
    );

    completers[1].complete(
      _page(<Map<String, dynamic>>[
        _eventJson(2, event: 'UserPromptSubmit', message: '서버B 발언'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('서버B 발언', findRichText: true), findsOneWidget);
    expect(find.text('서버A 발언', findRichText: true), findsNothing);
  });

  testWidgets('이벤트에 display_title이 있으면 그 시점의 제목 스냅샷을 행에 보여준다', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        handler: (_) async => _page(
          <Map<String, dynamic>>[
            _eventJson(
              2,
              displayTitle: '그때의 작업명',
              message: '본문',
            ),
            _eventJson(1, message: '제목 없는 이벤트'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('그때의 작업명'), findsOneWidget);
    expect(find.text('본문', findRichText: true), findsOneWidget);
    expect(find.text('제목 없는 이벤트', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('이력이 비어 있으면 empty 문구를 보여준다', (tester) async {
    await tester.pumpWidget(_wrap(handler: (_) async => _page(const [])));
    await tester.pumpAndSettle();
    expect(find.text('session.history.empty'), findsOneWidget);
  });

  testWidgets('좁은 폭(360)에서 긴 메시지·긴 이벤트 이름도 오버플로 없이 렌더링된다', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = _narrowViewport;
    addTearDown(() {
      tester.view
        ..resetDevicePixelRatio()
        ..resetPhysicalSize();
    });
    await tester.pumpWidget(
      _wrap(
        handler: (_) async => _page(
          <Map<String, dynamic>>[
            _eventJson(
              2,
              event: 'AVeryLongEventNameThatKeepsGoingWithoutSpaces',
              message:
                  '줄바꿈이 필요할 만큼 아주 긴 메시지 본문입니다. 좁은 폭에서도 '
                  '오버플로 없이 여러 줄로 흘러야 합니다.',
            ),
            _eventJson(1, event: 'UserPromptSubmit', message: '짧은 발언'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('session.history.user_prompt'), findsOneWidget);
  });
}

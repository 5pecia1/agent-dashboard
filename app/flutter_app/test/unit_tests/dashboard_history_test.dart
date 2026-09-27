import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_history.dart';

final Uri _base = Uri.parse('https://dash.example.dev');

class _Recorder {
  _Recorder(this._respond);

  final Future<ApiResponse> Function(ApiRequest request) _respond;
  final List<ApiRequest> requests = <ApiRequest>[];

  Future<ApiResponse> call(ApiRequest request) {
    requests.add(request);
    return _respond(request);
  }
}

DashboardApi _api(
  _Recorder recorder, {
  Uri? baseUrl,
  String? token = 'client-token',
}) => DashboardApi(
  send: recorder.call,
  config: DashboardApiConfig(baseUrl: baseUrl ?? _base, clientToken: token),
);

_Recorder _json(int status, Object? body) => _Recorder(
  (ApiRequest _) async =>
      ApiResponse(statusCode: status, body: jsonEncode(body)),
);

Map<String, dynamic> _eventJson({
  required int id,
  String sessionKey = 'claude-code:s1',
  String event = 'Notification',
  String? message,
}) => <String, dynamic>{
  'id': id,
  'session_key': sessionKey,
  'source': 'claude-code',
  'event': event,
  'message': message,
  'received_at': 1757300000000,
};

Map<String, dynamic> _pageJson(
  List<dynamic> events, {
  bool hasMore = false,
  int? nextBeforeId,
}) => <String, dynamic>{
  'events': events,
  'has_more': hasMore,
  'next_before_id': nextBeforeId,
};

void main() {
  group('요청 모양', () {
    test('경로·기본 prefix·Bearer 헤더·200 limit이 계약대로다', () async {
      final recorder = _json(200, _pageJson(const []));
      final api = _api(recorder, baseUrl: Uri.parse('https://dash.example.dev/api'));

      await api.history(sessionKey: 'claude-code:s1');

      final request = recorder.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/dashboard/events');
      expect(request.url.host, 'dash.example.dev');
      expect(request.headers['Authorization'], 'Bearer client-token');
      expect(request.url.queryParameters['limit'], '$kHistoryPageSize');
      expect(kHistoryPageSize, 200);
      expect(request.url.queryParameters.containsKey('before_id'), isFalse);
      expect(request.url.queryParameters['kind'], 'all');
    });

    test('세션 키의 콜론·슬래시가 쿼리 값으로 온전히 인코딩된다', () async {
      final recorder = _json(200, _pageJson(const []));
      final api = _api(recorder);
      const key = 'claude-code:proj/a:b';

      await api.history(sessionKey: key);

      final request = recorder.requests.single;
      expect(request.url.queryParameters['session_key'], key);
      expect(request.url.path, '/dashboard/events');
      expect(request.url.query, contains('session_key=claude-code%3Aproj%2Fa%3Ab'));
    });

    test('promptsOnly와 beforeId가 kind·before_id 쿼리로 나간다', () async {
      final recorder = _json(200, _pageJson(const []));
      final api = _api(recorder);

      await api.history(sessionKey: 'codex:s2', promptsOnly: true, beforeId: 42);

      final request = recorder.requests.single;
      expect(request.url.queryParameters['kind'], 'prompts');
      expect(request.url.queryParameters['before_id'], '42');
      expect(request.url.queryParameters['session_key'], 'codex:s2');
    });
  });

  group('응답 해석', () {
    test('정상 페이지를 파싱한다 — message null도 허용한다', () async {
      final recorder = _json(
        200,
        _pageJson(
          <Map<String, dynamic>>[
            _eventJson(id: 9, event: 'UserPromptSubmit', message: '이어서 해줘'),
            _eventJson(id: 8, message: null),
          ],
          hasMore: true,
          nextBeforeId: 8,
        ),
      );

      final DashboardHistoryPage page = await _api(
        recorder,
      ).history(sessionKey: 'claude-code:s1');

      expect(page.events, hasLength(2));
      expect(page.events[0].id, 9);
      expect(page.events[0].isUserPrompt, isTrue);
      expect(page.events[0].message, '이어서 해줘');
      expect(page.events[1].message, isNull);
      expect(page.events[1].isUserPrompt, isFalse);
      expect(page.hasMore, isTrue);
      expect(page.nextBeforeId, 8);
    });

    test('has_more인데 next_before_id가 없거나 어긋나면 malformed다(조용한 절단 금지)', () async {
      for (final body in <Map<String, dynamic>>[
        _pageJson(<Map<String, dynamic>>[_eventJson(id: 9)], hasMore: true),
        _pageJson(
          <Map<String, dynamic>>[_eventJson(id: 9)],
          hasMore: true,
          nextBeforeId: 3,
        ),
        _pageJson(
          <Map<String, dynamic>>[_eventJson(id: 9)],
          hasMore: true,
          nextBeforeId: 0,
        ),
      ]) {
        await expectLater(
          _api(_json(200, body)).history(sessionKey: 'k'),
          throwsA(isA<DashboardMalformedResponse>()),
          reason: 'body=$body',
        );
      }
    });

    test('필드가 빠지거나 타입이 어긋난 응답은 malformed다(기본값을 만들지 않는다)', () async {
      for (final body in <Object?>[
        <String, dynamic>{'events': <dynamic>[]},
        <String, dynamic>{'has_more': false, 'next_before_id': null},
        <String, dynamic>{'events': <dynamic>[], 'has_more': false},
        _pageJson(const <dynamic>[], nextBeforeId: 9),
        _pageJson(const <dynamic>[], hasMore: true, nextBeforeId: 1),
        _pageJson(<Map<String, dynamic>>[
          <String, dynamic>{'id': 'nine'},
        ]),
        _pageJson(const <dynamic>['not-an-object']),
      ]) {
        await expectLater(
          _api(_json(200, body)).history(sessionKey: 'k'),
          throwsA(isA<DashboardMalformedResponse>()),
          reason: 'body=$body',
        );
      }
    });

    test('401은 malformed가 아니라 DashboardUnauthorized로 그대로 나간다', () async {
      final recorder = _json(401, <String, String>{'error': 'unauthorized'});
      await expectLater(
        _api(recorder).history(sessionKey: 'k'),
        throwsA(
          isA<DashboardUnauthorized>().having(
            (DashboardUnauthorized e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
    });
  });
}

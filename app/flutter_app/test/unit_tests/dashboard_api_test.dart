/// `dashboard_api.dart`를 서버·네트워크 없이 닫는다.
///
/// 모든 테스트는 [httpSendProvider]에 가짜 핸들러를 꽂아 요청을 가로채고
/// 응답을 지어낸다. 그래서 실패 분기(401/403/5xx/타임아웃)를 실제 장애를
/// 만들지 않고도 하나씩 태울 수 있다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';

final Uri _base = Uri.parse('https://dash.example.dev');

/// 요청을 기록하면서 정해진 응답을 돌려주는 가짜 전송.
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
  String? token = 'client-token',
  Duration timeout = const Duration(seconds: 5),
}) => DashboardApi(
  send: recorder.call,
  config: DashboardApiConfig(
    baseUrl: _base,
    clientToken: token,
    timeout: timeout,
  ),
);

_Recorder _json(int status, Object? body) => _Recorder(
  (ApiRequest _) async =>
      ApiResponse(statusCode: status, body: jsonEncode(body)),
);

Map<String, dynamic> _syncBody({
  int protocolVersion = kDashboardProtocolVersion,
}) => <String, dynamic>{
  'protocol_version': protocolVersion,
  'reset': true,
  'cursor': 12,
  'has_more': false,
  'server_time': 1757300000000,
  'pruned_below_id': 0,
  'stall_ms': 300000,
  'mute_until': null,
  'sessions': <Map<String, dynamic>>[
    <String, dynamic>{
      'key': 'claude-code:a1',
      'source': 'claude-code',
      'session_id': 'a1',
      'project': '/w/a1',
      'host': 'mac-0',
      'state': 'waiting_input',
      'last_event': 'Notification',
      'last_message': '승인 대기',
      'last_occurred_at': 1757299999000,
      'created_at': 1757299000000,
      'updated_at': 1757299999000,
      'stale': false,
      // 클라이언트가 모르는 키가 섞여도 무시하고 지나가야 한다.
      'future_field': <String, dynamic>{'x': 1},
    },
  ],
  'transitions': <Map<String, dynamic>>[],
};

void main() {
  group('(f) 실패 분기를 종류별로 구분한다', () {
    test('401은 DashboardUnauthorized', () async {
      final recorder = _json(401, <String, String>{'error': 'unauthorized'});
      await expectLater(
        _api(recorder).sync(),
        throwsA(
          isA<DashboardUnauthorized>()
              .having((DashboardUnauthorized e) => e.statusCode, 'status', 401)
              .having(
                (DashboardUnauthorized e) => e.message,
                'message',
                contains('unauthorized'),
              ),
        ),
      );
    });

    test('403은 DashboardForbidden', () async {
      final recorder = _json(403, <String, String>{'error': '권한 없음'});
      await expectLater(
        _api(recorder).sync(),
        throwsA(
          isA<DashboardForbidden>().having(
            (DashboardForbidden e) => e.statusCode,
            'status',
            403,
          ),
        ),
      );
    });

    test('5xx는 DashboardServerError(재시도 가능한 유일한 HTTP 실패)', () async {
      final recorder = _json(503, <String, String>{'error': 'D1 unavailable'});
      await expectLater(
        _api(recorder).sync(),
        throwsA(
          isA<DashboardServerError>().having(
            (DashboardServerError e) => e.statusCode,
            'status',
            503,
          ),
        ),
      );
    });

    test('그 밖의 4xx는 DashboardClientError', () async {
      final recorder = _json(400, <String, String>{
        'error': 'unsupported protocol_version',
      });
      await expectLater(
        _api(recorder).sync(),
        throwsA(
          isA<DashboardClientError>().having(
            (DashboardClientError e) => e.statusCode,
            'status',
            400,
          ),
        ),
      );
    });

    test('응답이 늦으면 DashboardTimeout', () async {
      // 영원히 완료되지 않는 응답 = 네트워크 지연.
      final recorder = _Recorder(
        (ApiRequest _) => Completer<ApiResponse>().future,
      );
      await expectLater(
        _api(recorder, timeout: const Duration(milliseconds: 20)).sync(),
        throwsA(
          isA<DashboardTimeout>()
              .having((DashboardTimeout e) => e.statusCode, 'status', isNull)
              .having(
                (DashboardTimeout e) => e.message,
                'message',
                contains('/dashboard/sync'),
              ),
        ),
      );
    });

    test('전송 자체가 던지면 DashboardNetworkFailure', () async {
      final recorder = _Recorder(
        (ApiRequest _) =>
            Future<ApiResponse>.error(const SocketExceptionLike('연결할 수 없음')),
      );
      await expectLater(
        _api(recorder).sync(),
        throwsA(isA<DashboardNetworkFailure>()),
      );
    });

    test('2xx인데 JSON 객체가 아니면 DashboardMalformedResponse', () async {
      final broken = _Recorder(
        (ApiRequest _) async =>
            const ApiResponse(statusCode: 200, body: '<html>proxy</html>'),
      );
      await expectLater(
        _api(broken).sync(),
        throwsA(isA<DashboardMalformedResponse>()),
      );

      final array = _Recorder(
        (ApiRequest _) async =>
            const ApiResponse(statusCode: 200, body: '[1,2,3]'),
      );
      await expectLater(
        _api(array).sync(),
        throwsA(isA<DashboardMalformedResponse>()),
      );
    });

    test('모르는 프로토콜 major는 DashboardProtocolMismatch', () async {
      final recorder = _json(200, _syncBody(protocolVersion: 2));
      await expectLater(
        _api(recorder).sync(),
        throwsA(
          isA<DashboardProtocolMismatch>().having(
            (DashboardProtocolMismatch e) => e.serverVersion,
            'serverVersion',
            2,
          ),
        ),
      );
    });

    test('JSON이 아닌 오류 본문도 문구로 살려 낸다', () async {
      final recorder = _Recorder(
        (ApiRequest _) async =>
            const ApiResponse(statusCode: 502, body: 'Bad Gateway'),
      );
      await expectLater(
        _api(recorder).sync(),
        throwsA(
          isA<DashboardServerError>().having(
            (DashboardServerError e) => e.message,
            'message',
            contains('Bad Gateway'),
          ),
        ),
      );
    });
  });

  group('GET /dashboard/sync', () {
    test('since·limit·include_ended가 질의로 나가고 Bearer가 붙는다', () async {
      final recorder = _json(200, _syncBody());
      await _api(recorder).sync(since: 41, limit: 50, includeEnded: true);

      final request = recorder.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, kSyncPath);
      expect(request.url.queryParameters, <String, String>{
        'since': '41',
        'limit': '50',
        'include_ended': '1',
      });
      expect(request.headers['Authorization'], 'Bearer client-token');
      expect(request.headers['Accept'], 'application/json');
      expect(request.body, isNull);
    });

    test('since가 없으면 질의도 비고, 응답은 스냅샷으로 읽힌다', () async {
      final recorder = _json(200, _syncBody());
      final response = await _api(recorder).sync();

      expect(recorder.requests.single.url.query, isEmpty);
      expect(response.reset, isTrue);
      expect(response.cursor, 12);
      expect(response.sessions.single.key, 'claude-code:a1');
      expect(response.sessions.single.state, 'waiting_input');
      expect(response.sessions.single.isAlertState, isTrue);
      expect(response.transitions, isEmpty);
    });

    test('토큰이 없으면 Authorization 헤더를 붙이지 않는다', () async {
      final recorder = _json(200, _syncBody());
      await _api(recorder, token: null).sync();
      expect(
        recorder.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test('경로 접두사가 있는 baseUrl도 이어 붙인다', () async {
      final recorder = _json(200, _syncBody());
      final api = DashboardApi(
        send: recorder.call,
        config: DashboardApiConfig(
          baseUrl: Uri.parse('https://dash.example.dev/api/'),
        ),
      );
      await api.sync(since: 1);
      expect(recorder.requests.single.url.path, '/api/dashboard/sync');
    });
  });

  group('기기·구독 등록', () {
    test('POST /dashboard/devices는 token·platform을 보낸다', () async {
      final recorder = _json(200, <String, bool>{'ok': true});
      await _api(
        recorder,
      ).registerDevice(token: 'fcm-token', platform: 'macos');

      final request = recorder.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, kDevicesPath);
      expect(request.headers['Content-Type'], 'application/json');
      expect(jsonDecode(request.body!), <String, String>{
        'token': 'fcm-token',
        'platform': 'macos',
      });
    });

    test('웹 클라이언트는 transport·label까지 명시해 보낸다', () async {
      final recorder = _json(200, <String, bool>{'ok': true});
      await _api(recorder).registerDevice(
        token: 'fcm-web-token',
        platform: 'web',
        transport: 'fcm',
        label: 'Sol의 크롬',
      );

      expect(jsonDecode(recorder.requests.single.body!), <String, String>{
        'token': 'fcm-web-token',
        'platform': 'web',
        'transport': 'fcm',
        'label': 'Sol의 크롬',
      });
    });

    test('빈 label은 키 자체를 보내지 않는다(서버가 기존 이름을 지우지 않게)', () async {
      final recorder = _json(200, <String, bool>{'ok': true});
      await _api(recorder).registerDevice(
        token: 't',
        platform: 'web',
        transport: 'fcm',
        label: '',
      );

      expect(jsonDecode(recorder.requests.single.body!), <String, String>{
        'token': 't',
        'platform': 'web',
        'transport': 'fcm',
      });
    });

    test('POST /dashboard/subscriptions는 평평한 구독 본문을 보낸다', () async {
      final recorder = _json(200, <String, bool>{'ok': true});
      await _api(recorder).registerSubscription(
        const PushSubscriptionDto(
          endpoint: 'https://fcm.googleapis.com/x',
          p256dh: 'key',
          auth: 'secret',
        ),
      );

      final request = recorder.requests.single;
      expect(request.url.path, kSubscriptionsPath);
      expect(jsonDecode(request.body!), <String, String>{
        'endpoint': 'https://fcm.googleapis.com/x',
        'p256dh': 'key',
        'auth': 'secret',
      });
    });

    test('DELETE /dashboard/subscriptions는 endpoint를 질의로 보낸다', () async {
      final recorder = _json(200, <String, bool>{'ok': true});
      await _api(
        recorder,
      ).removeSubscription(endpoint: 'https://fcm.googleapis.com/x');

      final request = recorder.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, kSubscriptionsPath);
      expect(
        request.url.queryParameters['endpoint'],
        'https://fcm.googleapis.com/x',
      );
      expect(request.body, isNull);
    });

    test('없는 구독을 지우면(404) 성공으로 접는다', () async {
      final recorder = _json(404, <String, String>{'error': 'not found'});
      await _api(recorder).removeSubscription(endpoint: 'gone');
      expect(recorder.requests, hasLength(1));
    });

    test('구독 해지의 401은 그대로 올라온다', () async {
      final recorder = _json(401, <String, String>{'error': 'unauthorized'});
      await expectLater(
        _api(recorder).removeSubscription(endpoint: 'x'),
        throwsA(isA<DashboardUnauthorized>()),
      );
    });
  });

  group('GET /dashboard/push-config', () {
    test('평평한 응답을 그대로 읽는다', () async {
      final recorder = _json(200, <String, dynamic>{
        'channels': <String>['fcm'],
        'firebase_config': <String, dynamic>{
          'apiKey': 'k',
          'projectId': 'p',
          'appId': 'a',
        },
        'vapid_key': 'vapid',
      });
      final config = await _api(recorder).pushConfig();

      expect(recorder.requests.single.url.path, kPushConfigPath);
      expect(config.channels, <String>['fcm']);
      expect(config.firebaseConfig['projectId'], 'p');
      expect(config.vapidKey, 'vapid');
      expect(config.canSubscribeOnWeb, isTrue);
      expect(config.isUnavailable, isFalse);
    });

    test('fcm 아래 중첩된 camelCase 응답도 같은 값으로 읽는다', () async {
      final recorder = _json(200, <String, dynamic>{
        'fcm': <String, dynamic>{
          'firebaseConfig': <String, dynamic>{'apiKey': 'k'},
          'vapidKey': 'vapid',
        },
      });
      final config = await _api(recorder).pushConfig();

      expect(config.hasChannel('fcm'), isTrue);
      expect(config.firebaseConfig['apiKey'], 'k');
      expect(config.vapidKey, 'vapid');
    });

    test('자격증명이 없으면 DashboardPushUnavailable', () async {
      final recorder = _json(200, <String, dynamic>{'channels': <String>[]});
      await expectLater(
        _api(recorder).pushConfig(),
        throwsA(isA<DashboardPushUnavailable>()),
      );
    });

    test('라우트가 아직 없으면(404) DashboardPushUnavailable', () async {
      final recorder = _json(404, <String, String>{'error': 'not found'});
      await expectLater(
        _api(recorder).pushConfig(),
        throwsA(
          isA<DashboardPushUnavailable>().having(
            (DashboardPushUnavailable e) => e.statusCode,
            'status',
            404,
          ),
        ),
      );
    });

    test('501/503도 DashboardPushUnavailable로 접는다', () async {
      final recorder = _json(501, <String, String>{'error': 'not implemented'});
      await expectLater(
        _api(recorder).pushConfig(),
        throwsA(isA<DashboardPushUnavailable>()),
      );
    });

    test('500은 push 문제가 아니라 서버 오류로 남는다', () async {
      final recorder = _json(500, <String, String>{'error': 'boom'});
      await expectLater(
        _api(recorder).pushConfig(),
        throwsA(isA<DashboardServerError>()),
      );
    });
  });

  group('운영 엔드포인트', () {
    test('GET /dashboard/diagnostics를 DTO로 읽는다', () async {
      final recorder = _json(200, <String, dynamic>{
        'last_event_at': 1757300000000,
        'max_transition_id': 42,
        'pruned_below_id': 3,
        'last_push': <String, dynamic>{
          'transport': 'fcm',
          'target': 'token-1',
          'result': 'sent',
          'detail': null,
          'created_at': 1757300000000,
        },
        'device_failure_count': 1,
        'subscription_failure_count': 0,
        'channels': <String, bool>{'fcm': true, 'web-push': false},
        'table_counts': <String, int>{'dashboard_events': 12},
      });
      final diagnostics = await _api(recorder).diagnostics();

      expect(recorder.requests.single.url.path, kDiagnosticsPath);
      expect(diagnostics.maxTransitionId, 42);
      expect(diagnostics.lastPush?.transport, 'fcm');
      expect(diagnostics.deviceFailureCount, 1);
      expect(diagnostics.channels['fcm'], isTrue);
      expect(diagnostics.hasLivePushChannel, isTrue);
      expect(diagnostics.tableCounts['dashboard_events'], 12);
    });

    test('POST /dashboard/test-push는 채널별 결과를 돌려준다', () async {
      final recorder = _json(200, <String, dynamic>{
        'ok': true,
        'transition_id': 51,
        'channels': <String, dynamic>{
          'fcm': <String, dynamic>{'sent': 2, 'removed': 1},
          'web-push': <String, dynamic>{
            'sent': 0,
            'removed': 0,
            'skipped': 'no_credentials',
          },
        },
      });
      final result = await _api(recorder).testPush(label: '확인용');

      expect(recorder.requests.single.url.path, kTestPushPath);
      expect(jsonDecode(recorder.requests.single.body!), <String, String>{
        'label': '확인용',
      });
      expect(result.ok, isTrue);
      expect(result.transitionId, 51);
      expect(result.sentCount, 2);
      expect(result.channels['web-push']?.skipped, 'no_credentials');
    });

    test('POST /dashboard/mute는 음소거 종료 시각을 돌려준다', () async {
      final muted = _json(200, <String, dynamic>{
        'ok': true,
        'mute_until': 1757300600000,
      });
      expect(await _api(muted).mute(minutes: 10), 1757300600000);
      expect(jsonDecode(muted.requests.single.body!), <String, int>{
        'minutes': 10,
      });

      final cleared = _json(200, <String, dynamic>{
        'ok': true,
        'mute_until': null,
      });
      expect(await _api(cleared).mute(minutes: 0), isNull);
    });

    test('GET /dashboard/ui-lang은 서버 값을 그대로 읽는다', () async {
      final set = _json(200, <String, dynamic>{'ui_lang': 'ko'});
      expect(await _api(set).uiLang(), 'ko');
      expect(set.requests.single.url.path, kUiLangPath);
      expect(set.requests.single.method, 'GET');

      final unset = _json(200, <String, dynamic>{'ui_lang': null});
      expect(await _api(unset).uiLang(), isNull, reason: '서버가 아직 정하지 않음');
    });

    test('POST /dashboard/ui-lang은 확인된 값을 돌려준다(낙관적 갱신 없음 — mute()와 같은 전례)', () async {
      final recorder = _json(200, <String, dynamic>{'ui_lang': 'en'});
      expect(await _api(recorder).setUiLang('en'), 'en');
      expect(recorder.requests.single.url.path, kUiLangPath);
      expect(recorder.requests.single.method, 'POST');
      expect(
        jsonDecode(recorder.requests.single.body!),
        <String, String?>{'lang': 'en'},
        reason:
            '요청 키는 lang, 응답 키는 ui_lang이다(정본 settings.ui_lang.endpoint.post). '
            'ui_lang으로 보내면 서버의 `"lang" in body` 키 부재 400에 걸린다',
      );

      final cleared = _json(200, <String, dynamic>{'ui_lang': null});
      expect(
        await _api(cleared).setUiLang(null),
        isNull,
        reason: "'system' 선택은 호출자가 null로 옮겨 적어 보낸다 — 서버 값을 지운다",
      );
      expect(
        jsonDecode(cleared.requests.single.body!),
        <String, String?>{'lang': null},
        reason: '명시적 null도 lang 키에 실려야 "선택 해제"로 읽힌다 — 키 자체가 빠지면 400이다',
      );
    });

    test('빈 본문 응답도 성공으로 읽는다', () async {
      final recorder = _Recorder(
        (ApiRequest _) async => const ApiResponse(statusCode: 204),
      );
      await _api(recorder).registerDevice(token: 't', platform: 'macos');
      expect(recorder.requests, hasLength(1));
    });
  });

  group('provider 배선', () {
    test('override 없이 부르면 시임 미설정으로 실패한다', () async {
      final container = ProviderContainer(
        overrides: [
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: _base),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(dashboardApiProvider).sync(),
        throwsA(
          isA<DashboardNetworkFailure>().having(
            (DashboardNetworkFailure e) => e.message,
            'message',
            contains('httpSendProvider'),
          ),
        ),
      );
    });

    test('httpSendProvider만 갈아끼우면 전체 클라이언트가 가짜로 돈다', () async {
      final recorder = _json(200, _syncBody());
      final container = ProviderContainer(
        overrides: [
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: _base, clientToken: 'tkn'),
          ),
          httpSendProvider.overrideWithValue(recorder.call),
        ],
      );
      addTearDown(container.dispose);

      final response = await container.read(dashboardApiProvider).sync();
      expect(response.cursor, 12);
      expect(recorder.requests.single.headers['Authorization'], 'Bearer tkn');
    });

    test('설정 provider를 override하지 않으면 즉시 알려 준다', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // riverpod 3은 provider가 던진 예외를 한 겹 감싸므로 타입 대신
      // 안내 문구가 사용자에게 닿는지를 본다.
      expect(
        () => container.read(dashboardApiProvider),
        throwsA(
          predicate<Object>(
            (Object error) =>
                error.toString().contains('dashboardApiConfigProvider'),
            'dashboardApiConfigProvider override를 안내하는 예외',
          ),
        ),
      );
    });
  });
}

/// `dart:io`를 쓰지 않고 "전송 계층이 던진 낯선 예외"를 흉내 낸다
/// (데이터 계층은 dart:io에도 웹 API에도 묶이지 않는다).
class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);
  final String message;
  @override
  String toString() => 'SocketExceptionLike: $message';
}

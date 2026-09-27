/// `push_provider.dart`를 실제 브라우저/서버 없이 닫는다.
///
/// [dashboardApiProvider]가 필요로 하는 전송은 `dashboard_api_test.dart`와
/// 같은 관용으로 [httpSendProvider]에 가짜 핸들러를 꽂아 흉내 낸다. 서비스
/// 워커/Firebase SDK는 [webPushTokenFnProvider] 하나만 override하면 되고,
/// T17f 완료 기준 (d)의 핵심 — 서버가 `client_ready:false`를 말했을 때
/// **브라우저를 건드리지도 않고** 폴링 전용으로 저하되는 것 — 을 실제 FCM
/// 자격증명 없이 값으로만 재현한다.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/platform/web_push.dart';
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/push_provider.dart';

final Uri _base = Uri.parse('https://dash.example.dev');

/// [handler]로 응답을 짓는 가짜 전송. 호출 기록도 남긴다.
class _Recorder {
  _Recorder(this._handler);

  final Future<ApiResponse> Function(ApiRequest request) _handler;
  final List<ApiRequest> requests = <ApiRequest>[];

  Future<ApiResponse> call(ApiRequest request) {
    requests.add(request);
    return _handler(request);
  }
}

// 타입 이름을 쓰지 않고 추론에 맡긴다 — 실제 타입(`Override`)은
// `package:riverpod/misc.dart`에 있고 `flutter_riverpod`의 barrel export에는
// 없다(`http_provider.dart`의 `httpSendProviderOverride`와 같은 이유).
final _apiConfigOverride = dashboardApiConfigProvider.overrideWithValue(
  DashboardApiConfig(baseUrl: _base),
);

/// 절대 불려서는 안 되는 자리에 꽂는 시임 — 불리면 즉시 테스트를 실패시킨다.
Never _mustNotBeCalled() =>
    throw StateError('이 경로에서는 호출되지 않아야 한다.');

/// 완전한 자격증명을 담은 서버 응답(실제 dashboard-server가 보내는 모양).
String _readyBody({bool clientReady = true}) => jsonEncode(<String, Object?>{
  'channels': <String>['fcm'],
  'fcm': <String, Object?>{
    'web_config': <String, Object?>{'apiKey': 'k', 'projectId': 'p'},
    'vapid_key': 'vapid-key',
    'client_ready': clientReady,
  },
});

void main() {
  test('데스크톱(isWasm=false)이면 서버/브라우저 시임 어느 것도 건드리지 않고 notApplicable이다', () async {
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(false),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue((_) async => _mustNotBeCalled()),
        webPushTokenFnProvider.overrideWithValue((_) async => _mustNotBeCalled()),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.notApplicable);
    expect(result.token, isNull);
  });

  test('push-config가 404면 unavailable로 저하되고 토큰을 요청하지 않는다', () async {
    final recorder = _Recorder((request) async {
      expect(request.url.path, '/dashboard/push-config');
      return const ApiResponse(statusCode: 404, body: '{"error":"not found"}');
    });
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue((_) async => _mustNotBeCalled()),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.unavailable);
    expect(recorder.requests, hasLength(1));
  });

  test('채널은 있지만 자격증명이 비어 있으면 unavailable이다', () async {
    final recorder = _Recorder(
      (_) async => ApiResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'channels': <String>[],
          'fcm': null,
        }),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue((_) async => _mustNotBeCalled()),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.unavailable);
  });

  test(
    '완료 기준 (d): 서버가 client_ready:false면 브라우저를 건드리지 않고 폴링 전용으로 남는다',
    () async {
      final recorder = _Recorder(
        (_) async => ApiResponse(statusCode: 200, body: _readyBody(clientReady: false)),
      );
      final container = ProviderContainer(
        overrides: [
          isWasmRuntimeProvider.overrideWithValue(true),
          _apiConfigOverride,
          httpSendProvider.overrideWithValue(recorder.call),
          // 자격증명 값은 다 있어도 서버가 아니라고 했으므로 이 시임까지
          // 내려가서는 안 된다 — 내려가면 `getToken()`이 권한 프롬프트를
          // 띄울 수 있다.
          webPushTokenFnProvider.overrideWithValue((_) async => _mustNotBeCalled()),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(pushRegistrarProvider)();

      expect(result.availability, PushAvailability.unavailable);
      // push-config 조회 한 번만 나가고 기기 등록은 시도하지 않는다.
      expect(recorder.requests, hasLength(1));
    },
  );

  test('권한이 아직 없으면 permissionRequired이고 서버에 등록하지 않는다', () async {
    final recorder = _Recorder(
      (_) async => ApiResponse(statusCode: 200, body: _readyBody()),
    );
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue(
          (_) async => const WebPushTokenResult(
            WebPushTokenStatus.permissionRequired,
            detail: 'Notification.permission=default',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.permissionRequired);
    expect(recorder.requests, hasLength(1));
  });

  test('브라우저가 지원하지 않으면(unsupported) 실패가 아니라 unavailable이다', () async {
    final recorder = _Recorder(
      (_) async => ApiResponse(statusCode: 200, body: _readyBody()),
    );
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue(
          (_) async => const WebPushTokenResult.unsupported('no ServiceWorker'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.unavailable);
    expect(recorder.requests, hasLength(1));
  });

  test('토큰 취득 자체가 실패하면 failed다', () async {
    final recorder = _Recorder(
      (_) async => ApiResponse(statusCode: 200, body: _readyBody()),
    );
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue(
          (_) async => const WebPushTokenResult.failed('getToken 실패'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.failed);
    expect(result.token, isNull);
    expect(recorder.requests, hasLength(1));
  });

  test(
    '토큰을 받으면 POST /dashboard/devices에 transport:fcm · platform:web으로 등록한다',
    () async {
      final recorder = _Recorder((request) async {
        if (request.url.path == '/dashboard/push-config') {
          return ApiResponse(statusCode: 200, body: _readyBody());
        }
        if (request.url.path == kDevicesPath && request.method == 'POST') {
          return const ApiResponse(statusCode: 200);
        }
        return _mustNotBeCalled();
      });
      final container = ProviderContainer(
        overrides: [
          isWasmRuntimeProvider.overrideWithValue(true),
          _apiConfigOverride,
          httpSendProvider.overrideWithValue(recorder.call),
          webPushTokenFnProvider.overrideWithValue((config) async {
            expect(config.vapidKey, 'vapid-key');
            expect(config.firebaseConfig['projectId'], 'p');
            expect(config.clientReady, isTrue);
            return const WebPushTokenResult.acquired('fcm-web-token');
          }),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(pushRegistrarProvider)(
        label: 'Sol의 크롬',
      );

      expect(result.availability, PushAvailability.registered);
      expect(result.isRegistered, isTrue);
      expect(result.token, 'fcm-web-token');
      expect(recorder.requests, hasLength(2));
      expect(jsonDecode(recorder.requests[1].body!), <String, Object?>{
        'token': 'fcm-web-token',
        'platform': 'web',
        'transport': 'fcm',
        'label': 'Sol의 크롬',
      });
    },
  );

  test('label을 모르면 아예 보내지 않는다(서버가 기존 이름을 유지한다)', () async {
    final recorder = _Recorder((request) async {
      if (request.url.path == '/dashboard/push-config') {
        return ApiResponse(statusCode: 200, body: _readyBody());
      }
      return const ApiResponse(statusCode: 204);
    });
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue(
          (_) async => const WebPushTokenResult.acquired('fcm-web-token'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.registered);
    expect(
      jsonDecode(recorder.requests[1].body!),
      isNot(contains('label')),
    );
  });

  test('서버 등록이 실패해도 던지지 않고 failed로 접는다', () async {
    final recorder = _Recorder((request) async {
      if (request.url.path == '/dashboard/push-config') {
        return ApiResponse(statusCode: 200, body: _readyBody());
      }
      return const ApiResponse(statusCode: 500, body: '{"error":"boom"}');
    });
    final container = ProviderContainer(
      overrides: [
        isWasmRuntimeProvider.overrideWithValue(true),
        _apiConfigOverride,
        httpSendProvider.overrideWithValue(recorder.call),
        webPushTokenFnProvider.overrideWithValue(
          (_) async => const WebPushTokenResult.acquired('fcm-web-token'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.failed);
    expect(result.detail, contains('기기 등록 실패'));
  });
}

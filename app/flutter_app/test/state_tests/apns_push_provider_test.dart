/// TASK D-app: macOS(APNs) 등록 경로와 배너 소유권을 실제 Firebase·실기기
/// 없이 닫는다 (A안 설계 ②③).
///
/// `push_provider_test.dart`가 웹 경로에 하는 것과 정확히 같은 관용이다:
/// 서버는 [httpSendProvider]에 가짜 핸들러를 꽂아 흉내 내고, Firebase/APNs는
/// [apnsTokenFnProvider] 하나만 override한다. 그래서 이 파일은 Firebase
/// 자격증명도, `aps-environment` entitlement도, 실기기도 필요 없다 —
/// 실제 APNs 수신 확인은 자격증명·서명 뒤 '사용자 확인' 항목이다.
///
/// 확인하는 계약 넷:
///   1. `transport:'fcm-apns'` / `platform:'macos'`로 등록한다(정본
///      `push.channels.fcm-apns`).
///   2. `apple_client_ready:false`거나 `apple_config`가 없으면 **Firebase를
///      건드리지도 않고** 폴링+로컬 알림으로 남는다.
///   3. entitlement 미활성(설계 ⑤ — `unsupported`)은 실패가 아니라
///      `unavailable`이고, 소유권은 앱(로컬 알림)에 남는다.
///   4. 등록에 성공한 순간에만 [apnsRegisteredProvider]가 true가 된다.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/platform/apns_push.dart';
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/push_provider.dart';

final Uri _base = Uri.parse('https://dash.example.dev');

final _apiConfigOverride = dashboardApiConfigProvider.overrideWithValue(
  DashboardApiConfig(baseUrl: _base),
);

/// 절대 불려서는 안 되는 자리에 꽂는 시임 — 불리면 즉시 테스트를 실패시킨다.
Never _mustNotBeCalled() => throw StateError('이 경로에서는 호출되지 않아야 한다.');

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

/// 실제 dashboard-server가 보내는 모양(D-server가 apple_config를 얹은 뒤).
String _appleReadyBody({bool appleClientReady = true, bool withApple = true}) =>
    jsonEncode(<String, Object?>{
      'channels': <String>['fcm'],
      'fcm': <String, Object?>{
        'web_config': <String, Object?>{'apiKey': 'web-k'},
        'vapid_key': 'vapid-key',
        'client_ready': true,
        'apple_config': withApple
            ? <String, Object?>{
                'apiKey': 'apple-k',
                'appId': '1:1:ios:abc',
                'messagingSenderId': '1',
                'projectId': 'p',
              }
            : null,
        'apple_client_ready': withApple && appleClientReady,
      },
    });

ProviderContainer _appleContainer({
  required Future<ApiResponse> Function(ApiRequest) send,
  required ApnsTokenFn acquireToken,
}) => ProviderContainer(
  overrides: [
    isWasmRuntimeProvider.overrideWithValue(false),
    isApplePushHostProvider.overrideWithValue(true),
    _apiConfigOverride,
    httpSendProvider.overrideWithValue(send),
    apnsTokenFnProvider.overrideWithValue(acquireToken),
    // 웹 시임은 이 경로에서 절대 불리면 안 된다.
    webPushTokenFnProvider.overrideWithValue((_) async => _mustNotBeCalled()),
  ],
);

void main() {
  test('토큰을 받으면 transport:fcm-apns · platform:macos로 등록한다', () async {
    final recorder = _Recorder((request) async {
      if (request.url.path == kPushConfigPath) {
        return ApiResponse(statusCode: 200, body: _appleReadyBody());
      }
      if (request.url.path == kDevicesPath && request.method == 'POST') {
        return const ApiResponse(statusCode: 200);
      }
      return _mustNotBeCalled();
    });
    final container = _appleContainer(
      send: recorder.call,
      acquireToken: (config) async {
        // 설계 ③: 초기화 옵션은 빌드가 아니라 서버가 준 값이다.
        expect(config.appleConfig['projectId'], 'p');
        expect(config.appleClientReady, isTrue);
        return const ApnsTokenResult.acquired('fcm-apns-token');
      },
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)(label: 'Sol의 맥');

    expect(result.availability, PushAvailability.registered);
    expect(result.transport, kPushTransportFcmApns);
    expect(result.isApnsRegistered, isTrue);
    expect(recorder.requests, hasLength(2));
    expect(jsonDecode(recorder.requests[1].body!), <String, Object?>{
      'token': 'fcm-apns-token',
      'platform': kPushPlatformMacos,
      'transport': kPushTransportFcmApns,
      'label': 'Sol의 맥',
    });
  });

  test('등록에 성공하면 apnsRegisteredProvider가 true가 된다 (설계 ② 소유권)', () async {
    final container = _appleContainer(
      send: (request) async => request.url.path == kPushConfigPath
          ? ApiResponse(statusCode: 200, body: _appleReadyBody())
          : const ApiResponse(statusCode: 204),
      acquireToken: (_) async => const ApnsTokenResult.acquired('t'),
    );
    addTearDown(container.dispose);

    expect(
      container.read(apnsRegisteredProvider),
      isFalse,
      reason: '등록 전에는 배너의 주인이 앱(로컬 알림)이다',
    );

    await container.read(pushRegistrarProvider)();

    expect(container.read(apnsRegisteredProvider), isTrue);
  });

  test(
    '설계 ⑤: entitlement 미활성(unsupported)은 실패가 아니라 unavailable이고 소유권은 앱에 남는다',
    () async {
      final recorder = _Recorder(
        (_) async => ApiResponse(statusCode: 200, body: _appleReadyBody()),
      );
      final container = _appleContainer(
        send: recorder.call,
        acquireToken: (_) async =>
            const ApnsTokenResult.unsupported('APNs device token이 없다'),
      );
      addTearDown(container.dispose);

      final result = await container.read(pushRegistrarProvider)();

      expect(result.availability, PushAvailability.unavailable);
      expect(result.isApnsRegistered, isFalse);
      expect(container.read(apnsRegisteredProvider), isFalse);
      // push-config 조회 한 번만 나가고 기기 등록은 시도하지 않는다.
      expect(recorder.requests, hasLength(1));
    },
  );

  test('권한을 거부하면 permissionRequired이고 로컬 알림 폴백이 유지된다', () async {
    final recorder = _Recorder(
      (_) async => ApiResponse(statusCode: 200, body: _appleReadyBody()),
    );
    final container = _appleContainer(
      send: recorder.call,
      acquireToken: (_) async =>
          const ApnsTokenResult.permissionRequired('authorizationStatus=denied'),
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.permissionRequired);
    expect(container.read(apnsRegisteredProvider), isFalse);
    expect(recorder.requests, hasLength(1));
  });

  test('apple_client_ready:false면 Firebase를 건드리지도 않는다', () async {
    final recorder = _Recorder(
      (_) async => ApiResponse(
        statusCode: 200,
        body: _appleReadyBody(appleClientReady: false),
      ),
    );
    final container = _appleContainer(
      send: recorder.call,
      // 값이 다 있어도 서버가 아니라고 했으므로 이 시임까지 내려가면 안 된다 —
      // 내려가면 macOS 권한 프롬프트가 뜰 수 있다.
      acquireToken: (_) async => _mustNotBeCalled(),
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.unavailable);
    expect(recorder.requests, hasLength(1));
  });

  test('서버가 apple_config를 아예 안 주면 unavailable이다', () async {
    final container = _appleContainer(
      send: (_) async =>
          ApiResponse(statusCode: 200, body: _appleReadyBody(withApple: false)),
      acquireToken: (_) async => _mustNotBeCalled(),
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.unavailable);
    expect(result.detail, contains('apple_config'));
  });

  test('서버 등록이 실패해도 던지지 않고 failed로 접으며 소유권을 넘기지 않는다', () async {
    final container = _appleContainer(
      send: (request) async => request.url.path == kPushConfigPath
          ? ApiResponse(statusCode: 200, body: _appleReadyBody())
          : const ApiResponse(statusCode: 500, body: '{"error":"boom"}'),
      acquireToken: (_) async => const ApnsTokenResult.acquired('t'),
    );
    addTearDown(container.dispose);

    final result = await container.read(pushRegistrarProvider)();

    expect(result.availability, PushAvailability.failed);
    expect(result.detail, contains('기기 등록 실패'));
    expect(container.read(apnsRegisteredProvider), isFalse);
  });

  test('한 번 등록됐어도 다음 시도가 실패하면 소유권이 앱으로 되돌아온다', () async {
    var acquired = true;
    final container = _appleContainer(
      send: (request) async => request.url.path == kPushConfigPath
          ? ApiResponse(statusCode: 200, body: _appleReadyBody())
          : const ApiResponse(statusCode: 204),
      acquireToken: (_) async => acquired
          ? const ApnsTokenResult.acquired('t')
          : const ApnsTokenResult.permissionRequired('권한이 철회됐다'),
    );
    addTearDown(container.dispose);

    await container.read(pushRegistrarProvider)();
    expect(container.read(apnsRegisteredProvider), isTrue);

    acquired = false;
    await container.read(pushRegistrarProvider)();
    expect(container.read(apnsRegisteredProvider), isFalse);
  });

  group('isAppleConfigComplete (순수 판정)', () {
    test('필수 네 키가 다 있어야 true다', () {
      expect(
        isAppleConfigComplete(const <String, Object?>{
          'apiKey': 'k',
          'appId': 'a',
          'messagingSenderId': 's',
          'projectId': 'p',
        }),
        isTrue,
      );
    });

    test('하나라도 없거나 비어 있으면 false다', () {
      for (final missing in kAppleConfigRequiredKeys) {
        final config = <String, Object?>{
          for (final key in kAppleConfigRequiredKeys) key: 'x',
        }..remove(missing);
        expect(isAppleConfigComplete(config), isFalse, reason: '$missing 누락');
      }
      expect(
        isAppleConfigComplete(const <String, Object?>{
          'apiKey': '',
          'appId': 'a',
          'messagingSenderId': 's',
          'projectId': 'p',
        }),
        isFalse,
      );
    });

    test('타입이 문자열이 아니면 false다', () {
      expect(
        isAppleConfigComplete(const <String, Object?>{
          'apiKey': 1,
          'appId': 'a',
          'messagingSenderId': 's',
          'projectId': 'p',
        }),
        isFalse,
      );
    });
  });
}

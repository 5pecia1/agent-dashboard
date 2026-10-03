/// 앱이 지금 서버에 쓰는 API 설정(`config_provider.dart`의
/// `DashboardApiConfigController`)과, 그 값을 따라가는
/// `dashboardApiConfigProvider` override·`dashboardServerUrlProvider`를 닫는다.
///
/// 부팅 스냅샷(`dashboardConfigValuesProvider`)은 저장해도 갱신되지 않는다.
/// 설정 화면이 저장한 주소·토큰이 재시작 없이 쓰이려면 API 설정이 부팅 뒤에도
/// 바뀔 수 있어야 하고, 서버 주소가 없는 동안은 예전처럼 읽는 쪽에 던져야 한다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/config_provider.dart';

const String _urlA = 'https://a.example.test';
const String _urlB = 'https://b.example.test/api';
const String _tokenA = 'token-a';
const String _tokenB = 'token-b';

DashboardApiConfig _config(String url, String token) =>
    DashboardApiConfig(baseUrl: Uri.parse(url), clientToken: token);

/// 운영 조립(`main.dart`의 `buildDashboardRoot`)이 꽂는 두 자리를 그대로
/// 쓴다. [initial]이 null이면 첫 실행이다.
ProviderContainer _container({
  DashboardApiConfig? initial,
  DashboardConfigValues? snapshot,
}) {
  final container = ProviderContainer(
    overrides: [
      dashboardInitialApiConfigProvider.overrideWithValue(initial),
      dashboardApiConfigProviderOverride,
      if (snapshot != null)
        dashboardConfigValuesProvider.overrideWithValue(snapshot),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('시작값', () {
    test(
      '시작값이 없으면(첫 실행) 지금 쓰는 설정이 없고 dashboardApiConfigProvider는 읽는 쪽에 던진다',
      () {
        final container = _container();

        expect(container.read(dashboardApiConfigControllerProvider), isNull);
        expect(
          () => container.read(dashboardApiConfigProvider),
          throwsA(isA<Object>()),
          reason: '서버 주소가 없는 동안은 아무도 읽지 않아야 한다는 계약 그대로다',
        );
        expect(
          () => container.read(dashboardApiProvider),
          throwsA(isA<Object>()),
        );
      },
    );

    test('시작값이 있으면 그 값이 지금 쓰는 설정이고 dashboardApiConfigProvider가 그대로 준다', () {
      final initial = _config(_urlA, _tokenA);
      final container = _container(initial: initial);

      expect(container.read(dashboardApiConfigControllerProvider), initial);
      expect(container.read(dashboardApiConfigProvider), initial);
      expect(container.read(dashboardApiProvider).config, initial);
    });

    test('override가 없는 컨테이너(화면 단위 테스트)는 지금 쓰는 설정이 null이다', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(dashboardApiConfigControllerProvider), isNull);
    });
  });

  group('apply', () {
    test('첫 실행에서 던졌던 dashboardApiConfigProvider가 저장 뒤에는 새 값을 준다', () {
      final container = _container();
      expect(
        () => container.read(dashboardApiConfigProvider),
        throwsA(isA<Object>()),
      );

      final applied = container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: _tokenA);

      expect(applied, _config(_urlA, _tokenA));
      expect(
        container.read(dashboardApiConfigProvider),
        _config(_urlA, _tokenA),
        reason: '오류 상태가 캐시로 남지 않는다',
      );
      final api = container.read(dashboardApiProvider);
      expect(api.config.baseUrl, Uri.parse(_urlA));
      expect(api.config.clientToken, _tokenA);
    });

    test('주소를 바꾸면 dashboardApiProvider가 새 설정으로 다시 만들어진다', () {
      final container = _container(initial: _config(_urlA, _tokenA));
      final before = container.read(dashboardApiProvider);

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlB, clientToken: _tokenB);

      final after = container.read(dashboardApiProvider);
      expect(after, isNot(same(before)));
      expect(after.config, _config(_urlB, _tokenB));
      expect(
        before.config,
        _config(_urlA, _tokenA),
        reason: '비행 중인 호출은 옛 설정을 그대로 쥔다',
      );
    });

    test('토큰만 바꿔도 dashboardApiConfigProvider를 듣는 쪽이 새 값을 받는다', () async {
      final container = _container(initial: _config(_urlA, _tokenA));
      final seen = <DashboardApiConfig>[];
      container.listen(
        dashboardApiConfigProvider,
        (previous, next) => seen.add(next),
      );

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: _tokenB);
      await container.pump();

      expect(seen, [_config(_urlA, _tokenB)]);
    });

    test('같은 값을 다시 저장하면 아무도 깨우지 않는다', () async {
      final container = _container(initial: _config(_urlA, _tokenA));
      final seen = <DashboardApiConfig>[];
      container.listen(
        dashboardApiConfigProvider,
        (previous, next) => seen.add(next),
      );

      final applied = container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlA, clientToken: _tokenA);
      await container.pump();

      expect(applied, _config(_urlA, _tokenA));
      expect(seen, isEmpty);
    });

    test('쓸 수 없는 주소는 아무것도 바꾸지 않고 null을 돌려준다', () {
      final initial = _config(_urlA, _tokenA);
      final container = _container(initial: initial);
      final controller = container.read(
        dashboardApiConfigControllerProvider.notifier,
      );

      for (final serverUrl in <String?>[
        null,
        'https://api.example.test:443x',
        'http://[::1',
      ]) {
        expect(
          controller.apply(serverUrl: serverUrl, clientToken: _tokenB),
          isNull,
          reason: '$serverUrl',
        );
        expect(
          container.read(dashboardApiConfigControllerProvider),
          initial,
          reason: '실행 중인 연결은 그대로다: $serverUrl',
        );
      }
    });

    test('첫 실행에서 쓸 수 없는 주소를 저장해도 여전히 값이 없다', () {
      final container = _container();

      final applied = container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://api.example.test:443x', clientToken: 't');

      expect(applied, isNull);
      expect(container.read(dashboardApiConfigControllerProvider), isNull);
      expect(
        () => container.read(dashboardApiConfigProvider),
        throwsA(isA<Object>()),
      );
    });
  });

  group('dashboardServerUrlProvider', () {
    test('지금 쓰는 설정이 없으면 부팅 스냅샷의 주소다', () {
      final container = _container(
        snapshot: const DashboardConfigValues(serverUrl: _urlA),
      );

      expect(container.read(dashboardServerUrlProvider), _urlA);
    });

    test('스냅샷에도 설정에도 주소가 없으면 null이다', () {
      final container = _container(snapshot: DashboardConfigValues.empty);

      expect(container.read(dashboardServerUrlProvider), isNull);
    });

    test('이 세션에서 저장한 주소가 부팅 스냅샷보다 먼저다', () {
      final container = _container(snapshot: DashboardConfigValues.empty);
      expect(container.read(dashboardServerUrlProvider), isNull);

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlB, clientToken: _tokenB);

      expect(container.read(dashboardServerUrlProvider), _urlB);
    });

    test('주소를 바꾸면 옛 주소가 아니라 바꾼 주소를 돌려준다', () {
      final container = _container(
        initial: _config(_urlA, _tokenA),
        snapshot: const DashboardConfigValues(serverUrl: _urlA),
      );
      expect(container.read(dashboardServerUrlProvider), _urlA);

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: _urlB, clientToken: _tokenB);

      expect(container.read(dashboardServerUrlProvider), _urlB);
    });
  });
}

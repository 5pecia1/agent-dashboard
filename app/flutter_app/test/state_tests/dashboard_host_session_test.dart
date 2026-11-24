import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/agent_dashboard.dart';
import 'package:my_dashboard/main.dart' show buildDashboardRoot;
import 'package:my_dashboard/src/state/config_provider.dart'
    show dashboardConfigValuesProvider;
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/dashboard_host_session.dart'
    show sessionTransport;

final origin = Uri.parse('https://dashboard.test');
final endpoint = origin.resolve('/dashboard/sync');
const timeout = Duration(seconds: 2);

DashboardHostSession session(
  Future<String?> Function({String? rejectedToken}) token,
) => DashboardHostSession(
  origin: origin,
  accessToken: token,
  wrapApp: (child) => child,
  connectionSettings: (context, language) => const SizedBox(),
);

void main() {
  testWidgets('호스트 부팅은 저장된 서버 자격 대신 새 세션을 쓰고 나머지 설정을 보존한다', (tester) async {
    const original = DashboardConfigValues(
      serverUrl: 'not a URL',
      clientToken: 'old static',
      cursor: 150,
      seenWatermark: 90,
      themeMode: 'dark',
      extra: {'custom': 7},
    );
    late DashboardConfigValues observed;
    late DashboardApi api;
    await tester.pumpWidget(
      buildDashboardRoot(
        original,
        session: session(({rejectedToken}) async => 'local fixture'),
        app: Consumer(
          builder: (context, ref, child) {
            observed = ref.watch(dashboardConfigValuesProvider);
            api = ref.watch(dashboardApiProvider);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(api.config.baseUrl.origin, origin.origin);
    expect(api.config.clientToken, isNull);
    expect(observed.serverUrl, origin.origin);
    expect(observed.clientToken, isNull);
    expect(observed.cursor, isNull);
    expect(observed.seenWatermark, isNull);
    expect(observed.themeMode, 'dark');
    expect(observed.extra, original.extra);
    expect(original.clientToken, 'old static');
  });

  test('읽기는 거절된 자격을 한 번만 갱신하며 다른 서비스에 리다이렉트하지 않는다', () async {
    final requested = <String?>[];
    final sent = <ApiRequest>[];
    final authorized = sessionTransport(
      session(({rejectedToken}) async {
        requested.add(rejectedToken);
        return rejectedToken == null ? 'fixture-one' : 'fixture-two';
      }),
      (request) async {
        sent.add(request);
        return ApiResponse(statusCode: sent.length == 1 ? 401 : 200);
      },
      active: () => true,
      timeout: timeout,
    );
    final result = await authorized(ApiRequest(method: 'GET', url: endpoint));
    expect(result.statusCode, 200);
    expect(requested, [null, 'fixture-one']);
    expect(sent.map((r) => r.headers['Authorization']), [
      'Bearer fixture-one',
      'Bearer fixture-two',
    ]);
    expect(sent.every((r) => !r.followRedirects && r.url == endpoint), isTrue);
  });

  test('서버 쓰기는 자격이 갱신되어도 자동 재전송하지 않는다', () async {
    for (final method in ['POST', 'PUT', 'DELETE']) {
      var sends = 0;
      String? rejected;
      final authorized = sessionTransport(
        session(({rejectedToken}) async {
          rejected = rejectedToken;
          return rejectedToken == null ? 'fixture-one' : 'fixture-two';
        }),
        (_) async {
          sends++;
          return const ApiResponse(statusCode: 401, body: 'Bearer fixture-one');
        },
        active: () => true,
        timeout: timeout,
      );
      final result = await authorized(
        ApiRequest(method: method, url: endpoint, body: '{}'),
      );
      expect(rejected, 'fixture-one');
      expect(sends, 1);
      expect(result.statusCode, 401);
      expect(result.body, isEmpty);
    }
  });

  test('출처와 API 경로가 일치하는 요청에만 세션 자격을 제공한다', () async {
    final authorized = sessionTransport(
      session(
        ({rejectedToken}) async => fail('unexpected credentials request'),
      ),
      (r) async => fail('unexpected request'),
      active: () => true,
      timeout: timeout,
    );
    for (final uri in [
      'https://other.test/dashboard/sync',
      'https://u@dashboard.test/dashboard/sync',
      'https://dashboard.test:8443/dashboard/sync',
      'https://dashboard.test/other',
    ]) {
      await expectLater(
        authorized(ApiRequest(method: 'GET', url: Uri.parse(uri))),
        throwsA(isA<DashboardUnauthorized>()),
      );
    }
    for (final url in [
      'http://elsewhere.test',
      'https://u@dashboard.test',
      'https://dashboard.test/suffix',
      'https://dashboard.test/?token=secret',
    ]) {
      expect(
        () => DashboardHostSession(
          origin: Uri.parse(url),
          accessToken: ({rejectedToken}) async => null,
          wrapApp: (child) => child,
          connectionSettings: (context, language) => const SizedBox(),
        ),
        throwsArgumentError,
      );
    }
  });

  test('로그아웃하거나 제한 시간이 지난 후 준비된 자격으로 쓰기를 시작하지 않는다', () async {
    for (final expired in [false, true]) {
      var mounted = true;
      final pending = Completer<String?>();
      final authorized = sessionTransport(
        session(({rejectedToken}) => pending.future),
        (_) async => fail('mutation after expiry or logout'),
        active: () => mounted,
        timeout: expired ? Duration.zero : timeout,
      );
      final attempt = authorized(ApiRequest(method: 'DELETE', url: endpoint));
      if (!expired) mounted = false;
      pending.complete('fixture');
      await expectLater(attempt, throwsA(isA<DashboardApiException>()));
    }
  });

  test('자격 조회 실패의 상세 내용이 화면 오류로 노출되지 않는다', () async {
    final authorized = sessionTransport(
      session(({rejectedToken}) async => throw StateError('sensitive fixture')),
      (_) async => fail('unexpected request'),
      active: () => true,
      timeout: timeout,
    );
    await expectLater(
      authorized(ApiRequest(method: 'GET', url: endpoint)),
      throwsA(
        isA<DashboardNetworkFailure>().having(
          (e) => e.toString(),
          'error',
          isNot(contains('sensitive fixture')),
        ),
      ),
    );
  });
}

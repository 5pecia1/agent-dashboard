import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';

const connection = DevinConnection(
  baseUrl: 'https://devin.test',
  apiKey: 'test-key',
);

// 실제 GetUserStatus 응답에서 관측한 필드 구조. 값은 테스트용이다.
//
// 리셋 시각(`*QuotaResetAtUnix`)은 **항상 미래여야 한다** — `QuotaResetTime`
// (`lib/src/ui/widgets/quota_widgets.dart`)이 `DateTime.now()`와의 차이로
// reset_days/reset_hours/reset_due 분기를 고르기 때문에, 고정 epoch가
// 만료되는 순간 `reset_days`를 단언하는 위젯 테스트가 시간 폭탄이 된다
// (옛 값 1789891200 = 2026-09-20T08:00Z이 실제로 만료돼 그날의
// `flutter test`가 깨졌다 — 그래서 1년 뒤로 밀어 둔 값들이다).
Map<String, dynamic> userStatusFixture() => {
  'userStatus': {
    'planStatus': {
      'planInfo': {
        'planName': 'Max',
        'billingStrategy': 'BILLING_STRATEGY_QUOTA',
        'hideDailyQuota': true,
        'devinInfo': {'accountDisplayName': 'tester'},
      },
      'planStart': '2027-09-14T14:21:06Z',
      'planEnd': '2027-10-14T14:21:06Z',
      'dailyQuotaRemainingPercent': 100,
      'weeklyQuotaRemainingPercent': 48,
      'overageBalanceMicros': '7462105',
      'dailyQuotaResetAtUnix': '1821513600',
      'weeklyQuotaResetAtUnix': '1821427200',
    },
  },
};

// 주간 한도 소진 계정의 실측 응답 모양 — proto3는 기본값(0) 필드를 생략하므로
// `weeklyQuotaRemainingPercent` 키 자체가 없고, 리셋 시각과 음수 overage
// (초과 사용 부채)만 남는다.
Map<String, dynamic> userStatusExhaustedFixture() => {
  'userStatus': {
    'planStatus': {
      'planInfo': {
        'planName': 'Max',
        'billingStrategy': 'BILLING_STRATEGY_QUOTA',
        'hideDailyQuota': true,
        'devinInfo': {'accountDisplayName': 'tester'},
      },
      'planStart': '2027-09-14T14:21:06Z',
      'planEnd': '2027-10-14T14:21:06Z',
      'dailyQuotaRemainingPercent': 100,
      'overageBalanceMicros': '-1714726',
      'dailyQuotaResetAtUnix': '1821513600',
      'weeklyQuotaResetAtUnix': '1821427200',
    },
  },
};

void main() {
  test('주소를 비우면 표준 서버로 접고 RPC 경로는 루트로 정규화한다', () {
    expect(
      DevinConnection.parse('', 'key').baseUrl,
      'https://server.codeium.com',
    );
    expect(
      DevinConnection.parse('  https://devin.test/  ', 'key').baseUrl,
      'https://devin.test',
    );
    expect(
      DevinConnection.parse(
        'https://devin.test$kDevinUserStatusPath',
        'key',
      ).userStatusUrl.toString(),
      'https://devin.test$kDevinUserStatusPath',
    );
    for (final url in [
      'javascript:alert(1)',
      'https://user:pass@devin.test',
      'https://devin.test?token=x',
      'devin.test',
      'https://devin.test/#foo',
    ]) {
      expect(() => DevinConnection.parse(url, 'key'), throwsFormatException);
    }
    expect(() => DevinConnection.parse('', 'a\nb'), throwsFormatException);
    expect(() => DevinConnection.parse('', '  '), throwsFormatException);
  });

  test('응답에서 쿼터와 리셋 시각을 읽고 사용률은 잔량의 보수로 환산한다', () {
    final quota = DevinQuota.fromUserStatus(userStatusFixture());
    expect(quota.accountName, 'tester');
    expect(quota.planName, 'Max');
    expect(quota.billingStrategy, 'BILLING_STRATEGY_QUOTA');
    expect(quota.weeklyRemainingPercent, 48);
    expect(quota.weeklyUsedPercent, 52);
    expect(quota.dailyUsedPercent, 0);
    expect(quota.hideDailyQuota, isTrue);
    expect(quota.overageBalanceMicros, 7462105);
    expect(
      quota.weeklyResetAt,
      DateTime.fromMillisecondsSinceEpoch(1821427200000),
    );
  });

  test('윈도우가 있는데 잔량 키가 생략된 소진 응답은 0을 복원해 100%로 읽는다', () {
    final quota = DevinQuota.fromUserStatus(userStatusExhaustedFixture());
    expect(quota.weeklyRemainingPercent, 0);
    expect(quota.weeklyUsedPercent, 100);
    expect(quota.dailyUsedPercent, 0);
    expect(quota.weeklyResetAt, isNotNull);
    expect(quota.overageBalanceMicros, -1714726);
  });

  test('일간 윈도우만 남은 QUOTA 응답도 같은 규칙으로 0을 복원한다', () {
    final quota = DevinQuota.fromUserStatus({
      'userStatus': {
        'planStatus': {
          'planInfo': {'billingStrategy': 'BILLING_STRATEGY_QUOTA'},
          'dailyQuotaResetAtUnix': '1821513600',
        },
      },
    });
    expect(quota.dailyUsedPercent, 100);
    expect(quota.weeklyUsedPercent, isNull);
  });

  test('잔량과 리셋 시각이 둘 다 없는 QUOTA 응답은 null을 유지한다', () {
    // 윈도우 자체가 없으면 0으로 복원하지 않는다 — 없는 쿼터를 소진으로 착각 금지.
    final quota = DevinQuota.fromUserStatus({
      'userStatus': {
        'planStatus': {
          'planInfo': {'billingStrategy': 'BILLING_STRATEGY_QUOTA'},
        },
      },
    });
    expect(quota.weeklyUsedPercent, isNull);
    expect(quota.dailyUsedPercent, isNull);
  });

  test('QUOTA가 아닌 계정은 리셋 시각만 있어도 잔량을 추론하지 않는다', () {
    final quota = DevinQuota.fromUserStatus({
      'userStatus': {
        'planStatus': {
          'planInfo': {'billingStrategy': 'BILLING_STRATEGY_ACU'},
          'weeklyQuotaResetAtUnix': '1821427200',
        },
      },
    });
    expect(quota.weeklyUsedPercent, isNull);
  });

  test('ACU 한도는 있는데 누적치 키가 없으면 0으로 읽는다', () {
    // 신선한 ACU 계정의 실측 모양 — 누적치 0도 proto3가 생략한다.
    final quota = DevinQuota.fromUserStatus({
      'userStatus': {
        'planStatus': {
          'planInfo': {'planName': 'Enterprise'},
          'acuLimit': '500',
        },
      },
    });
    expect(quota.acuConsumed, 0);
    expect(quota.acuLimit, 500);
  });

  test('overage USD 서식은 음수 부채도 부호를 달러 밖에 유지한다', () {
    expect(formatDevinOverageUsd(7462105), r'$7.46');
    expect(formatDevinOverageUsd(-1714726), r'-$1.71');
    expect(formatDevinOverageUsd(0), r'$0.00');
  });

  test('쿼터 필드가 없는 과금 방식도 파싱되고 ACU 값을 읽는다', () {
    final quota = DevinQuota.fromUserStatus({
      'userStatus': {
        'planStatus': {
          'planInfo': {'planName': 'Enterprise'},
          'acuConsumed': 12.5,
          'acuLimit': '500',
        },
      },
    });
    expect(quota.weeklyUsedPercent, isNull);
    expect(quota.dailyUsedPercent, isNull);
    expect(quota.acuConsumed, 12.5);
    expect(quota.acuLimit, 500);
  });

  test('userStatus가 없는 응답은 지원 형식이 아니다', () {
    expect(
      () => DevinQuota.fromUserStatus({'unexpected': true}),
      throwsFormatException,
    );
  });

  test('연동 설정 저장과 해제가 다른 필드를 보존하고 로그에는 키가 없다', () {
    const initial = DashboardConfigValues(
      serverUrl: 'https://dash.test',
      clientToken: 'dash-key',
      cursor: 17,
      themeMode: 'dark',
    );
    final configured = initial.withDevin(connection);
    expect(DashboardConfigValues.fromJson(configured.toJson()), configured);
    expect(configured.copyWith(cursor: 18).devin, connection);
    expect(configured.withDevin(null), initial);
    expect(configured.toString(), isNot(contains('test-key')));
    expect(connection.toString(), isNot(contains('test-key')));
  });

  test('POST 본문의 metadata.api_key로만 인증하고 리다이렉트는 금지한다', () async {
    final requests = <ApiRequest>[];
    final api = DevinUsageApi((request) async {
      requests.add(request);
      return ApiResponse(
        statusCode: 200,
        body: jsonEncode(userStatusFixture()),
      );
    });
    final quota = await api.userStatus(connection);
    expect(quota.weeklyUsedPercent, 52);
    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, kDevinUserStatusPath);
    expect(request.followRedirects, isFalse);
    expect(request.headers.containsKey('Authorization'), isFalse);
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    expect(body, {
      'metadata': {
        'api_key': 'test-key',
        'ide_name': kDevinClientName,
        'ide_version': kDevinClientVersion,
        'extension_name': kDevinClientName,
        'extension_version': kDevinClientVersion,
      },
    });
  });

  test('인증 오류 시간 초과 손상 응답을 구분하고 서버 원문은 노출하지 않는다', () async {
    // 이 서버는 잘못된 키에 401이 아니라 400 + invalid_argument를 돌려준다
    // (실측 확인) — 그 조합도 키 문제로 안내한다.
    for (final (code, body, label) in [
      (401, '', 'devin.unauthorized'),
      (403, '', 'devin.unauthorized'),
      (400, '{"code":"unauthenticated"}', 'devin.unauthorized'),
      (400, '{"code":"invalid_argument"}', 'devin.unauthorized'),
      (500, '', 'devin.server_error'),
      (400, '{"code":"not_found"}', 'devin.server_error'),
      (302, '', 'devin.server_error'),
    ]) {
      final api = DevinUsageApi(
        (_) async => ApiResponse(statusCode: code, body: body),
      );
      await expectLater(
        api.userStatus(connection),
        throwsA(
          isA<DevinUsageFailure>().having((e) => e.labelKey, 'label', label),
        ),
      );
    }
    final malformed = DevinUsageApi(
      (_) async => const ApiResponse(statusCode: 200, body: '<html>x</html>'),
    );
    await expectLater(
      malformed.userStatus(connection),
      throwsA(
        isA<DevinUsageFailure>().having(
          (e) => e.labelKey,
          'label',
          'devin.invalid_response',
        ),
      ),
    );
    final timeout = DevinUsageApi(
      (_) => Completer<ApiResponse>().future,
      timeout: const Duration(milliseconds: 1),
    );
    await expectLater(
      timeout.userStatus(connection),
      throwsA(
        isA<DevinUsageFailure>().having(
          (e) => e.labelKey,
          'label',
          'devin.timeout',
        ),
      ),
    );
  });

  test('미설정 시 요청하지 않고 저장 직후 조회하며 연결 해제 후 늦은 응답은 버린다', () async {
    final reply = Completer<ApiResponse>();
    final requests = <ApiRequest>[];
    final container = ProviderContainer(
      overrides: [
        httpSendProvider.overrideWithValue((request) {
          requests.add(request);
          return reply.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(devinUsageControllerProvider.notifier);
    await controller.refresh();
    expect(requests, isEmpty);
    controller.configure(connection);
    final pending = controller.refresh();
    expect(requests.length, 1, reason: '중복 새로고침은 합친다');
    controller.configure(null);
    reply.complete(
      ApiResponse(statusCode: 200, body: jsonEncode(userStatusFixture())),
    );
    await pending;
    expect(container.read(devinUsageControllerProvider).connection, isNull);
    expect(container.read(devinUsageControllerProvider).quota, isNull);
  });

  test('실패 시 마지막 성공 값과 시각을 보존하고 새 키로 다시 조회한다', () async {
    var fail = false;
    final bodies = <String?>[];
    final container = ProviderContainer(
      overrides: [
        httpSendProvider.overrideWithValue((request) async {
          bodies.add(request.body);
          return fail
              ? const ApiResponse(statusCode: 401)
              : ApiResponse(
                  statusCode: 200,
                  body: jsonEncode(userStatusFixture()),
                );
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(devinUsageControllerProvider.notifier);
    controller.configure(connection);
    await controller.refresh();
    final original = container.read(devinUsageControllerProvider);
    fail = true;
    await controller.refresh();
    final failed = container.read(devinUsageControllerProvider);
    expect(failed.quota, same(original.quota));
    expect(failed.updatedAt, original.updatedAt);
    expect(failed.errorKey, 'devin.unauthorized');
    fail = false;
    controller.configure(
      const DevinConnection(baseUrl: 'https://new.test', apiKey: 'new-key'),
    );
    await controller.refresh();
    expect(
      (jsonDecode(bodies.last!) as Map<String, dynamic>)['metadata']
          as Map<String, dynamic>,
      {
        'api_key': 'new-key',
        'ide_name': kDevinClientName,
        'ide_version': kDevinClientVersion,
        'extension_name': kDevinClientName,
        'extension_version': kDevinClientVersion,
      },
    );
    expect(container.read(devinUsageControllerProvider).errorKey, isNull);
  });
}

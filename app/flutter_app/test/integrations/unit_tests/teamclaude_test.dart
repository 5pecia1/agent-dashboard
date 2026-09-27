import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_api.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/http_transport_io.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';

const connection = TeamClaudeConnection(
  baseUrl: 'https://tc.test',
  apiKey: 'test-key',
);

// 실제 1.1.20 응답에서 관측한 필드 구조. 이름과 수치는 테스트용이다.
Map<String, dynamic> statusFixture() => {
  'accounts': [
    {
      'name': 'name-says-codex',
      'provider': 'anthropic',
      'quota': {
        'unified5h': 0.3,
        'unified7d': 0.95,
        'scopedWeekly': {
          // 24시간 경계 아래로 내려가지 않는 고정 미래 시각(2033-05-18)으로
          // reset_days 분기를 결정적으로 검증한다.
          'fable': {'utilization': 0.58, 'resetAt': 2000000000000},
        },
      },
    },
    {
      'name': 'team',
      'provider': 'anthropic',
      'disabled': true,
      'quota': {'unified5h': 0.5, 'unified7d': 0.98, 'unified7dFable': null},
    },
    {
      'name': 'name-says-claude',
      'provider': 'codex',
      'quota': {'planType': 'pro', 'unified7d': 0.34},
    },
    {
      'name': 'lite',
      'provider': 'codex',
      'quota': {'planType': 'prolite', 'unified7d': 0.01},
    },
  ],
};

Map<String, dynamic> quotaFixture() => {
  'accounts': [
    {
      'name': 'name-says-codex',
      'tier': {'weight': 20, 'rateLimitTier': 'default_claude_max_20x'},
    },
    {
      'name': 'team',
      'tier': {'weight': 1, 'seatTier': 'team_standard'},
      'buckets': {
        'weeklyFable': {'source': 'unified7d'},
      },
    },
  ],
};

void main() {
  test('대표 리셋은 해당 한도에서 가장 가까운 미래 시각이고 과거 및 다른 한도는 제외한다', () {
    final now = DateTime.utc(2026, 9, 14);
    final early = now.add(const Duration(hours: 1));
    final late = now.add(const Duration(days: 2));
    TeamClaudeAccount account(DateTime? reset) => TeamClaudeAccount(
      name: 'test',
      provider: kTeamClaudeProvider,
      capacityWeight: 1,
      limits: {
        TeamClaudeBucket.weekly: TeamClaudeLimit(
          utilization: 0.5,
          resetAt: reset,
        ),
        TeamClaudeBucket.fiveHour: TeamClaudeLimit(
          utilization: 0.1,
          resetAt: now.add(const Duration(minutes: 5)),
        ),
      },
    );
    final accounts = [
      account(late),
      account(now.subtract(const Duration(minutes: 1))),
      account(null),
      account(early),
    ];
    expect(
      TeamClaudeTotal(
        accounts,
        TeamClaudeBucket.weekly,
        weighted: true,
        now: now,
      ).nextResetAt,
      early,
    );
    expect(
      TeamClaudeTotal(
        [account(now), account(null)],
        TeamClaudeBucket.weekly,
        weighted: true,
        now: now,
      ).nextResetAt,
      isNull,
    );
  });
  test('요금제 조회 장애도 이전 완전한 결과를 보존하고 인증 오류 뒤 복귀 시 자동 요청하지 않는다', () async {
    int? quotaError;
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        httpSendProvider.overrideWithValue((request) async {
          requests++;
          if (request.url.path == kTeamClaudeQuotaPath && quotaError != null) {
            return ApiResponse(statusCode: quotaError);
          }
          return ApiResponse(
            statusCode: 200,
            body: jsonEncode(
              request.url.path == kTeamClaudeStatusPath
                  ? statusFixture()
                  : quotaFixture(),
            ),
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(teamClaudeControllerProvider.notifier);
    controller.configure(connection);
    await controller.refresh();
    final first = container.read(teamClaudeControllerProvider);
    quotaError = 503;
    await controller.refresh();
    expect(
      container.read(teamClaudeControllerProvider).snapshot,
      same(first.snapshot),
    );
    expect(
      container.read(teamClaudeControllerProvider).updatedAt,
      first.updatedAt,
    );
    expect(
      container.read(teamClaudeControllerProvider).errorKey,
      'teamclaude.server_error',
    );
    quotaError = 401;
    await controller.refresh();
    final beforeResume = requests;
    controller.setActive(false);
    controller.setActive(true);
    expect(requests, beforeResume);
    expect(
      container.read(teamClaudeControllerProvider).errorKey,
      'teamclaude.unauthorized',
    );
  });

  test('비어 있는 scoped 한도는 유효한 전용 값으로 보완하고 큰 가중치도 유한한 비율을 만든다', () {
    final account = TeamClaudeAccount.fromJson(
      {
        'name': 'max',
        'provider': 'anthropic',
        'quota': {
          'unified7dFable': 0.4,
          'scopedWeekly': {'fable': <String, dynamic>{}},
        },
      },
      summary: {
        'tier': {'weight': 1e308},
      },
    );
    final total = TeamClaudeTotal(
      [account, account],
      TeamClaudeBucket.fable,
      weighted: true,
    );
    expect(total.usedPercent, 40);
    final codex = TeamClaudeSnapshot.fromJson(
      statusFixture(),
    ).forProvider(kTeamCodexProvider);
    expect(
      () => TeamClaudeTotal(codex, TeamClaudeBucket.weekly, weighted: false),
      throwsArgumentError,
    );
    expect(
      TeamClaudeTotal(
        [codex.first],
        TeamClaudeBucket.weekly,
        weighted: false,
      ).usedPercent,
      34,
    );
  });
  test('제공자는 이름이 아닌 명시적 provider로 구분하고 Claude 용량을 가중한다', () {
    final snapshot = TeamClaudeSnapshot.fromJson(
      statusFixture(),
      quota: quotaFixture(),
    );
    final claude = snapshot.forProvider(kTeamClaudeProvider);
    expect(claude.map((a) => a.name), ['name-says-codex', 'team']);
    expect(
      TeamClaudeTotal(claude, TeamClaudeBucket.fiveHour, weighted: true).ratio,
      closeTo((0.3 * 20 + 0.5) / 21, 1e-10),
    );
    expect(
      TeamClaudeTotal(
        claude,
        TeamClaudeBucket.weekly,
        weighted: true,
      ).usedPercent,
      95,
    );
    final fableTotal = TeamClaudeTotal(
      claude,
      TeamClaudeBucket.fable,
      weighted: true,
    );
    expect(fableTotal.usedPercent, 58);
    expect(fableTotal.knownAccounts, 1);
    expect(fableTotal.partial, isTrue);
    expect(claude.last.limits[TeamClaudeBucket.fable]!.utilization, isNull);
    expect(claude.last.disabled, isTrue, reason: '전체 보유 용량에는 비활성 계정도 포함한다');
    expect(snapshot.forProvider(kTeamCodexProvider).map((a) => a.plan), [
      'pro',
      'prolite',
    ]);
  });

  test('quota 요약의 Fable 별칭은 명시 상태 값이 없으면 Fable 한도로 보지 않는다', () {
    final account = TeamClaudeAccount.fromJson(
      {
        'name': 'raven-seat',
        'provider': 'anthropic',
        'quota': {
          'unified5h': 1,
          'unified7d': 0.37,
          'unified7dSonnet': null,
          'unified7dFable': null,
          'scopedWeekly': <String, dynamic>{},
        },
      },
      summary: {
        'tier': {
          'weight': 1,
          'rateLimitTier': 'default_raven',
          'seatTier': 'team_standard',
        },
        'buckets': {
          'weeklyShared': {'source': 'unified7d'},
          'weeklySonnet': {'source': 'unified7d'},
          'weeklyFable': {'source': 'unified7d'},
        },
      },
    );
    expect(account.limits[TeamClaudeBucket.fable]!.utilization, isNull);
    expect(account.limits[TeamClaudeBucket.weekly]!.utilization, 0.37);
    final explicit = TeamClaudeAccount.fromJson(
      {
        'name': 'fable-seat',
        'provider': 'anthropic',
        'quota': {'unified7dFable': 0.9},
      },
      summary: {
        'tier': {'weight': 1},
      },
    );
    expect(explicit.limits[TeamClaudeBucket.fable]!.utilization, 0.9);
    final total = TeamClaudeTotal(
      [account, explicit],
      TeamClaudeBucket.fable,
      weighted: true,
    );
    expect(total.knownAccounts, 1);
    expect(total.usedPercent, 90);
    expect(total.partial, isTrue);
  });

  test('용량이나 사용률이 없으면 영 퍼센트로 채우지 않고 부분 집계한다', () {
    final accounts = TeamClaudeSnapshot.fromJson(
      statusFixture(),
    ).forProvider(kTeamClaudeProvider);
    final total = TeamClaudeTotal(
      accounts,
      TeamClaudeBucket.weekly,
      weighted: true,
    );
    expect(total.ratio, isNull);
    expect(total.knownAccounts, 0);
    expect(total.partial, isTrue);
    expect(accounts.last.limits[TeamClaudeBucket.fable]!.utilization, isNull);
    expect(TeamClaudeLimit.fromValues('50', null).utilization, isNull);
    expect(TeamClaudeLimit.fromValues(double.nan, null).utilization, isNull);
    expect(TeamClaudeLimit.fromValues(-0.1, null).utilization, isNull);
  });

  test('요금제 정보 결합은 배열 순서가 바뀌어도 맞고 중복 이름은 제외한다', () {
    final quota = quotaFixture();
    quota['accounts'] = (quota['accounts'] as List).reversed.toList();
    final snapshot = TeamClaudeSnapshot.fromJson(statusFixture(), quota: quota);
    expect(snapshot.accounts.first.capacityWeight, 20);
    final status = statusFixture();
    (status['accounts'] as List).add((status['accounts'] as List).first);
    final ambiguous = TeamClaudeSnapshot.fromJson(status, quota: quota);
    expect(ambiguous.accounts.first.capacityWeight, isNull);
    (quota['accounts'] as List).add((quota['accounts'] as List).first);
    final duplicateQuota = TeamClaudeSnapshot.fromJson(
      statusFixture(),
      quota: quota,
    );
    expect(duplicateQuota.accounts[1].capacityWeight, isNull);
  });

  test('관측한 ISO 및 epoch 밀리초 초기화 시각을 읽고 잘못된 응답은 거절한다', () {
    expect(
      TeamClaudeLimit.fromValues(0, '2026-09-17T00:00:00Z').resetAt,
      DateTime.utc(2026, 9, 17),
    );
    expect(
      TeamClaudeLimit.fromValues(
        0.2,
        1789545600077,
      ).resetAt!.millisecondsSinceEpoch,
      1789545600077,
    );
    expect(() => TeamClaudeSnapshot.fromJson({}), throwsFormatException);
    expect(
      () => TeamClaudeSnapshot.fromJson({
        'accounts': [null],
      }),
      throwsFormatException,
    );
  });

  test('화면 주소와 헤더 전체 붙여넣기를 정규화하고 부적절한 주소와 다중 헤더는 거절한다', () {
    final parsed = TeamClaudeConnection.parse(
      ' https://tc.test/prefix/teamclaude/dashboard/ ',
      ' X-Api-Key: test-key ',
    );
    expect(
      parsed.statusUrl.toString(),
      'https://tc.test/prefix/teamclaude/status',
    );
    expect(parsed.apiKey, 'test-key');
    for (final url in [
      'javascript:alert(1)',
      'https://user:pass@tc.test',
      'https://tc.test?token=x',
      'tc.test',
      'https://tc.test/#foo',
    ]) {
      expect(
        () => TeamClaudeConnection.parse(url, 'key'),
        throwsFormatException,
      );
    }
    expect(
      () => TeamClaudeConnection.parse(
        'https://tc.test',
        'X-Api-Key: a\nX-Foo: b',
      ),
      throwsFormatException,
    );
  });

  test('연동 설정 저장과 해제가 기존 토큰 테마 커서를 보존하고 로그에는 키가 없다', () {
    const initial = DashboardConfigValues(
      serverUrl: 'https://dash.test',
      clientToken: 'dash-key',
      cursor: 17,
      themeMode: 'dark',
      uiLang: 'ko',
      seenWatermark: 8,
    );
    final configured = initial.withTeamClaude(connection);
    expect(DashboardConfigValues.fromJson(configured.toJson()), configured);
    expect(configured.copyWith(cursor: 18).teamClaude, connection);
    expect(configured.withTeamClaude(null), initial);
    expect(configured.toString(), isNot(contains('test-key')));
    expect(connection.toString(), isNot(contains('test-key')));
  });

  test('상태와 요금제 조회에는 TeamClaude 키만 보내고 리다이렉트는 금지한다', () async {
    final requests = <ApiRequest>[];
    final api = TeamClaudeApi((request) async {
      requests.add(request);
      return ApiResponse(
        statusCode: 200,
        body: jsonEncode(
          request.url.path == kTeamClaudeStatusPath
              ? statusFixture()
              : quotaFixture(),
        ),
      );
    });
    final snapshot = await api.status(connection);
    expect(snapshot.accounts.first.capacityWeight, 20);
    expect(requests.map((r) => r.url.path), [
      kTeamClaudeStatusPath,
      kTeamClaudeQuotaPath,
    ]);
    for (final request in requests) {
      expect(request.method, 'GET');
      expect(request.followRedirects, isFalse);
      expect(request.headers['X-Api-Key'], 'test-key');
      expect(request.headers.containsKey('Authorization'), isFalse);
    }
  });

  test('요금제 조회가 없는 서버도 계정 내역은 보여주고 가중치는 추측하지 않는다', () async {
    final api = TeamClaudeApi(
      (request) async => request.url.path == kTeamClaudeStatusPath
          ? ApiResponse(statusCode: 200, body: jsonEncode(statusFixture()))
          : const ApiResponse(statusCode: 404),
    );
    final result = await api.status(connection);
    expect(result.accounts.length, 4);
    expect(result.accounts.first.capacityWeight, isNull);
  });

  test('인증 오류 시간 초과 손상 응답을 구분하고 서버 원문은 노출하지 않는다', () async {
    for (final code in [401, 403, 500, 302]) {
      final api = TeamClaudeApi(
        (_) async => ApiResponse(statusCode: code, body: 'test-key'),
      );
      await expectLater(
        api.status(connection),
        throwsA(
          isA<TeamClaudeFailure>().having(
            (e) => e.labelKey,
            'label',
            code == 401 || code == 403
                ? 'teamclaude.unauthorized'
                : 'teamclaude.server_error',
          ),
        ),
      );
    }
    final malformed = TeamClaudeApi(
      (_) async =>
          const ApiResponse(statusCode: 200, body: '<html>test-key</html>'),
    );
    await expectLater(
      malformed.status(connection),
      throwsA(
        isA<TeamClaudeFailure>().having(
          (e) => e.labelKey,
          'label',
          'teamclaude.invalid_response',
        ),
      ),
    );
    final timeout = TeamClaudeApi(
      (_) => Completer<ApiResponse>().future,
      timeout: const Duration(milliseconds: 1),
    );
    await expectLater(
      timeout.status(connection),
      throwsA(
        isA<TeamClaudeFailure>().having(
          (e) => e.labelKey,
          'label',
          'teamclaude.timeout',
        ),
      ),
    );
  });

  test('실제 HTTP 전송도 리다이렉트 대상에 키를 보내지 않는다', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) {
      paths.add(request.uri.path);
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/elsewhere');
      request.response.close();
    });
    final response = await sendHttpRequest(
      ApiRequest(
        method: 'GET',
        url: Uri.parse('http://127.0.0.1:${server.port}/teamclaude/status'),
        headers: {'X-Api-Key': 'test-key'},
        followRedirects: false,
      ),
    );
    expect(response.statusCode, HttpStatus.found);
    expect(paths, ['/teamclaude/status']);
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
    final controller = container.read(teamClaudeControllerProvider.notifier);
    await controller.refresh();
    expect(requests, isEmpty);
    controller.configure(connection);
    final pending = controller.refresh();
    expect(requests.length, 1, reason: '중복 새로고침은 합친다');
    controller.configure(null);
    reply.complete(
      ApiResponse(statusCode: 200, body: jsonEncode(statusFixture())),
    );
    await pending;
    expect(container.read(teamClaudeControllerProvider).connection, isNull);
    expect(container.read(teamClaudeControllerProvider).snapshot, isNull);
  });

  test('연결 정보가 바뀌면 새 키로 조회하고 실패 시 마지막 성공 값과 시각을 보존한다', () async {
    var fail = false;
    final keys = <String?>[];
    final container = ProviderContainer(
      overrides: [
        httpSendProvider.overrideWithValue((request) async {
          keys.add(request.headers['X-Api-Key']);
          return fail
              ? const ApiResponse(statusCode: 401)
              : ApiResponse(
                  statusCode: 200,
                  body: jsonEncode(
                    request.url.path == kTeamClaudeStatusPath
                        ? statusFixture()
                        : quotaFixture(),
                  ),
                );
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(teamClaudeControllerProvider.notifier);
    controller.configure(connection);
    await controller.refresh();
    final original = container.read(teamClaudeControllerProvider);
    fail = true;
    await controller.refresh();
    final failed = container.read(teamClaudeControllerProvider);
    expect(failed.snapshot, same(original.snapshot));
    expect(failed.updatedAt, original.updatedAt);
    expect(failed.errorKey, 'teamclaude.unauthorized');
    fail = false;
    controller.configure(
      const TeamClaudeConnection(
        baseUrl: 'https://new.test',
        apiKey: 'new-key',
      ),
    );
    await controller.refresh();
    expect(keys.last, 'new-key');
    expect(container.read(teamClaudeControllerProvider).errorKey, isNull);
  });
}

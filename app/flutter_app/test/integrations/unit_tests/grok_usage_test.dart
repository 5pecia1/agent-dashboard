import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/grok_bot_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_bot_secret.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/platform/grok_auth_io.dart';
import 'package:my_dashboard/src/integrations/platform/grok_bot_auth_io.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/usage_panels.dart';

void main() {
  final now = DateTime.utc(2026, 9, 28, 12);

  Map<String, Object?> session({
    String key = 'access-token',
    String? expiresAt,
    String email = 'person@example.test',
  }) => {
    'key': key,
    'user_id': 'user-1',
    'email': email,
    'team_id': 'team-1',
    'refresh_token': 'refresh-secret',
    'expires_at': ?expiresAt,
  };

  test('유효한 auth.x.ai 세션을 고르고 갱신 토큰은 담지 않는다', () {
    final result = interpretGrokAuthJson({
      'https://auth.x.ai::client': session(
        expiresAt: now.add(const Duration(hours: 2)).toIso8601String(),
      ),
      'other': session(key: 'other-token', email: 'other@example.test'),
    }, now: now);
    expect(result.status, GrokAuthStatus.ready);
    expect(result.session!.accessToken, 'access-token');
    expect(result.session!.email, 'person@example.test');
    expect(result.toString(), isNot(contains('access-token')));
    expect(result.toString(), isNot(contains('refresh-secret')));
    expect(result.session.toString(), isNot(contains('access-token')));
    expect(result.session.toString(), isNot(contains('refresh-secret')));
  });

  test('만료가 5분 이내인 auth.x.ai 세션은 다른 키로 넘어가지 않는다', () {
    final result = interpretGrokAuthJson({
      'https://auth.x.ai': session(
        expiresAt: now.add(const Duration(minutes: 5)).toIso8601String(),
      ),
      'other': session(
        key: 'fresh-other',
        expiresAt: now.add(const Duration(hours: 3)).toIso8601String(),
      ),
    }, now: now);
    expect(result.status, GrokAuthStatus.expired);
    expect(result.session, isNull);
  });

  test('auth.x.ai 항목이 없으면 다른 신선한 세션을 쓴다', () {
    final result = interpretGrokAuthJson({
      'legacy': session(
        key: 'legacy-token',
        expiresAt: now.add(const Duration(hours: 1)).toIso8601String(),
      ),
    }, now: now);
    expect(result.status, GrokAuthStatus.ready);
    expect(result.session!.accessToken, 'legacy-token');
  });

  test('주간 사용률과 리셋 시각을 읽고 월간 금액은 그 다음이다', () {
    final weekly = grokUsageReadingFromJson({
      'config': {
        'creditUsagePercent': 75,
        'subscriptionTier': 'SuperGrok',
        'currentPeriod': {'end': '2026-10-05T00:00:00Z'},
        'monthlyLimit': {'val': '15000'},
        'used': {'val': 3000},
      },
    }, accountLabel: 'person@example.test');
    expect(weekly!.window, GrokUsageWindow.weekly);
    expect(weekly.usedPercent, 75);
    expect(weekly.plan, 'SuperGrok');
    expect(weekly.accountLabel, 'person@example.test');
    expect(weekly.resetsAt, DateTime.utc(2026, 10, 5));

    final monthly = grokUsageReadingFromJson({
      'monthlyLimit': {'val': 15000},
      'used': {'val': '3000'},
      'billingPeriodEnd': '2026-10-01T00:00:00Z',
    });
    expect(monthly!.window, GrokUsageWindow.monthly);
    expect(monthly.usedPercent, closeTo(20, 0.001));
  });

  test('주간 구간인데 사용률 키가 없으면 0%이고 같은 본문의 월간 금액은 보지 않는다', () {
    final fresh = grokUsageReadingFromJson({
      'config': {
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'end': '2026-10-05T09:19:26.641555+00:00',
        },
        'onDemandCap': {'val': 0},
        'monthlyLimit': {'val': 15000},
        'used': {'val': 3000},
        'productUsage': [
          {'product': 'GrokBuild'},
        ],
      },
    });
    expect(fresh!.window, GrokUsageWindow.weekly);
    expect(fresh.usedPercent, 0);
    expect(fresh.resetsAt, DateTime.parse('2026-10-05T09:19:26.641555+00:00'));
  });

  test('제품별 사용률이 있으면 그 합을 주간 사용률로 읽는다', () {
    final products = grokUsageReadingFromJson({
      'config': {
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'end': '2026-10-05T00:00:00Z',
        },
        'productUsage': [
          {'product': 'GrokBuild', 'usagePercent': 54},
          {'product': 'GrokChat', 'usagePercent': 46},
          'skip',
        ],
      },
    });
    expect(products!.window, GrokUsageWindow.weekly);
    expect(products.usedPercent, 100);
    expect(products.resetsAt, DateTime.utc(2026, 10, 5));

    final clamped = grokUsageReadingFromJson({
      'config': {
        'productUsage': [
          {'usagePercent': 60},
          {'usagePercent': 50},
        ],
      },
    });
    expect(clamped!.usedPercent, 100);
    expect(clamped.window, GrokUsageWindow.weekly);
  });

  test('사용률 키가 있으면 0과 100을 그대로 읽고 제품 합으로 바꾸지 않는다', () {
    final full = grokUsageReadingFromJson({
      'config': {
        'creditUsagePercent': 100,
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'end': '2026-09-28T09:19:26.641555+00:00',
        },
        'productUsage': [
          {'usagePercent': 40},
          {'usagePercent': 40},
        ],
      },
    });
    expect(full!.usedPercent, 100);
    expect(full.window, GrokUsageWindow.weekly);

    final zero = grokUsageReadingFromJson({
      'config': {'creditUsagePercent': 0},
    });
    expect(zero!.usedPercent, 0);
    expect(zero.window, GrokUsageWindow.weekly);
  });

  test('사용률 키가 null이거나 주간 구간이 없으면 0%로 메우지 않는다', () {
    final explicitNull = grokUsageReadingFromJson({
      'config': {
        'creditUsagePercent': null,
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'end': '2026-10-05T00:00:00Z',
        },
      },
    });
    expect(explicitNull, isNull);

    final noWindow = grokUsageReadingFromJson({
      'config': {
        'onDemandCap': {'val': 0},
        'monthlyLimit': {'val': 0},
        'used': {'val': 49},
      },
    });
    expect(noWindow, isNull);
  });

  test('주간 비율이 없는 첫 응답 뒤에 월간 조회를 한 번 더 한다', () async {
    final requests = <ApiRequest>[];
    final api = GrokUsageApi((request) async {
      requests.add(request);
      if (request.url.queryParameters['format'] == 'credits') {
        return const ApiResponse(statusCode: 200, body: '{"config":{}}');
      }
      return const ApiResponse(
        statusCode: 200,
        body:
            '{"config":{"monthlyLimit":{"val":100},"used":{"val":25},"subscriptionTier":"API"}}',
      );
    });
    final reading = await api.fetch(
      base: Uri.parse('https://billing.test/v1'),
      session: const GrokSession(
        accessToken: 'secret-token',
        userId: 'user-1',
        email: 'person@example.test',
      ),
    );
    expect(reading.usedPercent, 25);
    expect(reading.window, GrokUsageWindow.monthly);
    expect(requests, hasLength(2));
    expect(
      requests.first.url,
      Uri.parse('https://billing.test/v1/billing?format=credits'),
    );
    expect(requests.last.url, Uri.parse('https://billing.test/v1/billing'));
    expect(requests.first.followRedirects, isFalse);
    expect(requests.first.headers['Authorization'], 'Bearer secret-token');
    expect(requests.first.headers['X-XAI-Token-Auth'], kGrokClientTokenAuth);
    expect(requests.first.headers['x-userid'], 'user-1');
    expect(api.toString(), isNot(contains('secret-token')));
  });

  test('생략된 주간 0%는 월간 조회 없이 반환한다', () async {
    var calls = 0;
    final api = GrokUsageApi((request) async {
      calls++;
      return const ApiResponse(
        statusCode: 200,
        body:
            '{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-10-05T09:19:26.641555+00:00"}}}',
      );
    });
    final reading = await api.fetch(
      base: Uri.parse('https://billing.test/v1'),
      session: const GrokSession(accessToken: 'secret-token'),
    );
    expect(reading.usedPercent, 0);
    expect(reading.window, GrokUsageWindow.weekly);
    expect(
      reading.resetsAt,
      DateTime.parse('2026-10-05T09:19:26.641555+00:00'),
    );
    expect(calls, 1);
  });

  test('401은 두 번째 조회 없이 인증 실패다', () async {
    var calls = 0;
    final api = GrokUsageApi((request) async {
      calls++;
      return const ApiResponse(statusCode: 401, body: '{}');
    });
    await expectLater(
      api.fetch(
        base: Uri.parse(kGrokDefaultBillingBase),
        session: const GrokSession(accessToken: 'secret-token'),
      ),
      throwsA(
        isA<GrokUsageFailure>().having(
          (error) => error.labelKey,
          'labelKey',
          'grok.unauthorized',
        ),
      ),
    );
    expect(calls, 1);
  });

  test('로그인 파일 경로는 GROK_HOME을 우선한다', () {
    expect(
      grokAuthFilePath(grokHome: '/tmp/grok-home', home: '/Users/someone'),
      '/tmp/grok-home/auth.json',
    );
    expect(
      grokAuthFilePath(home: '/Users/someone'),
      '/Users/someone/.grok/auth.json',
    );
  });

  test('임시 로그인 파일에서 세션을 읽고 없는 파일은 missing이다', () {
    final dir = Directory.systemTemp.createTempSync('grok-auth-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/auth.json').writeAsStringSync(
      jsonEncode({
        'https://auth.x.ai::client': session(
          expiresAt: now.add(const Duration(hours: 1)).toIso8601String(),
        ),
      }),
    );
    final ready = readGrokAuthAt(grokHome: dir.path, now: now);
    expect(ready.status, GrokAuthStatus.ready);
    expect(ready.session!.email, 'person@example.test');
    final missing = readGrokAuthAt(grokHome: '${dir.path}-absent', now: now);
    expect(missing.status, GrokAuthStatus.missing);
  });

  test('카드 줄 나누기는 최소 폭의 합으로 결정한다', () {
    expect(packUsageCardLines([480, 280, 280], 1040), [
      [0, 1, 2],
    ]);
    expect(packUsageCardLines([480, 280, 280], 1039), [
      [0, 1],
      [2],
    ]);
    expect(packUsageCardLines([280, 280], 600), [
      [0, 1],
    ]);
  });

  test('남는 폭은 최소 폭 위에서 비율로 나눈다', () {
    final widths = usageLineWidths(
      flexes: const [3, 2, 2],
      minWidths: const [480, 280, 280],
      width: 1400,
    );
    expect(widths[1], closeTo(widths[2], 0.01));
    expect(widths[0], greaterThan(widths[1]));
    expect(widths[0] / widths[1], lessThan(2));
    expect(
      widths.fold<double>(0, (sum, width) => sum + width),
      closeTo(1400, 0.01),
    );
  });

  const botCiphertext = 'djEw8xRyJ94lKggp5+wOwOtu1zN9V+WahGmt7nOmSlG+sVE=';

  test('v10 암호문은 알려진 암호로만 풀리고 다른 접두는 실패한다', () {
    expect(
      decryptGrokBotCiphertext(botCiphertext, 'test-password'),
      'bot-access-token',
    );
    expect(decryptGrokBotCiphertext(botCiphertext, 'other-password'), isNull);
    expect(
      decryptGrokBotCiphertext(
        base64Encode(utf8.encode('hello!!!!')),
        'test-password',
      ),
      isNull,
    );
    expect(
      decryptGrokBotCiphertext('not-base64', 'test-password').toString(),
      isNot(contains('test-password')),
    );
  });

  test('활성 Grok Bot 계정의 접근 토큰 암호문만 고른다', () {
    final preview = grokBotPreviewFromSecrets({
      'cursor-accounts': jsonEncode({
        'active': 'account-a',
        'accounts': {
          'account-a': {
            'cursor-access-token': botCiphertext,
            'cursor-refresh-token': 'refresh-secret',
          },
          'account-b': {'cursor-access-token': 'other-cipher'},
        },
      }),
    });
    expect(preview.status, GrokBotAuthStatus.ready);
    expect(preview.ciphertext, botCiphertext);
    expect(preview.toString(), isNot(contains(botCiphertext)));
    expect(preview.toString(), isNot(contains('refresh-secret')));
    expect(
      grokBotPreviewFromSecrets({
        'cursor-accounts': '{"active":null,"accounts":{}}',
      }).status,
      GrokBotAuthStatus.missing,
    );
    expect(
      () => grokBotPreviewFromSecrets({'cursor-accounts': '{'}),
      throwsFormatException,
    );
  });

  test('키체인 거절과 항목 없음을 구분하고 암호는 문자열에 남기지 않는다', () {
    final ready = interpretGrokBotKeychain(
      exitCode: 0,
      stdout: 'keychain-secret\n',
      stderr: '',
    );
    expect(ready.status, GrokBotKeychainStatus.ready);
    expect(ready.password, 'keychain-secret');
    expect(ready.toString(), isNot(contains('keychain-secret')));
    expect(
      interpretGrokBotKeychain(
        exitCode: 128,
        stdout: '',
        stderr: 'User canceled the operation.',
      ).status,
      GrokBotKeychainStatus.denied,
    );
    expect(
      interpretGrokBotKeychain(
        exitCode: 44,
        stdout: '',
        stderr: 'The specified item could not be found in the keychain.',
      ).status,
      GrokBotKeychainStatus.unavailable,
    );
  });

  test('Grok Bot 사용량 JSON은 퍼센트와 리셋만 남긴다', () {
    final reading = grokBotReadingFromJson({
      'usagePercent': 59.5,
      'nextResetTimestampUtc': '2026-09-29T03:05:07.537Z',
      'grokPlanLabel': 'SuperGrok',
      'dashboardUrl': 'https://cursor.com/dashboard/user-secret',
      'cursorPlanName': 'Free',
    });
    expect(reading!.usedPercent, closeTo(59.5, 0.001));
    expect(reading.window, GrokUsageWindow.weekly);
    expect(reading.plan, 'SuperGrok');
    expect(reading.resetsAt, DateTime.parse('2026-09-29T03:05:07.537Z'));
    expect(reading.toString(), isNot(contains('user-secret')));
    expect(
      grokBotReadingFromJson({'dashboardUrl': 'https://cursor.com'}),
      isNull,
    );
  });

  test('Grok Bot 조회는 Connect POST이고 401은 인증 실패다', () async {
    final requests = <ApiRequest>[];
    final api = GrokUsageApi((request) async {
      requests.add(request);
      return const ApiResponse(statusCode: 401, body: '{}');
    });
    await expectLater(
      api.fetchBot(accessToken: 'bot-token'),
      throwsA(
        isA<GrokUsageFailure>().having(
          (error) => error.labelKey,
          'labelKey',
          'grok.bot_unauthorized',
        ),
      ),
    );
    expect(requests.single.method, 'POST');
    expect(requests.single.url, Uri.parse(kGrokBotUsageEndpoint));
    expect(requests.single.headers['Authorization'], 'Bearer bot-token');
    expect(requests.single.headers['Connect-Protocol-Version'], '1');
    expect(requests.single.body, '{}');
    expect(requests.single.followRedirects, isFalse);
  });

  test('저장된 Grok Bot 파일을 풀 때 주입한 키체인 암호만 쓴다', () async {
    final dir = Directory.systemTemp.createTempSync('grok-bot-auth-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/sand-secrets.json').writeAsStringSync(
      jsonEncode({
        'cursor-accounts': jsonEncode({
          'active': 'account-a',
          'accounts': {
            'account-a': {'cursor-access-token': botCiphertext},
          },
        }),
      }),
    );
    final preview = readGrokBotPreviewAt(supportDir: dir.path);
    expect(preview.status, GrokBotAuthStatus.ready);
    final unlocked = await unlockGrokBotAt(
      preview,
      readKeychain: () async => const GrokBotKeychainRead(
        GrokBotKeychainStatus.ready,
        password: 'test-password',
      ),
    );
    expect(unlocked.status, GrokBotAuthStatus.ready);
    expect(unlocked.accessToken, 'bot-access-token');
    expect(unlocked.toString(), isNot(contains('bot-access-token')));
    expect(unlocked.toString(), isNot(contains('test-password')));
    expect(
      readGrokBotPreviewAt(supportDir: '${dir.path}-absent').status,
      GrokBotAuthStatus.missing,
    );
  });

  test('CLI 로그인이 없어도 Grok Bot 주간 사용률을 읽는다', () async {
    final requests = <ApiRequest>[];
    final container = ProviderContainer(
      overrides: [
        grokUsageSupportedProvider.overrideWithValue(true),
        grokInitialEnabledProvider.overrideWithValue(true),
        grokInitialBotEnabledProvider.overrideWithValue(true),
        grokAuthReadProvider.overrideWithValue(
          () => const GrokAuthReadResult.missing(),
        ),
        grokBotPreviewProvider.overrideWithValue(
          () => const GrokBotPreview(
            GrokBotAuthStatus.ready,
            ciphertext: 'ciphertext-not-a-token',
          ),
        ),
        grokBotUnlockProvider.overrideWithValue(
          (preview) async => GrokBotAuthReadResult(
            GrokBotAuthStatus.ready,
            accessToken: 'bot-token',
            ciphertextHash: preview.ciphertextHash,
          ),
        ),
        httpSendProvider.overrideWithValue((request) async {
          requests.add(request);
          return const ApiResponse(
            statusCode: 200,
            body:
                '{"usagePercent":59.5,"nextResetTimestampUtc":"2026-09-29T03:05:07.537Z","grokPlanLabel":"SuperGrok","dashboardUrl":"https://cursor.com/dashboard/user-secret"}',
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(grokUsageControllerProvider, (_, _) {});
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (container.read(grokUsageControllerProvider).botReading == null) {
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final state = container.read(grokUsageControllerProvider);
    expect(state.errorKey, 'grok.signed_out');
    expect(state.botReading!.usedPercent, closeTo(59.5, 0.001));
    expect(state.botReading!.plan, 'SuperGrok');
    expect(state.toString(), isNot(contains('bot-token')));
    expect(state.toString(), isNot(contains('user-secret')));
    expect(requests.single.url, Uri.parse(kGrokBotUsageEndpoint));
    expect(requests.single.headers['Authorization'], 'Bearer bot-token');
  });
}

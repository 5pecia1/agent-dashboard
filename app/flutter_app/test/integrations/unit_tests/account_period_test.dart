import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/account_period.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';

void main() {
  test('기간 종료 시각은 시간대와 실제 달력 날짜가 있는 응답만 받는다', () {
    for (final value in [
      '2026-02-30T00:00:00Z',
      '2026-13-01T00:00:00Z',
      '2026-01-00T00:00:00Z',
      '2026-01-01T24:00:00Z',
      '2026-01-01T00:60:00Z',
      '2026-01-01T00:00:60Z',
      '2026-01-01T00:00:00+24:00',
      '2026-01-01T00:00:00+09:60',
      '2026-01-01T00:00:00',
      '2026-01-01',
    ]) {
      expect(parseAccountPeriodEnd(value), isNull, reason: value);
    }
    expect(
      parseAccountPeriodEnd(' 2024-02-29T12:34:56.123456+09:00 '),
      DateTime.utc(2024, 2, 29, 3, 34, 56, 123, 456),
    );
  });
  test('Devin의 과거 플랜 종료일을 주간 초기화 날짜와 독립적으로 보존한다', () {
    final quota = DevinQuota.fromUserStatus({
      'userStatus': {
        'planStatus': {
          'planEnd': '2020-01-02T12:34:00+09:00',
          'weeklyQuotaRemainingPercent': 50,
          'weeklyQuotaResetAtUnix': '1578009600',
        },
      },
    });
    expect(quota.planEndsAt, DateTime.utc(2020, 1, 2, 3, 34));
    expect(quota.weeklyResetAt, isNot(quota.planEndsAt));
    expect(quota.weeklyUsedPercent, 50);
  });

  test('Devin 종료일이 누락되거나 잘못돼도 사용량은 그대로 읽는다', () {
    for (final value in [null, '', 'not-a-date', 123, <String, Object?>{}]) {
      final quota = DevinQuota.fromUserStatus({
        'userStatus': {
          'planStatus': {'planEnd': ?value, 'weeklyQuotaRemainingPercent': 50},
        },
      });
      expect(quota.planEndsAt, isNull);
      expect(quota.weeklyUsedPercent, 50);
    }
  });

  test('Grok의 주간 초기화와 청구 기간 종료일을 각각 보존한다', () {
    final reading = grokUsageReadingFromJson({
      'config': {
        'creditUsagePercent': 25,
        'currentPeriod': {'end': '2020-01-03T00:00:00Z'},
        'billingPeriodEnd': '2020-01-20T00:00:00Z',
      },
    });
    expect(reading?.resetsAt, DateTime.utc(2020, 1, 3));
    expect(reading?.billingPeriodEndsAt, DateTime.utc(2020, 1, 20));
    expect(reading?.usedPercent, 25);
  });

  test('Grok의 청구 기간 종료일만 있으면 사용량 초기화 날짜로 대체하지 않는다', () {
    final reading = grokUsageReadingFromJson({
      'monthlyLimit': {'val': 100},
      'used': {'val': 20},
      'billingPeriodEnd': '2020-01-20T00:00:00Z',
    });
    expect(reading?.window, GrokUsageWindow.monthly);
    expect(reading?.resetsAt, isNull);
    expect(reading?.billingPeriodEndsAt, DateTime.utc(2020, 1, 20));
  });

  test('Grok 청구 날짜가 없거나 잘못돼도 주간 초기화와 사용률은 유지한다', () {
    for (final value in [null, '', 'not-a-date', 123, <String, Object?>{}]) {
      final reading = grokUsageReadingFromJson({
        'config': {
          'creditUsagePercent': 25,
          'currentPeriod': {'end': '2020-01-03T00:00:00Z'},
          'billingPeriodEnd': ?value,
        },
      });
      expect(reading?.billingPeriodEndsAt, isNull);
      expect(reading?.resetsAt, DateTime.utc(2020, 1, 3));
      expect(reading?.usedPercent, 25);
    }
  });
}

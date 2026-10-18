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

  test('Grok credits 응답의 billingPeriodEnd는 주간 사용량 구간이다', () {
    // Period shape observed from /billing?format=credits on 2026-10-11.
    final reading = grokUsageReadingFromJson({
      'config': {
        'creditUsagePercent': 25,
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'start': '2026-10-05T09:19:26.641555+00:00',
          'end': '2026-10-12T09:19:26.641555+00:00',
        },
        'billingPeriodStart': '2026-10-05T09:19:26.641555+00:00',
        'billingPeriodEnd': '2026-10-12T09:19:26.641555+00:00',
      },
    });
    expect(reading?.window, GrokUsageWindow.weekly);
    expect(reading?.resetsAt, DateTime.utc(2026, 10, 12, 9, 19, 26, 641, 555));
    expect(reading?.usedPercent, 25);
  });

  test('Grok 월간 금액 응답의 billingPeriodEnd는 달력 월 사용량 초기화다', () {
    // Period shape observed from /billing on 2026-10-11, not the 24th renewal.
    final reading = grokUsageReadingFromJson({
      'config': {
        'monthlyLimit': {'val': 100},
        'used': {'val': 20},
        'billingPeriodStart': '2026-10-01T00:00:00+00:00',
        'billingPeriodEnd': '2026-11-01T00:00:00+00:00',
      },
    });
    expect(reading?.window, GrokUsageWindow.monthly);
    expect(reading?.resetsAt, DateTime.utc(2026, 11, 1));
    expect(reading?.usedPercent, 20);
  });

  test('Grok은 currentPeriod를 우선하고 잘못된 기간 날짜를 달력 보정하지 않는다', () {
    for (final value in [null, '', 'not-a-date', 123, <String, Object?>{}]) {
      final reading = grokUsageReadingFromJson({
        'config': {
          'creditUsagePercent': 25,
          'currentPeriod': {'end': '2020-01-03T00:00:00Z'},
          'billingPeriodEnd': ?value,
        },
      });
      expect(reading?.resetsAt, DateTime.utc(2020, 1, 3));
      expect(reading?.usedPercent, 25);
    }
    for (final value in ['2026-02-30T00:00:00Z', '2026-10-12T00:00:00']) {
      final reading = grokUsageReadingFromJson({
        'creditUsagePercent': 25,
        'currentPeriod': {'end': value},
        'billingPeriodEnd': '2026-10-12T00:00:00Z',
      });
      expect(reading?.resetsAt, isNull);
      expect(reading?.usedPercent, 25);
    }
  });
}

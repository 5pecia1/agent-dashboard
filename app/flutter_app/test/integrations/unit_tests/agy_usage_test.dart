import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';

import '../fixtures/agy_usage_fixture.dart';

Map<String, dynamic> _data(Map<String, dynamic> fixture) =>
    (fixture['command'] as Map<String, dynamic>)['data']
        as Map<String, dynamic>;

Matcher _failure(String key) => throwsA(
  isA<AgyUsageFailure>().having((failure) => failure.labelKey, 'label', key),
);

AgyUsageApi _api(
  String payload, {
  String version = '1.3.3',
  int exitCode = 0,
}) => AgyUsageApi(
  (arguments) async => arguments.first == '--version'
      ? AgyCommandResult(exitCode: 0, stdout: version)
      : AgyCommandResult(exitCode: exitCode, stdout: payload),
);

void main() {
  test('실측 구조의 두 공유 그룹에서 사용률을 읽고 토큰 집계와 표시 문구를 무시한다', () async {
    final reading = await _api(jsonEncode(agyUsageFixture())).fetch();
    expect(reading.groups, hasLength(2));
    final gemini = reading.groups.first;
    expect(gemini.labelKey, 'agy.gemini');
    expect(gemini.buckets.map((b) => b.id), ['gemini-5h', 'gemini-weekly']);
    expect(gemini.buckets.first.usedPercent, closeTo(42, 0.000001));
    expect(gemini.buckets.last.usedPercent, closeTo(19, 0.000001));
    expect(gemini.buckets.last.resetsAt, DateTime.utc(2030, 10, 17, 9, 58, 41));
    final thirdParty = reading.groups.last;
    expect(thirdParty.labelKey, 'agy.third_party');
    expect(thirdParty.buckets.first.usedPercent, closeTo(2, 0.000001));
    expect(thirdParty.buckets.last.usedPercent, closeTo(1, 0.000001));
  });

  test('잔량 0과 1은 소진과 미사용이고 누락된 값은 정보 없음으로 남는다', () {
    final data = _data(agyUsageFixture());
    final buckets = agyFixtureBuckets(data);
    buckets[0]['remaining_fraction'] = 0;
    buckets[1]['remaining_fraction'] = 1;
    var reading = agyUsageReadingFromJson(data);
    expect(reading.groups.first.buckets.first.usedPercent, 0);
    expect(reading.groups.first.buckets.last.usedPercent, 100);
    buckets[0].remove('remaining_fraction');
    buckets[0]['reset_time'] = '2030-02-30T09:00:00Z';
    reading = agyUsageReadingFromJson(data);
    expect(reading.groups.first.buckets.last.usedPercent, isNull);
    expect(reading.groups.first.buckets.last.resetsAt, isNull);
    buckets.removeAt(0);
    expect(agyUsageReadingFromJson(data).groups.first.buckets, hasLength(1));
  });

  test('새 그룹과 기간을 원문으로 보존하며 중복 ID와 잘못된 비율은 거부한다', () {
    final data = {
      'groups': [
        {
          'name': 'Future models',
          'buckets': [
            {
              'id': 'future-daily',
              'name': 'Daily limit',
              'window': 'daily',
              'remaining_fraction': 0.25,
            },
          ],
        },
      ],
    };
    final group = agyUsageReadingFromJson(data).groups.single;
    expect(group.name, 'Future models');
    expect(group.labelKey, isNull);
    expect(group.buckets.single.name, 'Daily limit');
    expect(group.buckets.single.usedPercent, 75);
    expect(group.buckets.single.labelKey, isNull);
    final original = _data(agyUsageFixture());
    final buckets = agyFixtureBuckets(original);
    final bucket = buckets.first;
    for (final invalid in [-0.1, 1.1, '0.5', double.nan, double.infinity]) {
      bucket['remaining_fraction'] = invalid;
      expect(() => agyUsageReadingFromJson(original), throwsFormatException);
    }
    bucket['remaining_fraction'] = 0.5;
    buckets.add(Map<String, dynamic>.of(bucket));
    expect(() => agyUsageReadingFromJson(original), throwsFormatException);
  });

  test('구버전과 식별되지 않는 버전에서는 usage 명령을 실행하지 않는다', () async {
    for (final version in [
      '1.0.16',
      '1.1.11',
      '1.2.8',
      '1.2.9-alpha',
      '2.0.0-beta',
      'not a version',
    ]) {
      final calls = <List<String>>[];
      final api = AgyUsageApi((arguments) async {
        calls.add(arguments);
        return AgyCommandResult(exitCode: 0, stdout: version);
      });
      await expectLater(api.fetch(), _failure('agy.unsupported_version'));
      expect(calls, [
        ['--version'],
      ]);
    }
    for (final version in ['1.2.9', '1.2.9+build1', '1.3.3\n', 'v2.0.0']) {
      expect(
        await _api(jsonEncode(agyUsageFixture()), version: version).fetch(),
        isA<AgyUsageReading>(),
      );
    }
  });

  test('성공 종료여도 일반 에이전트 응답이나 깨진 JSON은 쿼터로 취급하지 않는다', () async {
    final turn = agyUsageFixture()..['num_turns'] = 1;
    final wrongCommand = agyUsageFixture();
    (wrongCommand['command'] as Map<String, dynamic>)['name'] = 'model';
    for (final payload in [
      '',
      'not JSON',
      '{}',
      jsonEncode(turn),
      jsonEncode(wrongCommand),
    ]) {
      await expectLater(
        _api(payload).fetch(),
        _failure('agy.invalid_response'),
      );
    }
    final empty = agyUsageFixture();
    _data(empty)['groups'] = <Map<String, dynamic>>[];
    await expectLater(
      _api(jsonEncode(empty)).fetch(),
      _failure('agy.no_usage'),
    );
    await expectLater(
      _api(jsonEncode(agyUsageFixture()), exitCode: 1).fetch(),
      _failure('agy.query_failed'),
    );
  });

  test('인증 실패는 원문 자격 정보 없이 안내하고 시간 초과는 그대로 전달한다', () async {
    final api = _api(
      jsonEncode({
        'status': 'ERROR',
        'error': 'Authentication required: private@example.test secret',
      }),
    );
    await expectLater(api.fetch(), _failure('agy.sign_in_required'));
    expect(
      const AgyUsageFailure('agy.sign_in_required').toString(),
      isNot(contains('private@example.test')),
    );
    final timeout = AgyUsageApi(
      (_) async => throw const AgyUsageFailure('agy.timeout'),
    );
    await expectLater(timeout.fetch(), _failure('agy.timeout'));
  });
}

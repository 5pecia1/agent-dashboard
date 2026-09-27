/// `util/mute_time.dart`의 [formatMuteUntilClock] — 값만으로 닫는 순수
/// 함수 하나. 트레이 메뉴의 "해제" 라벨과 설정 화면의 뮤트 상태 문구 둘
/// 다 이 함수 하나로 시각을 그린다.
///
/// 검증 지적(high): 이 함수를 호출·단언하는 테스트가 이전에 하나도
/// 없었다. 로컬 타임존에 의존하는 함수라, 기대값도 같은 방식
/// (`DateTime(...)` 생성자, 로컬 벽시계)으로 계산해 실행 환경의 타임존과
/// 무관하게 재현한다.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/util/mute_time.dart';

void main() {
  group('formatMuteUntilClock', () {
    test('HH:mm 24시간제, 0으로 왼쪽 채움', () {
      final epochMs = DateTime(2026, 9, 11, 3, 5).millisecondsSinceEpoch;
      expect(formatMuteUntilClock(epochMs), '03:05');
    });

    test('자정 경계(0시)도 두 자리로 채운다', () {
      final epochMs = DateTime(2026, 9, 11, 0, 0).millisecondsSinceEpoch;
      expect(formatMuteUntilClock(epochMs), '00:00');
    });

    test('오후 시각은 24시간제 두 자리 그대로(오전/오후 표기 없음)', () {
      final epochMs = DateTime(2026, 9, 11, 23, 59).millisecondsSinceEpoch;
      expect(formatMuteUntilClock(epochMs), '23:59');
    });
  });
}

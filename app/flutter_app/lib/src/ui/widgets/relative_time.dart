/// 상대 시간 문구(예: "3분 전") — 세션 카드·타임라인이 공유하는 판정.
///
/// [relativeTimeSpec]은 epoch ms 두 개만으로 판정하는 순수 함수라 시계도
/// FFI도 만지지 않는다 — 단위 테스트가 값만으로 경계(0분/1시간/1일)를
/// 재현한다. [relativeTimeText]는 그 판정을 [t]로 옮기는 얇은 래퍼다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/i18n/t.dart';

const int _kMsPerMinute = 60000;
const int _kMsPerHour = 3600000;
const int _kMsPerDay = 86400000;

/// `thenMs`부터 `nowMs`까지 지난 시간을 i18n 키+인자로 판정한다. 시계
/// 역전(음수 델타)은 0으로 접어 "방금 전"으로 본다.
({String key, Map<String, String>? args}) relativeTimeSpec({
  required int nowMs,
  required int thenMs,
}) {
  final delta = nowMs - thenMs;
  final clamped = delta < 0 ? 0 : delta;
  final minutes = clamped ~/ _kMsPerMinute;
  if (minutes < 1) return (key: 'time.just_now', args: null);
  final hours = clamped ~/ _kMsPerHour;
  if (hours < 1) {
    return (key: 'time.minutes_ago', args: <String, String>{'minutes': '$minutes'});
  }
  final days = clamped ~/ _kMsPerDay;
  if (days < 1) {
    return (key: 'time.hours_ago', args: <String, String>{'hours': '$hours'});
  }
  return (key: 'time.days_ago', args: <String, String>{'days': '$days'});
}

/// [relativeTimeSpec]을 실제 화면 문구로 옮긴다(build 단계 전용 — [t]와
/// 같은 재렌더링 근거).
String relativeTimeText(WidgetRef ref, {required int nowMs, required int thenMs}) {
  final spec = relativeTimeSpec(nowMs: nowMs, thenMs: thenMs);
  return t(ref, spec.key, spec.args);
}

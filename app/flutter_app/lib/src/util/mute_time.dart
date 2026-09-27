/// TASK MUTE-impl: 음소거 종료 시각을 사람이 읽는 시각(`HH:mm`, 로컬
/// 벽시계)으로 바꾸는 순수 함수 하나.
///
/// `ui/setup_page.dart`(뮤트 상태 표시)와 `platform/tray_native.dart`(트레이
/// 메뉴의 "해제" 라벨) 둘 다 쓰는데, 그 두 파일은 서로 다른 계층(ui/
/// platform)이라 어느 한쪽에 두면 다른 쪽이 그 계층을 import하게 된다 —
/// 그래서 어느 계층에도 속하지 않는 이 파일에 둔다(`ui/widgets/
/// relative_time.dart`의 `relativeTimeSpec`과 같은 이유로 순수 함수만
/// 담는다 — 시계도 i18n도 만지지 않아 단위 테스트가 값만으로 자정 등
/// 경계를 재현한다).
library;

/// [epochMs]를 로컬 시간대 기준 `HH:mm`(24시간, 0으로 왼쪽 채움)으로
/// 포맷한다. 숫자 두 자리뿐이라 로케일에 따라 달라질 표기가 없다 — EN/KO
/// 어느 쪽 문구에 `{time}` 인자로 꽂아도 그대로 통한다.
String formatMuteUntilClock(int epochMs) {
  final local = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

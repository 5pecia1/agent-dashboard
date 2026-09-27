/// TASK TRAY-impl: 트레이 우클릭 메뉴에서 고를 수 있는 명령.
///
/// 플랫폼 의존이 전혀 없는 순수 Dart라 `tray_native.dart`/`tray_web.dart`
/// 양쪽에서(그리고 이 둘을 갈라 태우는 조건부 export와 무관하게) 그대로
/// 쓸 수 있다 — `dart:io`나 `tray_manager`를 끌고 오지 않으므로 웹 빌드
/// 그래프에 들어가도 안전하다(그래서 `tray.dart`가 조건부 export 목록이
/// 아니라 이 파일을 직접 export한다).
library;

/// `TrayCommand`와 `MenuItem.key`를 잇는 문자열. Dart의 `enum.name`을 그대로
/// 쓰지 않는 이유: 이 문자열은 tray_manager를 거쳐 네이티브(플랫폼 채널
/// 이벤트)를 오간다 — enum 이름을 리팩터링해도(예: `mute30` ->
/// `muteThirtyMinutes`) 이미 화면에 떠 있는 메뉴/저장된 값과 어긋나지 않게
/// 값을 여기 고정한다.
enum TrayCommand {
  /// 왼쪽 클릭과 같은 동작 — 창을 앞으로 가져온다.
  open('tray_open'),

  /// `POST /dashboard/mute`로 30분 음소거.
  mute30('tray_mute30'),

  /// TASK MUTE-impl: `POST /dashboard/mute`에 `minutes: 0`을 보내 즉시
  /// 해제. 음소거 중일 때만 메뉴에 나타난다(`buildTrayMenuItems`) —
  /// `mute30`과 같은 자리를 놓고 서로 배타적으로 갈아 낀다.
  unmute('tray_unmute'),

  /// 상주 여부를 무시하고 진짜로 프로세스를 종료한다.
  quit('tray_quit');

  const TrayCommand(this.menuItemKey);

  final String menuItemKey;

  /// `MenuItem.key`(nullable, 알 수 없는 값 가능)로부터 [TrayCommand]를
  /// 되찾는다. 매칭되는 값이 없으면(예: 구분선 `MenuItem.separator()`의
  /// key는 항상 null) null.
  static TrayCommand? fromKey(String? key) {
    for (final command in TrayCommand.values) {
      if (command.menuItemKey == key) return command;
    }
    return null;
  }
}

/// 컨텍스트 메뉴 안 각 세션 항목의 `MenuItem.key` 접두어 — 뒤에 세션 키가
/// 붙는다(예: `tray_seen_claude_code:abc`). 세션 키 자체는 `:`를 포함할 수
/// 있으므로 접두어 매칭만으로 안전하게 되짚는다(`traySeenSessionKey` 참고).
///
/// enum에 넣지 않는 이유는 `TrayCommand` 문서와 같다 — enum은 "고를 수 있는
/// 고정 명령" 목록이고, 세션 수만큼 생기는 동적 키는 그 공간이 아니다.
const String traySeenMenuKeyPrefix = 'tray_seen_';

/// 세션 키 -> 세션 항목의 `MenuItem.key`.
String traySeenMenuKey(String sessionKey) =>
    '$traySeenMenuKeyPrefix$sessionKey';

/// `MenuItem.key`가 미확인 세션 항목이면 그 세션 키를, 아니면 null을
/// 돌려준다. 접두어만 있고 세션 키가 빈 키는 없는 것으로 친다 — 빈 키로
/// `markSeen`을 불러도 아무것도 못 찾는다.
String? traySeenSessionKey(String? menuItemKey) {
  if (menuItemKey == null || !menuItemKey.startsWith(traySeenMenuKeyPrefix)) {
    return null;
  }
  final sessionKey = menuItemKey.substring(traySeenMenuKeyPrefix.length);
  return sessionKey.isEmpty ? null : sessionKey;
}

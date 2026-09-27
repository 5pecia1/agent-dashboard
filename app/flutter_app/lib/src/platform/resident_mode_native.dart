/// 상주 동작(창을 닫아도 백그라운드 유지) 토글의 데스크톱 구현
/// (TASK D-app, A안 설계 ④).
///
/// **왜 MethodChannel인가.** `applicationShouldTerminateAfterLastWindowClosed`
/// 는 AppKit이 마지막 창이 닫히는 순간 `NSApplicationDelegate`에게 묻는
/// 값이라 Dart에서 직접 답할 수 없다 — Swift 쪽이 그 답을 알고 있어야 한다.
/// 지금까지는 `macos/Runner/AppDelegate.swift`가 `false`를 하드코딩했다
/// (창닫기 = 숨김이 언제나 강제였다). 이 채널이 그 하드코딩을 사용자
/// 설정으로 바꾼다: Dart가 값을 밀어 넣고, Swift는 그 값을 기억했다가
/// AppKit이 물을 때 그대로 답한다.
///
/// **던지지 않는다.** 채널 반대편이 없어도(macOS가 아닌 데스크톱, 아직
/// 창이 안 뜬 부팅 초기, 플러그인 미등록) 설정 화면이 예외로 멈추면 안
/// 된다 — 값은 이미 `config.json`에 저장돼 있고 다음 실행에서 다시
/// 적용된다. 실패는 조용한 no-op이다(`local_notifications_native.dart`의
/// 표시 실패와 같은 관용).
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// `macos/Runner/MainFlutterWindow.swift`의 같은 이름과 짝이다. 한쪽만
/// 바꾸면 조용히 no-op이 된다(채널이 없으면 [MissingPluginException]).
const String kResidentChannelName = 'app/resident';

/// 상주 설정 메서드. 인자는 `{'enabled': bool}`.
const String kResidentSetMethod = 'setResident';

const String kResidentShowWindowMethod = 'showWindow';

const String kResidentHideWindowMethod = 'hideWindow';

/// [kResidentSetMethod]의 인자 키.
const String kResidentEnabledArg = 'enabled';

/// 상주 토글을 지원하는 호스트인가. 지금은 macOS만이다 — linux/windows에는
/// 대응하는 AppDelegate 훅이 없다(그쪽 셸은 마지막 창이 닫히면 앱이
/// 끝나는 게 플랫폼 기본값이다).
///
/// `feature_status.dart`의 `hasDesktopHost`와 같은 판정 기준
/// (`defaultTargetPlatform`)을 쓴다 — 위젯 테스트에서는 android로 고정돼
/// false이므로 (1) 골든(`setup_page_*.png`)에 이 토글이 나타나지 않고
/// (기존 `setup.resident_note` 문구가 `hasDesktopHost` 뒤에 있어 골든에
/// 없던 것과 정확히 같다) (2) 테스트가 실제 MethodChannel을 건드리지
/// 않는다. 토글 자체의 검증은 `residentToggleSupportedProvider`를
/// override해서 한다.
bool get hasResidentToggleHost =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

const MethodChannel _channel = MethodChannel(kResidentChannelName);

/// 네이티브 쪽에 상주 여부를 밀어 넣는다. 부팅 시퀀스(`main.dart`)가 저장된
/// 값으로 한 번, 이후 설정 화면이 토글할 때마다 한 번씩 부른다.
Future<void> applyResidentMode(bool enabled) async {
  if (!hasResidentToggleHost) return;
  try {
    await _channel.invokeMethod<void>(kResidentSetMethod, <String, Object?>{
      kResidentEnabledArg: enabled,
    });
  } on MissingPluginException {
    // 채널 반대편이 아직/영영 없다 — 조용히 접는다.
  } on PlatformException {
    // 네이티브가 거절했다. 값은 이미 저장돼 있으므로 다음 실행에서 다시 민다.
  }
}

Future<void> showResidentWindow() async {
  if (!hasResidentToggleHost) return;
  try {
    await _channel.invokeMethod<void>(kResidentShowWindowMethod);
  } on MissingPluginException {
    // 네이티브 채널이 없으면 창을 복원할 수 없다.
  } on PlatformException {
    // 네이티브가 창 복원을 거절해도 호출자 흐름은 계속한다.
  }
}

Future<void> hideResidentWindow() async {
  if (!hasResidentToggleHost) return;
  try {
    await _channel.invokeMethod<void>(kResidentHideWindowMethod);
  } on MissingPluginException {
    // 네이티브 채널이 없으면 숨길 창을 다루는 쪽도 없다 — 조용히 접는다.
  } on PlatformException {
    // 네이티브가 창 숨김을 거절해도 호출자 흐름은 계속한다.
  }
}

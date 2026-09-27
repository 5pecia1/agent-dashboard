/// 테마 모드(system/light/dark) 선택 — `MaterialApp.themeMode`에 직접
/// 이어지는 값.
///
/// **`resident_provider.dart`가 아니라 `background_activity_provider.dart`의
/// 관용을 따른 이유.** `resident_provider.dart`는 값 자체를 들고 있는
/// [Notifier]가 아니다(호스트 capability 확인 + 네이티브 적용 함수뿐이고,
/// 실제 값·반응성은 `setup_page.dart`의 로컬 위젯 상태가 갖는다) — 상주의
/// 효과가 MethodChannel 건너편(AppDelegate)에서만 보이기 때문이다. 테마
/// 모드는 반대로 **Flutter 위젯 트리 자신**(`app.dart`의 루트
/// `MaterialApp.themeMode`)이 반응해야 하는 값이라, 화면 트리 전체에 걸친
/// 실시간 상태가 필요하다 — 그래서 [BackgroundActivityController]와 같은
/// 자리(부팅 시점에 저장된 값으로 한 번 seed, 이후 설정 화면이 바뀔 때마다
/// setter 호출)의 [Notifier]로 둔다.
///
/// **`build()`가 [dashboardConfigValuesProvider]를 watch하지 않는 이유는
/// 같다**(`background_activity_provider.dart` 문서 참고): 그 provider는
/// override 없이는 던지는 부팅 스냅샷이고, `sessions_page.dart`/
/// `setup_page.dart` 위젯 테스트 다수가 그 provider를 override하지 않은 채
/// 돈다 — 이 컨트롤러가 자기 `build()` 안에서 그 provider를 읽으면 그
/// 테스트들이 전부 깨진다. 대신 `app.dart`의 부팅 시퀀스가 저장된 값으로
/// 명시적으로 seed하고, `setup_page.dart`의 선택 UI가 바뀔 때마다 같은
/// setter를 다시 부른다.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 저장된 원값(`DashboardConfigValues.themeMode`, `'system'`/`'light'`/
/// `'dark'` 또는 null)을 [ThemeMode]로 접는 순수 함수. 알 수 없는 값(손상된
/// 저장소 등)과 null은 전부 [ThemeMode.system]으로 접는다 — 이 앱 전체의
/// 기본 동작이자 안전한 폴백이다.
ThemeMode parseThemeMode(String? raw) => switch (raw) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

/// [parseThemeMode]의 역함수 — 저장소에 쓸 원값. `DashboardConfigValues`
/// 생성자에 바로 넘길 수 있게 [ThemeMode.system]도 (null이 아니라)
/// `'system'` 문자열로 명시적으로 남긴다 — `copyWith`가 `??` 기반이라
/// null을 넘기면 "안 바꾼다"는 뜻이 되어 시스템으로 되돌리는 선택 자체가
/// 사라져 버리기 때문이다(`config_provider.dart`의 `copyWith` 문서 참고).
String themeModeConfigValue(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};

/// 테마 모드 값을 들고 있는 [Notifier]. `app.dart`의 [SolApp]이 이 값을
/// watch해 `MaterialApp.themeMode`에 그대로 꽂는다.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  /// 부팅 경로(`app.dart`)가 저장된 값으로, 설정 화면
  /// (`setup_page.dart._setThemeMode`)이 선택이 바뀔 때마다 부른다.
  void setThemeMode(ThemeMode mode) {
    state = mode;
  }
}

final NotifierProvider<ThemeModeController, ThemeMode> themeModeControllerProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

/// 상주 동작(창을 닫아도 백그라운드 유지) 시임 (TASK D-app, A안 설계 ④).
///
/// `capability_provider.dart`와 같은 3계층: 함수 타입 -> `Provider<Fn>` ->
/// 얇은 함수(`platform/resident_mode_*.dart`). 화면(`ui/setup_page.dart`)과
/// 부팅(`main.dart`)은 이 두 provider만 보고, MethodChannel이 있는지도
/// 모른다.
///
/// 값 자체(켜짐/꺼짐)는 여기 없다 — `config_provider.dart`의
/// `DashboardConfigValues.resident`가 정본이고 그 파일이 영속화까지
/// 책임진다. 이 파일은 "그 값을 OS에 어떻게 전달하는가"와 "이 호스트가
/// 그런 토글을 가질 수 있는가"만 갖는다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/platform/resident_mode_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/resident_mode_web.dart'
    as bridge;

/// 이 호스트가 상주 토글을 가질 수 있는가(macOS만 true).
///
/// **상수가 아니라 provider인 이유**: 판정의 바탕인 `defaultTargetPlatform`
/// 이 위젯 테스트에서는 android로 고정된다(`flutter_test` 기본값) — 그래서
/// 화면이 그 상수로 직접 분기하면 토글이 테스트 트리에 아예 들어오지 않아
/// 검증할 수가 없다. `setup_page.dart`의 웹 푸시 절이 `isWasmRuntimeProvider`
/// 를 쓰는 것과 같은 이유이고, 같은 해법이다. 기본값이 테스트에서
/// false이므로 골든(`setup_page_*.png`)은 이 토글을 그리지 않는다 — 기존
/// 상주 안내 문구가 `hasDesktopHost` 뒤에 있어 골든에 없던 것과 정확히 같다.
final Provider<bool> residentToggleSupportedProvider = Provider<bool>(
  (ref) => bridge.hasResidentToggleHost,
);

/// 상주 여부를 네이티브(AppDelegate)에 밀어 넣는 함수 모양.
typedef ResidentModeApplyFn = Future<void> Function(bool enabled);

/// 테스트는 이 Provider를 override해 MethodChannel 없이 호출 여부만 본다.
final Provider<ResidentModeApplyFn> residentModeApplyProvider =
    Provider<ResidentModeApplyFn>((ref) => bridge.applyResidentMode);

/// `background_activity_native.dart`의 웹 거울 — 항상 no-op이다.
///
/// 브라우저 탭에는 App Nap도 `NSWorkspace.didWakeNotification`도 없다.
/// 이 파일이 따로 필요한 이유는 `resident_mode_web.dart`와 같다 — 없으면
/// 조건부 import가 네이티브 구현(`dart:ffi` 아님, 하지만 macOS 전용 가정)을
/// 웹 컴파일 타깃까지 끌고 들어간다.
library;

/// no-op. 밀어 넣을 네이티브 쪽이 없다.
Future<void> applyBackgroundActivity(bool active) async {}

/// 웹에는 wake 신호가 없다.
Stream<void> watchWakeSignals() => const Stream<void>.empty();

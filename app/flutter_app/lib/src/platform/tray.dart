/// TASK TRAY-impl: macOS 메뉴 바(트레이) 아이콘의 공개 파사드.
///
/// [TrayCommand]는 `tray_command.dart`에서 그대로 재노출한다(플랫폼
/// 의존이 없다 — 어느 쪽을 export하든 항상 같다). [installTray]와 그
/// 시임들(`trayOpenProvider` 등)은 `local_notifications_native.dart`/
/// `_web.dart`, `resident_mode_native.dart`/`_web.dart`와 동일한 조건부
/// export로 갈라 태운다 — `tray_native.dart`가 `package:tray_manager/
/// tray_manager.dart`(무조건 `dart:io` import)를 쓰기 때문에, 이 파일을
/// 그냥 `import`했다면 `flutter build web`이 깨진다.
library;

export 'tray_command.dart';
export 'tray_native.dart'
    if (dart.library.js_interop) 'tray_web.dart';

// Optional feature imports.

import 'dart:io';

import 'package:my_dashboard/src/platform/feature_status.dart' show hasDesktopHost;
import 'package:my_dashboard/src/platform/local_notifications_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/local_notifications_web.dart'
    as local_notifications;

/// First bootstrap connects only explicitly selected desktop features.
/// Global hotkeys require a caller-supplied key and callback; none is registered here.
///
/// T16: [onNotificationTap]이 있으면 알림 백엔드 프로브 전에 먼저
/// 등록한다 — `local_notifications_native.dart`의 자기 테스트 알림보다
/// 딥링크 등록이 먼저 있어야 냉시작 딥링크([registerNotificationTapHandler]
/// 문서 참고)를 놓치지 않는다.
Future<void> initializeSelectedFeatures({
  local_notifications.NotificationTapHandler? onNotificationTap,
}) async {
  // Optional feature initialization.
  await _ensureDashboardStateDir();
  if (onNotificationTap != null) {
    local_notifications.registerNotificationTapHandler(onNotificationTap);
  }
  await local_notifications.probeNotificationSupport();
}

/// `~/.local/state/my-dashboard/`가 부팅 시점에 존재하도록 한다 —
/// `config_store_io.dart`가 이 디렉터리에 `config.json`을 쓴다. 웹에는
/// 해당하지 않는다([hasDesktopHost]가 false면 아무것도 하지 않는다).
/// 실패해도(권한 없음 등) 부팅을 막지 않는다 — 디렉터리를 만드는 일은
/// 저장된 값을 바꾸지 않는다. 그 디렉터리를 읽지 못하면 설정 읽기가
/// `ConfigReadException`으로 알리고 부팅은 실패 화면을 띄운다
/// (`ui/config_read_failure.dart`). 읽지 못한 설정을 빈 값으로 접지 않는다.
Future<void> _ensureDashboardStateDir() async {
  if (!hasDesktopHost) return;
  try {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final dir = Directory('$home/.local/state/my-dashboard');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  } on FileSystemException {
    // best-effort — 읽기 실패는 설정 읽기가 따로 알린다(위 문서).
  }
}

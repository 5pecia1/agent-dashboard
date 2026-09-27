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
/// 실패해도(권한 없음 등) 부팅을 막지 않는다 — 각 시임 자신의 IO 계층이
/// 이미 "없으면 empty/absent로 접는다"는 관용을 갖고 있다.
Future<void> _ensureDashboardStateDir() async {
  if (!hasDesktopHost) return;
  try {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final dir = Directory('$home/.local/state/my-dashboard');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  } on FileSystemException {
    // best-effort — 각 시임이 스스로 없음/손상을 접는다.
  }
}

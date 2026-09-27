import 'package:flutter/foundation.dart';

/// Runtime results, updated only after plugin operations complete.
class DesktopFeatureStatus extends ChangeNotifier {
  bool _windowControl = false;
  bool _globalHotkey = false;
  bool _notifyLocal = false;
  bool _notifyPermissionDenied = false;

  bool get windowControl => _windowControl;
  bool get globalHotkey => _globalHotkey;

  /// T16: 최초 실행 1회 프로브(권한 요청 + 자기 테스트 알림)가
  /// flutter_local_notifications나 osascript 폴백 중 하나로 실제 알림을
  /// 띄울 수 있음을 확인했다. `windowControl`/`globalHotkey`와 같은 자리 —
  /// 정본은 여전히 프로브를 실행하는 쪽(`local_notifications_native.dart`의
  /// 부팅 시퀀스 호출)이고 이 필드는 그 결과의 거울이다.
  bool get notifyLocal => _notifyLocal;

  /// T16 후속: macOS 알림 권한이 **사용자/시스템이 명시적으로 거부한**
  /// 상태인가 — 플러그인이 고장 나서 물어볼 수 없는 경우와는 다르다
  /// (`local_notifications_native.dart`의 `PrimaryProbeOutcome` 문서
  /// 참고). true면 `notifyLocal`은 반드시 false다(osascript로도 접지
  /// 않는다 — 거부된 권한을 우회할 방법이 없다는 사실을 그대로 드러낸다).
  bool get notifyPermissionDenied => _notifyPermissionDenied;

  void windowChanged(bool ready) {
    if (_windowControl == ready) return;
    _windowControl = ready;
    notifyListeners();
  }

  void hotkeyChanged(bool ready) {
    if (_globalHotkey == ready) return;
    _globalHotkey = ready;
    notifyListeners();
  }

  void notifyLocalChanged(bool ready) {
    if (_notifyLocal == ready) return;
    _notifyLocal = ready;
    notifyListeners();
  }

  void notifyPermissionDeniedChanged(bool denied) {
    if (_notifyPermissionDenied == denied) return;
    _notifyPermissionDenied = denied;
    notifyListeners();
  }
}

final desktopFeatureStatus = DesktopFeatureStatus();

bool get hasDesktopHost =>
    !kIsWeb &&
    const {
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);

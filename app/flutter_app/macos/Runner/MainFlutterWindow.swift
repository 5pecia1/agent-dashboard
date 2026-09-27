import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  static let dragRestoreFrameSize = NSSize(width: 800, height: 632)
  static let nearFullscreenCoverage: CGFloat = 0.9
  private var restoringFrameForDrag = false
  private let windowNavigation = WindowNavigation()

  override func awakeFromNib() {
    AppDelegate.registerMainWindow(self)
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(restoreDefaultFrameBeforeMove(_:)),
      name: NSWindow.willMoveNotification,
      object: self
    )

    RegisterGeneratedPlugins(registry: flutterViewController)
    // TASK D-app (A안 설계 ④): 상주 토글 채널. 플러그인이 아니라 이 앱
    // 자신의 채널이라 `RegisterGeneratedPlugins` 뒤에 손으로 붙인다.
    // 엔진의 binaryMessenger에 매다는 이유는 이 창이 곧 엔진의 주인이기
    // 때문이다 — 값은 `AppDelegate`가 들고 있어야 AppKit이 물을 때
    // (`applicationShouldTerminateAfterLastWindowClosed`) 답할 수 있다.
    Self.registerResidentChannel(messenger: flutterViewController.engine.binaryMessenger)
    registerWindowNavigationChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// 거의 전체 화면 크기의 창을 제목 표시줄로 끌기 시작할 때 돌려놓을
  /// 평소 크기 프레임을 계산한다. 보통 크기 창이면 nil이다.
  static func restoredFrameForDrag(
    windowFrame: NSRect,
    visibleFrame: NSRect,
    mouseLocation: NSPoint
  ) -> NSRect? {
    guard windowFrame.width >= visibleFrame.width * nearFullscreenCoverage,
          windowFrame.height >= visibleFrame.height * nearFullscreenCoverage
    else { return nil }

    let restoredWidth = min(dragRestoreFrameSize.width, visibleFrame.width * nearFullscreenCoverage)
    let restoredHeight = min(dragRestoreFrameSize.height, visibleFrame.height * nearFullscreenCoverage)
    let horizontalAnchor = min(
      max((mouseLocation.x - windowFrame.minX) / windowFrame.width, 0),
      1
    )
    let topOffset = min(max(windowFrame.maxY - mouseLocation.y, 0), restoredHeight)
    let proposed = NSRect(
      x: mouseLocation.x - restoredWidth * horizontalAnchor,
      y: mouseLocation.y - restoredHeight + topOffset,
      width: restoredWidth,
      height: restoredHeight
    )
    let maxX = visibleFrame.maxX - restoredWidth
    let maxY = visibleFrame.maxY - restoredHeight
    return NSRect(
      x: min(max(proposed.minX, visibleFrame.minX), maxX),
      y: min(max(proposed.minY, visibleFrame.minY), maxY),
      width: restoredWidth,
      height: restoredHeight
    )
  }

  @objc private func restoreDefaultFrameBeforeMove(_ notification: Notification) {
    // setFrame이 willMove 알림을 다시 보낼 수 있으므로 재진입을 막는다.
    guard !restoringFrameForDrag,
          let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
          let restoredFrame = Self.restoredFrameForDrag(
            windowFrame: frame,
            visibleFrame: visibleFrame,
            mouseLocation: NSEvent.mouseLocation
          )
    else { return }
    restoringFrameForDrag = true
    setFrame(restoredFrame, display: true)
    restoringFrameForDrag = false
  }

  /// Dart의 `resident_mode_native.dart`/`background_activity_native.dart`가
  /// 부르는 메서드를 받는다. 인자가 없거나 모양이 다르면 상주 기본값(true)
  /// 또는 비방지(false)로 답한다 — 알림이 조용히 끊기는 쪽으로 실패하지
  /// 않는다.
  ///
  /// TASK P-impl (3): `AppDelegate.residentChannel`에도 저장해 둔다 — 이
  /// 지역 변수는 함수가 끝나면 사라지지만, wake 신호(Native -> Dart)는
  /// 나중에 `AppDelegate`가 이 채널로 `invokeMethod`를 불러야 해서 더 긴
  /// 생명주기가 필요하다.
  private static func registerResidentChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: AppDelegate.residentChannelName,
      binaryMessenger: messenger
    )
    AppDelegate.residentChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case AppDelegate.residentSetMethod:
        let arguments = call.arguments as? [String: Any]
        let enabled = arguments?[AppDelegate.residentEnabledArgument] as? Bool ?? true
        (NSApp.delegate as? AppDelegate)?.setResident(enabled)
        result(nil)
      case AppDelegate.backgroundActivitySetMethod:
        let arguments = call.arguments as? [String: Any]
        let active = arguments?[AppDelegate.backgroundActivityActiveArgument] as? Bool ?? false
        (NSApp.delegate as? AppDelegate)?.setBackgroundActivity(active)
        result(nil)
      case AppDelegate.showWindowMethod:
        AppDelegate.showMainWindow()
        result(nil)
      case AppDelegate.hideWindowMethod:
        AppDelegate.hideMainWindow()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerWindowNavigationChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: WindowNavigation.channelName,
      binaryMessenger: messenger
    )
    let navigation = windowNavigation
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case WindowNavigation.scanMethod:
        let arguments = call.arguments as? [String: Any]
        let bundleId = arguments?[WindowNavigation.bundleIdArgument] as? String
        navigation.scan(bundleId: bundleId) { result($0) }
      case WindowNavigation.focusMethod:
        guard let arguments = call.arguments as? [String: Any],
              let token = arguments[WindowNavigation.tokenArgument] as? String else {
          result(WindowNavigation.FocusStatus.staleTarget.rawValue)
          return
        }
        navigation.focus(token: token) { result($0) }
      case WindowNavigation.openSettingsMethod:
        navigation.openSettings()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

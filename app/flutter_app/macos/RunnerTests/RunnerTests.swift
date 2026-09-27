import Cocoa
import FlutterMacOS
import XCTest

@testable import my_dashboard

class RunnerTests: XCTestCase {

  func test앱이재시작되면기존창토큰을거부한다() {
    let launch = Date(timeIntervalSince1970: 100)
    XCTAssertFalse(WindowNavigation.targetIsCurrent(
      createdAt: 100, now: 110,
      recordedLaunch: launch, currentLaunch: launch.addingTimeInterval(1),
      recordedBundle: "com.example.editor", currentBundle: "com.example.editor"
    ))
  }

  func test같은PID라도앱식별자가다르면창토큰을거부한다() {
    let launch = Date(timeIntervalSince1970: 100)
    XCTAssertFalse(WindowNavigation.targetIsCurrent(
      createdAt: 100, now: 110,
      recordedLaunch: launch, currentLaunch: launch,
      recordedBundle: "com.example.editor", currentBundle: "com.example.other"
    ))
  }

  func test조회후5분이경과하면창토큰을거부한다() {
    let launch = Date(timeIntervalSince1970: 100)
    XCTAssertTrue(WindowNavigation.targetIsCurrent(
      createdAt: 100, now: 399,
      recordedLaunch: launch, currentLaunch: launch,
      recordedBundle: "com.example.editor", currentBundle: "com.example.editor"
    ))
    XCTAssertFalse(WindowNavigation.targetIsCurrent(
      createdAt: 100, now: 400,
      recordedLaunch: launch, currentLaunch: launch,
      recordedBundle: "com.example.editor", currentBundle: "com.example.editor"
    ))
  }

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func test트레이로열면현재데스크톱에창이표시된다() {
    let delegate = AppDelegate()
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    AppDelegate.registerMainWindow(window)

    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(
      delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
    )
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))

    window.orderOut(nil)
  }

  func test거의전체화면창을드래그하면기본크기로복원된다() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let windowFrame = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let mouse = NSPoint(x: 720, y: 890)

    let restored = MainFlutterWindow.restoredFrameForDrag(
      windowFrame: windowFrame,
      visibleFrame: visible,
      mouseLocation: mouse
    )

    XCTAssertEqual(restored, NSRect(x: 320, y: 268, width: 800, height: 632))
    // 포인터의 수평 비율과 타이틀바 상단 오프셋이 복원 후에도 유지된다.
    XCTAssertEqual((mouse.x - restored!.minX) / restored!.width, 0.5, accuracy: 0.001)
    XCTAssertEqual(restored!.maxY - mouse.y, windowFrame.maxY - mouse.y, accuracy: 0.001)
  }

  func test보통크기창은드래그해도복원대상이아니다() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let windowFrame = NSRect(x: 100, y: 100, width: 800, height: 632)

    XCTAssertNil(
      MainFlutterWindow.restoredFrameForDrag(
        windowFrame: windowFrame,
        visibleFrame: visible,
        mouseLocation: NSPoint(x: 500, y: 700)
      )
    )
  }

  func test화면끝에서드래그해도복원된창은화면안에남는다() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let windowFrame = NSRect(x: 0, y: 25, width: 1440, height: 875)

    for mouse in [
      NSPoint(x: -50, y: 899),
      NSPoint(x: 1, y: 899),
      NSPoint(x: 1439, y: 899),
      NSPoint(x: 1500, y: 899),
    ] {
      let restored = MainFlutterWindow.restoredFrameForDrag(
        windowFrame: windowFrame,
        visibleFrame: visible,
        mouseLocation: mouse
      )
      XCTAssertNotNil(restored)
      XCTAssertGreaterThanOrEqual(restored!.minX, visible.minX)
      XCTAssertLessThanOrEqual(restored!.maxX, visible.maxX)
      XCTAssertGreaterThanOrEqual(restored!.minY, visible.minY)
      XCTAssertLessThanOrEqual(restored!.maxY, visible.maxY)
    }
  }

  func test드래그시작알림이거의전체화면창을기본크기로줄인다() {
    guard let visible = NSScreen.main?.visibleFrame else { return }
    let window = MainFlutterWindow(
      contentRect: NSRect(
        x: visible.minX,
        y: visible.minY,
        width: visible.width,
        height: visible.height
      ),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    // awakeFromNib은 XIB 경로에서만 불리므로 옵저버를 직접 단다.
    NotificationCenter.default.addObserver(
      window,
      selector: NSSelectorFromString("restoreDefaultFrameBeforeMove:"),
      name: NSWindow.willMoveNotification,
      object: window
    )
    defer { NotificationCenter.default.removeObserver(window) }

    NotificationCenter.default.post(
      name: NSWindow.willMoveNotification,
      object: window
    )

    let expectedWidth = min(
      MainFlutterWindow.dragRestoreFrameSize.width,
      visible.width * MainFlutterWindow.nearFullscreenCoverage
    )
    let expectedHeight = min(
      MainFlutterWindow.dragRestoreFrameSize.height,
      visible.height * MainFlutterWindow.nearFullscreenCoverage
    )
    XCTAssertEqual(window.frame.width, expectedWidth, accuracy: 1)
    XCTAssertEqual(window.frame.height, expectedHeight, accuracy: 1)
  }

  func test드래그알림이와도보통크기창은그대로다() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    NotificationCenter.default.addObserver(
      window,
      selector: NSSelectorFromString("restoreDefaultFrameBeforeMove:"),
      name: NSWindow.willMoveNotification,
      object: window
    )
    defer { NotificationCenter.default.removeObserver(window) }
    let before = window.frame

    NotificationCenter.default.post(
      name: NSWindow.willMoveNotification,
      object: window
    )

    XCTAssertEqual(window.frame, before)
  }

  func test창숨기기는보이는메인윈도우만화면에서내린다() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    AppDelegate.registerMainWindow(window)
    window.orderFrontRegardless()

    XCTAssertTrue(window.isVisible)
    AppDelegate.hideMainWindow()
    XCTAssertFalse(window.isVisible)
  }

}

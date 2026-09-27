import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // TASK D-app (A안 설계 ④): 상주 동작은 이제 하드코딩이 아니라 사용자 설정이다.
  //
  // 이 앱이 macOS 알림 배너의 유일한 발신자다(별도 상주 데몬 없음) — 그러려면
  // 마지막 창을 닫아도 프로세스가 살아 있어야 계속 발신할 수 있다. 그래서
  // 기본값은 계속 "상주"(창닫기 = 숨김)다. 다만 그 값을 Dart가
  // `MethodChannel("app/resident")`로 밀어 넣을 수 있게 열어 뒀다 —
  // 설정 화면의 "창을 닫아도 백그라운드 유지" 토글이 그 채널을 부른다
  // (`lib/src/platform/resident_mode_native.dart`).
  //
  // 기본값이 true인 것이 중요하다: 채널 메시지가 오기 전(부팅 초기)이나
  // 영영 오지 않아도(Dart 쪽 실패) 알림이 조용히 끊기지 않는다. 사용자가
  // 명시적으로 끌 때만 false가 된다.
  //
  // 이름은 Dart 쪽 상수(`kResidentChannelName`/`kResidentSetMethod`/
  // `kResidentEnabledArg`)와 반드시 같아야 한다 — 한쪽만 바꾸면 채널이
  // 조용히 no-op이 된다(Dart가 MissingPluginException을 삼킨다).
  static let residentChannelName = "app/resident"
  static let residentSetMethod = "setResident"
  static let residentEnabledArgument = "enabled"

  // TASK P-impl (1)(3): 같은 채널(`app/resident`) 위에 메서드 두 개를 더
  // 얹는다 — 새 채널을 만들지 않는다. `setBackgroundActivity`는
  // Dart -> Native(App Nap 방지 on/off, `lib/src/platform/
  // background_activity_native.dart`), `wakeMethod`는 반대 방향(Native ->
  // Dart, 맥이 깨어났다는 신호)이다.
  static let backgroundActivitySetMethod = "setBackgroundActivity"
  static let backgroundActivityActiveArgument = "active"
  static let wakeMethod = "onWake"
  static let showWindowMethod = "showWindow"
  static let hideWindowMethod = "hideWindow"

  /// `MainFlutterWindow.registerResidentChannel`이 붙인 채널. wake 신호를
  /// Dart로 보내려면(Native -> Dart 방향) 이 참조가 함수 스코프를 벗어나
  /// 살아 있어야 한다 — `MainFlutterWindow.swift` 문서 참고.
  static var residentChannel: FlutterMethodChannel?

  private var isResident = true

  private static var mainWindow: MainFlutterWindow?

  /// TASK P-impl (1): 상주 모드 && 창 숨김 동안만 걸어 두는 App Nap 방지
  /// 토큰. `ProcessInfo.beginActivity`가 돌려주는 불투명 토큰을 들고 있다가
  /// `endActivity`에 그대로 돌려줘야 한다 — 토큰 없이 끌 수 없다.
  private var backgroundActivityToken: NSObjectProtocol?

  static func registerMainWindow(_ window: MainFlutterWindow) {
    mainWindow = window
  }

  static func showMainWindow() {
    guard let mainWindow else { return }
    mainWindow.collectionBehavior.insert(.moveToActiveSpace)
    NSApp.activate(ignoringOtherApps: true)
    mainWindow.makeKeyAndOrderFront(nil)
  }

  static func hideMainWindow() {
    mainWindow?.orderOut(nil)
  }

  /// `MainFlutterWindow`가 채널을 붙이고, 도착한 값을 이리로 넘긴다.
  func setResident(_ enabled: Bool) {
    isResident = enabled
  }

  /// TASK P-impl (1): `active`면 App Nap 방지를 걸고, 아니면 푼다.
  ///
  /// **옵션은 `.userInitiatedAllowingIdleSystemSleep`이다 — TASK P-gate가
  /// Apple 문서 재대조로 바로잡음.** 애초 구현은 `.background`를 썼는데,
  /// Apple의 Energy Efficiency Guide("Prioritize Work at the App Level")가
  /// 정확히 반대로 말한다: `NSActivityBackground`는 "discretionary or
  /// maintenance work"용 표식이라 시스템이 그 작업을 계속 미루거나 App
  /// Nap에 넣을 자유를 유지한다 — 즉 `.background`는 App Nap을 막지
  /// **않는다**. App Nap을 실제로 막는 쪽은 `.userInitiated` 계열이다:
  /// "denoting user-initiated work prevents the system from deferring the
  /// operations or putting your app in App Nap." 그중
  /// `.userInitiated`(순정)는 시스템 유휴 절전까지 막지만(`pmset`에
  /// `PreventUserIdleSystemSleep` assertion이 걸린다),
  /// `.userInitiatedAllowingIdleSystemSleep`은 App Nap만 막고 시스템은
  /// 여전히 사용자의 에너지 절약 설정대로 잠들 수 있게 둔다 — 이 앱이
  /// 원하는 정확히 그 조합이다. 잠자기 중 놓친 전이는 깨어난 뒤 커서 기반
  /// 동기화 따라잡기(`SyncState.cursor`, wake 트리거)가 그대로 복구하므로
  /// 잠자기 자체를 막을 이유가 없다는 원래 근거는 그대로 유효하다 — 바뀐
  /// 건 옵션 값뿐이다.
  ///
  /// **TASK A-impl (3) 실측(2026-09-10, 릴리스 빌드를 실제로 실행해서).**
  /// 이 옵션이 무엇을 만들고 무엇을 만들지 않는지 값으로 확인했다:
  ///
  ///   * `pmset -g assertions`에 이 프로세스의 항목은 **없다** — 그리고 그게
  ///     맞는 결과다. 전력 assertion(`PreventUserIdleSystemSleep`)을 만드는
  ///     것은 `NSActivityIdleSystemSleepDisabled` 비트뿐이고, 이 옵션은 바로
  ///     그 비트를 뺀 값이다(그 비트가 켜지면 맥이 영영 잠들지 못한다 = 위
  ///     "잠자기 허용" 조건 위반). 그래서 assertion 유무는 이 옵션의 성패
  ///     기준이 될 수 없다.
  ///   * App Nap이 실제로 막혔는지는 **타이머가 제 시각에 도는가**로 쟀다.
  ///     창을 닫아 숨긴 상태(상주 켜짐)에서 `GET /dashboard/sync`가
  ///     11s/41s/71s/101s — 정확히 30초 간격(`kSyncInactiveInterval`)으로
  ///     계속 나갔고(로컬 서버 로그), `ps -o pri`는 내내 47을 유지했다.
  ///     App Nap에 들어간 프로세스는 우선순위가 바닥으로 떨어지고 타이머가
  ///     분 단위로 뭉개진다 — 그 흔적이 전혀 없다.
  ///   * 같은 숨김 상태에서 `working` 세션이 있을 때 서버에 전이를 하나
  ///     주입하니 **7.8초 만에** 실제 macOS 배너가 배달됐다(8초 간격 +
  ///     발신 경로 전체가 창을 닫은 채로 살아 있다는 뜻).
  func setBackgroundActivity(_ active: Bool) {
    if active {
      guard backgroundActivityToken == nil else { return }
      backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "상주 모드에서 창이 숨겨진 동안 백그라운드 폴링 타이머 유지"
      )
    } else {
      if let token = backgroundActivityToken {
        ProcessInfo.processInfo.endActivity(token)
        backgroundActivityToken = nil
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 상주면 종료하지 않는다(창만 사라진다). 상주를 끄면 마지막 창을 닫을 때
    // 앱이 실제로 끝난다 — 그때부터 알림은 다시 열 때까지 오지 않는다.
    return !isResident
  }

  // TASK P-impl (3): 맥이 잠에서 깨면 곧바로 Dart에 알려 즉시 동기화 1회를
  // 트리거한다(`sync_controller.dart`의 `SyncWakeWatchFn`). 관찰은 앱
  // 생명주기 전체 동안 유효해야 하므로 `applicationDidFinishLaunching`에서
  // 한 번만 등록한다(중복 등록 방지).
  //
  // **`super`를 부르지 않는다 — TASK A-impl의 실물 확인이 잡은 결함.**
  // `applicationDidFinishLaunching(_:)`은 `NSApplicationDelegate` 프로토콜의
  // **선택** 메서드고 `FlutterAppDelegate`는 그걸 구현하지 않는다. 그래서
  // `super`를 부르면 `objc_msgSendSuper`가 대상을 찾지 못해
  // `NSInvalidArgumentException: -[my_dashboard.AppDelegate
  // applicationDidFinishLaunching:]: unrecognized selector sent to instance`
  // 로 터진다 — AppKit이 그 예외를 잡아 로그만 남기고 앱은 계속 뜨기
  // 때문에 눈에 보이지 않았지만, **예외가 이 메서드를 그 자리에서 끊어
  // 아래 `addObserver`가 영영 실행되지 않았다**(= wake 트리거가 프로덕션
  // 에서 죽어 있었다). 실측 근거: 실행 중인 앱의 통합 로그
  // (`log show --predicate 'processIdentifier == <pid>'`)에 부팅 때마다
  // 위 예외와 `FAULT: NSInvalidArgumentException`이 남는다.
  //
  // `override` 자체는 남긴다 — `FlutterAppDelegate`가 `NSObject` 계열의
  // 델리게이트라 이 메서드를 프로토콜 채택으로만 갖고 있어 Swift가
  // `override` 키워드를 요구한다.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
  }

  @objc private func handleWake() {
    Self.residentChannel?.invokeMethod(Self.wakeMethod, arguments: nil)
  }

  // 창을 전부 닫은 뒤 Dock 아이콘을 다시 클릭하면(hasVisibleWindows가
  // false) 숨어 있던 창을 되살린다 — 위 변경으로 프로세스는 살아 있지만
  // 창이 없으면 클릭해도 아무 반응이 없어 보이는 걸 막는다.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      Self.showMainWindow()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

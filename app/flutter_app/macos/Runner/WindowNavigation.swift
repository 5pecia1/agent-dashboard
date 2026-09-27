import ApplicationServices
import Cocoa
import os

/// AX 작업은 별도 직렬 큐에서 실행한다. 제목 외 문서 경로나 화면 내용은 읽지 않는다.
final class WindowNavigation {
  static let channelName = "app/window_navigation"
  static let scanMethod = "scan"
  static let focusMethod = "focus"
  static let openSettingsMethod = "openSettings"
  static let tokenArgument = "token"
  static let bundleIdArgument = "bundleId"

  enum FocusStatus: String {
    case focused, staleTarget, notGranted, timedOut, unconfirmed
  }

  private enum Limits {
    static let axTimeoutSeconds: Float = 0.25
    static let scanSeconds: TimeInterval = 4
    static let focusSeconds: TimeInterval = 2
    static let confirmationIntervalSeconds: TimeInterval = 0.05
    static let tokenLifetimeSeconds: TimeInterval = 300
    static let windowsPerApplication = 64
    static let retainedTargets = 512
  }

  private struct Target {
    let window: AXUIElement
    let application: AXUIElement
    let pid: pid_t
    let launchDate: Date
    let bundleId: String
    let title: String
    let createdAt: TimeInterval
  }

  private struct WindowList {
    let windows: [AXUIElement]
    let complete: Bool
    let error: AXError
  }

  private let queue = DispatchQueue(label: "app.window_navigation.ax", qos: .userInitiated)
  private static let focusLog = Logger(subsystem: channelName, category: "focus")
  private var targets: [String: Target] = [:]
  private static let accessibilitySettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  )!

  /// bundleId가 있으면 해당 앱만 조회하며 complete도 그 범위의 완전성을 뜻한다.
  /// 다른 앱의 무응답이 이미 저장된 앱 규칙의 이동을 차단하지 않게 한다.
  func scan(bundleId: String? = nil, completion: @escaping ([String: Any]) -> Void) {
    // NSWorkspace 데이터와 AppKit 조작은 메인 스레드에서만 접근한다.
    let requestedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetBundleId = (requestedBundleId?.isEmpty ?? true) ? nil : requestedBundleId
    let applications = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isTerminated &&
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    // 전체 조회가 시간 제한에 걸려도 사용자가 앱을 지정해 다시 찾을 수 있다.
    // catalogue는 AX 호출 없이 메인 큐에서 만들며 창 조회 필터와 분리한다.
    var applicationNames: [String: String] = [:]
    for app in applications {
      guard let bundleId = app.bundleIdentifier else { continue }
      applicationNames[bundleId] = app.localizedName ?? bundleId
    }
    let catalogue = applicationNames.sorted {
      let nameOrder = $0.value.localizedCaseInsensitiveCompare($1.value)
      return nameOrder == .orderedSame ? $0.key < $1.key : nameOrder == .orderedAscending
    }.map { ["bundleId": $0.key, "appName": $0.value] }
    let targetApplications = applications.filter {
      targetBundleId == nil || $0.bundleIdentifier == targetBundleId
    }
    let localHost = ProcessInfo.processInfo.hostName
    queue.async {
      let result = self.scan(
        applications: targetApplications, catalogue: catalogue, localHost: localHost
      )
      DispatchQueue.main.async { completion(result) }
    }
  }

  func focus(token: String, completion: @escaping (String) -> Void) {
    queue.async {
      let status = self.focus(token: token)
      DispatchQueue.main.async { completion(status.rawValue) }
    }
  }

  func openSettings() {
    // 명시적인 설정 버튼에서만 요청한다. 허용 여부는 사용자가 결정한다.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    NSWorkspace.shared.open(Self.accessibilitySettingsURL)
  }

  static func targetIsCurrent(
    createdAt: TimeInterval,
    now: TimeInterval,
    recordedLaunch: Date,
    currentLaunch: Date?,
    recordedBundle: String,
    currentBundle: String?
  ) -> Bool {
    now >= createdAt && now - createdAt < Limits.tokenLifetimeSeconds &&
      currentLaunch == recordedLaunch && currentBundle == recordedBundle
  }

  private func scan(
    applications: [NSRunningApplication], catalogue: [[String: String]], localHost: String
  ) -> [String: Any] {
    let trusted = AXIsProcessTrusted()
    pruneTargets()
    guard trusted else {
      targets.removeAll()
      return scanResult(
        trusted: false, complete: false, localHost: localHost, windows: [], catalogue: catalogue
      )
    }
    let deadline = ProcessInfo.processInfo.systemUptime + Limits.scanSeconds
    var windows: [[String: Any]] = []
    var complete = true
    for app in applications {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        complete = false
        break
      }
      guard !app.isTerminated else { continue }
      guard let bundleId = app.bundleIdentifier, let launchDate = app.launchDate else {
        complete = false
        continue
      }
      let application = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(application, Limits.axTimeoutSeconds)
      let list = windowList(application)
      complete = complete && list.complete
      for window in list.windows {
        guard ProcessInfo.processInfo.systemUptime < deadline,
              windows.count < Limits.retainedTargets else {
          complete = false
          break
        }
        AXUIElementSetMessagingTimeout(window, Limits.axTimeoutSeconds)
        let (titleValue, titleError) = attribute(window, kAXTitleAttribute)
        if titleError != .success && titleError != .noValue && titleError != .attributeUnsupported {
          complete = false
        }
        guard let title = titleValue as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let (minimizedValue, minimizedError) = attribute(window, kAXMinimizedAttribute)
        if minimizedError == .cannotComplete { complete = false }
        let token = UUID().uuidString
        targets[token] = Target(
          window: window, application: application, pid: app.processIdentifier,
          launchDate: launchDate, bundleId: bundleId, title: title,
          createdAt: ProcessInfo.processInfo.systemUptime
        )
        windows.append([
          "token": token, "bundleId": bundleId,
          "appName": app.localizedName ?? bundleId, "title": title,
          "minimized": minimizedValue as? Bool ?? false,
        ])
      }
    }
    pruneTargets()
    return scanResult(
      trusted: true, complete: complete, localHost: localHost, windows: windows,
      catalogue: catalogue
    )
  }

  private func focus(token: String) -> FocusStatus {
    guard AXIsProcessTrusted() else { return .notGranted }
    pruneTargets()
    guard let target = targets[token] else { return .staleTarget }
    let deadline = ProcessInfo.processInfo.systemUptime + Limits.focusSeconds
    guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
          Self.targetIsCurrent(
            createdAt: target.createdAt, now: ProcessInfo.processInfo.systemUptime,
            recordedLaunch: target.launchDate, currentLaunch: app.launchDate,
            recordedBundle: target.bundleId, currentBundle: app.bundleIdentifier
          ) else {
      targets.removeValue(forKey: token)
      return .staleTarget
    }
    let list = windowList(target.application)
    guard list.error == .success else { return status(for: list.error) }
    guard list.windows.contains(where: { CFEqual($0, target.window) }) else {
      return list.complete ? .staleTarget : .unconfirmed
    }
    let (title, titleError) = attribute(target.window, kAXTitleAttribute)
    guard titleError == .success else { return status(for: titleError) }
    guard title as? String == target.title else { return .staleTarget }
    let (minimized, minimizedError) = attribute(target.window, kAXMinimizedAttribute)
    if minimizedError == .cannotComplete { return .timedOut }
    if minimized as? Bool == true {
      let error = AXUIElementSetAttributeValue(
        target.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse
      )
      guard error == .success else { return status(for: error) }
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
    let activation = DispatchQueue.main.sync { () -> (
      sourceActive: Bool, cooperative: Bool, accepted: Bool
    ) in
      let sourceActive = NSApp.isActive
      guard !app.isTerminated else { return (sourceActive, false, false) }
      app.unhide()
      if #available(macOS 14.0, *) {
        // 협력 활성화는 넘겨줄 활성 상태를 현재 앱이 가진 경우에만 쓴다.
        // 배너·트레이 클릭으로 백그라운드에서 호출되면 일반 요청을 보낸다.
        if sourceActive {
          NSApp.yieldActivation(to: app)
          if app.activate(from: NSRunningApplication.current, options: []) {
            return (sourceActive, true, true)
          }
        }
        return (sourceActive, sourceActive, app.activate(options: []))
      } else {
        return (sourceActive, false, app.activate(options: .activateIgnoringOtherApps))
      }
    }
    Self.focusLog.info(
      "activation sourceActive=\(activation.sourceActive, privacy: .public) cooperative=\(activation.cooperative, privacy: .public) accepted=\(activation.accepted, privacy: .public)"
    )
    guard !app.isTerminated else { return .staleTarget }
    guard AXIsProcessTrusted() else { return .notGranted }
    guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
    // AppKit의 거절만으로 실패하지 않는다. 권한을 받은 공개 AX 경로는
    // 앱이 백그라운드일 때도 시도할 수 있으며, 실제 전환은 아래에서 검증한다.
    let frontmostError = AXUIElementSetAttributeValue(
      target.application, kAXFrontmostAttribute as CFString, kCFBooleanTrue
    )
    Self.focusLog.info("activation frontmostSet=\(frontmostError.rawValue, privacy: .public)")
    if frontmostError == .invalidUIElement { return .staleTarget }
    guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
    // 앱마다 설정 가능한 AX 속성이 다르므로 최종 확인 결과로 성공을 판단한다.
    let raiseError = selectWindow(target, afterActivation: false)
    if raiseError == .invalidUIElement { return .staleTarget }
    var lastError = raiseError
    var retriedAfterActivation = false
    var lastFrontmost = false
    var lastWindowMatched = false
    var lastRestored = false
    while ProcessInfo.processInfo.systemUptime < deadline {
      guard AXIsProcessTrusted() else { return .notGranted }
      guard !app.isTerminated else { return .staleTarget }
      let isFrontmost = DispatchQueue.main.sync {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
      }
      // 활성화 직전의 raise가 앱의 기존 main/key 창 복원으로 덮일 수 있다.
      // 실제 전면 앱이 된 것을 확인한 뒤 선택한 창을 딱 한 번 다시 올린다.
      if isFrontmost && !retriedAfterActivation {
        retriedAfterActivation = true
        lastError = selectWindow(target, afterActivation: true)
        if lastError == .invalidUIElement { return .staleTarget }
      }
      let (focused, focusedError) = attribute(target.application, kAXFocusedWindowAttribute)
      lastError = focusedError
      let windowMatched = focusedError == .success && focused.map {
        CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, target.window)
      } == true
      lastFrontmost = isFrontmost
      lastWindowMatched = windowMatched
      if windowMatched && isFrontmost {
        let (isMinimized, error) = attribute(target.window, kAXMinimizedAttribute)
        lastRestored = error == .success && isMinimized as? Bool == false
        if lastRestored { return .focused }
        if error == .invalidUIElement { return .staleTarget }
        lastError = error
      }
      Thread.sleep(forTimeInterval: Limits.confirmationIntervalSeconds)
    }
    // 진단값에 앱 식별자·제목·토큰·프로젝트 경로를 포함하지 않는다.
    Self.focusLog.info(
      "confirmation frontmost=\(lastFrontmost, privacy: .public) windowMatched=\(lastWindowMatched, privacy: .public) restored=\(lastRestored, privacy: .public) retried=\(retriedAfterActivation, privacy: .public) axError=\(lastError.rawValue, privacy: .public)"
    )
    return lastError == .cannotComplete ? .timedOut : .unconfirmed
  }

  private func selectWindow(_ target: Target, afterActivation: Bool) -> AXError {
    let focusedError = AXUIElementSetAttributeValue(
      target.application, kAXFocusedWindowAttribute as CFString, target.window
    )
    let mainError = AXUIElementSetAttributeValue(
      target.window, kAXMainAttribute as CFString, kCFBooleanTrue
    )
    let raiseError = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
    Self.focusLog.info(
      "selection afterActivation=\(afterActivation, privacy: .public) focusedSet=\(focusedError.rawValue, privacy: .public) mainSet=\(mainError.rawValue, privacy: .public) raise=\(raiseError.rawValue, privacy: .public)"
    )
    return raiseError
  }

  private func windowList(_ application: AXUIElement) -> WindowList {
    var count: CFIndex = 0
    let countError = AXUIElementGetAttributeValueCount(
      application, kAXWindowsAttribute as CFString, &count
    )
    if countError == .attributeUnsupported || countError == .noValue {
      return WindowList(windows: [], complete: true, error: countError)
    }
    guard countError == .success else {
      return WindowList(windows: [], complete: false, error: countError)
    }
    guard count > 0 else { return WindowList(windows: [], complete: true, error: .success) }
    var values: CFArray?
    let error = AXUIElementCopyAttributeValues(
      application, kAXWindowsAttribute as CFString, 0,
      min(count, Limits.windowsPerApplication), &values
    )
    return WindowList(
      windows: values as? [AXUIElement] ?? [],
      complete: error == .success && count <= Limits.windowsPerApplication,
      error: error
    )
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, error)
  }

  private func status(for error: AXError) -> FocusStatus {
    if !AXIsProcessTrusted() { return .notGranted }
    switch error {
    case .invalidUIElement: return .staleTarget
    case .cannotComplete: return .timedOut
    default: return .unconfirmed
    }
  }

  private func pruneTargets() {
    let now = ProcessInfo.processInfo.systemUptime
    targets = targets.filter {
      now >= $0.value.createdAt && now - $0.value.createdAt < Limits.tokenLifetimeSeconds
    }
    let excess = targets.count - Limits.retainedTargets
    if excess > 0 {
      for entry in targets.sorted(by: { $0.value.createdAt < $1.value.createdAt }).prefix(excess) {
        targets.removeValue(forKey: entry.key)
      }
    }
  }

  private func scanResult(
    trusted: Bool, complete: Bool, localHost: String, windows: [[String: Any]],
    catalogue: [[String: String]]
  ) -> [String: Any] {
    [
      "trusted": trusted, "complete": complete, "localHost": localHost,
      "windows": windows, "applications": catalogue,
    ]
  }
}

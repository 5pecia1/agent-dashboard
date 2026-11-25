import AppKit
import Sparkle

typealias DashboardFeedPreparation = (@escaping (URL?) -> Void) -> Void

@MainActor
final class DashboardLaunchUpdater: NSObject, SPUUpdaterDelegate {
  private enum CheckKind { case background, manual }

  private var launchChecked = false
  private var preparation: CheckKind?
  private var activeKind: CheckKind?
  private var canFocusObservation: NSKeyValueObservation?
  private var delayedManualCheck: DashboardFeedPreparation?
  private var feedURL: URL?
  private var updater: SPUUpdater?
  private var showingFailure = false

  static var configuredFeed: URLComponents? {
    let bundle = Bundle.main
    guard let product = bundle.object(forInfoDictionaryKey: "DashboardUpdateBundleIdentifier") as? String,
          product == bundle.bundleIdentifier,
          let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    else { return nil }
    return URLComponents(string: feed)
  }

  func checkOnce(prepare: @escaping DashboardFeedPreparation) {
    guard !launchChecked else { return }
    launchChecked = true
    guard preparation == nil, updater?.sessionInProgress != true else { return }
    prepareCheck(.background, prepare: prepare)
  }

  func checkNow(prepare: @escaping DashboardFeedPreparation) {
    guard !showingFailure else { return }
    if preparation != nil {
      // A click while the launch authorization is pending promotes that request.
      preparation = .manual
    } else if let updater, updater.sessionInProgress {
      if updater.canCheckForUpdates {
        delayedManualCheck = nil
        updater.checkForUpdates() // Bring the existing Sparkle offer to the front.
      } else if activeKind == .background {
        // Ignore duplicate clicks while Sparkle is already showing a manual
        // progress UI. A click during a quiet fetch must still receive feedback.
        delayedManualCheck = prepare
      }
    } else {
      prepareCheck(.manual, prepare: prepare)
    }
  }

  private func prepareCheck(_ kind: CheckKind, prepare: @escaping DashboardFeedPreparation) {
    guard let pinned = Self.configuredFeed else {
      if kind == .manual { reportUnavailable() }
      return
    }
    preparation = kind
    // Neither the app's first frame nor a menu event should wait on authorization.
    DispatchQueue.main.async { [weak self] in
      prepare { candidate in
        DispatchQueue.main.async {
          guard let self, let requested = self.preparation else { return }
          self.preparation = nil
          guard let candidate, Self.permits(candidate, for: pinned, bundleID: Bundle.main.bundleIdentifier) else {
            if requested == .manual { self.reportUnavailable() }
            return
          }
          self.feedURL = candidate
          do {
            let driver = try self.startedUpdater()
            // Preserve the offer's Remind Me Later button; disable the scheduler
            // as soon as the current cycle finishes. Installs always require consent.
            driver.automaticallyChecksForUpdates = true
            driver.automaticallyDownloadsUpdates = false
            self.activeKind = requested
            if requested == .manual { driver.checkForUpdates() }
            else { driver.checkForUpdatesInBackground() }
          } catch {
            self.feedURL = nil
            if requested == .manual { self.reportUnavailable() }
          }
        }
      }
    }
  }

  private func startedUpdater() throws -> SPUUpdater {
    if let updater { return updater }
    let bundle = Bundle.main
    let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
    let driver = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                            userDriver: userDriver, delegate: self)
    driver.automaticallyChecksForUpdates = false
    driver.automaticallyDownloadsUpdates = false
    try driver.start()
    updater = driver
    // Sparkle sets this KVO property when it can bring a discovered update's
    // standard UI to the front, before the background cycle ends.
    canFocusObservation = driver.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
      guard change.newValue == true else { return }
      DispatchQueue.main.async { self?.focusPendingCheck() }
    }
    return driver
  }

  private func focusPendingCheck() {
    guard delayedManualCheck != nil, let updater, updater.sessionInProgress, updater.canCheckForUpdates else { return }
    delayedManualCheck = nil
    updater.checkForUpdates()
  }

  private func reportUnavailable() {
    let korean = Self.isKorean()
    let alert = NSAlert()
    alert.messageText = korean ? "업데이트를 확인할 수 없습니다" : "Unable to Check for Updates"
    alert.informativeText = korean
      ? "네트워크 연결과 업데이트 서비스 접근 권한을 확인한 뒤 다시 시도하세요."
      : "Check your network connection and access to the update service, then try again."
    alert.addButton(withTitle: korean ? "확인" : "OK")
    showingFailure = true
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window) { [weak self] _ in self?.showingFailure = false }
    } else {
      alert.runModal()
      showingFailure = false
    }
  }

  static func isKorean(_ languages: [String] = Locale.preferredLanguages) -> Bool {
    Bundle.preferredLocalizations(from: ["en", "ko"], forPreferences: languages).first == "ko"
  }

  static func permits(_ url: URL, for pinned: URLComponents, bundleID: String?) -> Bool {
    guard let resolved = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = pinned.scheme?.lowercased(), let host = pinned.host?.lowercased(),
          !host.isEmpty, pinned.user == nil, pinned.password == nil,
          pinned.fragment == nil, pinned.query == nil,
          resolved.scheme?.lowercased() == scheme, resolved.host?.lowercased() == host,
          resolved.port == pinned.port, resolved.percentEncodedPath == pinned.percentEncodedPath,
          resolved.user == nil, resolved.password == nil, resolved.fragment == nil
    else { return false }
    if scheme == "https" { return true }
    // Only separately identified fixture bundles may test an HTTP loopback server.
    return scheme == "http" && bundleID?.hasSuffix(".qa") == true &&
      (host == "127.0.0.1" || host == "[::1]")
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
               error: Error?) {
    updater.automaticallyChecksForUpdates = false
    activeKind = nil
    feedURL = nil
    if let prepare = delayedManualCheck {
      delayedManualCheck = nil
      DispatchQueue.main.async { [weak self] in self?.checkNow(prepare: prepare) }
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    feedURL?.absoluteString
  }
}

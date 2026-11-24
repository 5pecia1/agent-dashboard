import AppKit
import Sparkle

@MainActor
final class DashboardLaunchUpdater: NSObject, SPUUpdaterDelegate {
  private var launchChecked = false
  private var feedURL: URL?
  private var updater: SPUUpdater?

  func checkOnce(prepare: @escaping (@escaping (URL?) -> Void) -> Void) {
    guard !launchChecked else { return }
    launchChecked = true
    let bundle = Bundle.main
    // Development and integration targets with a distinct bundle identifier
    // must never consume a production release, even when they share this plist.
    guard let product = bundle.object(forInfoDictionaryKey: "DashboardUpdateBundleIdentifier") as? String,
          product == bundle.bundleIdentifier,
          let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
          let pinned = URLComponents(string: feed) else { return }

    // Launch and the first frame must never wait for network authorization.
    DispatchQueue.main.async { [weak self] in
      prepare { candidate in
        DispatchQueue.main.async {
          guard let self, self.updater == nil, let candidate,
                Self.permits(candidate, for: pinned, bundleID: bundle.bundleIdentifier)
          else { return }
          self.feedURL = candidate
          let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
          let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                   userDriver: driver, delegate: self)
          self.updater = updater
          // Sparkle only offers Remind Me Later when checks are enabled. Stop
          // its scheduler as soon as this one launch cycle finishes.
          updater.automaticallyChecksForUpdates = true
          updater.automaticallyDownloadsUpdates = false
          do {
            try updater.start()
            updater.checkForUpdatesInBackground()
          } catch {
            // A private feed can contain a short-lived ticket. Keep URLs out of logs.
            NSLog("Dashboard update check could not start (code %ld)", (error as NSError).code)
          }
        }
      }
    }
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
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    feedURL?.absoluteString
  }
}

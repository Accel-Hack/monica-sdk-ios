import Foundation
import Monica

final class FakePlatform: MonicaPlatform {
  var environment: AppleEnvironment? = AppleEnvironment(
    deviceModel: "iPhone15,2", isSimulator: false, osName: "iOS", osVersion: "17.4.1",
    appIdentifier: "com.example.app", appVersion: "2.3.1", appBuild: "231", executableName: "ExampleApp")
  private(set) var listener: ((String) -> Void)?
  let suiteName = "monica-swift-tests-\(UUID().uuidString)"
  /// A suite of its own, removed with the platform. It starts with a fresh
  /// `202`, so a test that is not about the presence check sees no heartbeat;
  /// ``forgetPresence()`` makes it a first launch. A relaunch is a second
  /// install with the same platform.
  private(set) lazy var defaults: UserDefaults = {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(Date(), forKey: "com.accelhack.monica.presence.intervalStartedAt")
    return defaults
  }()
  var tracking: Bool { listener != nil }

  func trackLifecycle(_ listener: @escaping (String) -> Void) -> MonicaCancellable {
    self.listener = listener
    // Strong on purpose: the installed Monica keeps the platform, and with it
    // the suite its client writes to, until it closes.
    return Cancel { self.listener = nil }
  }

  deinit {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
  }

  @discardableResult
  func forgetPresence() -> FakePlatform {
    defaults.removePersistentDomain(forName: suiteName)
    return self
  }

  func emit(_ transition: String) {
    listener?(transition)
  }

  private final class Cancel: MonicaCancellable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func cancel() { body() }
  }
}

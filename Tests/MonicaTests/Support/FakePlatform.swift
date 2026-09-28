import Foundation
import Monica

final class FakePlatform: MonicaPlatform {
  var environment: AppleEnvironment? = AppleEnvironment(
    deviceModel: "iPhone15,2", isSimulator: false, osName: "iOS", osVersion: "17.4.1",
    appIdentifier: "com.example.app", appVersion: "2.3.1", appBuild: "231", executableName: "ExampleApp")
  private(set) var listener: ((String) -> Void)?
  static let suiteName = "monica-swift-tests"
  /// One suite, reset by every new platform. It starts with a fresh `202`, so
  /// a test that is not about the presence check sees no heartbeat;
  /// ``forgetPresence()`` makes it a first launch. A relaunch is a second
  /// install with the same platform.
  let defaults: UserDefaults = {
    let defaults = UserDefaults(suiteName: FakePlatform.suiteName)!
    defaults.removePersistentDomain(forName: FakePlatform.suiteName)
    defaults.set(Date(), forKey: "com.accelhack.monica.presence.lastAcceptedAt")
    return defaults
  }()
  var tracking: Bool { listener != nil }

  func trackLifecycle(_ listener: @escaping (String) -> Void) -> MonicaCancellable {
    self.listener = listener
    return Cancel { [weak self] in self?.listener = nil }
  }

  @discardableResult
  func forgetPresence() -> FakePlatform {
    defaults.removePersistentDomain(forName: Self.suiteName)
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

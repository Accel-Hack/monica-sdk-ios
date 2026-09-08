import Foundation
import Monica

final class FakePlatform: MonicaPlatform {
  var environment: AppleEnvironment? = AppleEnvironment(
    deviceModel: "iPhone15,2", isSimulator: false, osName: "iOS", osVersion: "17.4.1",
    appIdentifier: "com.example.app", appVersion: "2.3.1", appBuild: "231", executableName: "ExampleApp")
  private(set) var listener: ((String) -> Void)?
  var tracking: Bool { listener != nil }

  func trackLifecycle(_ listener: @escaping (String) -> Void) -> MonicaCancellable {
    self.listener = listener
    return Cancel { [weak self] in self?.listener = nil }
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

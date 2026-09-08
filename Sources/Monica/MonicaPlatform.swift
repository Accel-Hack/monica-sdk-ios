import Foundation

/// Stops a lifecycle subscription.
public protocol MonicaCancellable {
  func cancel()
}

/// Everything ``Monica`` needs from the OS. Keeping UIKit behind this protocol
/// is what makes the integration testable on a Mac: the classes that decide
/// *what* to send hold no UIKit types.
public protocol MonicaPlatform {
  /// Device, OS and application facts read once at install time.
  var environment: AppleEnvironment? { get }
  /// Starts reporting app lifecycle transitions (`active`, `inactive`,
  /// `background`, `foreground`, `memory_warning`).
  func trackLifecycle(_ listener: @escaping (String) -> Void) -> MonicaCancellable
}

final class ClosureCancellable: MonicaCancellable {
  private var body: (() -> Void)?
  init(_ body: @escaping () -> Void) { self.body = body }
  func cancel() {
    body?()
    body = nil
  }
}

/// The platform for any process: environment only, no lifecycle events.
struct FoundationPlatform: MonicaPlatform {
  var environment: AppleEnvironment? { AppleEnvironment.current() }
  func trackLifecycle(_ listener: @escaping (String) -> Void) -> MonicaCancellable {
    ClosureCancellable {}
  }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// UIKit's application notifications. No swizzling: view controller names are
/// the application's to report through `setScreen`.
struct UIKitPlatform: MonicaPlatform {
  var environment: AppleEnvironment? { AppleEnvironment.current() }

  func trackLifecycle(_ listener: @escaping (String) -> Void) -> MonicaCancellable {
    let center = NotificationCenter.default
    let pairs: [(Notification.Name, String)] = [
      (UIApplication.didBecomeActiveNotification, "active"),
      (UIApplication.willResignActiveNotification, "inactive"),
      (UIApplication.didEnterBackgroundNotification, "background"),
      (UIApplication.willEnterForegroundNotification, "foreground"),
      (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
    ]
    let observers = pairs.map { name, label in
      center.addObserver(forName: name, object: nil, queue: nil) { _ in listener(label) }
    }
    return ClosureCancellable { observers.forEach(center.removeObserver) }
  }
}

enum DefaultPlatform {
  static func make() -> MonicaPlatform { UIKitPlatform() }
}
#else
enum DefaultPlatform {
  static func make() -> MonicaPlatform { FoundationPlatform() }
}
#endif

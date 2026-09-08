import Monica
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  static let tag = "MonicaSample"
  var window: UIWindow?

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    installMonica()

    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UINavigationController(rootViewController: MainViewController())
    window.makeKeyAndVisible()
    self.window = window
    return true
  }

  private func installMonica() {
    let configured = Bundle.main.infoDictionary?["MonicaDSN"] as? String ?? ""
    // The placeholder keeps the SDK exercised even without a DSN: ingest answers
    // 401, which LoggingTransport reports as rejected.
    let dsn = configured.isEmpty ? "https://mpk_placeholder@ingest.stg.monica.accelhack.net/ios-sample" : configured
    if configured.isEmpty {
      NSLog("[\(Self.tag)] MONICA_DSN is not configured; using a placeholder key. Set it in Config/Local.xcconfig.")
    }

    var options = MonicaOptions(dsn: dsn, environment: isDebugBuild ? "development" : "production")
    options.inAppModules = ["MonicaSample"]
    do {
      options.transport = LoggingTransport(try URLSessionTransport(dsn: dsn, maxRetries: 2, requestTimeout: 10))
    } catch {
      NSLog("[\(Self.tag)] transport rejected the DSN: \(error)")
    }
    options.beforeSend = { event, _ in
      NSLog("[\(Self.tag)] beforeSend event_id=\(event.eventId ?? "?") level=\(event.level?.rawValue ?? "?") grouping=\(Self.groupingInputs(of: event))")
      return event
    }
    do {
      let monica = try Monica.install(options)
      NSLog("[\(Self.tag)] MONICA installed: \(monica.stats.queued) queued")
    } catch {
      NSLog("[\(Self.tag)] MONICA install failed: \(error)")
    }
  }

  /// What the backend groups on, so grouping can be checked from the console
  /// alone: the innermost exception type and the in_app frame filenames the SDK
  /// built. The same crash on two builds of the same configuration must print
  /// the same line; a stripped build prints bare image names (`MonicaSample`)
  /// for every frame, which is the degenerate case README describes. The
  /// grouping algorithm itself is MONICA's and is not part of the public
  /// contract, so the sample does not compute a fingerprint.
  private static func groupingInputs(of event: MonicaEvent) -> String {
    if let fingerprint = event["fingerprint"] { return "custom fingerprint=\(fingerprint)" }
    guard let values = (event["exception"] as? [String: Any])?["values"] as? [[String: Any]],
      let innermost = values.last
    else { return "message=\(event["message"] ?? "")" }
    let frames = ((innermost["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]]) ?? []
    let inApp = frames.filter { $0["in_app"] as? Bool == true }.map { String(describing: $0["filename"] ?? "") }
    return "\(innermost["type"] ?? "?") in_app=\(inApp)"
  }

  private var isDebugBuild: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }
}

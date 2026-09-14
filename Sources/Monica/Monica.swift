import Foundation

/// The MONICA integration for an iOS application.
///
/// Install it once, normally from `application(_:didFinishLaunchingWithOptions:)`:
///
/// ```swift
/// var options = MonicaOptions(dsn: Secrets.monicaDSN, environment: "production")
/// options.release = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
/// try Monica.install(options)
/// ```
///
/// Initialisation is explicit. Nothing starts sending because the package is
/// linked, and ``current`` is nil until an application asks for it.
public final class Monica {
  /// `sdk.name`: the Package name. SwiftPM has no registry, so this is the
  /// name a consumer sees in `Package.swift` (the package *identity* is the
  /// repository name, `monica-sdk-ios`).
  public static let sdkName = "monica-swift"
  /// `sdk.version`: the git tag a release is cut from. `release.yml` refuses a
  /// tag that does not match this value.
  public static let sdkVersion = "0.1.0"
  /// `platform` on every event. `swift` names the language, as the other
  /// values do; the OS is in `contexts.os`.
  public static let platformName = "swift"

  /// Guards only the `installed` pointer, so ``current`` never waits on I/O,
  /// a flush, or application code.
  private static let currentLock = NSLock()
  /// Serialises install / close against each other. Never held while calling
  /// application code (`beforeSend`, a custom transport).
  private static let lifecycleLock = NSLock()
  private static var installed: Monica?

  public let client: MonicaClient
  private let reporter: CrashReporter?
  private let environment: String
  private let release: String?
  private let inAppModules: [String]
  private var lifecycle: MonicaCancellable?
  private let sessionQueue = DispatchQueue(label: "monica-swift-session", qos: .utility)
  private let stateLock = NSLock()
  private var closed = false

  private init(client: MonicaClient, reporter: CrashReporter?, environment: String, release: String?,
               inAppModules: [String]) {
    self.client = client
    self.reporter = reporter
    self.environment = environment
    self.release = release
    self.inAppModules = inAppModules
  }

  /// Installs the integration with the platform of the running OS.
  @discardableResult
  public static func install(_ options: MonicaOptions) throws -> Monica {
    try install(options, platform: DefaultPlatform.make())
  }

  /// Installs the integration on any ``MonicaPlatform``.
  ///
  /// A second install replaces the first: the previous instance is closed,
  /// which flushes it and restores the crash handlers it had replaced.
  @discardableResult
  public static func install(_ options: MonicaOptions, platform: MonicaPlatform) throws -> Monica {
    let validated = try options.validated()
    lifecycleLock.lock(); defer { lifecycleLock.unlock() }

    // Retire the previous instance first: the crash handler is process-wide,
    // so it must be uninstalled before the new one takes it over.
    currentLock.lock()
    let previous = installed
    installed = nil
    currentLock.unlock()
    previous?.shutdown()

    let environment = platform.environment
    let inAppModules = options.inAppModules.isEmpty
      ? [environment?.executableName].compactMap { $0 } : options.inAppModules
    let release = options.release ?? environment?.appVersion
    let transport = options.transport
      ?? URLSessionTransport(dsn: validated.dsn, maxRetries: options.maxRetries,
                             requestTimeout: options.requestTimeout, configuration: .ephemeral,
                             onDiagnostic: options.onDiagnostic)
    let client = MonicaClient(options: validated, transport: transport, inAppModules: inAppModules, release: release)
    if options.attachDeviceContext, let environment = environment {
      environment.apply(to: client.globalScope)
    }

    var reporter: CrashReporter?
    if options.captureCrashes {
      let candidate = CrashReporter(directory: options.crashReportDirectory ?? CrashReporter.defaultDirectory())
      if candidate.install() { reporter = candidate }
    }

    let monica = Monica(client: client, reporter: reporter, environment: validated.environment, release: release,
                        inAppModules: inAppModules)
    currentLock.lock()
    installed = monica
    currentLock.unlock()

    // The previous launch's crash is handled off the main thread and outside
    // every lock: it symbolicates up to 128 frames and runs the app's
    // `beforeSend`, which may itself call back into `Monica.current`.
    monica.sendPendingCrashReport()
    monica.persistSession()
    if options.trackAppLifecycle {
      monica.lifecycle = platform.trackLifecycle { [weak monica] transition in
        monica?.onLifecycle(transition)
      }
    }
    return monica
  }

  /// The installed integration, or nil when nothing has been installed.
  public static var current: Monica? {
    currentLock.lock(); defer { currentLock.unlock() }
    return installed
  }

  /// The scope applied to every event: tags, contexts and breadcrumbs.
  public var scope: Scope { client.globalScope }

  /// False when `captureCrashes` was requested but the handlers could not be
  /// installed (the report directory is not writable, for instance). The rest
  /// of the SDK keeps working; only crashes go unreported.
  public var isCrashCaptureInstalled: Bool { reporter != nil }

  @discardableResult
  public func captureError(_ error: Error, context: CaptureContext = CaptureContext()) -> String? {
    let addresses = Thread.callStackReturnAddresses.map { UInt($0.uintValue) }
    return client.captureError(error, context: context, callStack: addresses, skipFrames: 1)
  }

  @discardableResult
  public func captureMessage(_ message: String, context: CaptureContext = CaptureContext()) -> String? {
    client.captureMessage(message, context: context)
  }

  public func addBreadcrumb(category: String, message: String) {
    client.globalScope.addBreadcrumb(category: category, message: message)
  }

  /// Identifies the person using the application. Nothing is sent about them
  /// until this is called.
  public func setUser(id: String) {
    setUser(["id": id])
  }

  /// Identifies the person using the application with whatever fields apply.
  public func setUser(_ user: [String: Any]?) {
    client.globalScope.setUser(user)
    persistSession()
  }

  /// Records the screen the application considers itself on.
  public func setScreen(_ screen: String) {
    client.globalScope.setTag("screen", screen)
    client.globalScope.addBreadcrumb(category: "ui.lifecycle", message: "\(screen).appeared")
    persistSession()
  }

  public func flush(timeout: TimeInterval) -> Bool {
    client.flush(timeout: timeout)
  }

  public var stats: MonicaStats { client.stats }

  /// Flushes, removes the crash handlers and the lifecycle observers, and stops sending.
  public func close() {
    Self.lifecycleLock.lock(); defer { Self.lifecycleLock.unlock() }
    Self.currentLock.lock()
    if Self.installed === self { Self.installed = nil }
    Self.currentLock.unlock()
    shutdown()
  }

  /// Everything `close()` does except the bookkeeping of ``current``. Callers
  /// hold `lifecycleLock`, so install and close never interleave.
  private func shutdown() {
    stateLock.lock()
    let alreadyClosed = closed
    closed = true
    stateLock.unlock()
    if alreadyClosed { return }
    lifecycle?.cancel()
    lifecycle = nil
    reporter?.uninstall()
    client.close()
  }

  private var isClosed: Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    return closed
  }

  private func onLifecycle(_ transition: String) {
    if isClosed { return }
    client.globalScope.addBreadcrumb(category: "app.lifecycle", message: transition)
  }

  private func sendPendingCrashReport() {
    guard let reporter = reporter else { return }
    let fallbackEnvironment = environment
    let fallbackRelease = release
    let fallbackContexts = client.globalScope.snapshot().contexts
    let inAppModules = self.inAppModules
    let client = self.client
    // Same serial queue as `persistSession`, so the previous launch's
    // session.json is read before this launch overwrites it.
    sessionQueue.async {
      guard let report = reporter.readPendingReport() else { return }
      if client.isShutDown { return }
      let event = CrashReporter.event(
        from: report, session: reporter.readSession(), fallbackEnvironment: fallbackEnvironment,
        fallbackRelease: fallbackRelease, fallbackContexts: fallbackContexts, inAppModules: inAppModules)
      let accepted = client.capturePrepared(event) != nil
      // Keep the file for the next launch only when the client refused it for
      // being closed. Sampling or a `beforeSend` that returned nil is a
      // decision, not a failure, so the report is done with either way.
      if accepted || !client.isShutDown { reporter.discardPendingReport() }
    }
  }

  /// The crash report the C handler writes has no room for the scope, so the
  /// parts of it a crash needs are kept on disk and refreshed when they change.
  private func persistSession() {
    guard let reporter = reporter else { return }
    let snapshot = client.globalScope.snapshot()
    var session: [String: Any] = ["environment": environment, "tags": snapshot.tags, "contexts": snapshot.contexts]
    if let release = release { session["release"] = release }
    if let user = snapshot.user { session["user"] = user }
    sessionQueue.async { reporter.writeSession(session) }
  }
}

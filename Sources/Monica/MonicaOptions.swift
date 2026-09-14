import Foundation

/// Configuration for ``Monica``. Every field except `dsn` and `environment`
/// has a default that matches monica-android.
public struct MonicaOptions {
  /// `limits.json` `items_per_envelope`: a batch never exceeds it.
  public static let maxItemsPerEnvelope = 100
  /// `envelope.json` `errorItem.environment.maxLength`. JSON Schema counts
  /// `maxLength` in code points, so this is compared against
  /// `unicodeScalars.count` and never `String.count`: 128 grapheme clusters of
  /// combining marks or flag emoji are 256 or more code points, and would be
  /// accepted here only to be rejected by ingest on every event.
  public static let maxEnvironmentLength = 128

  /// The project DSN. It must carry a public `mpk_` key.
  public var dsn: String
  /// `production`, `staging`, ... At most 128 code points.
  public var environment: String
  /// Defaults to the bundle's `CFBundleShortVersionString`.
  public var release: String?
  /// Binary image names whose frames count as `in_app`. When empty, the main
  /// executable's name is used.
  public var inAppModules: [String] = []
  /// Decides what actually leaves the device. PII removal belongs here.
  public var beforeSend: ((MonicaEvent, CaptureHint) -> MonicaEvent?)?
  public var sampleRate: Double = 1
  public var maxQueueSize: Int = 100
  public var maxBreadcrumbs: Int = 50
  public var batchSize: Int = 30
  public var flushInterval: TimeInterval = 5
  public var flushTimeout: TimeInterval = 2
  public var requestTimeout: TimeInterval = 10
  public var maxRetries: Int = 2
  /// Installs the signal and NSException handlers. The crash is written to
  /// disk and sent on the next launch.
  public var captureCrashes: Bool = true
  /// Records foreground / background transitions as `app.lifecycle` breadcrumbs.
  public var trackAppLifecycle: Bool = true
  /// Attaches `contexts.device`, `contexts.os` and `contexts.app`.
  public var attachDeviceContext: Bool = true
  /// Replaces the HTTP transport. Intended for tests.
  public var transport: MonicaTransport?
  /// Receives the warnings the SDK would otherwise write to `os_log`, together
  /// with the ``MonicaTransportResult`` behind each one, so an application can
  /// route them into its own logging or surface the `422` `issues` in a debug
  /// screen. Nil (the default) means `os_log`; `{ _ in }` silences them.
  ///
  /// Called on the sender queue, not the main thread, and only for the
  /// transport this SDK builds: a transport supplied through ``transport``
  /// decides for itself what to report.
  public var onDiagnostic: ((MonicaDiagnostic) -> Void)?
  /// Where the pending crash report and the scope snapshot live. Defaults to
  /// `Application Support/monica` inside the app container.
  public var crashReportDirectory: URL?

  public init(dsn: String, environment: String) {
    self.dsn = dsn
    self.environment = environment
  }

  /// Validates the options so a secret key or a nonsense timeout fails at
  /// install time, even when a test supplies its own transport.
  func validated() throws -> ValidatedOptions {
    let parsedDSN = try DSN.parse(dsn)
    let trimmedEnvironment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedEnvironment.isEmpty { throw MonicaConfigurationError.emptyEnvironment }
    if trimmedEnvironment.unicodeScalars.count > Self.maxEnvironmentLength {
      throw MonicaConfigurationError.invalidValue(
        "environment must be at most \(Self.maxEnvironmentLength) code points")
    }
    if !(0...1).contains(sampleRate) {
      throw MonicaConfigurationError.invalidValue("sampleRate must be between 0 and 1")
    }
    if maxQueueSize <= 0 { throw MonicaConfigurationError.invalidValue("maxQueueSize must be positive") }
    if maxBreadcrumbs <= 0 { throw MonicaConfigurationError.invalidValue("maxBreadcrumbs must be positive") }
    if batchSize <= 0 { throw MonicaConfigurationError.invalidValue("batchSize must be positive") }
    if flushInterval <= 0 { throw MonicaConfigurationError.invalidValue("flushInterval must be positive") }
    if flushTimeout <= 0 { throw MonicaConfigurationError.invalidValue("flushTimeout must be positive") }
    if requestTimeout <= 0 { throw MonicaConfigurationError.invalidValue("requestTimeout must be positive") }
    if maxRetries < 0 { throw MonicaConfigurationError.invalidValue("maxRetries must not be negative") }
    // An envelope may carry at most 100 items and a batch cannot exceed the
    // queue, so a larger batchSize would only produce envelopes ingest rejects.
    var clamped = self
    clamped.batchSize = min(batchSize, min(maxQueueSize, Self.maxItemsPerEnvelope))
    return ValidatedOptions(dsn: parsedDSN, environment: trimmedEnvironment, options: clamped)
  }
}

/// The options after validation. `Monica` only ever works with this.
struct ValidatedOptions {
  let dsn: DSN
  let environment: String
  let options: MonicaOptions
}

import Foundation

/// Delivers one envelope. Return `true` when ingest accepted it, `false` when
/// it was rejected or could not be delivered after retries.
public protocol MonicaTransport {
  func send(_ envelope: MonicaEnvelope) throws -> Bool
  /// Called once when the client closes. Release sockets and queues here.
  func close()
}

public extension MonicaTransport {
  func close() {}
}

/// Sends envelopes with `URLSession`, gzip-compressed as ingest requires.
///
/// The policy is the one `spec/v1/transport.json` publishes for every MONICA
/// SDK: `202` accepted; `429` waits out `Retry-After`; `5xx` and I/O failures
/// back off with jitter; `401` drops the envelope and stops this transport,
/// because a revoked key will not come back; every other 4xx is dropped rather
/// than retried forever. `413` is dropped too: the client splits envelopes
/// below the published size before they reach the transport, so ingest should
/// never answer it (the contract calls for split-and-retry; see README).
public final class URLSessionTransport: NSObject, MonicaTransport {
  // The constants transport.json fixes. The contract test compares each of
  // them with the vendored copy, so a change on MONICA's side fails a test
  // here instead of drifting.
  static let ingestPath = DSN.ingestPath
  static let contentType = "application/json"
  static let contentEncoding = "gzip"
  static let publicKeyHeader = "X-Monica-Key"
  static let maxRetryAfterSeconds: TimeInterval = 60
  static let backoffBaseMillis = 1_000
  static let backoffFactor = 2
  static let backoffMaxMillis = 30_000
  static let backoffJitterMin = 0.5
  static let backoffJitterMax = 1.0

  private let endpoint: URL
  private let key: String
  private let maxRetries: Int
  private let requestTimeout: TimeInterval
  private let session: URLSession
  private let stateLock = NSLock()
  private var stopped = false
  /// Injected by tests so retries do not really wait.
  var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

  public convenience init(dsn: String, maxRetries: Int = 2, requestTimeout: TimeInterval = 10) throws {
    let parsed = try DSN.parse(dsn)
    if maxRetries < 0 { throw MonicaConfigurationError.invalidValue("maxRetries must not be negative") }
    if requestTimeout <= 0 { throw MonicaConfigurationError.invalidValue("requestTimeout must be positive") }
    self.init(dsn: parsed, maxRetries: maxRetries, requestTimeout: requestTimeout, configuration: .ephemeral)
  }

  init(dsn: DSN, maxRetries: Int, requestTimeout: TimeInterval, configuration: URLSessionConfiguration) {
    endpoint = dsn.endpoint
    key = dsn.publicKey
    self.maxRetries = maxRetries
    self.requestTimeout = requestTimeout
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = requestTimeout
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    let delegate = RedirectRefusingDelegate()
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    super.init()
  }

  deinit {
    session.invalidateAndCancel()
  }

  /// True once ingest has answered `401`: the key is invalid or revoked, and
  /// `transport.json` says to drop and stop. Nothing is sent afterwards; a new
  /// `install()` with a working DSN creates a new transport.
  public var isStopped: Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    return stopped
  }

  /// `URLSession` retains its delegate and queue until invalidated, so waiting
  /// for `deinit` would leak one session per install / close cycle.
  public func close() {
    session.invalidateAndCancel()
  }

  public func send(_ envelope: MonicaEnvelope) throws -> Bool {
    if isStopped { return false }
    let body = try Gzip.compress(try envelope.jsonData())
    for attempt in 0...maxRetries {
      switch perform(body) {
      case .status(let status, let retryAfter):
        if (200..<300).contains(status) { return true }
        if status == 401 {
          stateLock.lock()
          stopped = true
          stateLock.unlock()
          return false
        }
        if status != 429 && status < 500 { return false }
        if attempt == maxRetries { return false }
        sleep(status == 429 ? Self.retryAfter(retryAfter, attempt: attempt) : Self.backoff(attempt))
      case .failure:
        if attempt == maxRetries { return false }
        sleep(Self.backoff(attempt))
      }
    }
    return false
  }

  private enum Outcome {
    case status(Int, retryAfter: String?)
    case failure
  }

  private func perform(_ body: Data) -> Outcome {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = requestTimeout
    request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(Self.contentEncoding, forHTTPHeaderField: "Content-Encoding")
    request.setValue(key, forHTTPHeaderField: Self.publicKeyHeader)

    let done = DispatchSemaphore(value: 0)
    var outcome = Outcome.failure
    let task = session.dataTask(with: request) { _, response, error in
      if error == nil, let http = response as? HTTPURLResponse {
        outcome = .status(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
      }
      done.signal()
    }
    task.resume()
    // The session already enforces the timeout; this is the last line of
    // defence so the sender queue can never hang forever.
    if done.wait(timeout: .now() + requestTimeout * 2 + 1) == .timedOut {
      task.cancel()
      return .failure
    }
    return outcome
  }

  /// `Retry-After` as integer seconds, capped. Anything else (an HTTP-date, a
  /// missing header) falls back to the backoff for this attempt.
  static func retryAfter(_ header: String?, attempt: Int) -> TimeInterval {
    if let header = header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)) {
      return min(max(TimeInterval(seconds), 0), maxRetryAfterSeconds)
    }
    return backoff(attempt)
  }

  /// `min(base * factor^attempt, max)` milliseconds, then a draw between
  /// `jitterMin` and `jitterMax` of that ceiling: the window transport.json
  /// describes, so every SDK backs off at the same pace.
  static func backoff(_ attempt: Int) -> TimeInterval {
    var ceiling = backoffBaseMillis
    for _ in 0..<max(attempt, 0) {
      ceiling *= backoffFactor
      if ceiling >= backoffMaxMillis { break }
    }
    ceiling = min(ceiling, backoffMaxMillis)
    let floor = Int(Double(ceiling) * backoffJitterMin)
    let cap = Int(Double(ceiling) * backoffJitterMax)
    let millis = Int.random(in: floor...cap)
    return TimeInterval(millis) / 1_000
  }
}

/// Ingest never redirects; following one could send the key elsewhere.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

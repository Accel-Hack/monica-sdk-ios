import Foundation

/// Delivers one envelope. Return `true` when ingest accepted it, `false` when
/// it was rejected or could not be delivered after retries.
public protocol MonicaTransport {
  func send(_ envelope: MonicaEnvelope) throws -> Bool
  /// Delivers one envelope and reports what ingest answered.
  ///
  /// ``MonicaClient`` calls this one, so a transport that reads the `4xx` body
  /// can hand back the `422` `issues` instead of collapsing everything into
  /// `false`. Implementing it is optional: the default wraps ``send(_:)``, so a
  /// transport written before this existed keeps working unchanged.
  func deliver(_ envelope: MonicaEnvelope) throws -> MonicaTransportResult
  /// Called once when the client closes. Release sockets and queues here.
  func close()
}

public extension MonicaTransport {
  func deliver(_ envelope: MonicaEnvelope) throws -> MonicaTransportResult {
    MonicaTransportResult(accepted: try send(envelope))
  }

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
///
/// The body of a dropped `4xx` is read as `error.json`, so a `422` reports the
/// `issues` that name the fields ingest refused instead of losing them.
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
  /// `error.json` bodies are a handful of issues. Anything larger is not a
  /// diagnosis, so it is dropped rather than parsed.
  static let maxErrorBodyBytes = 64 * 1024

  private let endpoint: URL
  private let key: String
  private let maxRetries: Int
  private let requestTimeout: TimeInterval
  private let session: URLSession
  private let onDiagnostic: ((MonicaDiagnostic) -> Void)?
  private let stateLock = NSLock()
  private var stopped = false
  /// Injected by tests so retries do not really wait.
  var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

  public convenience init(dsn: String, maxRetries: Int = 2, requestTimeout: TimeInterval = 10,
                          onDiagnostic: ((MonicaDiagnostic) -> Void)? = nil) throws {
    let parsed = try DSN.parse(dsn)
    if maxRetries < 0 { throw MonicaConfigurationError.invalidValue("maxRetries must not be negative") }
    if requestTimeout <= 0 { throw MonicaConfigurationError.invalidValue("requestTimeout must be positive") }
    self.init(dsn: parsed, maxRetries: maxRetries, requestTimeout: requestTimeout, configuration: .ephemeral,
              onDiagnostic: onDiagnostic)
  }

  init(dsn: DSN, maxRetries: Int, requestTimeout: TimeInterval, configuration: URLSessionConfiguration,
       onDiagnostic: ((MonicaDiagnostic) -> Void)? = nil) {
    endpoint = dsn.endpoint
    key = dsn.publicKey
    self.maxRetries = maxRetries
    self.requestTimeout = requestTimeout
    self.onDiagnostic = onDiagnostic
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

  /// True once this transport must not send again: ingest answered `401` (the
  /// key is invalid or revoked, and `transport.json` says to drop and stop) or
  /// `close()` invalidated the session. A new `install()` with a working DSN
  /// creates a new transport.
  public var isStopped: Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    return stopped
  }

  private func stop() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()
  }

  /// `URLSession` retains its delegate and queue until invalidated, so waiting
  /// for `deinit` would leak one session per install / close cycle.
  ///
  /// Stopping first is not a nicety: `URLSession` raises an Objective-C
  /// exception ("Task created in a session that has been invalidated") when a
  /// task is created after `invalidateAndCancel`, and that exception cannot be
  /// caught from Swift. A `flush` that times out leaves the sender queue
  /// draining, so without this flag a retry after `close()` would abort the
  /// application.
  public func close() {
    stop()
    session.invalidateAndCancel()
  }

  public func send(_ envelope: MonicaEnvelope) throws -> Bool {
    try deliver(envelope).accepted
  }

  public func deliver(_ envelope: MonicaEnvelope) throws -> MonicaTransportResult {
    if isStopped { return MonicaTransportResult(accepted: false) }
    let body = try Gzip.compress(try envelope.jsonData())
    for attempt in 0...maxRetries {
      // `close()` can land between two attempts, on another thread.
      if isStopped { return MonicaTransportResult(accepted: false) }
      switch perform(body) {
      case .status(let status, let retryAfter, let responseBody):
        if (200..<300).contains(status) { return MonicaTransportResult(accepted: true, status: status) }
        if status == 401 {
          stop()
          return rejected(status: status, body: responseBody)
        }
        if status != 429 && status < 500 { return rejected(status: status, body: responseBody) }
        if attempt == maxRetries { return MonicaTransportResult(accepted: false, status: status) }
        sleep(status == 429 ? Self.retryAfter(retryAfter, attempt: attempt) : Self.backoff(attempt))
      case .failure:
        if attempt == maxRetries { return MonicaTransportResult(accepted: false) }
        sleep(Self.backoff(attempt))
      }
    }
    return MonicaTransportResult(accepted: false)
  }

  /// A dropped `4xx`, with whatever `error.json` said about it.
  ///
  /// A `422` warns once per envelope: `ingest.md` says to read the `issues` and
  /// fix the payload, and a developer who never sees them cannot. A `401` warns
  /// once too, because it is the last envelope this transport will ever send
  /// and silence looks exactly like "everything is fine". The retry loop cannot
  /// reach here twice for one envelope: a `4xx` other than `429` returns
  /// immediately, and after a `401` `deliver` stops before sending.
  private func rejected(status: Int, body: Data?) -> MonicaTransportResult {
    let parsed = Self.parseErrorBody(body)
    let result = MonicaTransportResult(accepted: false, status: status, errorCode: parsed.code,
                                       errorMessage: parsed.message, issues: parsed.issues)
    if let message = MonicaDiagnostics.message(for: result) {
      let diagnostic = MonicaDiagnostic(message: message, result: result)
      if let onDiagnostic = onDiagnostic { onDiagnostic(diagnostic) } else { MonicaDiagnostics.emit(diagnostic) }
    }
    return result
  }

  /// Reads a body as `error.json`. A body that is empty, oversized, not JSON,
  /// or simply shaped differently is not an error here: the envelope is dropped
  /// exactly as before, with no diagnosis to show. Individual issues whose
  /// `path` or `message` is not a string are skipped for the same reason.
  static func parseErrorBody(_ body: Data?) -> (code: String?, message: String?, issues: [MonicaIssue]) {
    guard let body = body, !body.isEmpty, body.count <= maxErrorBodyBytes,
          let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let error = root["error"] as? [String: Any] else { return (nil, nil, []) }
    var issues: [MonicaIssue] = []
    for raw in (error["issues"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any],
            let path = item["path"] as? String, let message = item["message"] as? String else { continue }
      issues.append(MonicaIssue(path: path, message: message))
    }
    return (error["code"] as? String, error["message"] as? String, issues)
  }

  /// The body worth keeping: a `4xx` that is not a `429`, small enough to be a
  /// diagnosis. Everything else is released here instead of travelling further.
  static func errorBody(_ data: Data?, status: Int) -> Data? {
    guard (400..<500).contains(status), status != 429, let data = data,
          data.count <= maxErrorBodyBytes else { return nil }
    return data
  }

  private enum Outcome {
    case status(Int, retryAfter: String?, body: Data?)
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
    let task = session.dataTask(with: request) { data, response, error in
      if error == nil, let http = response as? HTTPURLResponse {
        outcome = .status(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                          body: Self.errorBody(data, status: http.statusCode))
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

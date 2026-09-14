import Foundation
@testable import Monica
import XCTest
import zlib

/// Scripts HTTP responses without a server. Everything the transport sends is
/// recorded so headers and the gzip body can be checked.
final class StubProtocol: URLProtocol {
  struct Response {
    var status: Int
    var headers: [String: String] = [:]
    /// The response body. Ingest sends `error.json` here on a 4xx.
    var body: Data = Data()
    /// When set, the stub reports a redirect to this URL before the response.
    var redirectTo: URL? = nil
  }

  static var responses: [Response?] = []
  static var requests: [(URLRequest, Data?)] = []
  private static let lock = NSLock()

  static func reset(_ script: [Response?]) {
    lock.lock(); defer { lock.unlock() }
    responses = script
    requests = []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      stream.close()
      return data
    }
    Self.requests.append((request, body))
    let scripted = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
    Self.lock.unlock()
    guard let response = scripted else {
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      return
    }
    let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                               headerFields: response.headers)!
    if let target = response.redirectTo {
      var redirected = URLRequest(url: target)
      redirected.httpMethod = request.httpMethod
      redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: http)
    }
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
  private var sleeps: [TimeInterval] = []
  /// Everything the transport would have written to `os_log`, so the warning
  /// can be asserted on instead of being read by a human in Console.
  private var diagnostics: [MonicaDiagnostic] = []

  /// `capturesDiagnostics: false` leaves `onDiagnostic` nil, which is what an
  /// application gets by default: the warning goes to `os_log` instead.
  private func transport(maxRetries: Int = 2, capturesDiagnostics: Bool = true) throws -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let sink: ((MonicaDiagnostic) -> Void)? = capturesDiagnostics
      ? { [weak self] in self?.diagnostics.append($0) } : nil
    let transport = URLSessionTransport(dsn: try DSN.parse("https://mpk_public@ingest.monica.test:8443/42"),
                                        maxRetries: maxRetries, requestTimeout: 2, configuration: configuration,
                                        onDiagnostic: sink)
    transport.sleep = { [weak self] in self?.sleeps.append($0) }
    return transport
  }

  private func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
  }

  private func envelope() -> MonicaEnvelope {
    MonicaEnvelope(sdkName: "monica-swift", sdkVersion: "0.1.0", sentAt: "2026-09-03T00:00:00.000Z", discarded: 0,
                   items: [MonicaEvent(["type": "error", "message": "boom"])])
  }

  func testPostsAGzippedEnvelopeWithThePublicKeyHeader() throws {
    StubProtocol.reset([.init(status: 202)])
    XCTAssertTrue(try transport().send(envelope()))

    XCTAssertEqual(StubProtocol.requests.count, 1)
    let (request, body) = StubProtocol.requests[0]
    XCTAssertEqual(request.url?.absoluteString, "https://ingest.monica.test:8443/v1/envelope")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Monica-Key"), "mpk_public")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let bytes = try XCTUnwrap(body)
    XCTAssertEqual(bytes[bytes.startIndex], 0x1f)
    XCTAssertEqual(bytes[bytes.startIndex + 1], 0x8b)
    let json = try JSONSerialization.jsonObject(with: gunzip(bytes)) as? [String: Any]
    XCTAssertEqual((json?["sdk"] as? [String: String])?["name"], "monica-swift")
    XCTAssertEqual((json?["items"] as? [[String: Any]])?.first?["message"] as? String, "boom")
  }

  func testDoesNotRetryAClientError() throws {
    StubProtocol.reset([.init(status: 422)])
    XCTAssertFalse(try transport().send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 1)
    XCTAssertTrue(sleeps.isEmpty)
  }

  func testAnUnauthorizedResponseStopsTheTransportForGood() throws {
    // transport.json: 401 is drop_and_stop. A revoked key does not come back,
    // and hammering ingest with it would only earn a 429 for everyone else.
    StubProtocol.reset([.init(status: 401), .init(status: 202)])
    let transport = try transport()
    XCTAssertFalse(transport.isStopped)
    let rejected = try transport.deliver(envelope())
    XCTAssertFalse(rejected.accepted)
    XCTAssertEqual(rejected.status, 401)
    XCTAssertTrue(transport.isStopped)
    XCTAssertFalse(try transport.send(envelope()), "nothing is sent after a 401")
    let afterStop = try transport.deliver(envelope())
    XCTAssertNil(afterStop.status, "no request means no status")
    XCTAssertTrue(afterStop.stopped, "and `stopped` tells that apart from a network failure")
    XCTAssertEqual(StubProtocol.requests.count, 1)
    XCTAssertTrue(sleeps.isEmpty)
    XCTAssertEqual(diagnostics.count, 1, "the transport going quiet for good is worth saying once")
  }

  func testClosingStopsTheTransportBeforeTheSessionIsInvalidated() throws {
    // `URLSession` raises an Objective-C exception ("Task created in a session
    // that has been invalidated") when a task is created after
    // `invalidateAndCancel`, and it cannot be caught from Swift: the process
    // aborts. A `flush` that outlives its timeout leaves the sender queue
    // draining, so a retry can reach `send` after `close()` has run.
    StubProtocol.reset([.init(status: 202)])
    let transport = try transport()
    transport.close()
    XCTAssertTrue(transport.isStopped)
    XCTAssertFalse(try transport.send(envelope()), "nothing is sent after close()")
    XCTAssertEqual(StubProtocol.requests.count, 0, "no task may be created on the invalidated session")
  }

  func testARetryAfterCloseDoesNotTouchTheInvalidatedSession() throws {
    // The failure sequence in full: the first attempt is a 503, and `close()`
    // lands while the transport is backing off.
    StubProtocol.reset([.init(status: 503), .init(status: 202)])
    let transport = try transport()
    transport.sleep = { [weak transport] _ in transport?.close() }
    XCTAssertFalse(try transport.send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 1, "the retry must be abandoned, not sent on a dead session")
  }

  func testRetriesServerErrorsWithBackoffUntilAccepted() throws {
    StubProtocol.reset([.init(status: 503), .init(status: 500), .init(status: 202)])
    XCTAssertTrue(try transport().send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 3)
    XCTAssertEqual(sleeps.count, 2)
    XCTAssertTrue(sleeps[0] >= 0.5 && sleeps[0] <= 1.0, "\(sleeps)")
    XCTAssertTrue(sleeps[1] >= 1.0 && sleeps[1] <= 2.0, "\(sleeps)")
  }

  func testGivesUpAfterMaxRetries() throws {
    StubProtocol.reset([.init(status: 500), .init(status: 500), .init(status: 500), .init(status: 202)])
    XCTAssertFalse(try transport().send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 3)
  }

  func testHonoursRetryAfterOnTooManyRequests() throws {
    StubProtocol.reset([.init(status: 429, headers: ["Retry-After": "3"]), .init(status: 202)])
    XCTAssertTrue(try transport().send(envelope()))
    XCTAssertEqual(sleeps, [3])
  }

  // MARK: 422 issues (spec/v1/error.json, ingest.md)

  func testReportsTheIssuesOfAnUnprocessableEnvelope() throws {
    // ingest.md: a 422 is dropped, and the `issues` name the fields to fix.
    // Losing them is how an integration can send nothing for weeks unnoticed.
    let body = try json([
      "error": [
        "code": "invalid_envelope",
        "message": "envelope failed validation",
        "issues": [
          ["path": "$.items[0].request.method", "message": "Invalid type: Expected string"],
          ["path": "$.items[1].timestamp", "message": "Invalid format"],
        ],
      ],
    ])
    StubProtocol.reset([.init(status: 422, body: body)])

    let result = try transport().deliver(envelope())

    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.status, 422)
    XCTAssertEqual(result.errorCode, "invalid_envelope")
    XCTAssertEqual(result.errorMessage, "envelope failed validation")
    XCTAssertEqual(result.issues, [
      MonicaIssue(path: "$.items[0].request.method", message: "Invalid type: Expected string"),
      MonicaIssue(path: "$.items[1].timestamp", message: "Invalid format"),
    ])
    XCTAssertEqual(diagnostics.count, 1, "one warning per envelope")
    let message = diagnostics[0].message
    XCTAssertEqual(message, "monica: ingest rejected the envelope with 422 (invalid_envelope): 2 issue(s)"
      + "; $.items[0].request.method: Invalid type: Expected string; $.items[1].timestamp: Invalid format")
    XCTAssertEqual(diagnostics[0].result.issues.count, 2)
    XCTAssertEqual(StubProtocol.requests.count, 1, "a 422 is still dropped, not retried")
    XCTAssertTrue(sleeps.isEmpty)
  }

  func testSaysThatA401HasSilencedTheTransport() throws {
    // The same warning path as a 422, with the wording every SDK uses: after a
    // 401 nothing is ever sent again, and silence looks like success.
    StubProtocol.reset([.init(status: 401, body: try json(["error": ["code": "unauthorized",
                                                                    "message": "invalid key"]])),
                        .init(status: 202)])
    let transport = try transport()

    let result = try transport.deliver(envelope())

    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.status, 401)
    XCTAssertTrue(result.stopped)
    XCTAssertEqual(result.errorCode, "unauthorized")
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(diagnostics[0].message,
                   "monica: ingest rejected the envelope with 401 (unauthorized); no further envelopes will be sent")
    XCTAssertEqual(diagnostics[0].result.status, 401)

    // Once only: the stopped transport does not reach ingest again.
    XCTAssertFalse(try transport.send(envelope()))
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(StubProtocol.requests.count, 1)
  }

  func testA401WithoutABodyStillNamesTheStatus() throws {
    StubProtocol.reset([.init(status: 401)])
    XCTAssertFalse(try transport().send(envelope()))
    XCTAssertEqual(diagnostics.map { $0.message },
                   ["monica: ingest rejected the envelope with 401 (unknown); no further envelopes will be sent"])
  }

  func testWarnsOnceEvenWhenTheBodyCarriesNoIssues() throws {
    StubProtocol.reset([.init(status: 422, body: try json(["error": ["code": "invalid_envelope",
                                                                    "message": "nope"]]))])
    XCTAssertFalse(try transport().send(envelope()))
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(diagnostics[0].message,
                   "monica: ingest rejected the envelope with 422 (invalid_envelope): 0 issue(s)")
  }

  func testABodyThatIsNotErrorJSONStillEndsInAPlainDrop() throws {
    var oversized = Data(repeating: UInt8(ascii: "x"), count: 70 * 1024)
    oversized.replaceSubrange(0..<9, with: Data("{\"error\":".utf8))
    let bodies: [Data] = [
      Data(),                                                     // empty
      Data("<html>502</html>".utf8),                              // not JSON
      Data("[1, 2, 3]".utf8),                                     // JSON, wrong root
      try json(["error": "invalid_envelope"]),                    // error is not an object
      try json(["error": ["code": 7, "issues": "many"]]),         // wrong member types
      try json(["error": ["code": "c", "message": "m",
                          "issues": [["path": 1, "message": "m"], ["path": "$.a"], "nonsense"]]]),
      oversized,                                                  // beyond the 64 KiB cap
    ]
    for body in bodies {
      StubProtocol.reset([.init(status: 422, body: body)])
      diagnostics = []
      let result = try transport().deliver(envelope())
      XCTAssertFalse(result.accepted, "\(body.count) bytes")
      XCTAssertEqual(result.status, 422)
      XCTAssertEqual(result.issues, [], "no issue survives a body like this: \(body.count) bytes")
      XCTAssertEqual(diagnostics.count, 1, "the 422 itself is still worth one warning")
      XCTAssertTrue(diagnostics[0].message.hasSuffix("0 issue(s)"), diagnostics[0].message)
      XCTAssertEqual(StubProtocol.requests.count, 1)
      XCTAssertTrue(sleeps.isEmpty)
    }
  }

  func testAnotherClientErrorIsUnchangedAndNotWarnedAbout() throws {
    // 400 is `drop` too, but it carries no field-level issues and does not stop
    // the transport, so there is nothing to warn about: only 422 and 401 do.
    StubProtocol.reset([.init(status: 400, body: try json(["error": ["code": "bad_request",
                                                                     "message": "malformed"]]))])
    let result = try transport().deliver(envelope())
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.status, 400)
    XCTAssertEqual(result.errorCode, "bad_request")
    XCTAssertTrue(diagnostics.isEmpty)
    XCTAssertEqual(StubProtocol.requests.count, 1)
    XCTAssertTrue(sleeps.isEmpty)
  }

  func testTheBodyOfARetriedStatusIsNotRead() throws {
    // 429 and 5xx are retried, so their bodies are not diagnoses. Reading them
    // would also mean warning once per attempt.
    let body = try json(["error": ["code": "rate_limited", "message": "slow down",
                                   "issues": [["path": "$.x", "message": "m"]]]])
    StubProtocol.reset([.init(status: 429, headers: ["Retry-After": "1"], body: body),
                        .init(status: 503, body: body), .init(status: 202)])
    let result = try transport().deliver(envelope())
    XCTAssertTrue(result.accepted)
    XCTAssertEqual(result.status, 202)
    XCTAssertEqual(result.issues, [])
    XCTAssertTrue(diagnostics.isEmpty)
    XCTAssertEqual(StubProtocol.requests.count, 3)
    XCTAssertEqual(sleeps.count, 2)
  }

  func testANetworkFailureLeavesTheStatusUnknown() throws {
    StubProtocol.reset([nil, nil, nil])
    let result = try transport().deliver(envelope())
    XCTAssertFalse(result.accepted)
    XCTAssertNil(result.status, "nothing answered, so there is no status to report")
    XCTAssertFalse(result.stopped, "a failure to reach ingest is not a revoked key")
    XCTAssertTrue(diagnostics.isEmpty)
  }

  func testATransportThatOnlyImplementsSendStillDelivers() throws {
    // The protocol default keeps transports written before `deliver` existed
    // working: accepted is whatever `send` returned, with nothing else to say.
    // Through the existential, so this exercises the protocol witness the way a
    // `MonicaOptions.transport` does, not a statically dispatched extension.
    let recording = RecordingTransport()
    let legacy: MonicaTransport = recording
    let accepted = try legacy.deliver(envelope())
    XCTAssertTrue(accepted.accepted)
    XCTAssertNil(accepted.status)
    XCTAssertEqual(accepted.issues, [])
    XCTAssertFalse(accepted.stopped)
    recording.accept = false
    XCTAssertFalse(try legacy.deliver(envelope()).accepted)
    XCTAssertEqual(recording.envelopes.count, 2)
  }

  // MARK: the default sink

  func testTheDefaultSinkTakesADiagnosticWithoutComplaint() throws {
    // `onDiagnostic` nil means os_log. Nothing here can read the log back, so
    // this only proves the default path runs: the OSLog handle is built, the
    // format string matches its argument, and nothing traps.
    let result = MonicaTransportResult(accepted: false, status: 422, errorCode: "invalid_envelope",
                                       errorMessage: "envelope failed validation",
                                       issues: [MonicaIssue(path: "$.items[0].request.method", message: "Invalid")])
    MonicaDiagnostics.emit(MonicaDiagnostic(message: try XCTUnwrap(MonicaDiagnostics.message(for: result)),
                                            result: result))
    MonicaDiagnostics.emit(MonicaDiagnostic(message: "monica: %@ is not a format substitution", result: result))
    XCTAssertEqual(MonicaDiagnostics.subsystem, "com.accelhack.monica")
    XCTAssertEqual(MonicaDiagnostics.category, "transport")
  }

  func testAnUnprocessableEnvelopeIsStillReportedWithoutADiagnosticHook() throws {
    let body = try json(["error": ["code": "invalid_envelope", "message": "no",
                                   "issues": [["path": "$.items[0].timestamp", "message": "Invalid format"]]]])
    StubProtocol.reset([.init(status: 422, body: body)])

    // Warnings go to os_log here; the result must carry the issues all the same.
    let result = try transport(capturesDiagnostics: false).deliver(envelope())

    XCTAssertFalse(result.accepted)
    XCTAssertEqual(result.issues, [MonicaIssue(path: "$.items[0].timestamp", message: "Invalid format")])
    XCTAssertTrue(diagnostics.isEmpty, "nothing was hooked, so nothing was captured")
  }

  func testAVeryLongIssueListIsTrimmedInTheMessageOnly() throws {
    // os_log truncates a long line, so the message names the first ten and
    // counts the rest. The result keeps every issue.
    let issues = (0..<12).map { ["path": "$.items[\($0)].timestamp", "message": "Invalid format"] }
    StubProtocol.reset([.init(status: 422, body: try json(["error": ["code": "invalid_envelope",
                                                                     "message": "no", "issues": issues]]))])

    let result = try transport().deliver(envelope())

    XCTAssertEqual(result.issues.count, 12)
    let message = try XCTUnwrap(diagnostics.first?.message)
    XCTAssertTrue(message.hasPrefix("monica: ingest rejected the envelope with 422 (invalid_envelope): 12 issue(s)"),
                  message)
    XCTAssertTrue(message.hasSuffix("; $.items[9].timestamp: Invalid format; and 2 more"), message)
    XCTAssertFalse(message.contains("$.items[10]"), message)
  }

  func testCapsRetryAfterAndFallsBackToBackoffWhenUnparseable() {
    XCTAssertEqual(URLSessionTransport.retryAfter("600", attempt: 0), 60)
    XCTAssertEqual(URLSessionTransport.retryAfter("-5", attempt: 0), 0)
    // Integer seconds only (transport.json retry_after.integer_seconds_only):
    // an HTTP-date, a fraction or garbage all fall back to the backoff window.
    for header in ["tomorrow", "Wed, 21 Oct 2026 07:28:00 GMT", "1.5", "nan", "inf", "-inf"] {
      let fallback = URLSessionTransport.retryAfter(header, attempt: 0)
      XCTAssertTrue(fallback >= 0.5 && fallback <= 1.0, "\(header) -> \(fallback)")
    }
    XCTAssertLessThanOrEqual(URLSessionTransport.backoff(9), 30)
  }

  func testNeverFollowsARedirectSoTheKeyStaysWithIngest() throws {
    StubProtocol.reset([.init(status: 302, headers: ["Location": "https://evil.test/v1/envelope"],
                              redirectTo: URL(string: "https://evil.test/v1/envelope")!)])
    XCTAssertFalse(try transport().send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 1)
    XCTAssertEqual(StubProtocol.requests[0].0.url?.host, "ingest.monica.test")
    XCTAssertTrue(sleeps.isEmpty, "a 3xx is final, not retried")
  }

  func testRetriesNetworkFailures() throws {
    StubProtocol.reset([nil, .init(status: 202)])
    XCTAssertTrue(try transport().send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 2)
    XCTAssertEqual(sleeps.count, 1)
  }

  func testZeroRetriesMeansASingleAttempt() throws {
    StubProtocol.reset([.init(status: 500), .init(status: 202)])
    XCTAssertFalse(try transport(maxRetries: 0).send(envelope()))
    XCTAssertEqual(StubProtocol.requests.count, 1)
  }

  private func gunzip(_ input: Data) throws -> Data {
    var stream = z_stream()
    var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    XCTAssertEqual(status, Z_OK)
    defer { inflateEnd(&stream) }
    var output = Data(count: 1 << 16)
    let produced: Int = input.withUnsafeBytes { inputBytes in
      output.withUnsafeMutableBytes { outputBytes in
        stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(outputBytes.count)
        status = inflate(&stream, Z_FINISH)
        return Int(stream.total_out)
      }
    }
    XCTAssertEqual(status, Z_STREAM_END)
    output.count = produced
    return output
  }
}

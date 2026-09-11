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
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
  private var sleeps: [TimeInterval] = []

  private func transport(maxRetries: Int = 2) throws -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let transport = URLSessionTransport(dsn: try DSN.parse("https://mpk_public@ingest.monica.test:8443/42"),
                                        maxRetries: maxRetries, requestTimeout: 2, configuration: configuration)
    transport.sleep = { [weak self] in self?.sleeps.append($0) }
    return transport
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
    XCTAssertFalse(try transport.send(envelope()))
    XCTAssertTrue(transport.isStopped)
    XCTAssertFalse(try transport.send(envelope()), "nothing is sent after a 401")
    XCTAssertEqual(StubProtocol.requests.count, 1)
    XCTAssertTrue(sleeps.isEmpty)
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

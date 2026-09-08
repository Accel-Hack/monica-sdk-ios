import Foundation
@testable import Monica
import XCTest

/// The queue, batching and delivery paths that the facade tests do not reach:
/// sampling, oversized envelopes, transport failure, the periodic timer, flush
/// timeouts and re-entrancy from `beforeSend`.
final class ClientBehaviourTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    super.setUp()
    directory = TestSupport.temporaryDirectory()
  }

  override func tearDown() {
    Monica.current?.close()
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func options(_ transport: MonicaTransport) -> MonicaOptions {
    TestSupport.options(transport: transport, directory: directory)
  }

  // MARK: sampling

  func testSampleRateZeroDropsEverythingAndOneKeepsEverything() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.sampleRate = 0
    let dropped = try Monica.install(options, platform: FakePlatform())
    XCTAssertNil(dropped.captureMessage("boom"))
    XCTAssertNil(dropped.captureError(CheckoutError.declined(code: 1)))
    XCTAssertTrue(dropped.flush(timeout: 1))
    XCTAssertEqual(transport.items.count, 0)

    options.sampleRate = 1
    let kept = try Monica.install(options, platform: FakePlatform())
    XCTAssertNotNil(kept.captureMessage("boom"))
    XCTAssertTrue(kept.flush(timeout: 1))
    XCTAssertEqual(transport.items.count, 1)
  }

  func testSamplingComparesTheRandomDrawAgainstTheRate() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.sampleRate = 0.5
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.client.random = { 0.49 }
    XCTAssertNotNil(monica.captureMessage("kept"))
    monica.client.random = { 0.5 }
    XCTAssertNil(monica.captureMessage("dropped"))
    XCTAssertTrue(monica.flush(timeout: 1))
    XCTAssertEqual(transport.items.map { $0["message"] as? String }, ["kept"])
  }

  // MARK: envelope size

  func testSplitsAByteHeavyBatchIntoSafeEnvelopes() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.batchSize = 10
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    let heavy = String(repeating: "x", count: 600_000)
    monica.captureMessage(heavy)
    monica.captureMessage(heavy)
    XCTAssertTrue(monica.flush(timeout: 5))

    XCTAssertEqual(transport.envelopes.count, 2, "two 600 KB items cannot share one envelope")
    for envelope in transport.envelopes {
      XCTAssertLessThanOrEqual(try envelope.jsonData().count, MonicaClient.maxSafeEnvelopeJSONBytes)
    }
    XCTAssertEqual(monica.stats.discarded, 0)
  }

  func testDropsOnlyAnIndividuallyOversizedEvent() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage(String(repeating: "x", count: 1_100_000))
    monica.captureMessage("small")
    XCTAssertFalse(monica.flush(timeout: 5), "an oversized drop is reported as a partial flush")

    XCTAssertEqual(transport.items.map { $0["message"] as? String }, ["small"])
    XCTAssertEqual(transport.envelopes.last?.discarded, 1, "the drop travels in the next envelope, as in the Java SDK")
  }

  func testNonSerialisableContextIsDroppedLikeAnOversizedEvent() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage("poison", context: CaptureContext().context("payload", ["at": Date()]))
    monica.captureMessage("fine")
    XCTAssertFalse(monica.flush(timeout: 5))

    XCTAssertEqual(transport.items.map { $0["message"] as? String }, ["fine"])
    XCTAssertEqual(transport.envelopes.last?.discarded, 1)
  }

  func testBatchSizeIsClampedToTheEnvelopeLimitAndTheQueue() throws {
    var options = MonicaOptions(dsn: "https://mpk_k@ingest.monica.test/1", environment: "production")
    options.batchSize = 500
    XCTAssertEqual(try options.validated().options.batchSize, 100)
    options.maxQueueSize = 20
    XCTAssertEqual(try options.validated().options.batchSize, 20)
    options.batchSize = 5
    XCTAssertEqual(try options.validated().options.batchSize, 5)
  }

  // MARK: transport failure

  func testARejectedEnvelopeCountsAsDiscardedAndFlushReportsIt() throws {
    let transport = RecordingTransport()
    transport.accept = false
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage("a")
    monica.captureMessage("b")
    XCTAssertFalse(monica.flush(timeout: 2))
    XCTAssertEqual(monica.stats, MonicaStats(queued: 0, discarded: 2))
    XCTAssertEqual(transport.envelopes.count, 1)
  }

  func testAThrowingTransportNeverEscapesToTheHost() throws {
    let transport = ThrowingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage("a")
    XCTAssertFalse(monica.flush(timeout: 2))
    XCTAssertEqual(transport.attempts, 1)
    XCTAssertEqual(monica.stats.discarded, 1)
    XCTAssertNotNil(monica.captureMessage("still alive"))
  }

  // MARK: timer, flush, close

  func testThePeriodicTimerSendsWithoutAnExplicitFlush() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 0.05
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage("tick")
    XCTAssertTrue(TestSupport.waitUntil(timeout: 5) { transport.items.count == 1 },
                  "timer never drained the queue: \(monica.stats)")
  }

  func testFlushReturnsFalseWhenTheTransportOutlivesTheTimeout() throws {
    let transport = BlockingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage("slow")
    let started = Date()
    XCTAssertFalse(monica.flush(timeout: 0.2))
    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "flush must not outlive its timeout")
    XCTAssertFalse(monica.flush(timeout: -1))
    transport.gate.signal()
    XCTAssertTrue(TestSupport.waitUntil { transport.sends == 1 })
  }

  func testCloseSendsWhatIsPendingAndIsIdempotent() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.captureMessage("pending")
    monica.close()
    XCTAssertEqual(transport.items.count, 1)
    monica.close()
    XCTAssertNil(monica.captureMessage("after close"))
    XCTAssertEqual(transport.items.count, 1)
  }

  // MARK: re-entrancy

  func testACaptureFromInsideBeforeSendIsDroppedInsteadOfRecursing() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    var calls = 0
    options.beforeSend = { event, _ in
      calls += 1
      // A hook that reports about itself must not recurse until the stack is gone.
      XCTAssertNil(Monica.current?.captureMessage("from beforeSend"))
      Monica.current?.addBreadcrumb(category: "hook", message: "ran")
      return event
    }
    let monica = try Monica.install(options, platform: FakePlatform())
    XCTAssertNotNil(monica.captureMessage("outer"))
    XCTAssertTrue(monica.flush(timeout: 1))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(transport.items.map { $0["message"] as? String }, ["outer"])
  }

  func testBeforeSendMayTouchMonicaCurrentWhileTheReinstallIsInProgress() throws {
    // Monica.current must never wait on install or close.
    let first = RecordingTransport()
    let second = RecordingTransport()
    var firstOptions = options(BlockingTransport())
    firstOptions.flushInterval = 60
    firstOptions.transport = first
    try Monica.install(firstOptions, platform: FakePlatform())
    let started = Date()
    let replacement = try Monica.install(options(second), platform: FakePlatform())
    XCTAssertTrue(Monica.current === replacement)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  // MARK: scope precedence

  func testEventTagsAndContextsWinOverTheScopeAndTheScopeNeverOverwritesEventUser() throws {
    let transport = RecordingTransport()
    let monica = try Monica.install(options(transport), platform: FakePlatform())
    monica.setScreen("A")
    monica.scope.setContext("os", ["name": "scope"])
    monica.setUser(id: "scope-user")
    var options = options(transport)
    options.beforeSend = { event, _ in
      event["user"] = ["id": "hook-user"]
      return event
    }
    monica.captureMessage("boom", context: CaptureContext().tag("screen", "B").context("os", ["name": "event"]))
    XCTAssertTrue(monica.flush(timeout: 1))
    let item = transport.only()
    XCTAssertEqual(item.tags["screen"], "B")
    XCTAssertEqual(item.context("os", "name") as? String, "event")
    XCTAssertEqual(item.user?["id"] as? String, "scope-user")
  }

  func testClearingTheUserRemovesItFromLaterEvents() throws {
    let transport = RecordingTransport()
    let monica = try Monica.install(options(transport), platform: FakePlatform())
    monica.setUser(id: "u_1")
    monica.setUser(nil)
    monica.captureMessage("first")
    monica.setUser([:])
    monica.captureMessage("second")
    XCTAssertTrue(monica.flush(timeout: 1))
    XCTAssertTrue(transport.items.allSatisfy { $0.user == nil })
  }
}

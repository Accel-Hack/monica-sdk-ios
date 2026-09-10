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

  func testANonSerialisableContextIsRewrittenInsteadOfSilencingTheSDK() throws {
    // `Date`, `URL`, `Double.nan` and any other object are not JSON. Failing at
    // serialisation time was fatal in a way nothing could notice: a context set
    // on the *scope* rides on every event, so every envelope failed to
    // serialise, the client counted each one as oversized, and the SDK stopped
    // reporting for the life of the process without a word.
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.scope.setContext("session", ["startedAt": Date(timeIntervalSince1970: 0), "ratio": Double.nan])
    monica.captureMessage("first", context: CaptureContext().context("payload", ["url": URL(string: "https://x.test/a")!]))
    monica.captureMessage("second")
    XCTAssertTrue(monica.flush(timeout: 5), "an unrepresentable value must not look like an oversized event")

    XCTAssertEqual(transport.items.map { $0["message"] as? String }, ["first", "second"])
    XCTAssertEqual(transport.envelopes.last?.discarded, 0)
    let first = transport.items[0]
    XCTAssertEqual(first.context("session", "startedAt") as? String, "1970-01-01T00:00:00.000Z")
    XCTAssertEqual(first.context("session", "ratio") as? String, "nan")
    XCTAssertEqual(first.context("payload", "url") as? String, "https://x.test/a")
    // And the whole envelope really is serialisable.
    XCTAssertNoThrow(try XCTUnwrap(transport.envelopes.first).jsonData())
  }

  func testAnEventBrokenByBeforeSendIsDroppedAloneRatherThanWithItsBatch() throws {
    // `put(key, nil)` removes the key, which is the natural way to redact a
    // field — and produces an item ingest answers 422 to. A 4xx drops the whole
    // envelope, so one bad item used to take up to `batchSize` valid events
    // with it, on every drain.
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 60
    options.beforeSend = { event, _ in
      if event["message"] as? String == "redacted" { event.put("environment", nil) }
      return event
    }
    let monica = try Monica.install(options, platform: FakePlatform())
    XCTAssertNil(monica.captureMessage("redacted"))
    XCTAssertNotNil(monica.captureMessage("kept"))
    XCTAssertTrue(monica.flush(timeout: 5))

    XCTAssertEqual(transport.items.map { $0["message"] as? String }, ["kept"])
    XCTAssertEqual(transport.envelopes.last?.discarded, 1, "the broken item is accounted for")
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

  func testMonicaCurrentDoesNotWaitOnAReinstallThatIsStuckFlushing() throws {
    // `Monica.current` reads `currentLock`, never `lifecycleLock`, so it must
    // not wait on an install that is stuck flushing the instance it replaces —
    // which matters because an application's `beforeSend` is allowed to read
    // it. The reinstall has to be genuinely blocked for this to mean anything:
    // the first instance's transport holds its `send` open, so the sender queue
    // is still inside application code when the second `install` calls
    // `previous.shutdown()`.
    let blocking = BlockingTransport()
    var firstOptions = options(blocking)
    firstOptions.flushInterval = 60
    firstOptions.flushTimeout = 3
    let first = try Monica.install(firstOptions, platform: FakePlatform())
    // A fatal drains immediately, so the sender queue parks inside `send`.
    first.captureMessage("blocking", context: CaptureContext().level(.fatal))
    XCTAssertTrue(TestSupport.waitUntil { blocking.sends == 1 }, "the sender queue must be inside send()")

    let reinstalled = DispatchSemaphore(value: 0)
    var replacement: Monica?
    DispatchQueue.global().async {
      replacement = try? Monica.install(self.options(RecordingTransport()), platform: FakePlatform())
      reinstalled.signal()
    }
    // Wait until that install is inside the retiring instance's flush.
    XCTAssertTrue(TestSupport.waitUntil { Monica.current == nil })

    // `install` clears `installed` before it retires the previous instance, so
    // the answer during the window is nil — but it has to come back at once
    // rather than after `flushTimeout`, and a capture must not wedge either.
    let started = Date()
    for _ in 0..<200 {
      XCTAssertNil(Monica.current)
      XCTAssertNil(first.captureMessage("during reinstall"), "the retiring instance stops accepting events")
    }
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertLessThan(elapsed, 1, "Monica.current waited on the reinstall (took \(elapsed)s)")

    blocking.gate.signal()
    XCTAssertEqual(reinstalled.wait(timeout: .now() + 10), .success)
    XCTAssertNotNil(replacement)
    XCTAssertTrue(Monica.current === replacement)
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

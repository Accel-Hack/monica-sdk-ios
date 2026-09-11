import Foundation
import Monica
import XCTest

final class MonicaTests: XCTestCase {
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

  func testAttachesDeviceOsAndAppContextWithoutIdentifyingTheInstall() throws {
    let transport = RecordingTransport()
    let monica = try Monica.install(options(transport), platform: FakePlatform())

    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 1))

    let item = transport.only()
    XCTAssertEqual(item["platform"] as? String, "swift")
    XCTAssertEqual(item["release"] as? String, "2.3.1")
    XCTAssertEqual(item["environment"] as? String, "test")
    XCTAssertEqual(transport.envelopes[0].sdk["name"], "monica-swift")
    XCTAssertEqual(item.context("device", "model") as? String, "iPhone15,2")
    XCTAssertEqual(item.context("device", "manufacturer") as? String, "Apple")
    XCTAssertEqual(item.context("os", "name") as? String, "iOS")
    XCTAssertEqual(item.context("os", "version") as? String, "17.4.1")
    XCTAssertEqual(item.context("app", "app_identifier") as? String, "com.example.app")
    XCTAssertEqual(item.context("app", "app_build") as? String, "231")
    XCTAssertNil(item.user)
  }

  func testMarksOnlyTheApplicationsOwnImageAsInApp() throws {
    let transport = RecordingTransport()
    let monica = try Monica.install(options(transport), platform: FakePlatform())

    monica.captureError(CheckoutError.declined(code: 402))
    XCTAssertTrue(monica.flush(timeout: 1))

    let frames = transport.only().frames
    XCTAssertFalse(frames.isEmpty)
    // The default in_app image is the executable the platform reports
    // (ExampleApp), which nothing in this process belongs to.
    XCTAssertTrue(frames.allSatisfy { ($0["in_app"] as? Bool) == false })
    XCTAssertTrue((frames.last?["function"] as? String)?.contains("testMarksOnlyTheApplicationsOwnImageAsInApp") == true,
                  "frames run oldest caller to newest, so the capture site is last: \(frames.last ?? [:])")
  }

  func testHonoursAnExplicitInAppModuleOverTheDetectedOne() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.inAppModules = [TestSupport.testImageName]
    let monica = try Monica.install(options, platform: FakePlatform())

    monica.captureError(CheckoutError.declined(code: 402))
    XCTAssertTrue(monica.flush(timeout: 1))

    let frames = transport.only().frames
    let inApp = frames.filter { ($0["in_app"] as? Bool) == true }
    XCTAssertFalse(inApp.isEmpty)
    XCTAssertTrue(inApp.allSatisfy { ($0["filename"] as? String)?.hasPrefix(TestSupport.testImageName + "/") == true },
                  "\(inApp.compactMap { $0["filename"] })")
    XCTAssertEqual(frames.last?["filename"] as? String, "\(TestSupport.testImageName)/MonicaTests.swift")
  }

  func testRecordsLifecycleTransitionsAndScreensAsBreadcrumbsAndATag() throws {
    let transport = RecordingTransport()
    let platform = FakePlatform()
    var options = options(transport)
    options.trackAppLifecycle = true
    let monica = try Monica.install(options, platform: platform)
    XCTAssertTrue(platform.tracking)

    platform.emit("active")
    monica.setScreen("CheckoutViewController")
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 1))

    let item = transport.only()
    XCTAssertEqual(item.tags["screen"], "CheckoutViewController")
    XCTAssertEqual(item.breadcrumbs.count, 2)
    XCTAssertEqual(item.breadcrumbs[0]["category"] as? String, "app.lifecycle")
    XCTAssertEqual(item.breadcrumbs[0]["message"] as? String, "active")
    XCTAssertEqual(item.breadcrumbs[1]["category"] as? String, "ui.lifecycle")
    XCTAssertEqual(item.breadcrumbs[1]["message"] as? String, "CheckoutViewController.appeared")
  }

  func testKeepsOnlyTheMostRecentBreadcrumbs() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.maxBreadcrumbs = 3
    let monica = try Monica.install(options, platform: FakePlatform())

    for index in 0..<10 { monica.addBreadcrumb(category: "ui.click", message: "tap-\(index)") }
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 1))

    let breadcrumbs = transport.only().breadcrumbs
    XCTAssertEqual(breadcrumbs.count, 3)
    XCTAssertEqual(breadcrumbs[0]["message"] as? String, "tap-7")
  }

  func testSendsNothingAboutTheUserUntilTheApplicationSaysSo() throws {
    let transport = RecordingTransport()
    let monica = try Monica.install(options(transport), platform: FakePlatform())

    monica.setUser(id: "u_123")
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 1))

    XCTAssertEqual(transport.only().user?["id"] as? String, "u_123")
  }

  func testAppliesCaptureContextOnTopOfTheScope() throws {
    let transport = RecordingTransport()
    let monica = try Monica.install(options(transport), platform: FakePlatform())

    monica.captureError(CheckoutError.declined(code: 402), context: CaptureContext().tag("feature", "checkout").level(.warning))
    XCTAssertTrue(monica.flush(timeout: 1))

    let item = transport.only()
    XCTAssertEqual(item.tags["feature"], "checkout")
    XCTAssertEqual(item["level"] as? String, "warning")
    XCTAssertEqual(item.exceptionValues.first?["type"] as? String, "MonicaTests.CheckoutError")
    XCTAssertEqual(item.mechanism["handled"] as? Bool, true)
  }

  func testBeforeSendGetsTheLastWord() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    var seen: [String] = []
    options.beforeSend = { event, hint in
      seen.append(event["message"] as? String ?? "")
      if hint.originalError != nil { return nil }
      event["user"] = nil
      return event
    }
    let monica = try Monica.install(options, platform: FakePlatform())
    monica.setUser(id: "u_123")

    XCTAssertNil(monica.captureError(CheckoutError.declined(code: 402)))
    XCTAssertNotNil(monica.captureMessage("kept"))
    XCTAssertTrue(monica.flush(timeout: 1))

    XCTAssertEqual(seen.count, 2)
    let item = transport.only()
    XCTAssertEqual(item["message"] as? String, "kept")
    XCTAssertNil(item.user)
  }

  func testASecondInstallReplacesTheFirst() throws {
    let first = RecordingTransport()
    let second = RecordingTransport()
    let platform = FakePlatform()
    var firstOptions = options(first)
    firstOptions.trackAppLifecycle = true

    try Monica.install(firstOptions, platform: platform)
    var secondOptions = options(second)
    secondOptions.trackAppLifecycle = true
    let replacement = try Monica.install(secondOptions, platform: platform)

    XCTAssertTrue(Monica.current === replacement)
    replacement.captureMessage("boom")
    XCTAssertTrue(replacement.flush(timeout: 1))
    XCTAssertEqual(first.items.count, 0)
    XCTAssertEqual(second.items.count, 1)
  }

  func testACaptureAfterCloseIsDropped() throws {
    let transport = RecordingTransport()
    let platform = FakePlatform()
    var options = options(transport)
    options.trackAppLifecycle = true
    let monica = try Monica.install(options, platform: platform)
    monica.close()

    XCTAssertNil(Monica.current)
    XCTAssertFalse(platform.tracking)
    XCTAssertNil(monica.captureMessage("boom"))
    XCTAssertEqual(transport.items.count, 0)
  }

  func testAFatalEventIsSentWithoutWaitingForTheFlushInterval() throws {
    let transport = RecordingTransport()
    var options = options(transport)
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())

    monica.captureError(CheckoutError.declined(code: 402), context: CaptureContext().level(.fatal).handled(false))

    XCTAssertTrue(TestSupport.waitUntil { transport.items.count == 1 })
    XCTAssertEqual(transport.only()["level"] as? String, "fatal")
    XCTAssertEqual(transport.only().mechanism["handled"] as? Bool, false)
  }

  func testDropsTheOldestEventWhenTheQueueIsFullAndReportsIt() throws {
    // batchSize is clamped to maxQueueSize, so a full queue is sent at once;
    // hold the sender on that first envelope to make the queue fill up behind it.
    let transport = BlockingTransport()
    var options = options(transport)
    options.maxQueueSize = 2
    options.flushInterval = 60
    let monica = try Monica.install(options, platform: FakePlatform())

    monica.captureMessage("m0")
    monica.captureMessage("m1")
    XCTAssertTrue(TestSupport.waitUntil { transport.sends == 1 })
    for index in 2..<5 { monica.captureMessage("m\(index)") }
    XCTAssertEqual(monica.stats, MonicaStats(queued: 2, discarded: 1))

    transport.gate.signal()
    transport.gate.signal()
    XCTAssertTrue(monica.flush(timeout: 2))
    XCTAssertEqual(transport.envelopes.count, 2)
    XCTAssertEqual(transport.envelopes[1].discarded, 1)
    XCTAssertEqual(transport.envelopes[1].items.map { $0["message"] as? String }, ["m3", "m4"])
  }

  func testRejectsASecretKeyAtInstallTime() {
    let transport = RecordingTransport()
    var options = options(transport)
    options.dsn = "https://msk_secret@ingest.monica.test/1"
    XCTAssertThrowsError(try Monica.install(options, platform: FakePlatform())) { error in
      XCTAssertEqual(error as? MonicaConfigurationError, .secretKeyInDSN)
    }
    XCTAssertNil(Monica.current)
  }
}

enum CheckoutError: Error {
  case declined(code: Int)
}

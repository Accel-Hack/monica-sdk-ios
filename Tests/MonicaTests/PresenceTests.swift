import Foundation
@testable import Monica
import XCTest

/// The `client_report` heartbeat: `start` at launch and on returning to the
/// foreground, `interval` from the flush timer, and only when no envelope has
/// been accepted for an interval.
final class PresenceTests: XCTestCase {
  private let interval = TimeInterval(MonicaClient.presenceIntervalMillis) / 1_000
  private var directory: URL!
  private var clock = Date()

  override func setUp() {
    super.setUp()
    directory = TestSupport.temporaryDirectory()
  }

  override func tearDown() {
    Monica.current?.close()
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  /// Installs, waits for the launch check, then hands the clock to the test.
  private func install(_ transport: RecordingTransport, _ platform: FakePlatform) throws -> Monica {
    var options = TestSupport.options(transport: transport, directory: directory)
    options.flushInterval = 3_600
    let monica = try Monica.install(options, platform: platform)
    XCTAssertTrue(monica.flush(timeout: 2))
    clock = Date()
    monica.client.now = { [unowned self] in self.clock }
    return monica
  }

  private func reports(_ transport: RecordingTransport) -> [String] {
    transport.items.filter { $0["type"] as? String == "client_report" }.compactMap { $0["trigger"] as? String }
  }

  func testInstallSendsAStartReportInAnEnvelopeOfItsOwn() throws {
    let transport = RecordingTransport()
    let monica = try install(transport, FakePlatform().forgetPresence())
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 2))

    XCTAssertEqual(transport.envelopes.map { $0.items.count }, [1, 1])
    let report = transport.envelopes[0].items[0].values
    XCTAssertEqual(report["type"] as? String, "client_report")
    XCTAssertEqual(report["trigger"] as? String, "start")
    XCTAssertEqual(report["platform"] as? String, "swift")
    XCTAssertEqual(report["environment"] as? String, "test")
    XCTAssertEqual(report["release"] as? String, "2.3.1")
    XCTAssertEqual(transport.envelopes[0].sdk, ["name": Monica.sdkName, "version": Monica.sdkVersion])
    XCTAssertEqual(transport.envelopes[1].items[0]["type"] as? String, "error")
  }

  func testAnIntervalReportOnlyAfterAnIntervalOfSilenceAndOnlyOnce() throws {
    let transport = RecordingTransport()
    let monica = try install(transport, FakePlatform().forgetPresence())
    XCTAssertEqual(reports(transport), ["start"])

    clock += interval - 1
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start"], "the 202 of the start report is less than an interval old")
    clock += 2
    monica.client.tick()
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start", "interval"])
  }

  func testAnAcceptedErrorEnvelopePushesTheDeadlineBack() throws {
    let transport = RecordingTransport()
    let monica = try install(transport, FakePlatform().forgetPresence())
    clock += interval / 2
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 2))

    clock += interval / 2 + 1
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start"])
    clock += interval / 2
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start", "interval"])
  }

  func testQueuedEventsAreSentInsteadAndAFailedReportWaitsForTheNextInterval() throws {
    let transport = RecordingTransport()
    let monica = try install(transport, FakePlatform().forgetPresence())
    transport.accept = false
    monica.captureMessage("queued")
    clock += interval + 1
    monica.client.tick()
    XCTAssertEqual(transport.items.map { $0["type"] as? String }, ["client_report", "error"],
                   "a tick with a queued event drains it and sends no report")

    monica.client.tick()
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start", "interval"], "a failed report is not retried on every tick")
    clock += interval
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start", "interval", "interval"])
  }

  func testThePresenceHeadersOfA202DecideTheNextCheck() throws {
    let transport = RecordingTransport()
    let platform = FakePlatform().forgetPresence()
    transport.presenceIntervalMs = "120000"
    transport.presenceSampleRate = "0.4"
    let monica = try install(transport, platform)
    XCTAssertEqual(platform.defaults.integer(forKey: MonicaClient.presenceIntervalKey), 120_000)
    XCTAssertEqual(platform.defaults.double(forKey: MonicaClient.presenceSampleRateKey), 0.4)

    // Malformed headers are ignored one by one; missing ones keep what is stored.
    for (intervalMs, rate) in [("1e5", "5e-1"), ("59999", "0.001"), ("120000.5", "1.5"), ("abc", "-0.5"),
                               ("", "")] {
      transport.presenceIntervalMs = intervalMs
      transport.presenceSampleRate = rate
      monica.captureMessage("boom")
      XCTAssertTrue(monica.flush(timeout: 2))
    }
    transport.presenceIntervalMs = nil
    transport.presenceSampleRate = nil
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 2))
    XCTAssertEqual(platform.defaults.integer(forKey: MonicaClient.presenceIntervalKey), 120_000)
    XCTAssertEqual(platform.defaults.double(forKey: MonicaClient.presenceSampleRateKey), 0.4)

    // Two minutes, not a day; and a draw at or above the rate thins the report out.
    clock += 121
    monica.client.random = { 0.4 }
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start"], "sampled out")
    clock += 121
    monica.client.random = { 0.39 }
    monica.client.tick()
    XCTAssertEqual(reports(transport), ["start", "interval"])

    transport.presenceIntervalMs = "60000"
    transport.presenceSampleRate = "1"
    clock += 121
    monica.client.tick()
    XCTAssertEqual(platform.defaults.integer(forKey: MonicaClient.presenceIntervalKey), 60_000, "the lower bound is valid")
    XCTAssertEqual(platform.defaults.double(forKey: MonicaClient.presenceSampleRateKey), 1)
  }

  func testARelaunchOrAReturnToTheForegroundWithinTheIntervalSendsNothing() throws {
    let transport = RecordingTransport()
    let platform = FakePlatform().forgetPresence()
    var options = TestSupport.options(transport: transport, directory: directory)
    options.flushInterval = 3_600
    XCTAssertTrue(try Monica.install(options, platform: platform).flush(timeout: 2))
    let relaunched = try Monica.install(options, platform: platform)
    platform.emit("foreground")
    platform.emit("active")
    XCTAssertTrue(relaunched.flush(timeout: 2))
    XCTAssertEqual(reports(transport), ["start"], "UserDefaults remembers the 202 across launches")

    platform.defaults.set(Date() - interval - 1, forKey: MonicaClient.lastAcceptedAtKey)
    platform.emit("foreground")
    XCTAssertTrue(relaunched.flush(timeout: 2))
    XCTAssertEqual(reports(transport), ["start", "start"], "the foreground check is a start report")
    XCTAssertTrue(platform.tracking, "subscribed although trackAppLifecycle is false")
    XCTAssertTrue(relaunched.scope.snapshot().breadcrumbs.isEmpty, "trackAppLifecycle still decides the breadcrumbs")
  }
}

import Foundation
import MonicaCrashHandler
@testable import Monica
import XCTest

private var previousHandlerCalls = 0
private let noopHandler: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { _, _, _ in
  previousHandlerCalls += 1
}

/// Exercises the C handler in-process. A signal sent with raise(2) is not a
/// fault, so once the handler has chained to the (no-op) previous handler the
/// test simply continues.
final class CrashHandlerTests: XCTestCase {
  private var directory: URL!
  private var reportPath: String { directory.appendingPathComponent("pending-crash.bin").path }

  override func setUp() {
    super.setUp()
    directory = TestSupport.temporaryDirectory()
    monica_crash_reset_for_testing()
    previousHandlerCalls = 0
  }

  override func tearDown() {
    monica_crash_uninstall()
    monica_crash_reset_for_testing()
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func isNoopHandler(_ action: sigaction) -> Bool {
    unsafeBitCast(action.__sigaction_u.__sa_sigaction, to: UnsafeRawPointer?.self)
      == unsafeBitCast(noopHandler, to: UnsafeRawPointer?.self)
  }

  private func installNoopHandler(for signal: Int32) -> sigaction {
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = noopHandler
    action.sa_flags = SA_SIGINFO
    sigemptyset(&action.sa_mask)
    var previous = sigaction()
    sigaction(signal, &action, &previous)
    return previous
  }

  func testWritesAReportForASignalThenHandsTheSignalToThePreviousHandler() throws {
    let original = installNoopHandler(for: SIGSEGV)
    defer { var restore = original; sigaction(SIGSEGV, &restore, nil) }

    XCTAssertTrue(monica_crash_install(reportPath))
    raise(SIGSEGV)

    XCTAssertEqual(previousHandlerCalls, 1)
    // The noop handler returned, so the process survived and the handler
    // re-armed itself: a later crash is still capturable. In a real crash the
    // previous disposition is SIG_DFL, which does not return.
    XCTAssertFalse(monica_crash_has_reported())
    let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
    let report = try XCTUnwrap(CrashReport.parse(data))
    XCTAssertEqual(report.kind, .signal)
    XCTAssertEqual(report.signal, SIGSEGV)
    XCTAssertFalse(report.frames.isEmpty)
    XCTAssertFalse(report.images.isEmpty)
    XCTAssertLessThan(abs(report.timestamp.timeIntervalSinceNow), 5)

    // The previous handler was called with the disposition restored — that is
    // what `previousHandlerCalls` proves — and then this handler took SIGSEGV
    // back, because control returning means the process is still alive.
    var current = sigaction()
    sigaction(SIGSEGV, nil, &current)
    XCTAssertFalse(isNoopHandler(current), "the handler must be back in place for the next crash")

    // Frames symbolicate against this very process.
    let frames = CrashReporter.frames(for: report, inAppModules: [TestSupport.testImageName])
    XCTAssertTrue(frames.contains { ($0["function"] as? String)?.contains("CrashHandlerTests") == true },
                  "expected a test frame in \(frames.compactMap { $0["function"] })")
    XCTAssertTrue(frames.contains { ($0["in_app"] as? Bool) == true })
  }

  func testASecondSignalDoesNotOverwriteTheFirstReport() throws {
    let original = installNoopHandler(for: SIGSEGV)
    let originalBus = installNoopHandler(for: SIGBUS)
    defer {
      var restore = original; sigaction(SIGSEGV, &restore, nil)
      var restoreBus = originalBus; sigaction(SIGBUS, &restoreBus, nil)
    }
    XCTAssertTrue(monica_crash_install(reportPath))

    raise(SIGSEGV)
    let first = try Data(contentsOf: URL(fileURLWithPath: reportPath))
    XCTAssertEqual(CrashReport.parse(first)?.signal, SIGSEGV)
    raise(SIGBUS)
    let second = try Data(contentsOf: URL(fileURLWithPath: reportPath))

    // The chained handler returned both times, so the process survived both
    // signals. A survived signal is not the crash worth keeping: the handler
    // re-arms and the next signal is reported afresh. Leaving the first report
    // in place instead — which is what this used to assert — meant the first
    // delivery of any of the six signals was the last one that could ever be
    // reported, even in a process that went on living.
    XCTAssertEqual(CrashReport.parse(second)?.signal, SIGBUS)
    XCTAssertEqual(previousHandlerCalls, 2)
  }

  func testAReportWrittenByTheExceptionHandlerSurvivesALaterSignal() throws {
    // The NSException handler writes its report and then abort()s. The SIGABRT
    // that follows must not replace it, whatever the previous disposition does.
    var ignore = sigaction()
    ignore.__sigaction_u.__sa_handler = SIG_IGN
    sigemptyset(&ignore.sa_mask)
    var original = sigaction()
    sigaction(SIGABRT, &ignore, &original)
    defer { sigaction(SIGABRT, &original, nil) }

    XCTAssertTrue(monica_crash_install(reportPath))
    monica_crash_record_exception("NSRangeException", "index 5 beyond bounds", nil, 0)
    raise(SIGABRT)

    let report = try XCTUnwrap(CrashReport.parse(try Data(contentsOf: URL(fileURLWithPath: reportPath))))
    XCTAssertEqual(report.kind, .exception)
    XCTAssertEqual(report.name, "NSRangeException")
  }

  func testRecordsAnExceptionWithNameReasonAndTheGivenAddresses() throws {
    XCTAssertTrue(monica_crash_install(reportPath))
    let addresses = Thread.callStackReturnAddresses.map { UInt64(truncatingIfNeeded: $0.uintValue) }
    addresses.withUnsafeBufferPointer {
      monica_crash_record_exception("NSRangeException", "index 5 beyond bounds", $0.baseAddress, UInt32($0.count))
    }

    let report = try XCTUnwrap(CrashReport.parse(try Data(contentsOf: URL(fileURLWithPath: reportPath))))
    XCTAssertEqual(report.kind, .exception)
    XCTAssertEqual(report.name, "NSRangeException")
    XCTAssertEqual(report.reason, "index 5 beyond bounds")
    XCTAssertEqual(report.frames, addresses)

    let event = CrashReporter.event(from: report, session: ["release": "1.2.3", "environment": "production",
                                                            "tags": ["screen": "Checkout"], "user": ["id": "u_1"]],
                                    fallbackEnvironment: "test", fallbackRelease: nil, fallbackContexts: [:],
                                    inAppModules: [TestSupport.testImageName])
    XCTAssertEqual(event["level"] as? String, "fatal")
    XCTAssertEqual(event["release"] as? String, "1.2.3")
    XCTAssertEqual(event["environment"] as? String, "production")
    XCTAssertEqual(event.tags["screen"], "Checkout")
    XCTAssertEqual(event.tags["crash.reported_at"], "next_launch")
    XCTAssertEqual(event.user?["id"] as? String, "u_1")
    XCTAssertEqual(event.exceptionValues.first?["type"] as? String, "NSRangeException")
    XCTAssertEqual(event.mechanism["handled"] as? Bool, false)
    XCTAssertTrue(event.frames.contains { ($0["function"] as? String)?.contains("CrashHandlerTests") == true })
  }

  func testUninstallRestoresEveryDisposition() {
    let original = installNoopHandler(for: SIGTRAP)
    defer { var restore = original; sigaction(SIGTRAP, &restore, nil) }
    XCTAssertTrue(monica_crash_install(reportPath))
    monica_crash_uninstall()

    var current = sigaction()
    sigaction(SIGTRAP, nil, &current)
    XCTAssertTrue(isNoopHandler(current))
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportPath))
  }

  func testRejectsAReportItCannotParse() {
    XCTAssertNil(CrashReport.parse(Data("not a report".utf8)))
    XCTAssertNil(CrashReport.parse(Data()))
  }

  func testRejectsCountsTheWriterCouldNeverProduceInsteadOfMisreadingTheFile() {
    XCTAssertNil(CrashReport.parse(ReportBytes(frames: Array(repeating: 1, count: 129)).data()),
                 "more frames than MONICA_CRASH_MAX_FRAMES means a corrupt file, not a longer one")
    XCTAssertNil(CrashReport.parse(ReportBytes(imageCount: 1025).data()))
    XCTAssertNil(CrashReport.parse(ReportBytes(version: 2).data()), "a future format is not guessed at")
    XCTAssertNil(CrashReport.parse(ReportBytes(kind: 7).data()))
    var truncated = ReportBytes(frames: [1, 2, 3]).data()
    truncated.removeLast(10)
    XCTAssertNil(CrashReport.parse(truncated))
    let report = CrashReport.parse(ReportBytes(frames: [0x10, 0x20], uuid: [UInt8](repeating: 0, count: 16)).data())
    XCTAssertEqual(report?.frames, [0x10, 0x20])
    XCTAssertNil(report?.images.first?.uuid, "an all-zero UUID means the image had none")
  }

  func testUUIDStringUsesTheCanonicalUppercaseForm() {
    XCTAssertEqual(CrashReport.uuidString([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]),
                   "01234567-89AB-CDEF-0123-456789ABCDEF")
  }

  func testChainsToAPreviousSigIgnWithoutCallingAddressOne() throws {
    // A reused sigaction with SA_SIGINFO still set and SIG_IGN as the handler:
    // the union makes sa_sigaction == (void *)1, which must never be called.
    var ignore = sigaction()
    ignore.__sigaction_u.__sa_handler = SIG_IGN
    ignore.sa_flags = SA_SIGINFO
    sigemptyset(&ignore.sa_mask)
    var original = sigaction()
    sigaction(SIGSEGV, &ignore, &original)
    defer { sigaction(SIGSEGV, &original, nil) }

    XCTAssertTrue(monica_crash_install(reportPath))
    raise(SIGSEGV)  // ignored afterwards, so the test process survives

    // A previous disposition of SIG_IGN means the signal is survivable by
    // definition, so the report describes a crash that is not happening: it is
    // thrown away and the handler takes SIGSEGV back. Keeping it — which is
    // what this used to assert — sent a `level: fatal` event on the next launch
    // for a process that never died, and left crash capture disarmed for good.
    XCTAssertFalse(monica_crash_has_reported())
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportPath))

    var current = sigaction()
    XCTAssertEqual(sigaction(SIGSEGV, nil, &current), 0)
    XCTAssertNotEqual(unsafeBitCast(current.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self),
                      unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self),
                      "the handler must be back in place for the next crash")
  }

  func testInstallsEverySignalItPromisesAndRemovesThemAll() {
    let signals = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
    var originals: [Int32: sigaction] = [:]
    for signal in signals {
      var current = sigaction()
      sigaction(signal, nil, &current)
      originals[signal] = current
    }
    defer { for signal in signals { var restore = originals[signal]!; sigaction(signal, &restore, nil) } }

    XCTAssertTrue(monica_crash_install(reportPath))
    var handlers = Set<UInt>()
    for signal in signals {
      var current = sigaction()
      sigaction(signal, nil, &current)
      XCTAssertNotEqual(current.sa_flags & SA_SIGINFO, 0, "SIG\(signal) should carry the SDK handler")
      handlers.insert(UInt(bitPattern: unsafeBitCast(current.__sigaction_u.__sa_sigaction, to: Int.self)))
    }
    XCTAssertEqual(handlers.count, 1, "the same handler serves every signal")

    monica_crash_uninstall()
    for signal in signals {
      var current = sigaction()
      sigaction(signal, nil, &current)
      XCTAssertEqual(unsafeBitCast(current.__sigaction_u.__sa_sigaction, to: Int.self),
                     unsafeBitCast(originals[signal]!.__sigaction_u.__sa_sigaction, to: Int.self))
    }
  }

  func testSymbolicatesAgainstARelocatedImageOnlyWhenTheUUIDMatches() throws {
    // Take a real image of this process and pretend it was loaded 64 KB lower
    // at crash time; addresses must be rebased before dladdr.
    let current = CrashReporter.currentImages()
    let addresses = Thread.callStackReturnAddresses.map { UInt($0.uintValue) }
    let live = try XCTUnwrap(StackFrames.symbolicate(addresses[0] &- 1))
    let (uuid, currentLoad) = try XCTUnwrap(current.first { $0.value == UInt64(live.imageAddress) })
    let slide: UInt64 = 0x10000
    let path = try XCTUnwrap(live.imagePath)
    func report(uuid: String) -> CrashReport {
      CrashReport(kind: .signal, signal: SIGTRAP, code: 0, faultAddress: 0, timestamp: Date(),
                  frames: [UInt64(addresses[0]) - slide, UInt64(addresses[1]) - slide],
                  images: [.init(loadAddress: currentLoad - slide, uuid: uuid, path: path)], name: nil, reason: nil)
    }
    let module = StackFrames.moduleName(ofImagePath: path)

    let matched = CrashReporter.frames(for: report(uuid: uuid), inAppModules: [module], currentImages: current)
    XCTAssertEqual(matched.count, 2)
    XCTAssertNotNil(matched[1]["function"], "\(matched)")
    XCTAssertEqual(matched[1]["image_addr"] as? String, StackFrames.hex(UInt(currentLoad - slide)),
                   "addresses are reported as they were at crash time")
    XCTAssertTrue((matched[1]["symbol_addr"] as? String)?.hasPrefix("0x") == true)

    let mismatched = CrashReporter.frames(for: report(uuid: "00000000-0000-0000-0000-00000000DEAD"),
                                          inAppModules: [module], currentImages: current)
    XCTAssertNil(mismatched[1]["function"], "a different build must not borrow this build's symbols")
    XCTAssertEqual(mismatched[1]["filename"] as? String, module)
    XCTAssertEqual(mismatched[1]["in_app"] as? Bool, true)
  }

  func testAFrameBelowEveryImageIsUnknownButStillWellFormed() {
    let report = CrashReport(kind: .signal, signal: SIGSEGV, code: 1, faultAddress: 0, timestamp: Date(),
                             frames: [0x10, 0x1000_0100],
                             images: [.init(loadAddress: 0x1000_0000, uuid: nil, path: "/x/MyApp.app/MyApp")],
                             name: nil, reason: nil)
    let frames = CrashReporter.frames(for: report, inAppModules: ["MyApp"], currentImages: [:])
    let unknown = frames[1]
    XCTAssertEqual(unknown["filename"] as? String, "unknown")
    XCTAssertEqual(unknown["in_app"] as? Bool, false)
    XCTAssertNil(unknown["image_addr"])
    XCTAssertEqual(unknown["instruction_addr"] as? String, "0x10")
  }

  func testExceptionFramesAreAllReturnAddressesUnlikeASignalReportsFirstFrame() throws {
    // Both reports point at the first byte of a symbol. For a signal that is
    // the pc and names that symbol; for an NSException it is a return address
    // and names the call site one byte before.
    let current = CrashReporter.currentImages()
    let addresses = Thread.callStackReturnAddresses.map { UInt($0.uintValue) }
    let live = try XCTUnwrap(StackFrames.symbolicate(addresses[1] &- 1))
    let (uuid, currentLoad) = try XCTUnwrap(current.first { $0.value == UInt64(live.imageAddress) })
    let symbolStart = UInt64(live.address)
    func report(kind: CrashReport.Kind) -> CrashReport {
      CrashReport(kind: kind, signal: 0, code: 0, faultAddress: 0, timestamp: Date(), frames: [symbolStart],
                  images: [.init(loadAddress: currentLoad, uuid: uuid, path: live.imagePath!)], name: "X", reason: nil)
    }
    let signalFrame = CrashReporter.frames(for: report(kind: .signal), inAppModules: [], currentImages: current)[0]
    let exceptionFrame = CrashReporter.frames(for: report(kind: .exception), inAppModules: [], currentImages: current)[0]
    XCTAssertEqual(signalFrame["symbol_addr"] as? String, StackFrames.hex(live.address))
    XCTAssertNotEqual(exceptionFrame["symbol_addr"] as? String, signalFrame["symbol_addr"] as? String)
  }

  func testUninstallLeavesAHandlerInstalledAfterUsAlone() throws {
    let transport = RecordingTransport()
    var options = TestSupport.options(transport: transport, directory: directory)
    options.captureCrashes = true
    let before = NSGetUncaughtExceptionHandler()
    let monica = try Monica.install(options, platform: FakePlatform())
    XCTAssertTrue(monica.isCrashCaptureInstalled)

    let other: @convention(c) (NSException) -> Void = { _ in }
    NSSetUncaughtExceptionHandler(other)
    monica.close()
    XCTAssertEqual(unsafeBitCast(NSGetUncaughtExceptionHandler(), to: Int.self), unsafeBitCast(other, to: Int.self),
                   "a later handler keeps its place")
    NSSetUncaughtExceptionHandler(before)

    // Without an interloper, close restores what was there before install.
    let again = try Monica.install(options, platform: FakePlatform())
    again.close()
    XCTAssertEqual(unsafeBitCast(NSGetUncaughtExceptionHandler(), to: Int.self), unsafeBitCast(before, to: Int.self))
  }

  func testInstallSucceedsWithoutCrashCaptureWhenTheDirectoryCannotBeCreated() throws {
    let transport = RecordingTransport()
    var options = TestSupport.options(transport: transport, directory: URL(fileURLWithPath: "/dev/null/monica"))
    options.captureCrashes = true
    let monica = try Monica.install(options, platform: FakePlatform())
    defer { monica.close() }
    XCTAssertFalse(monica.isCrashCaptureInstalled)
    XCTAssertNotNil(monica.captureMessage("still works"))
    XCTAssertTrue(monica.flush(timeout: 1))
  }

  func testThePreviousCrashRunsThroughBeforeSendWhichMayUseMonicaCurrent() throws {
    XCTAssertTrue(monica_crash_install(reportPath))
    let addresses = Thread.callStackReturnAddresses.map { UInt64(truncatingIfNeeded: $0.uintValue) }
    addresses.withUnsafeBufferPointer {
      monica_crash_record_exception("NSGenericException", "boom", $0.baseAddress, UInt32($0.count))
    }
    monica_crash_uninstall()
    monica_crash_reset_for_testing()

    let transport = RecordingTransport()
    var options = TestSupport.options(transport: transport, directory: directory)
    options.captureCrashes = true
    var sawCurrent = false
    options.beforeSend = { event, _ in
      // Must not deadlock: the pending crash is processed outside every lock.
      sawCurrent = Monica.current != nil
      Monica.current?.addBreadcrumb(category: "hook", message: "crash seen")
      event["tags"] = (event.tags.merging(["hook": "ran"]) { $1 })
      return event
    }
    let monica = try Monica.install(options, platform: FakePlatform())
    defer { monica.close() }
    XCTAssertTrue(TestSupport.waitUntil(timeout: 5) { transport.items.count == 1 })
    XCTAssertTrue(sawCurrent)
    let item = transport.only()
    XCTAssertEqual(item.tags["hook"], "ran")
    XCTAssertNil(item["breadcrumbs"], "the crash carries the crashed launch's scope, not this one's")
  }

  func testAFrameFromAnImageThatIsNoLongerLoadedStaysUnsymbolicated() {
    let report = CrashReport(kind: .signal, signal: SIGTRAP, code: 1, faultAddress: 0, timestamp: Date(),
                             frames: [0x1000_0100, 0x1000_0200],
                             images: [.init(loadAddress: 0x1000_0000, uuid: "00000000-0000-0000-0000-000000000001",
                                            path: "/private/var/containers/Bundle/Application/X/MyApp.app/MyApp")],
                             name: nil, reason: nil)
    let frames = CrashReporter.frames(for: report, inAppModules: ["MyApp"], currentImages: [:])
    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames[0]["filename"] as? String, "MyApp")
    XCTAssertEqual(frames[0]["in_app"] as? Bool, true)
    XCTAssertNil(frames[0]["function"])
    XCTAssertEqual(frames[0]["instruction_addr"] as? String, "0x10000200", "frames are oldest first")
    XCTAssertEqual(frames[0]["image_addr"] as? String, "0x10000000")

    let event = CrashReporter.event(from: report, session: nil, fallbackEnvironment: "test", fallbackRelease: "9",
                                    fallbackContexts: ["os": ["name": "iOS"]], inAppModules: ["MyApp"],
                                    currentImages: [:])
    XCTAssertEqual(event.exceptionValues.first?["type"] as? String, "SIGTRAP")
    XCTAssertEqual(event["release"] as? String, "9")
    XCTAssertEqual(event.context("os", "name") as? String, "iOS")
    let meta = event.mechanism["meta"] as? [String: Any]
    XCTAssertEqual((meta?["signal"] as? [String: Any])?["number"] as? Int, Int(SIGTRAP))
  }

  func testReadingThePendingReportLeavesItOnDiskUntilItIsExplicitlyDiscarded() throws {
    // Deleting on read lost the crash for good whenever the client turned out
    // to be closed by the time the event was ready — a consent callback calling
    // close(), or a second install() — because symbolicating up to 128 frames
    // takes long enough for that to happen.
    XCTAssertTrue(monica_crash_install(reportPath))
    monica_crash_record_exception("NSRangeException", "boom", nil, 0)
    monica_crash_uninstall()

    let reporter = CrashReporter(directory: directory)
    XCTAssertNotNil(reporter.readPendingReport())
    XCTAssertTrue(FileManager.default.fileExists(atPath: reportPath), "reading must not consume the report")
    XCTAssertNotNil(reporter.readPendingReport(), "so a later launch can still find it")
    reporter.discardPendingReport()
    XCTAssertNil(reporter.readPendingReport())
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportPath))
  }

  func testAnImageWithNoPathStillProducesAUsableFilename() throws {
    // The C handler leaves monica_crash_image.path zeroed when dladdr fails for
    // a loaded image. `frame.filename` has minLength 1 in envelope.json, so an
    // empty one would have had ingest reject the whole envelope — losing the
    // crash and every other item travelling with it.
    let report = CrashReport(kind: .signal, signal: SIGSEGV, code: 1, faultAddress: 0, timestamp: Date(),
                             frames: [0x1000_0010], images: [.init(loadAddress: 0x1000_0000, uuid: nil, path: "")],
                             name: nil, reason: nil)
    let frames = CrashReporter.frames(for: report, inAppModules: ["MyApp"])
    XCTAssertFalse(frames.isEmpty)
    for frame in frames {
      XCTAssertFalse((frame["filename"] as? String ?? "").isEmpty, "\(frame)")
    }
  }

  func testInstallSendsThePreviousLaunchsCrashAndForgetsIt() throws {
    // Pretend the previous launch died of an NSException.
    XCTAssertTrue(monica_crash_install(reportPath))
    let addresses = Thread.callStackReturnAddresses.map { UInt64(truncatingIfNeeded: $0.uintValue) }
    addresses.withUnsafeBufferPointer {
      monica_crash_record_exception("NSInvalidArgumentException", "boom", $0.baseAddress, UInt32($0.count))
    }
    monica_crash_uninstall()
    monica_crash_reset_for_testing()
    let session: [String: Any] = ["release": "0.9.0", "environment": "staging", "tags": ["screen": "Login"],
                                  "contexts": ["os": ["name": "iOS", "version": "17.0.0"]], "user": ["id": "u_9"]]
    try JSONSerialization.data(withJSONObject: session).write(to: directory.appendingPathComponent("session.json"))

    let transport = RecordingTransport()
    var options = TestSupport.options(transport: transport, directory: directory)
    options.captureCrashes = true
    options.inAppModules = [TestSupport.testImageName]
    let monica = try Monica.install(options, platform: FakePlatform())
    defer { monica.close() }

    XCTAssertTrue(TestSupport.waitUntil { transport.items.count == 1 })
    let item = transport.only()
    XCTAssertEqual(item["level"] as? String, "fatal")
    XCTAssertEqual(item["release"] as? String, "0.9.0")
    XCTAssertEqual(item["environment"] as? String, "staging")
    XCTAssertEqual(item.user?["id"] as? String, "u_9")
    XCTAssertEqual(item.exceptionValues.first?["type"] as? String, "NSInvalidArgumentException")
    XCTAssertTrue(item.frames.contains { ($0["in_app"] as? Bool) == true })
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportPath), "a report is sent once")

    // The new launch writes its own session for the next crash.
    monica.setUser(id: "u_10")
    let sessionURL = directory.appendingPathComponent("session.json")
    XCTAssertTrue(TestSupport.waitUntil {
      guard let data = try? Data(contentsOf: sessionURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
      return (json["user"] as? [String: Any])?["id"] as? String == "u_10"
        && (json["contexts"] as? [String: Any])?["device"] != nil
    })
  }
}

/// Builds crash report files byte by byte, in the layout `monica_crash.h` documents.
struct ReportBytes {
  var version: UInt32 = UInt32(MONICA_CRASH_REPORT_VERSION)
  var kind: UInt32 = UInt32(MONICA_CRASH_KIND_SIGNAL)
  var frames: [UInt64] = [0x1000]
  var imageCount: UInt32? = nil
  var uuid: [UInt8] = [UInt8](repeating: 0xAB, count: 16)

  init(version: UInt32 = UInt32(MONICA_CRASH_REPORT_VERSION), kind: UInt32 = UInt32(MONICA_CRASH_KIND_SIGNAL),
       frames: [UInt64] = [0x1000], imageCount: UInt32? = nil, uuid: [UInt8] = [UInt8](repeating: 0xAB, count: 16)) {
    self.version = version
    self.kind = kind
    self.frames = frames
    self.imageCount = imageCount
    self.uuid = uuid
  }

  func data() -> Data {
    var data = Data()
    func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    put(UInt32(MONICA_CRASH_REPORT_MAGIC)); put(version); put(kind)
    put(Int32(SIGTRAP)); put(Int32(0)); put(UInt64(0)); put(Int64(1_700_000_000))
    put(UInt32(frames.count)); frames.forEach { put($0) }
    let path = Array("/x/MyApp.app/MyApp".utf8)
    put(imageCount ?? 1)
    put(UInt64(0x1000)); data.append(contentsOf: uuid); put(UInt32(path.count)); data.append(contentsOf: path)
    put(UInt32(0)); put(UInt32(0))
    return data
  }
}

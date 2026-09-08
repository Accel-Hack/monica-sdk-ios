import Foundation
import MonicaCrashHandler

/// One crash as the C handler wrote it. See `monica_crash.h` for the layout.
struct CrashReport: Equatable {
  enum Kind: Equatable { case signal, exception }

  struct Image: Equatable {
    var loadAddress: UInt64
    var uuid: String?
    var path: String
  }

  var kind: Kind
  var signal: Int32
  var code: Int32
  var faultAddress: UInt64
  var timestamp: Date
  var frames: [UInt64]
  var images: [Image]
  var name: String?
  var reason: String?

  static func parse(_ data: Data) -> CrashReport? {
    var reader = Reader(data: data)
    guard reader.u32() == MONICA_CRASH_REPORT_MAGIC, reader.u32() == MONICA_CRASH_REPORT_VERSION,
      let kindValue = reader.u32(), let signal = reader.i32(), let code = reader.i32(),
      let fault = reader.u64(), let seconds = reader.i64(), let frameCount = reader.u32()
    else { return nil }
    let kind: Kind
    switch kindValue {
    case MONICA_CRASH_KIND_SIGNAL: kind = .signal
    case MONICA_CRASH_KIND_EXCEPTION: kind = .exception
    default: return nil
    }
    // The writer caps both counts; a larger value means a corrupt file, and
    // reading on would misalign every field after it.
    guard frameCount <= UInt32(MONICA_CRASH_MAX_FRAMES) else { return nil }
    var frames: [UInt64] = []
    for _ in 0..<frameCount {
      guard let frame = reader.u64() else { return nil }
      frames.append(frame)
    }
    guard let imageCount = reader.u32(), imageCount <= UInt32(MONICA_CRASH_MAX_IMAGES) else { return nil }
    var images: [Image] = []
    for _ in 0..<imageCount {
      guard let load = reader.u64(), let uuidBytes = reader.bytes(16), let path = reader.text() else { return nil }
      let isZero = uuidBytes.allSatisfy { $0 == 0 }
      images.append(Image(loadAddress: load, uuid: isZero ? nil : uuidString(uuidBytes), path: path))
    }
    let name = reader.text()
    let reason = reader.text()
    return CrashReport(kind: kind, signal: signal, code: code, faultAddress: fault,
                       timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)), frames: frames,
                       images: images, name: name.flatMap { $0.isEmpty ? nil : $0 },
                       reason: reason.flatMap { $0.isEmpty ? nil : $0 })
  }

  static func uuidString(_ bytes: [UInt8]) -> String {
    precondition(bytes.count == 16)
    return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress).uuidString }
  }

  private struct Reader {
    let data: Data
    var offset = 0
    init(data: Data) { self.data = data }

    mutating func bytes(_ count: Int) -> [UInt8]? {
      guard count >= 0, offset + count <= data.count else { return nil }
      let slice = [UInt8](data[data.startIndex + offset..<data.startIndex + offset + count])
      offset += count
      return slice
    }
    mutating func u32() -> UInt32? { bytes(4).map { $0.withUnsafeBytes { $0.load(as: UInt32.self) } } }
    mutating func i32() -> Int32? { bytes(4).map { $0.withUnsafeBytes { $0.load(as: Int32.self) } } }
    mutating func u64() -> UInt64? { bytes(8).map { $0.withUnsafeBytes { $0.load(as: UInt64.self) } } }
    mutating func i64() -> Int64? { bytes(8).map { $0.withUnsafeBytes { $0.load(as: Int64.self) } } }
    mutating func text() -> String? {
      guard let length = u32(), let raw = bytes(Int(length)) else { return nil }
      return String(decoding: raw, as: UTF8.self)
    }
  }
}

private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
private var exceptionHandlerInstalled = false

/// Objective-C exceptions do not arrive as a signal first: the runtime calls
/// this, then abort()s. Recording here keeps the exception name and reason,
/// and the flag it sets makes the SIGABRT handler leave the report alone.
private let uncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exception in
  let addresses = exception.callStackReturnAddresses.map { UInt64(truncatingIfNeeded: $0.uintValue) }
  addresses.withUnsafeBufferPointer { buffer in
    monica_crash_record_exception(exception.name.rawValue, exception.reason, buffer.baseAddress,
                                  UInt32(buffer.count))
  }
  previousExceptionHandler?(exception)
}

/// Owns the on-disk state the crash path needs: the pending report the C
/// handler writes, and the scope snapshot that gives that report its
/// release, environment, tags and user on the next launch.
final class CrashReporter {
  static let reportFileName = "pending-crash.bin"
  static let sessionFileName = "session.json"

  let directory: URL
  private(set) var installed = false

  init(directory: URL) {
    self.directory = directory
  }

  var reportURL: URL { directory.appendingPathComponent(Self.reportFileName) }
  var sessionURL: URL { directory.appendingPathComponent(Self.sessionFileName) }

  static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("monica", isDirectory: true)
  }

  func install() -> Bool {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var url = directory
      try? url.setResourceValues(values)
    } catch {
      return false
    }
    guard monica_crash_install(reportURL.path) else { return false }
    if !exceptionHandlerInstalled {
      previousExceptionHandler = NSGetUncaughtExceptionHandler()
      NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
      exceptionHandlerInstalled = true
    }
    installed = true
    return true
  }

  func uninstall() {
    guard installed else { return }
    monica_crash_uninstall()
    if exceptionHandlerInstalled {
      // Only step aside if nothing else has been installed on top of us;
      // otherwise the other handler would silently lose its own delegate.
      let ours = unsafeBitCast(uncaughtExceptionHandler, to: UnsafeRawPointer?.self)
      let now = unsafeBitCast(NSGetUncaughtExceptionHandler(), to: UnsafeRawPointer?.self)
      if now == ours { NSSetUncaughtExceptionHandler(previousExceptionHandler) }
      previousExceptionHandler = nil
      exceptionHandlerInstalled = false
    }
    installed = false
  }

  /// Reads and deletes the report the previous launch left behind, if any.
  func takePendingReport() -> CrashReport? {
    guard let data = try? Data(contentsOf: reportURL) else { return nil }
    try? FileManager.default.removeItem(at: reportURL)
    return CrashReport.parse(data)
  }

  func writeSession(_ session: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(session),
      let data = try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
    else { return }
    try? data.write(to: sessionURL, options: [.atomic])
  }

  func readSession() -> [String: Any]? {
    guard let data = try? Data(contentsOf: sessionURL) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  // MARK: turning a report into an event

  static let signalNames: [Int32: String] = [
    SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGILL: "SIGILL", SIGSEGV: "SIGSEGV",
    SIGTRAP: "SIGTRAP",
  ]

  /// The images loaded in this process, keyed by UUID, from the handler's table.
  static func currentImages() -> [String: UInt64] {
    var result: [String: UInt64] = [:]
    for index in 0..<monica_crash_image_count() {
      var image = monica_crash_image()
      guard monica_crash_image_at(index, &image) else { continue }
      let uuid = withUnsafeBytes(of: &image.uuid) { [UInt8]($0) }
      if uuid.allSatisfy({ $0 == 0 }) { continue }
      result[CrashReport.uuidString(uuid)] = image.load_address
    }
    return result
  }

  /// Symbolicates against the images loaded now. An address is only looked up
  /// when the image it belonged to is loaded again with the same UUID, so an
  /// app update between the crash and this launch cannot produce wrong names.
  static func frames(for report: CrashReport, inAppModules: [String],
                     currentImages: [String: UInt64] = currentImages()) -> [[String: Any]] {
    let images = report.images.filter { $0.loadAddress != 0 }.sorted { $0.loadAddress < $1.loadAddress }
    var frames: [[String: Any]] = []
    for (index, address) in report.frames.enumerated() {
      let address = UInt(truncatingIfNeeded: address)
      guard let image = images.last(where: { UInt(truncatingIfNeeded: $0.loadAddress) <= address }) else {
        frames.append(StackFrames.frame(address: address, symbol: nil, inAppModules: inAppModules,
                                        moduleOverride: "unknown"))
        continue
      }
      let load = UInt(truncatingIfNeeded: image.loadAddress)
      var symbol = StackFrames.Symbol(imagePath: image.path, imageAddress: load, name: nil, address: 0)
      if let uuid = image.uuid, let currentLoad = currentImages[uuid] {
        let current = UInt(truncatingIfNeeded: currentLoad) &+ (address &- load)
        // A signal report starts with the faulting pc; everything else,
        // including every NSException frame, is a return address.
        let isProgramCounter = report.kind == .signal && index == 0
        let lookup = isProgramCounter ? current : current &- 1
        if let found = StackFrames.symbolicate(lookup), found.imageAddress == UInt(truncatingIfNeeded: currentLoad) {
          symbol.name = found.name
          symbol.address = found.address == 0 ? 0 : found.address &- UInt(truncatingIfNeeded: currentLoad) &+ load
        }
      }
      frames.append(StackFrames.frame(address: address, symbol: symbol, inAppModules: inAppModules))
    }
    frames.reverse()
    return frames.count <= StackFrames.maxFrames ? frames : Array(frames.suffix(StackFrames.maxFrames))
  }

  static func event(from report: CrashReport, session: [String: Any]?, fallbackEnvironment: String,
                    fallbackRelease: String?, fallbackContexts: [String: Any], inAppModules: [String],
                    currentImages: [String: UInt64] = currentImages()) -> MonicaEvent {
    let type: String
    let value: String
    var mechanism: [String: Any] = ["type": "generic", "handled": false]
    switch report.kind {
    case .signal:
      let name = signalNames[report.signal] ?? "SIG\(report.signal)"
      type = name
      value = "Signal \(report.signal) (\(name)), code \(report.code), fault address \(StackFrames.hex(UInt(truncatingIfNeeded: report.faultAddress)))"
      mechanism["meta"] = ["signal": ["number": Int(report.signal), "code": Int(report.code), "name": name]]
    case .exception:
      type = report.name ?? "NSException"
      value = report.reason ?? ""
    }
    var exceptionValue: [String: Any] = ["type": type, "value": value, "mechanism": mechanism]
    let frames = frames(for: report, inAppModules: inAppModules, currentImages: currentImages)
    if !frames.isEmpty { exceptionValue["stacktrace"] = ["frames": frames] }

    let event = MonicaEvent([
      "type": "error",
      "event_id": UUID().uuidString.lowercased(),
      "timestamp": Timestamps.iso8601(report.timestamp),
      "level": MonicaLevel.fatal.rawValue,
      "platform": Monica.platformName,
      "environment": (session?["environment"] as? String) ?? fallbackEnvironment,
      "message": value,
      "exception": ["values": [exceptionValue]],
    ])
    if let release = (session?["release"] as? String) ?? fallbackRelease { event["release"] = release }
    var tags = (session?["tags"] as? [String: String]) ?? [:]
    tags["crash.reported_at"] = "next_launch"
    event["tags"] = tags
    let contexts = (session?["contexts"] as? [String: Any]) ?? fallbackContexts
    if !contexts.isEmpty { event["contexts"] = contexts }
    if let user = session?["user"] as? [String: Any], !user.isEmpty { event["user"] = user }
    return event
  }
}

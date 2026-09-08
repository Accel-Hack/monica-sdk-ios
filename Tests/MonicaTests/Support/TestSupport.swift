import Foundation
import Monica
import XCTest

enum TestSupport {
  static let repositoryRoot: URL = {
    // Tests/MonicaTests/Support/TestSupport.swift -> repository root
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }()

  /// The binary image this test code lives in. Under `swift test` it is the
  /// package test bundle, not `MonicaTests`, so nothing may hard-code the name.
  static let testImageName: String = {
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return "MonicaTests" }
    return (String(cString: name) as NSString).lastPathComponent
  }()

  static func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("monica-swift-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func options(transport: MonicaTransport, directory: URL) -> MonicaOptions {
    var options = MonicaOptions(dsn: "https://mpk_public@ingest.monica.test/1", environment: "test")
    options.transport = transport
    options.captureCrashes = false
    options.trackAppLifecycle = false
    options.crashReportDirectory = directory
    return options
  }

  static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
  }
}

extension MonicaEvent {
  var contexts: [String: Any] { (self["contexts"] as? [String: Any]) ?? [:] }
  var tags: [String: String] { (self["tags"] as? [String: String]) ?? [:] }
  var user: [String: Any]? { self["user"] as? [String: Any] }
  var breadcrumbs: [[String: Any]] { (self["breadcrumbs"] as? [[String: Any]]) ?? [] }
  var exceptionValues: [[String: Any]] {
    ((self["exception"] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
  }
  var frames: [[String: Any]] {
    ((exceptionValues.first?["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]]) ?? []
  }
  var mechanism: [String: Any] { (exceptionValues.first?["mechanism"] as? [String: Any]) ?? [:] }

  func context(_ group: String, _ key: String) -> Any? {
    (contexts[group] as? [String: Any])?[key]
  }
}

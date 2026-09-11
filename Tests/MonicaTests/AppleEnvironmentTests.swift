import Foundation
import Monica
import XCTest

final class AppleEnvironmentTests: XCTestCase {
  func testReadsOnlyBuildFactsFromTheRunningProcess() {
    let environment = AppleEnvironment.current()
    XCTAssertFalse(environment.osVersion.isEmpty)
    XCTAssertEqual(environment.osName, "macOS", "swift test runs on the Mac")
    XCTAssertNotNil(environment.deviceModel)
    XCTAssertFalse(environment.isSimulator)
  }

  func testWritesTheThreeContextsAndNothingIdentifying() {
    let environment = AppleEnvironment(deviceModel: "iPhone15,2", isSimulator: true, osName: "iOS", osVersion: "17.4.1",
                                       appIdentifier: "com.example.app", appVersion: "2.3.1", appBuild: "231",
                                       executableName: "ExampleApp")
    let transport = RecordingTransport()
    let directory = TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let platform = FakePlatform()
    platform.environment = environment
    let monica = try! Monica.install(TestSupport.options(transport: transport, directory: directory), platform: platform)
    defer { monica.close() }
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 1))

    let contexts = transport.only().contexts
    XCTAssertEqual(Set(contexts.keys), ["device", "os", "app"])
    XCTAssertEqual((contexts["device"] as? [String: Any])?["simulator"] as? Bool, true)
    // Only build facts: no device name, vendor id, serial or anything else
    // that would single out one install.
    XCTAssertEqual(Set((contexts["device"] as? [String: Any])?.keys ?? [:].keys), ["manufacturer", "model", "simulator"])
    XCTAssertEqual(Set((contexts["os"] as? [String: Any])?.keys ?? [:].keys), ["name", "version"])
    XCTAssertEqual(Set((contexts["app"] as? [String: Any])?.keys ?? [:].keys), ["app_identifier", "app_version", "app_build"])
  }

  func testAMissingEnvironmentLeavesTheEventWithoutContexts() throws {
    let transport = RecordingTransport()
    let directory = TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let platform = FakePlatform()
    platform.environment = nil
    var options = TestSupport.options(transport: transport, directory: directory)
    options.release = "explicit"
    let monica = try Monica.install(options, platform: platform)
    defer { monica.close() }
    monica.captureMessage("boom")
    XCTAssertTrue(monica.flush(timeout: 1))

    XCTAssertNil(transport.only()["contexts"])
    XCTAssertEqual(transport.only()["release"] as? String, "explicit")
  }
}

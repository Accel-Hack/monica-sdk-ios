import Foundation
@testable import Monica
import XCTest

final class MonicaOptionsTests: XCTestCase {
  func testParsesThePublicKeyAndRewritesThePathToTheEnvelopeEndpoint() throws {
    let dsn = try DSN.parse(" https://mpk_abc%40x@ingest.stg.monica.accelhack.net/android-sample ")
    XCTAssertEqual(dsn.publicKey, "mpk_abc@x")
    XCTAssertEqual(dsn.endpoint.absoluteString, "https://ingest.stg.monica.accelhack.net/v1/envelope")
    XCTAssertEqual(try DSN.parse("http://mpk_k@localhost:8787/1").endpoint.absoluteString,
                   "http://localhost:8787/v1/envelope")
  }

  func testRejectsWhatMustNotShipInsideAnAppBundle() {
    XCTAssertEqual(configurationError("https://msk_secret@ingest.monica.test/1"), .secretKeyInDSN)
    XCTAssertEqual(configurationError("http://mpk_k@ingest.monica.test/1"), .insecureDSN)
    XCTAssertEqual(configurationError(""), .emptyDSN)
    XCTAssertEqual(configurationError("https://ingest.monica.test/1"), .invalidDSN("no API key"))
    XCTAssertEqual(configurationError("not a url"), .invalidDSN("not a url"))
  }

  func testValidatesTheRestOfTheOptionsEvenWithACustomTransport() {
    var options = MonicaOptions(dsn: "https://mpk_k@ingest.monica.test/1", environment: " ")
    options.transport = RecordingTransport()
    XCTAssertEqual(validationError(options), .emptyEnvironment)

    options.environment = "production"
    options.sampleRate = 1.5
    XCTAssertEqual(validationError(options), .invalidValue("sampleRate must be between 0 and 1"))

    options.sampleRate = 1
    options.flushTimeout = 0
    XCTAssertEqual(validationError(options), .invalidValue("flushTimeout must be positive"))

    options.flushTimeout = 2
    options.maxRetries = -1
    XCTAssertEqual(validationError(options), .invalidValue("maxRetries must not be negative"))

    options.maxRetries = 0
    XCTAssertNil(validationError(options))
  }

  /// `envelope.json` measures `maxLength` in code points. Measuring the
  /// environment in grapheme clusters instead let 128 combining-mark or flag
  /// clusters through install-time validation and then had ingest answer 422 to
  /// every single event, with no configuration error anywhere.
  func testTheEnvironmentBoundIsCountedInCodePointsNotGraphemeClusters() {
    func error(_ environment: String) -> MonicaConfigurationError? {
      var options = MonicaOptions(dsn: "https://mpk_k@ingest.monica.test/1", environment: environment)
      options.transport = RecordingTransport()
      return validationError(options)
    }
    let tooLong = "environment must be at most 128 code points"
    // "e" + U+0301 is one cluster and two code points.
    let accented = String(repeating: "e\u{0301}", count: 64)
    XCTAssertEqual(accented.count, 64)
    XCTAssertEqual(accented.unicodeScalars.count, 128)
    XCTAssertNil(error(accented))
    XCTAssertEqual(error(accented + "e\u{0301}"), .invalidValue(tooLong))
    // A regional-indicator pair is one cluster and two code points too.
    XCTAssertEqual(error(String(repeating: "\u{1F1EF}\u{1F1F5}", count: 65)), .invalidValue(tooLong))
    XCTAssertNil(error(String(repeating: "x", count: 128)))
    XCTAssertEqual(error(String(repeating: "x", count: 129)), .invalidValue(tooLong))
  }

  func testDefaultsMatchTheAndroidSDK() {
    let options = MonicaOptions(dsn: "https://mpk_k@ingest.monica.test/1", environment: "production")
    XCTAssertEqual(options.maxBreadcrumbs, 50)
    XCTAssertEqual(options.maxQueueSize, 100)
    XCTAssertEqual(options.batchSize, 30)
    XCTAssertEqual(options.flushInterval, 5)
    XCTAssertEqual(options.requestTimeout, 10)
    XCTAssertEqual(options.maxRetries, 2)
    XCTAssertTrue(options.captureCrashes)
    XCTAssertTrue(options.trackAppLifecycle)
    XCTAssertTrue(options.attachDeviceContext)
  }

  private func configurationError(_ dsn: String) -> MonicaConfigurationError? {
    do {
      _ = try DSN.parse(dsn)
      return nil
    } catch {
      return error as? MonicaConfigurationError
    }
  }

  private func validationError(_ options: MonicaOptions) -> MonicaConfigurationError? {
    do {
      _ = try options.validated()
      return nil
    } catch {
      return error as? MonicaConfigurationError
    }
  }
}

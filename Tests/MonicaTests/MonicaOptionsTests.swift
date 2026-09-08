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

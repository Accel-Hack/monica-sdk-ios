import Foundation
@testable import Monica
import XCTest

private struct DescribedError: LocalizedError {
  var errorDescription: String? { "payment declined" }
}

final class ErrorConverterTests: XCTestCase {
  func testNamesSwiftErrorsByTheirFullyQualifiedType() {
    XCTAssertEqual(ErrorConverter.typeName(of: CheckoutError.declined(code: 402)), "MonicaTests.CheckoutError")
    XCTAssertEqual(ErrorConverter.message(of: CheckoutError.declined(code: 402)), "declined(code: 402)")
    XCTAssertEqual(ErrorConverter.message(of: DescribedError()), "payment declined")
  }

  func testNamesNSErrorsByDomainBecauseTheClassSaysNothing() {
    let error = NSError(domain: "NSURLErrorDomain", code: -1009,
                        userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
    XCTAssertEqual(ErrorConverter.typeName(of: error), "NSURLErrorDomain")
    XCTAssertEqual(ErrorConverter.message(of: error), "The Internet connection appears to be offline.")
  }

  func testAnEmptyDomainFallsBackToTheTypeSoTheSchemaMinLengthHolds() {
    let error = NSError(domain: "", code: 1, userInfo: nil)
    XCTAssertEqual(ErrorConverter.typeName(of: error), "NSError")
  }

  func testStopsAtEightNestedCausesEvenWhenTheChainIsACycle() {
    var chain = NSError(domain: "leaf", code: 0, userInfo: nil)
    for depth in 1...12 { chain = NSError(domain: "d\(depth)", code: depth, userInfo: [NSUnderlyingErrorKey: chain]) }
    let values = ErrorConverter.convert(chain, inAppModules: [], handled: true, callStack: [], skipFrames: 0)["values"] as? [[String: Any]]
    XCTAssertEqual(values?.count, 8)
  }

  func testFollowsTheUnderlyingErrorChainOutermostFirst() {
    let inner = NSError(domain: "inner", code: 1, userInfo: nil)
    let outer = NSError(domain: "outer", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
    let converted = ErrorConverter.convert(outer, inAppModules: [], handled: false, callStack: [], skipFrames: 0)
    let values = converted["values"] as? [[String: Any]]
    XCTAssertEqual(values?.map { $0["type"] as? String }, ["outer", "inner"])
    XCTAssertEqual(values?.first?["code"] as? Int, 2)
    XCTAssertEqual((values?.first?["mechanism"] as? [String: Any])?["handled"] as? Bool, false)
    XCTAssertNil(values?.first?["stacktrace"], "no addresses, no stacktrace")
  }

  func testOnlyTheOutermostValueCarriesTheStack() {
    let inner = NSError(domain: "inner", code: 1, userInfo: nil)
    let outer = NSError(domain: "outer", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
    let addresses = Thread.callStackReturnAddresses.map { UInt($0.uintValue) }
    let values = ErrorConverter.convert(outer, inAppModules: [], handled: true, callStack: addresses, skipFrames: 0)["values"] as? [[String: Any]]
    XCTAssertNotNil(values?[0]["stacktrace"])
    XCTAssertNil(values?[1]["stacktrace"])
  }
}

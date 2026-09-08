import Foundation
@testable import Monica
import XCTest

final class StackFramesTests: XCTestCase {
  func testDerivesTheFilenameFromTheOutermostTypeOfASwiftSymbol() {
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "MyApp.ViewController.didTapCrash() -> ()"),
                   "MyApp/ViewController.swift")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "closure #1 () -> () in MyApp.Checkout.pay() -> ()"),
                   "MyApp/Checkout.swift")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "@objc MyApp.ViewController.didTap(Any) -> ()"),
                   "MyApp/ViewController.swift")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "MyApp.Outer.Inner.run() -> ()"),
                   "MyApp/Outer.swift")
  }

  func testDemanglesBeforeDeriving() {
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "$s5MyApp14ViewControllerC11didTapCrashyyF"),
                   "MyApp/ViewController.swift")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "$s5MyApp14ViewControllerC11viewDidLoadyyFyycfU_"),
                   "MyApp/ViewController.swift")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "$s5MyApp14ViewControllerC11didTapCrashyyFTo"),
                   "MyApp/ViewController.swift")
    XCTAssertEqual(Demangle.demangle("$s5MyApp14ViewControllerC11didTapCrashyyF"),
                   "MyApp.ViewController.didTapCrash() -> ()")
  }

  func testReadsTheModuleOffTheManglingWhenItDiffersFromTheImageName() {
    XCTAssertEqual(Demangle.module(ofMangled: "$s6My_App14ViewControllerC11didTapCrashyyF"), "My_App")
    XCTAssertNil(Demangle.module(ofMangled: "$sSa6appendyyxF5MyApp3FooV_Tg5"))
    XCTAssertNil(Demangle.module(ofMangled: "-[ViewController viewDidLoad]"))
    XCTAssertEqual(StackFrames.filename(module: "My App", symbol: "$s6My_App14ViewControllerC11didTapCrashyyF"),
                   "My App/ViewController.swift")
    // A stdlib specialization living in the app image is attributed to the app type it was specialised for.
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "$sSa6appendyyxF5MyApp3FooV_Tg5"), "MyApp/Foo.swift")
  }

  func testUsesTheFunctionNameForFreeFunctions() {
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "MyApp.helper() -> ()"), "MyApp/helper.swift")
  }

  func testFallsBackToTheModuleForForeignSymbols() {
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "main"), "MyApp")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "NotMyApp.Foo.bar() -> ()"), "MyApp")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "generic specialization <Swift.Int> of Swift.Array.subscript.getter"),
                   "MyApp")
    XCTAssertEqual(StackFrames.filename(module: "libdyld.dylib", symbol: "start"), "libdyld.dylib")
  }

  func testUsesTheClassForObjectiveCMethods() {
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "-[ViewController viewDidLoad]"), "MyApp/ViewController.m")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "+[Store shared]"), "MyApp/Store.m")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: "__29-[ViewController viewDidLoad]_block_invoke"),
                   "MyApp/ViewController.m")
  }

  func testAnUnsymbolicatedFrameIsJustTheImage() {
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: nil), "MyApp")
    XCTAssertEqual(StackFrames.filename(module: "MyApp", symbol: ""), "MyApp")
  }

  /// MONICA groups an error on the innermost exception type and the in_app
  /// frames' filenames; addresses and function names do not contribute. Two
  /// things follow for Swift, and both are pinned here because the grouping
  /// algorithm itself is not part of the public contract (DEC53) and cannot
  /// be run in this repository.
  func testTheFilenameShapeIsStableAcrossBuildsAndDegeneratesWhenStripped() {
    // The same crash on two builds: different addresses, same symbols, same
    // grouping inputs. The derivation never looks at the address.
    let symbolicated = ["$s5MyApp14ViewControllerC11didTapCrashyyFTo", "$s5MyApp14ViewControllerC11didTapCrashyyF",
                        "$s5MyApp8CheckoutV3payyyF"]
    let build1 = symbolicated.enumerated().map { index, symbol in
      StackFrames.frame(address: 0x1000 + UInt(index), symbol: .init(imagePath: "/a/MyApp.app/MyApp", imageAddress: 0x1000, name: symbol, address: 0x1000),
                        inAppModules: ["MyApp"])
    }
    let build2 = symbolicated.enumerated().map { index, symbol in
      StackFrames.frame(address: 0x5000 + UInt(index), symbol: .init(imagePath: "/b/MyApp.app/MyApp", imageAddress: 0x5000, name: symbol, address: 0x5000),
                        inAppModules: ["MyApp"])
    }
    let inputs = { (frames: [[String: Any]]) in frames.filter { $0["in_app"] as? Bool == true }.map { $0["filename"] as? String } }
    XCTAssertEqual(inputs(build1), ["MyApp/ViewController.swift", "MyApp/ViewController.swift", "MyApp/Checkout.swift"])
    XCTAssertEqual(inputs(build1), inputs(build2))
    XCTAssertNotEqual(build1[0]["instruction_addr"] as? String, build2[0]["instruction_addr"] as? String)

    // A build that stripped its symbols (Xcode's archive default) yields the
    // bare image name for every in_app frame. Every crash of one signal then
    // collapses into a single group: the accepted degenerate case, and the
    // reason README asks for STRIP_INSTALLED_PRODUCT = NO or a dSYM upload.
    let stripped = (0..<3).map { index in
      StackFrames.frame(address: 0x1000 + UInt(index), symbol: .init(imagePath: "/a/MyApp.app/MyApp", imageAddress: 0x1000, name: nil, address: 0),
                        inAppModules: ["MyApp"])
    }
    XCTAssertEqual(inputs(stripped), ["MyApp", "MyApp", "MyApp"])
    XCTAssertTrue(stripped.allSatisfy { $0["function"] == nil })
  }

  func testModuleNameIsTheImageBasename() {
    XCTAssertEqual(StackFrames.moduleName(ofImagePath: "/private/var/containers/Bundle/Application/X/MyApp.app/MyApp"), "MyApp")
    XCTAssertEqual(StackFrames.moduleName(ofImagePath: "/System/Library/Frameworks/UIKit.framework/UIKit"), "UIKit")
    XCTAssertEqual(StackFrames.moduleName(ofImagePath: "/usr/lib/swift/libswiftCore.dylib"), "libswiftCore.dylib")
    XCTAssertEqual(StackFrames.moduleName(ofImagePath: "/X/MyApp.app/MyApp.debug.dylib"), "MyApp",
                   "Xcode Debug builds load the app's code from a debug dylib")
  }

  func testLiveFramesRunOldestCallerFirstWithDemangledFunctions() {
    let addresses = Thread.callStackReturnAddresses.map { UInt($0.uintValue) }
    let frames = StackFrames.frames(for: addresses, inAppModules: [TestSupport.testImageName], skipFrames: 0)
    XCTAssertEqual(frames.count, addresses.count)
    let last = frames.last
    XCTAssertEqual(last?["in_app"] as? Bool, true)
    XCTAssertTrue((last?["function"] as? String)?.contains("StackFramesTests") == true, "\(last ?? [:])")
    XCTAssertEqual(last?["filename"] as? String, "\(TestSupport.testImageName)/StackFramesTests.swift")
    XCTAssertTrue((last?["instruction_addr"] as? String)?.hasPrefix("0x") == true)
  }
}

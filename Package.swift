// swift-tools-version:5.9
import PackageDescription

// iOS 13 / Swift 5 language mode: the applications this ships to first are
// pinned there, and nothing in the SDK needs newer APIs. macOS is listed only so
// `swift test` can run on a Mac without a simulator.
//
// SwiftPM derives a dependency's identity from the repository name, so a
// consumer refers to this package as `monica-sdk-ios` even though the package
// (and `sdk.name` on the wire) is `monica-swift`:
//
//   .package(url: "https://github.com/Accel-Hack/monica-sdk-ios", from: "0.1.0")
//   .product(name: "Monica", package: "monica-sdk-ios")
let package = Package(
  name: "monica-swift",
  platforms: [.iOS(.v13), .macOS(.v10_15)],
  products: [
    .library(name: "Monica", targets: ["Monica"]),
  ],
  targets: [
    // The signal handler is C so that nothing on the crash path can call into
    // the Swift runtime, which is not async-signal-safe.
    .target(
      name: "MonicaCrashHandler",
      path: "Sources/MonicaCrashHandler",
      cSettings: [.define("_DARWIN_C_SOURCE")]
    ),
    .target(
      name: "Monica",
      dependencies: ["MonicaCrashHandler"],
      path: "Sources/Monica",
      linkerSettings: [.linkedLibrary("z")]
    ),
    .testTarget(
      name: "MonicaTests",
      dependencies: ["Monica", "MonicaCrashHandler"],
      path: "Tests/MonicaTests"
    ),
  ],
  swiftLanguageVersions: [.v5]
)

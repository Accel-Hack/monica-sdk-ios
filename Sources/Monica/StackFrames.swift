import Foundation

/// Builds `stacktrace.frames` from return addresses.
///
/// Swift has no source file or line number at runtime, so the frame's
/// `filename`, which MONICA groups on, is derived from the symbol the way the
/// public contract's payload obligations (`spec/v1/payload.md`, "filename")
/// define for Swift: `<module>/<Outermost>.swift` for a Swift symbol, where
/// `Outermost` is the first identifier after the module prefix (the type, or a
/// free function's name); `<module>/<Class>.m` for an Objective-C method; and
/// the bare module name for anything else, including a frame that could not
/// be symbolicated. A stripped build therefore names every in-app frame after
/// the image alone, and every crash of one signal collapses into one Issue.
enum StackFrames {
  struct Symbol {
    var imagePath: String?
    var imageAddress: UInt
    var name: String?
    var address: UInt
  }

  /// `limits.json` `frames_per_stacktrace`.
  static let maxFrames = 200

  /// Frames for the live process, oldest caller first as the wire format requires.
  static func frames(for addresses: [UInt], inAppModules: [String], skipFrames: Int) -> [[String: Any]] {
    let relevant = Array(addresses.dropFirst(min(skipFrames, addresses.count)))
    var frames: [[String: Any]] = []
    for address in relevant {
      // `callStackReturnAddresses` holds return addresses only: each points
      // just past a call, so step back into the call to name the right symbol
      // (a call in tail position would otherwise resolve to the next function).
      frames.append(frame(address: address, symbol: symbolicate(address &- 1), inAppModules: inAppModules))
    }
    frames.reverse()
    return frames.count <= maxFrames ? frames : Array(frames.suffix(maxFrames))
  }

  static func symbolicate(_ address: UInt) -> Symbol? {
    var info = Dl_info()
    guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else { return nil }
    return Symbol(
      imagePath: info.dli_fname.map { String(cString: $0) },
      imageAddress: UInt(bitPattern: info.dli_fbase),
      name: info.dli_sname.map { String(cString: $0) },
      address: UInt(bitPattern: info.dli_saddr)
    )
  }

  static func frame(address: UInt, symbol: Symbol?, inAppModules: [String], moduleOverride: String? = nil)
    -> [String: Any] {
    let module = moduleOverride ?? symbol?.imagePath.map(moduleName(ofImagePath:)) ?? "unknown"
    var frame: [String: Any] = [
      "filename": filename(module: module, symbol: symbol?.name),
      "in_app": inAppModules.contains(module),
      "instruction_addr": hex(address),
    ]
    if let name = symbol?.name { frame["function"] = Demangle.demangle(name) }
    if let symbol = symbol {
      if symbol.imageAddress != 0 { frame["image_addr"] = hex(symbol.imageAddress) }
      if symbol.address != 0 { frame["symbol_addr"] = hex(symbol.address) }
      if let path = symbol.imagePath { frame["package"] = path }
    }
    return frame
  }

  /// Xcode 16+ Debug builds put the app's code in `<App>.debug.dylib` next to a
  /// stub executable (confirmed 2026-09-03 with Xcode 26.6). The frames belong
  /// to the app all the same, so the suffix is dropped.
  ///
  /// The result is never empty. `envelope.json` gives `frame.filename` a
  /// `minLength` of 1, and the crash path can hand us an empty image path: the
  /// C handler leaves `monica_crash_image.path` zeroed when `dladdr` fails for
  /// a loaded image, and an empty `filename` would have made ingest reject the
  /// whole envelope — losing the crash and every other item travelling with it.
  static func moduleName(ofImagePath path: String) -> String {
    var name = (path as NSString).lastPathComponent
    if name.isEmpty { name = path }
    if name.hasSuffix(".debug.dylib") { name.removeLast(".debug.dylib".count) }
    return name.isEmpty ? "unknown" : name
  }

  private static let objcMethod = try! NSRegularExpression(pattern: "[-+]\\[([A-Za-z_][A-Za-z0-9_]*)")

  static func filename(module: String, symbol: String?) -> String {
    // `minLength: 1`; a module name only ever arrives empty through a caller
    // that bypassed `moduleName(ofImagePath:)`.
    let module = module.isEmpty ? "unknown" : module
    guard let symbol = symbol, !symbol.isEmpty else { return module }
    // The Swift module is normally the image name, but not always (a product
    // named "My App" builds module My_App), so read it off the mangling when
    // there is one.
    let swiftModule = Demangle.module(ofMangled: symbol) ?? module
    let demangled = Demangle.demangle(symbol)
    if let declaration = outermostDeclaration(in: demangled, module: swiftModule) {
      return "\(module)/\(declaration).swift"
    }
    let range = NSRange(demangled.startIndex..<demangled.endIndex, in: demangled)
    if let match = objcMethod.firstMatch(in: demangled, range: range),
      let classRange = Range(match.range(at: 1), in: demangled) {
      return "\(module)/\(demangled[classRange]).m"
    }
    return module
  }

  /// The identifier following `<module>.`: `closure #1 in MyApp.Checkout.pay()`
  /// and `MyApp.Checkout.pay()` both yield `Checkout`, `MyApp.helper()` yields
  /// `helper`. Nil when the symbol does not belong to the module.
  static func outermostDeclaration(in demangled: String, module: String) -> String? {
    let prefix = module + "."
    var searchRange = demangled.startIndex..<demangled.endIndex
    while let found = demangled.range(of: prefix, range: searchRange) {
      let identifierStart = found.upperBound
      var end = identifierStart
      while end < demangled.endIndex, demangled[end].isLetter || demangled[end].isNumber || demangled[end] == "_" {
        end = demangled.index(after: end)
      }
      let identifier = demangled[identifierStart..<end]
      // `MyApp.` inside another identifier (e.g. `NotMyApp.`) is not the module.
      let precededByIdentifier = found.lowerBound > demangled.startIndex
        && (demangled[demangled.index(before: found.lowerBound)].isLetter
            || demangled[demangled.index(before: found.lowerBound)].isNumber
            || demangled[demangled.index(before: found.lowerBound)] == "_")
      if !precededByIdentifier, !identifier.isEmpty { return String(identifier) }
      if end >= demangled.endIndex { return nil }
      searchRange = end..<demangled.endIndex
    }
    return nil
  }

  static func hex(_ value: UInt) -> String {
    "0x" + String(value, radix: 16)
  }
}

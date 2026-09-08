import Foundation

/// `swift_demangle` from libswiftCore, looked up at runtime because it is not
/// declared in any public header. Present on every Apple platform that runs Swift.
enum Demangle {
  private typealias Function = @convention(c) (
    UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
  ) -> UnsafeMutablePointer<CChar>?

  private static let function: Function? = {
    // RTLD_DEFAULT: search every loaded image. libswiftCore may be loaded by a
    // bundle rather than the main executable (test bundles do exactly that).
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "swift_demangle") else { return nil }
    return unsafeBitCast(symbol, to: Function.self)
  }()

  static func isSwiftSymbol(_ name: String) -> Bool {
    name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") || name.hasPrefix("_$S")
      || name.hasPrefix("_T0") || name.hasPrefix("$e") || name.hasPrefix("_$e")
  }

  /// The module a mangled Swift symbol starts with: `$s5MyApp...` yields
  /// `MyApp`. Nil for symbols that start with a standard-library shortcut
  /// (`$sSa...` for `Swift.Array`) or are not Swift at all.
  static func module(ofMangled name: String) -> String? {
    guard isSwiftSymbol(name) else { return nil }
    var rest = Substring(name)
    for prefix in ["_$s", "$s", "_$S", "$S", "_T0", "_$e", "$e"] where rest.hasPrefix(prefix) {
      rest = rest.dropFirst(prefix.count)
      break
    }
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard let length = Int(digits), length > 0 else { return nil }
    rest = rest.dropFirst(digits.count)
    guard rest.count >= length else { return nil }
    return String(rest.prefix(length))
  }

  /// Returns the demangled name, or the input when it is not a Swift symbol or
  /// cannot be demangled.
  static func demangle(_ name: String) -> String {
    guard isSwiftSymbol(name), let function = function else { return name }
    return name.withCString { cString -> String in
      guard let result = function(cString, strlen(cString), nil, nil, 0) else { return name }
      defer { free(result) }
      return String(cString: result)
    }
  }
}

import Foundation

/// Turns a Swift `Error` into `exception.values`, outermost first, following
/// `NSUnderlyingErrorKey` for the cause chain.
enum ErrorConverter {
  static func convert(_ error: Error, inAppModules: [String], handled: Bool, callStack: [UInt],
                      skipFrames: Int) -> [String: Any] {
    var values: [[String: Any]] = []
    var current: Error? = error
    var depth = 0
    while let error = current, depth < 8 {
      var value: [String: Any] = [
        "type": typeName(of: error),
        "value": message(of: error) ?? "",
        "mechanism": ["type": "generic", "handled": handled],
      ]
      let nsError = error as NSError
      value["domain"] = nsError.domain
      value["code"] = nsError.code
      if depth == 0 {
        let frames = StackFrames.frames(for: callStack, inAppModules: inAppModules, skipFrames: skipFrames)
        if !frames.isEmpty { value["stacktrace"] = ["frames": frames] }
      }
      values.append(value)
      current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
      depth += 1
    }
    return ["values": values]
  }

  /// `MyApp.CheckoutError` for a Swift type; the domain for a plain `NSError`,
  /// whose class name would say nothing about what went wrong.
  static func typeName(of error: Error) -> String {
    if type(of: error) is NSError.Type, !(error as NSError).domain.isEmpty { return (error as NSError).domain }
    return String(reflecting: type(of: error))
  }

  static func message(of error: Error) -> String? {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    if type(of: error) is NSError.Type { return (error as NSError).localizedDescription }
    return String(describing: error)
  }
}

import Foundation

/// Makes application-supplied values representable as JSON.
///
/// `Scope.setContext`, `CaptureContext.context` and `beforeSend` all take
/// `Any`, so an application can hand the SDK a `Date`, a `URL`, a `Double.nan`
/// or any other object. `JSONSerialization` rejects those, and a rejected
/// value used to be fatal in a way that was impossible to notice: a context
/// set once on the global scope is copied onto *every* event, so every
/// envelope failed to serialise and the client counted every event as
/// oversized. Reporting stopped for the life of the process and nothing said
/// why.
///
/// Rewriting the value is preferred over dropping the event: an approximation
/// of the context is worth more than the crash it was attached to.
enum JSONValues {
  /// Deep enough for any realistic context, shallow enough that a cyclic
  /// `NSMutableDictionary` cannot recurse forever.
  private static let maxDepth = 32

  static func sanitized(_ object: [String: Any]) -> [String: Any] {
    object.mapValues { sanitized($0, depth: 0) }
  }

  static func sanitized(_ value: Any, depth: Int = 0) -> Any {
    if depth >= maxDepth { return String(describing: value) }
    switch value {
    case is String, is NSNull:
      return value
    case let number as NSNumber:
      // Booleans are NSNumber too, and are already valid JSON.
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
      let double = number.doubleValue
      // NaN and the infinities are the one numeric shape JSON cannot carry.
      return double.isFinite ? number : String(describing: double)
    case let date as Date:
      return Timestamps.iso8601(date)
    case let url as URL:
      return url.absoluteString
    case let data as Data:
      return data.base64EncodedString()
    case let array as [Any]:
      return array.map { sanitized($0, depth: depth + 1) }
    case let dictionary as [String: Any]:
      return dictionary.mapValues { sanitized($0, depth: depth + 1) }
    case let dictionary as [AnyHashable: Any]:
      // An `NSDictionary` from Objective-C may be keyed by anything.
      var result: [String: Any] = [:]
      for (key, element) in dictionary {
        result[key as? String ?? String(describing: key)] = sanitized(element, depth: depth + 1)
      }
      return result
    default:
      return String(describing: value)
    }
  }
}

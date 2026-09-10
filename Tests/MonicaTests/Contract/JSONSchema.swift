import Foundation

/// The part of JSON Schema draft 2020-12 that MONICA's `envelope.json` and
/// `error.json` actually use, and nothing more.
///
/// A general validator would silently accept a keyword it does not implement
/// and the contract test would then check less than it claims. This one refuses
/// to load a schema that uses a keyword outside the list below, so a tightened
/// bundle fails the test loudly instead of passing through unchecked.
final class JSONSchema {
  struct Issue: CustomStringConvertible, Equatable {
    let path: String
    let message: String
    var description: String { "\(path): \(message)" }
  }

  enum LoadError: Error, CustomStringConvertible {
    case notAnObject(String)
    case unsupportedKeyword(String, at: String)
    case malformedKeyword(String, at: String, expected: String)
    var description: String {
      switch self {
      case .notAnObject(let where_): return "\(where_) is not a JSON object"
      case .unsupportedKeyword(let keyword, let at):
        return "unsupported JSON Schema keyword `\(keyword)` at \(at); teach JSONSchema.swift before trusting the result"
      case .malformedKeyword(let keyword, let at, let expected):
        return "JSON Schema keyword `\(keyword)` at \(at) is not \(expected); teach JSONSchema.swift before trusting the result"
      }
    }
  }

  /// Every keyword the validator implements. `format` is listed because
  /// draft 2020-12 makes it an annotation: it is read, and deliberately not
  /// asserted, exactly as the bundle's README asks.
  private static let supported: Set<String> = [
    "$schema", "$id", "title", "description", "type", "properties", "required", "$ref", "$defs",
    "enum", "const", "anyOf", "not", "minLength", "maxLength", "minItems", "maxItems", "minimum",
    "pattern", "format", "items", "additionalProperties", "propertyNames",
  ]

  let root: [String: Any]
  private var patterns: [String: NSRegularExpression] = [:]

  init(_ root: [String: Any]) throws {
    self.root = root
    try Self.audit(root, at: "#")
  }

  static func load(_ url: URL) throws -> JSONSchema {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
      throw LoadError.notAnObject(url.lastPathComponent)
    }
    return try JSONSchema(object)
  }

  /// A copy with the sub-schema at `pointer` replaced. Used to validate
  /// against a relaxation the bundle has not shipped yet; see the contract test.
  func replacing(pointer: String, with replacement: [String: Any]) throws -> JSONSchema {
    var copy = root
    let segments = pointer.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    func set(_ object: [String: Any], _ index: Int) -> [String: Any] {
      var object = object
      if index == segments.count - 1 {
        object[segments[index]] = replacement
      } else if let child = object[segments[index]] as? [String: Any] {
        object[segments[index]] = set(child, index + 1)
      }
      return object
    }
    copy = set(copy, 0)
    return try JSONSchema(copy)
  }

  /// Checks the *shape* of every keyword's value, not just its name.
  ///
  /// Allowlisting names alone is not enough. `"type": ["string", "null"]` is
  /// legal draft 2020-12 and would have loaded clean, and the validator's
  /// `schema["type"] as? String` would then have been nil — dropping the type
  /// constraint entirely instead of failing loudly, which is exactly what this
  /// file's doc comment promises cannot happen. The same held for
  /// `"enum": "x"`, `"required": "x"` and `"minLength": "3"`.
  private static func auditShape(_ keyword: String, _ value: Any, at path: String) throws {
    func require(_ condition: Bool, _ expected: String) throws {
      if !condition { throw LoadError.malformedKeyword(keyword, at: path, expected: expected) }
    }
    func isInteger(_ value: Any) -> Bool {
      guard let number = value as? NSNumber, !isBoolean(value) else { return false }
      return number.doubleValue == number.doubleValue.rounded()
    }
    switch keyword {
    case "$schema", "$id", "title", "description", "$ref", "pattern", "format":
      try require(value is String, "a string")
    case "type":
      // Both forms draft 2020-12 allows. The array form is validated as a union.
      if let names = value as? [Any] {
        try require(!names.isEmpty && names.allSatisfy { $0 is String }, "a non-empty array of strings")
      } else {
        try require(value is String, "a string or an array of strings")
      }
    case "required":
      try require((value as? [Any])?.allSatisfy { $0 is String } ?? false, "an array of strings")
    case "enum", "anyOf":
      try require((value as? [Any])?.isEmpty == false, "a non-empty array")
    case "minLength", "maxLength", "minItems", "maxItems":
      try require(isInteger(value), "an integer")
    case "minimum":
      try require(value is NSNumber && !isBoolean(value), "a number")
    case "properties", "$defs", "items", "not", "additionalProperties", "propertyNames":
      try require(value is [String: Any], "a JSON object")
    case "const":
      break // Any JSON value is a legal const.
    default:
      throw LoadError.unsupportedKeyword(keyword, at: path)
    }
  }

  private static func audit(_ schema: [String: Any], at path: String) throws {
    for (keyword, value) in schema {
      guard supported.contains(keyword) else { throw LoadError.unsupportedKeyword(keyword, at: path) }
      try auditShape(keyword, value, at: path)
      switch keyword {
      case "properties", "$defs":
        for (name, sub) in (value as? [String: Any]) ?? [:] {
          guard let sub = sub as? [String: Any] else { throw LoadError.notAnObject("\(path)/\(keyword)/\(name)") }
          try audit(sub, at: "\(path)/\(keyword)/\(name)")
        }
      case "items", "not", "additionalProperties", "propertyNames":
        guard let sub = value as? [String: Any] else { throw LoadError.notAnObject("\(path)/\(keyword)") }
        try audit(sub, at: "\(path)/\(keyword)")
      case "anyOf":
        for (index, sub) in ((value as? [Any]) ?? []).enumerated() {
          guard let sub = sub as? [String: Any] else { throw LoadError.notAnObject("\(path)/anyOf/\(index)") }
          try audit(sub, at: "\(path)/anyOf/\(index)")
        }
      default:
        break
      }
    }
  }

  // MARK: reading the schema

  /// The node at a JSON pointer such as `/$defs/errorItem/properties/platform`.
  func pointer(_ path: String) -> Any? {
    var current: Any? = root
    for segment in path.split(separator: "/").map(String.init) where !segment.isEmpty {
      current = (current as? [String: Any])?[segment]
    }
    return current
  }

  func definitionNames() -> [String] {
    ((root["$defs"] as? [String: Any]) ?? [:]).keys.sorted()
  }

  private func resolve(_ reference: String) -> [String: Any]? {
    guard reference.hasPrefix("#/") else { return nil }
    return pointer(String(reference.dropFirst(1))) as? [String: Any]
  }

  // MARK: validating

  func validate(_ instance: Any) -> [Issue] {
    var issues: [Issue] = []
    validate(instance, against: root, path: "$", issues: &issues)
    return issues
  }

  /// Validates against a sub-schema of this document (its `$ref`s still resolve here).
  func validate(_ instance: Any, at pointer: String) -> [Issue] {
    var issues: [Issue] = []
    guard let sub = self.pointer(pointer) as? [String: Any] else {
      return [Issue(path: "$", message: "no schema at \(pointer)")]
    }
    validate(instance, against: sub, path: "$", issues: &issues)
    return issues
  }

  private func validate(_ value: Any, against schema: [String: Any], path: String, issues: inout [Issue]) {
    if let reference = schema["$ref"] as? String {
      guard let target = resolve(reference) else {
        issues.append(Issue(path: path, message: "unresolvable $ref \(reference)"))
        return
      }
      validate(value, against: target, path: path, issues: &issues)
    }
    if let type = schema["type"] {
      // `type` is either a name or a union of names; the audit has already
      // rejected anything else.
      let names = (type as? String).map { [$0] } ?? (type as? [String]) ?? []
      if !names.contains(where: { Self.matches(type: $0, value) }) {
        issues.append(Issue(path: path, message: "expected \(names.joined(separator: " or "))"))
        return
      }
    }
    if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { Self.equal($0, value) }) {
      issues.append(Issue(path: path, message: "not one of \(allowed)"))
    }
    if let constant = schema["const"], !Self.equal(constant, value) {
      issues.append(Issue(path: path, message: "expected the constant \(constant)"))
    }
    if let variants = schema["anyOf"] as? [[String: Any]] {
      let satisfied = variants.contains { variant in
        var sub: [Issue] = []
        validate(value, against: variant, path: path, issues: &sub)
        return sub.isEmpty
      }
      if !satisfied { issues.append(Issue(path: path, message: "matches none of anyOf")) }
    }
    if let negated = schema["not"] as? [String: Any] {
      var sub: [Issue] = []
      validate(value, against: negated, path: path, issues: &sub)
      if sub.isEmpty { issues.append(Issue(path: path, message: "matches the schema it must not")) }
    }

    if let string = value as? String {
      let length = string.unicodeScalars.count
      if let minimum = schema["minLength"] as? Int, length < minimum {
        issues.append(Issue(path: path, message: "shorter than minLength \(minimum)"))
      }
      if let maximum = schema["maxLength"] as? Int, length > maximum {
        issues.append(Issue(path: path, message: "longer than maxLength \(maximum)"))
      }
      if let pattern = schema["pattern"] as? String, !matches(pattern: pattern, string) {
        issues.append(Issue(path: path, message: "does not match pattern \(pattern)"))
      }
    }
    if let number = value as? NSNumber, !Self.isBoolean(value) {
      if let minimum = schema["minimum"] as? NSNumber, number.compare(minimum) == .orderedAscending {
        issues.append(Issue(path: path, message: "below minimum \(minimum)"))
      }
    }
    if let array = value as? [Any] {
      if let minimum = schema["minItems"] as? Int, array.count < minimum {
        issues.append(Issue(path: path, message: "fewer than minItems \(minimum)"))
      }
      if let maximum = schema["maxItems"] as? Int, array.count > maximum {
        issues.append(Issue(path: path, message: "more than maxItems \(maximum)"))
      }
      if let items = schema["items"] as? [String: Any] {
        for (index, element) in array.enumerated() {
          validate(element, against: items, path: "\(path)[\(index)]", issues: &issues)
        }
      }
    }
    if let object = value as? [String: Any] {
      for name in (schema["required"] as? [String]) ?? [] where object[name] == nil {
        issues.append(Issue(path: "\(path).\(name)", message: "required"))
      }
      let properties = (schema["properties"] as? [String: Any]) ?? [:]
      for (name, property) in properties {
        guard let child = object[name], let property = property as? [String: Any] else { continue }
        validate(child, against: property, path: "\(path).\(name)", issues: &issues)
      }
      if let additional = schema["additionalProperties"] as? [String: Any] {
        for (name, child) in object where properties[name] == nil {
          validate(child, against: additional, path: "\(path).\(name)", issues: &issues)
        }
      }
      if let names = schema["propertyNames"] as? [String: Any] {
        for name in object.keys { validate(name, against: names, path: "\(path).\(name)", issues: &issues) }
      }
    }
  }

  private func matches(pattern: String, _ string: String) -> Bool {
    let regex: NSRegularExpression
    if let cached = patterns[pattern] {
      regex = cached
    } else {
      guard let compiled = try? NSRegularExpression(pattern: pattern) else { return false }
      patterns[pattern] = compiled
      regex = compiled
    }
    return regex.firstMatch(in: string, range: NSRange(string.startIndex..<string.endIndex, in: string)) != nil
  }

  private static func matches(type: String, _ value: Any) -> Bool {
    switch type {
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "string": return value is String
    case "boolean": return isBoolean(value)
    case "null": return value is NSNull
    case "number": return value is NSNumber && !isBoolean(value)
    case "integer":
      guard let number = value as? NSNumber, !isBoolean(value) else { return false }
      let double = number.doubleValue
      return double.isFinite && double == double.rounded()
    default: return false
    }
  }

  /// `JSONSerialization` hands back booleans as `NSNumber`; only the Core
  /// Foundation type id tells them apart from 0 and 1.
  static func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
    if isBoolean(lhs) != isBoolean(rhs) { return false }
    return (lhs as AnyObject).isEqual(rhs as AnyObject)
  }
}

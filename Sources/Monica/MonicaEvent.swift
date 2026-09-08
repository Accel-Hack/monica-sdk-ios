import Foundation

/// Severity, in the vocabulary of `spec/v1/envelope.json`.
public enum MonicaLevel: String, CaseIterable {
  case fatal, error, warning, info, debug
}

/// One error item as it will be serialised. Keys follow `spec/v1/envelope.json`;
/// `beforeSend` may read, rewrite or remove any of them.
public final class MonicaEvent {
  private var storage: [String: Any]

  public init(_ values: [String: Any] = [:]) {
    storage = values
  }

  public var values: [String: Any] { storage }

  public subscript(key: String) -> Any? {
    get { storage[key] }
    set {
      if let value = newValue { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
  }

  @discardableResult
  public func put(_ key: String, _ value: Any?) -> MonicaEvent {
    self[key] = value
    return self
  }

  @discardableResult
  public func remove(_ key: String) -> MonicaEvent {
    storage.removeValue(forKey: key)
    return self
  }

  /// `event_id`, always present once the client has built the event.
  public var eventId: String? { storage["event_id"] as? String }
  public var level: MonicaLevel? { (storage["level"] as? String).flatMap(MonicaLevel.init(rawValue:)) }
}

/// Extra facts for a single capture: level, tags and contexts on top of the scope.
public struct CaptureContext {
  public var level: MonicaLevel = .error
  public var message: String?
  public var handled: Bool = true
  public var tags: [String: String] = [:]
  public var contexts: [String: Any] = [:]

  public init() {}

  public func level(_ value: MonicaLevel) -> CaptureContext {
    var copy = self
    copy.level = value
    return copy
  }

  public func message(_ value: String) -> CaptureContext {
    var copy = self
    copy.message = value
    return copy
  }

  public func handled(_ value: Bool) -> CaptureContext {
    var copy = self
    copy.handled = value
    return copy
  }

  public func tag(_ key: String, _ value: String) -> CaptureContext {
    var copy = self
    copy.tags[key] = value
    return copy
  }

  public func context(_ key: String, _ value: Any) -> CaptureContext {
    var copy = self
    copy.contexts[key] = value
    return copy
  }
}

/// What `beforeSend` gets alongside the event.
public struct CaptureHint {
  /// The error passed to `captureError`, or nil for messages and crashes.
  public let originalError: Error?

  public init(originalError: Error? = nil) {
    self.originalError = originalError
  }
}

public struct MonicaStats: Equatable {
  public let queued: Int
  public let discarded: Int

  public init(queued: Int, discarded: Int) {
    self.queued = queued
    self.discarded = discarded
  }
}

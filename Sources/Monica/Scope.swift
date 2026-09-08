import Foundation

/// Tags, contexts, breadcrumbs and the user, applied to every event.
public final class Scope {
  static let defaultMaxBreadcrumbs = 100

  private let lock = NSLock()
  private var tags: [String: String] = [:]
  private var contexts: [String: Any] = [:]
  private var breadcrumbs: [[String: Any]] = []
  private var user: [String: Any]?
  private let maxBreadcrumbs: Int

  init(maxBreadcrumbs: Int = Scope.defaultMaxBreadcrumbs) {
    precondition(maxBreadcrumbs > 0, "maxBreadcrumbs must be positive")
    self.maxBreadcrumbs = maxBreadcrumbs
  }

  @discardableResult
  public func setTag(_ key: String, _ value: String) -> Scope {
    lock.lock(); defer { lock.unlock() }
    tags[key] = value
    return self
  }

  @discardableResult
  public func setContext(_ key: String, _ value: [String: Any]) -> Scope {
    lock.lock(); defer { lock.unlock() }
    contexts[key] = value
    return self
  }

  /// Identifies the person the events belong to. Nothing about them is sent
  /// until an application calls this, and `beforeSend` still gets the last word.
  @discardableResult
  public func setUser(_ value: [String: Any]?) -> Scope {
    lock.lock(); defer { lock.unlock() }
    user = (value?.isEmpty ?? true) ? nil : value
    return self
  }

  @discardableResult
  public func addBreadcrumb(category: String, message: String) -> Scope {
    lock.lock(); defer { lock.unlock() }
    breadcrumbs.append([
      "timestamp": Timestamps.iso8601(Date()),
      "category": category,
      "message": message,
    ])
    // A long-lived app must not grow its scope forever; drop the oldest.
    if breadcrumbs.count > maxBreadcrumbs {
      breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs)
    }
    return self
  }

  func apply(to event: MonicaEvent) {
    let snapshot = self.snapshot()
    var mergedTags = snapshot.tags
    if let eventTags = event["tags"] as? [String: String] {
      for (key, value) in eventTags { mergedTags[key] = value }
    }
    if !mergedTags.isEmpty { event["tags"] = mergedTags }

    var mergedContexts = snapshot.contexts
    if let eventContexts = event["contexts"] as? [String: Any] {
      for (key, value) in eventContexts { mergedContexts[key] = value }
    }
    if !mergedContexts.isEmpty { event["contexts"] = mergedContexts }
    if !snapshot.breadcrumbs.isEmpty && event["breadcrumbs"] == nil {
      event["breadcrumbs"] = snapshot.breadcrumbs
    }
    if let user = snapshot.user, event["user"] == nil { event["user"] = user }
  }

  struct Snapshot {
    var tags: [String: String]
    var contexts: [String: Any]
    var breadcrumbs: [[String: Any]]
    var user: [String: Any]?
  }

  func snapshot() -> Snapshot {
    lock.lock(); defer { lock.unlock() }
    return Snapshot(tags: tags, contexts: contexts, breadcrumbs: breadcrumbs, user: user)
  }
}

enum Timestamps {
  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()
  private static let lock = NSLock()

  static func iso8601(_ date: Date) -> String {
    lock.lock(); defer { lock.unlock() }
    return formatter.string(from: date)
  }
}

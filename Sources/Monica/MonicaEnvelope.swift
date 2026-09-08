import Foundation

/// What goes on the wire: the top level of `spec/v1/envelope.json`.
public struct MonicaEnvelope {
  public let sdk: [String: String]
  public let sentAt: String
  public let discarded: Int
  public let items: [MonicaEvent]

  init(sdkName: String, sdkVersion: String, sentAt: String, discarded: Int, items: [MonicaEvent]) {
    sdk = ["name": sdkName, "version": sdkVersion]
    self.sentAt = sentAt
    self.discarded = discarded
    self.items = items
  }

  public func jsonObject() -> [String: Any] {
    [
      "sdk": sdk,
      "sent_at": sentAt,
      "discarded": discarded,
      "items": items.map { $0.values },
    ]
  }

  /// Serialises the envelope. Throws when application-supplied context is not
  /// representable as JSON, which the client treats like an oversized event.
  public func jsonData() throws -> Data {
    let object = jsonObject()
    guard JSONSerialization.isValidJSONObject(object) else {
      throw MonicaEnvelopeError.notSerializable
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

public enum MonicaEnvelopeError: Error {
  case notSerializable
}

import Foundation
import Monica

/// The SDK logs nothing itself; this is where a person watching the console
/// sees whether ingest accepted the envelope.
final class LoggingTransport: MonicaTransport {
  private let inner: MonicaTransport

  init(_ inner: MonicaTransport) {
    self.inner = inner
  }

  func send(_ envelope: MonicaEnvelope) throws -> Bool {
    let started = Date()
    let accepted = try inner.send(envelope)
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    NSLog("[\(AppDelegate.tag)] \(accepted ? "accepted" : "REJECTED") \(envelope.items.count) item(s), \(elapsed)ms")
    return accepted
  }
}

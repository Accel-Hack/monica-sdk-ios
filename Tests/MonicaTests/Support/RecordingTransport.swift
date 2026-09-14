import Foundation
import Monica
import XCTest

final class RecordingTransport: MonicaTransport {
  private let lock = NSLock()
  private(set) var envelopes: [MonicaEnvelope] = []
  var accept = true
  private var gate: DispatchSemaphore?

  /// Parks the sender inside ``send(_:)`` until ``open()``, and lets every send
  /// through from then on. Capturing and the sender queue run at the same time,
  /// so a test that wants a known split has to keep the sender out of the way
  /// while it fills the queue.
  ///
  /// The envelope is recorded before the wait, so `envelopes` tells a test that
  /// the sender really has arrived and parked, the way `BlockingTransport.sends`
  /// does.
  func hold() {
    lock.lock(); defer { lock.unlock() }
    gate = DispatchSemaphore(value: 0)
  }

  func open() {
    lock.lock(); let gate = self.gate; lock.unlock()
    gate?.signal()
  }

  func send(_ envelope: MonicaEnvelope) throws -> Bool {
    lock.lock()
    envelopes.append(envelope)
    let gate = self.gate
    let accept = self.accept
    lock.unlock()
    // A turnstile: whoever gets through signals the next one, so the gate stays
    // open once it has been opened.
    if let gate { gate.wait(); gate.signal() }
    return accept
  }

  var items: [MonicaEvent] {
    lock.lock(); defer { lock.unlock() }
    return envelopes.flatMap { $0.items }
  }

  /// The single delivered item. A wrong count fails the test rather than
  /// trapping the whole process, and returns an empty event so the remaining
  /// assertions report what they saw.
  func only(file: StaticString = #filePath, line: UInt = #line) -> MonicaEvent {
    let all = items
    if all.count != 1 {
      XCTFail("expected exactly one item, got \(all.count): \(all.map { $0.values })", file: file, line: line)
      return all.first ?? MonicaEvent()
    }
    return all[0]
  }
}

/// A transport whose `send` throws, as an app-supplied one might.
final class ThrowingTransport: MonicaTransport {
  struct Failure: Error {}
  private(set) var attempts = 0
  func send(_ envelope: MonicaEnvelope) throws -> Bool {
    attempts += 1
    throw Failure()
  }
}

/// A transport that blocks the sender queue until released.
final class BlockingTransport: MonicaTransport {
  let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private(set) var envelopes: [MonicaEnvelope] = []
  var sends: Int { lock.lock(); defer { lock.unlock() }; return envelopes.count }
  func send(_ envelope: MonicaEnvelope) throws -> Bool {
    lock.lock(); envelopes.append(envelope); lock.unlock()
    gate.wait()
    return true
  }
}

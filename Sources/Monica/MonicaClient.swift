import Foundation

/// Queue, batching, sampling, `beforeSend` and envelope splitting. Mirrors
/// monica-core so the wire behaviour is the same as the Java SDKs.
public final class MonicaClient {
  // The ingest endpoint allows 1 MiB after gzip. A JSON preflight below one
  // million bytes also protects the decompressed limit and leaves framing room.
  static let maxSafeEnvelopeJSONBytes = 1_000_000
  private static let senderKey = DispatchSpecificKey<Bool>()
  private static let inBeforeSendKey = "com.accelhack.monica.inBeforeSend"

  private let options: ValidatedOptions
  private let transport: MonicaTransport
  private let inAppModules: [String]
  private let release: String?
  private let sender = DispatchQueue(label: "monica-swift-sender")
  private let timer: DispatchSourceTimer
  private let lock = NSLock()
  private var queue: [MonicaEvent] = []
  private var discarded = 0
  private var closed = false
  let globalScope: Scope
  var now: () -> Date = { Date() }
  var random: () -> Double = { Double.random(in: 0..<1) }

  init(options: ValidatedOptions, transport: MonicaTransport, inAppModules: [String], release: String?) {
    self.options = options
    self.transport = transport
    self.inAppModules = inAppModules
    self.release = release
    globalScope = Scope(maxBreadcrumbs: options.options.maxBreadcrumbs)
    sender.setSpecific(key: Self.senderKey, value: true)
    timer = DispatchSource.makeTimerSource(queue: sender)
    let interval = options.options.flushInterval
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in self?.drainBestEffort() }
    timer.resume()
  }

  // MARK: capture

  public func captureError(_ error: Error, context: CaptureContext = CaptureContext()) -> String? {
    if isClosed || Self.isInsideBeforeSend { return nil }
    // Swift errors carry no stack; the capture site is the best available.
    let addresses = Thread.callStackReturnAddresses.map { UInt($0.uintValue) }
    return captureError(error, context: context, callStack: addresses, skipFrames: 1)
  }

  func captureError(_ error: Error, context: CaptureContext, callStack: [UInt], skipFrames: Int) -> String? {
    if isClosed || Self.isInsideBeforeSend { return nil }
    let event = baseEvent(level: context.level)
    event["exception"] = ErrorConverter.convert(error, inAppModules: inAppModules, handled: context.handled,
                                                 callStack: callStack, skipFrames: skipFrames)
    event["message"] = context.message ?? ErrorConverter.message(of: error)
    apply(context, to: event)
    return prepareAndEnqueue(event, hint: CaptureHint(originalError: error), applyScope: true)
  }

  public func captureMessage(_ message: String, context: CaptureContext = CaptureContext()) -> String? {
    if isClosed || Self.isInsideBeforeSend { return nil }
    let event = baseEvent(level: context.level)
    event["message"] = message
    apply(context, to: event)
    return prepareAndEnqueue(event, hint: CaptureHint(), applyScope: true)
  }

  /// Enqueues an event that was assembled elsewhere: the crash report from the
  /// previous launch. The current scope is not applied because it describes
  /// this launch, not the one that crashed. `beforeSend` still runs.
  func capturePrepared(_ event: MonicaEvent) -> String? {
    if isClosed || Self.isInsideBeforeSend { return nil }
    return prepareAndEnqueue(event, hint: CaptureHint(), applyScope: false)
  }

  // MARK: lifecycle

  public var stats: MonicaStats {
    lock.lock(); defer { lock.unlock() }
    return MonicaStats(queued: queue.count, discarded: discarded)
  }

  public func flush(timeout: TimeInterval) -> Bool {
    if timeout < 0 { return false }
    if DispatchQueue.getSpecific(key: Self.senderKey) == true {
      var accepted = true
      while queued > 0 { accepted = drainOnce() && accepted }
      return accepted
    }
    let done = DispatchSemaphore(value: 0)
    var accepted = false
    sender.async { [weak self] in
      guard let self = self else { done.signal(); return }
      var result = true
      while self.queued > 0 { result = self.drainOnce() && result }
      accepted = result
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut { return false }
    return accepted
  }

  @discardableResult
  public func close(timeout: TimeInterval? = nil) -> Bool {
    lock.lock()
    if closed { lock.unlock(); return stats.queued == 0 }
    closed = true
    lock.unlock()
    let accepted = flush(timeout: timeout ?? options.options.flushTimeout)
    timer.cancel()
    transport.close()
    return accepted
  }

  private var isClosed: Bool {
    lock.lock(); defer { lock.unlock() }
    return closed
  }

  // MARK: internals

  private func baseEvent(level: MonicaLevel) -> MonicaEvent {
    let event = MonicaEvent([
      "type": "error",
      "event_id": UUID().uuidString.lowercased(),
      "timestamp": Timestamps.iso8601(now()),
      "level": level.rawValue,
      "platform": Monica.platformName,
      "environment": options.environment,
    ])
    if let release = release { event["release"] = release }
    return event
  }

  private func apply(_ context: CaptureContext, to event: MonicaEvent) {
    if !context.tags.isEmpty { event["tags"] = context.tags }
    if !context.contexts.isEmpty { event["contexts"] = context.contexts }
  }

  private func prepareAndEnqueue(_ original: MonicaEvent, hint: CaptureHint, applyScope: Bool) -> String? {
    if random() >= options.options.sampleRate { return nil }
    if applyScope { globalScope.apply(to: original) }
    guard let event = runBeforeSend(original, hint: hint) else { return nil }
    let eventId = event.eventId
    var sendNow = false
    lock.lock()
    if closed { lock.unlock(); return nil }
    if queue.count >= options.options.maxQueueSize {
      queue.removeFirst()
      discarded += 1
    }
    queue.append(event)
    sendNow = event.level == .fatal || queue.count >= options.options.batchSize
    lock.unlock()
    if sendNow { sender.async { [weak self] in self?.drainBestEffort() } }
    return eventId
  }

  /// A `beforeSend` that captures again would recurse until the stack is gone
  /// (Java catches the StackOverflowError; Swift cannot). Captures made while
  /// the hook runs on this thread are dropped instead.
  private func runBeforeSend(_ event: MonicaEvent, hint: CaptureHint) -> MonicaEvent? {
    guard let beforeSend = options.options.beforeSend else { return event }
    let thread = Thread.current.threadDictionary
    thread[Self.inBeforeSendKey] = true
    defer { thread.removeObject(forKey: Self.inBeforeSendKey) }
    return beforeSend(event, hint)
  }

  private static var isInsideBeforeSend: Bool {
    Thread.current.threadDictionary[inBeforeSendKey] as? Bool == true
  }

  private var queued: Int {
    lock.lock(); defer { lock.unlock() }
    return queue.count
  }

  private func drainBestEffort() {
    _ = drainOnce()
  }

  private func drainOnce() -> Bool {
    var batch: [MonicaEvent] = []
    var pendingDiscarded = 0
    lock.lock()
    let count = min(queue.count, options.options.batchSize)
    batch = Array(queue.prefix(count))
    queue.removeFirst(count)
    if batch.isEmpty { lock.unlock(); return true }
    pendingDiscarded = discarded
    discarded = 0
    lock.unlock()

    var oversizedDrop = false
    while !batch.isEmpty {
      let sentAt = Timestamps.iso8601(now())
      let fitting = fittingItemCount(batch, sentAt: sentAt, discarded: pendingDiscarded)
      if fitting == 0 {
        batch.removeFirst()
        pendingDiscarded += 1
        oversizedDrop = true
        continue
      }
      let envelope = MonicaEnvelope(sdkName: Monica.sdkName, sdkVersion: Monica.sdkVersion, sentAt: sentAt,
                                    discarded: pendingDiscarded, items: Array(batch.prefix(fitting)))
      let accepted = (try? transport.send(envelope)) ?? false
      if !accepted {
        lock.lock()
        discarded += pendingDiscarded + batch.count
        lock.unlock()
        return false
      }
      batch.removeFirst(fitting)
      pendingDiscarded = 0
    }
    if pendingDiscarded > 0 {
      lock.lock()
      discarded += pendingDiscarded
      lock.unlock()
    }
    return !oversizedDrop
  }

  private func fittingItemCount(_ items: [MonicaEvent], sentAt: String, discarded: Int) -> Int {
    if !fits(Array(items.prefix(1)), sentAt: sentAt, discarded: discarded) { return 0 }
    var count = items.count
    while count > 1 {
      if fits(Array(items.prefix(count)), sentAt: sentAt, discarded: discarded) { return count }
      count -= 1
    }
    return 1
  }

  private func fits(_ items: [MonicaEvent], sentAt: String, discarded: Int) -> Bool {
    let candidate = MonicaEnvelope(sdkName: Monica.sdkName, sdkVersion: Monica.sdkVersion, sentAt: sentAt,
                                   discarded: discarded, items: items)
    // Non-serializable application context is treated like an oversized event
    // so it cannot poison otherwise valid events in the same batch.
    guard let data = try? candidate.jsonData() else { return false }
    return data.count <= Self.maxSafeEnvelopeJSONBytes
  }
}

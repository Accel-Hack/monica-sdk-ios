import Foundation
import os

/// One field-level complaint from ingest: `error.json` `validationIssue`.
///
/// `path` is a JSON path into the envelope that was posted
/// (`$.items[0].request.method`), so it names the field to fix.
public struct MonicaIssue: Equatable {
  public let path: String
  public let message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

/// What ingest answered for one envelope.
///
/// `accepted` is the boolean ``MonicaTransport/send(_:)`` has always returned.
/// The rest is the diagnosis `transport.json` and `error.json` make available
/// and that this SDK used to throw away: the HTTP `status` (absent when the
/// request never got an answer), and for a `4xx` the `error.code` /
/// `error.message` and the `issues`.
public struct MonicaTransportResult {
  public var accepted: Bool
  /// True once this transport has stopped for good — ingest answered `401`, or
  /// `close()` invalidated the session — so later envelopes are dropped without
  /// a request. It distinguishes that from an envelope that merely failed to get
  /// through, the way `SendResult.isStopped()` does in monica-sdk-java.
  public var stopped: Bool
  /// The HTTP status of the last attempt. Nil when nothing answered (I/O
  /// failure, timeout) or when the transport had already stopped on a `401`.
  public var status: Int?
  /// `error.code`. Meant for people to read: branch on ``status``, not on this.
  public var errorCode: String?
  /// `error.message`.
  public var errorMessage: String?
  /// `error.issues`. Only a `422` carries them.
  public var issues: [MonicaIssue]

  public init(accepted: Bool, status: Int? = nil, errorCode: String? = nil, errorMessage: String? = nil,
              issues: [MonicaIssue] = [], stopped: Bool = false) {
    self.accepted = accepted
    self.stopped = stopped
    self.status = status
    self.errorCode = errorCode
    self.errorMessage = errorMessage
    self.issues = issues
  }
}

/// A warning the SDK wants the developer to see, with the machine-readable
/// result behind it.
///
/// ``message`` is worded the same in every MONICA SDK, so a support answer can
/// be searched for across platforms.
public struct MonicaDiagnostic {
  public var message: String
  public var result: MonicaTransportResult

  public init(message: String, result: MonicaTransportResult) {
    self.message = message
    self.result = result
  }
}

/// Where a ``MonicaDiagnostic`` goes when the application did not ask for
/// something else.
enum MonicaDiagnostics {
  /// `os_log`, not `os.Logger`: `Logger` is iOS 14 and this package supports
  /// iOS 13. The subsystem is the bundle identifier MONICA uses elsewhere in
  /// this SDK, so Console can filter on it.
  static let subsystem = "com.accelhack.monica"
  static let category = "transport"

  private static let log = OSLog(subsystem: subsystem, category: category)

  /// `os_log` truncates a long line, and a 422 on a batch of 30 events can
  /// carry more issues than fit. Only the first few are named; `issues` on the
  /// result keeps every one of them, so nothing is actually lost. The cap is a
  /// mobile-logging concern (monica-android does the same); the server-side
  /// SDKs print them all.
  static let maxIssuesInMessage = 10

  /// The wording all six SDKs share, or nil for a status not worth a warning.
  ///
  /// `422` names the fields to fix:
  /// `monica: ingest rejected the envelope with 422 (invalid_envelope): 1 issue(s); $.items[0].request.method: ...`
  ///
  /// `401` says that this was the last envelope:
  /// `monica: ingest rejected the envelope with 401 (unauthorized); no further envelopes will be sent`
  ///
  /// Neither the DSN key nor the envelope is included: a warning must not turn
  /// into a leak of what was being reported.
  static func message(for result: MonicaTransportResult) -> String? {
    let code = result.errorCode ?? "unknown"
    switch result.status {
    case 401:
      return "monica: ingest rejected the envelope with 401 (\(code)); no further envelopes will be sent"
    case 422:
      var text = "monica: ingest rejected the envelope with 422 (\(code)): \(result.issues.count) issue(s)"
      for issue in result.issues.prefix(maxIssuesInMessage) {
        text += "; \(issue.path): \(issue.message)"
      }
      let hidden = result.issues.count - maxIssuesInMessage
      if hidden > 0 { text += "; and \(hidden) more" }
      return text
    default:
      return nil
    }
  }

  /// `os_log` at error level, the nearest thing `os_log` has to a warning
  /// (`.default` is not surfaced by Xcode's console filter by default).
  /// The package only builds for Apple platforms (see `Package.swift`), so
  /// there is no non-`os` fallback to keep alive.
  static func emit(_ diagnostic: MonicaDiagnostic) {
    os_log("%{public}@", log: log, type: .error, diagnostic.message)
  }
}

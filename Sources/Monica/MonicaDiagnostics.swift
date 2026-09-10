import Foundation
#if canImport(os)
import os
#endif

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
              issues: [MonicaIssue] = []) {
    self.accepted = accepted
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

  #if canImport(os)
  private static let log = OSLog(subsystem: subsystem, category: category)
  #endif

  /// The wording all six SDKs share:
  /// `monica: ingest rejected the envelope with 422 (invalid_envelope): 1 issue(s); $.items[0].request.method: ...`
  ///
  /// Neither the DSN key nor the envelope is included: a warning must not turn
  /// into a leak of what was being reported.
  static func message(for result: MonicaTransportResult) -> String {
    let status = result.status.map(String.init) ?? "no response"
    var text = "monica: ingest rejected the envelope with \(status) (\(result.errorCode ?? "unknown")): "
      + "\(result.issues.count) issue(s)"
    for issue in result.issues {
      text += "; \(issue.path): \(issue.message)"
    }
    return text
  }

  /// `os_log` at error level, the nearest thing `os_log` has to a warning
  /// (`.default` is not surfaced by Xcode's console filter by default).
  static func emit(_ diagnostic: MonicaDiagnostic) {
    #if canImport(os)
    os_log("%{public}@", log: log, type: .error, diagnostic.message)
    #else
    FileHandle.standardError.write(Data((diagnostic.message + "\n").utf8))
    #endif
  }
}

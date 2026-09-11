import Foundation

/// Why the options were rejected. Raised by ``Monica/install(_:)`` so that a
/// misconfiguration fails at launch rather than on the first crash.
public enum MonicaConfigurationError: Error, Equatable, CustomStringConvertible {
  case emptyDSN
  case invalidDSN(String)
  case insecureDSN
  case secretKeyInDSN
  case emptyEnvironment
  case invalidValue(String)

  public var description: String {
    switch self {
    case .emptyDSN: return "dsn must not be empty"
    case .invalidDSN(let reason): return "dsn must be a valid URL: \(reason)"
    case .insecureDSN: return "dsn must use https except for localhost"
    case .secretKeyInDSN:
      return "dsn must contain a public mpk_ key; an msk_ key inside an app bundle is a leaked secret"
    case .emptyEnvironment: return "environment must not be empty"
    case .invalidValue(let reason): return reason
    }
  }
}

/// The parsed project DSN: `https://mpk_xxx@ingest.example/slug`.
struct DSN: Equatable {
  /// `POST /v1/envelope`: the only ingest route (`transport.json` `endpoint.path`).
  static let ingestPath = "/v1/envelope"
  /// The key kind a distributed app may carry (`transport.json` `auth[kind=public]`).
  static let publicKeyPrefix = "mpk_"
  /// Where plain http is tolerated (`transport.json` `dsn.insecure_hosts`).
  static let insecureHosts: Set<String> = ["localhost", "127.0.0.1"]

  let endpoint: URL
  let publicKey: String

  /// An app bundle ships to every user, so anything embedded in it is readable.
  /// A secret key in a distributed artifact is a leak, and failing here is
  /// what keeps it from shipping as one that merely logged a warning.
  static func parse(_ raw: String) throws -> DSN {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw MonicaConfigurationError.emptyDSN }
    guard let components = URLComponents(string: trimmed), let scheme = components.scheme,
      let host = components.host, !host.isEmpty
    else { throw MonicaConfigurationError.invalidDSN(trimmed) }

    let local = insecureHosts.contains(host)
    if scheme != "https" && !local { throw MonicaConfigurationError.insecureDSN }

    let key = components.user ?? ""  // already percent-decoded by URLComponents
    if key.isEmpty { throw MonicaConfigurationError.invalidDSN("no API key") }
    if !key.hasPrefix(publicKeyPrefix) { throw MonicaConfigurationError.secretKeyInDSN }

    var endpoint = URLComponents()
    endpoint.scheme = scheme
    endpoint.host = host
    endpoint.port = components.port
    endpoint.path = ingestPath
    guard let url = endpoint.url else { throw MonicaConfigurationError.invalidDSN(trimmed) }
    return DSN(endpoint: url, publicKey: key)
  }
}

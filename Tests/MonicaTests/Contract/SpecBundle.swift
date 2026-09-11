import CryptoKit
import Foundation

/// The vendored copy of MONICA's public contract bundle, verified against
/// `spec.lock.json` before anything reads it.
///
/// The contract is not owned by this repository. MONICA publishes it at
/// `https://spec.monica.accelhack.net/v1/` and `scripts/spec-sync.py` vendors a
/// copy into `spec/`. A hand-edited copy would turn the contract test into a
/// test of nothing, so every file is checked against the lock's digest and the
/// lock's `revision` is recomputed from those digests (the same definition the
/// bundle's README gives). Missing files fail; they never skip.
enum SpecBundle {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  struct Vector {
    let name: String
    let description: String
    /// Whether MONICA accepts the envelope.
    let valid: Bool
    /// Whether the published JSON Schema rejects it. Defaults to `!valid`; the
    /// bundle sets it to `false` where only MONICA's own validation can tell.
    let schemaRejects: Bool
    let envelope: Any
  }

  struct Loaded {
    let root: URL
    let directory: URL
    let origin: String
    let version: String
    let revision: String
    let schema: JSONSchema
    let errorSchema: JSONSchema
    let limits: [String: Any]
    let transport: [String: Any]
    let vectors: [Vector]
    let payloadObligations: String
  }

  private static let loaded: Result<Loaded, Error> = Result { try load(root: TestSupport.repositoryRoot) }

  /// The verified bundle. Throws (and so fails the calling test) when the
  /// copy is missing, tampered with, or out of step with the lock.
  static func verified() throws -> Loaded {
    try loaded.get()
  }

  static func load(root: URL) throws -> Loaded {
    let lockURL = root.appendingPathComponent("spec.lock.json")
    guard let lockData = try? Data(contentsOf: lockURL),
      let lock = try JSONSerialization.jsonObject(with: lockData) as? [String: Any]
    else { throw Failure(description: "spec.lock.json is missing or unreadable at \(lockURL.path); see README.md") }
    guard let origin = lock["origin"] as? String, let version = lock["version"] as? String,
      let revision = lock["revision"] as? String, let files = lock["files"] as? [String: String]
    else { throw Failure(description: "spec.lock.json must have origin, version, revision and files") }

    let directory = root.appendingPathComponent("spec").appendingPathComponent(version)
    var problems: [String] = []
    for (path, expected) in files {
      let file = directory.appendingPathComponent(path)
      guard let data = try? Data(contentsOf: file) else {
        problems.append("spec/\(version)/\(path) is not vendored")
        continue
      }
      if sha256(data) != expected {
        problems.append("spec/\(version)/\(path) does not match spec.lock.json (edit nothing under spec/; run the sync)")
      }
    }
    for path in filesUnder(directory) where files[path] == nil {
      problems.append("spec/\(version)/\(path) is not declared by spec.lock.json")
    }
    let recomputed = revisionOf(files)
    if recomputed != revision {
      problems.append("spec.lock.json: revision \(revision.prefix(12)) does not match its own files (\(recomputed.prefix(12)))")
    }
    if !problems.isEmpty {
      throw Failure(description:
        "The vendored contract is not what spec.lock.json records.\n  - " + problems.joined(separator: "\n  - ")
          + "\nThe contract lives in MONICA and is pulled in by a script:\n  python3 scripts/spec-sync.py\n"
          + "This must not be skipped: without it a change to the shared contract would only be caught in ingest.")
    }

    let vectorsDirectory = directory.appendingPathComponent("vectors/envelope")
    let vectors = try filesUnder(vectorsDirectory).sorted().map { name -> Vector in
      let url = vectorsDirectory.appendingPathComponent(name)
      guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        let valid = object["valid"] as? Bool, let envelope = object["envelope"]
      else { throw Failure(description: "vectors/envelope/\(name) must have valid and envelope") }
      return Vector(name: name, description: object["description"] as? String ?? "", valid: valid,
                    schemaRejects: (object["schema_rejects"] as? Bool) ?? !valid, envelope: envelope)
    }

    return Loaded(
      root: root, directory: directory, origin: origin, version: version, revision: revision,
      schema: try JSONSchema.load(directory.appendingPathComponent("envelope.json")),
      errorSchema: try JSONSchema.load(directory.appendingPathComponent("error.json")),
      limits: try json(directory.appendingPathComponent("limits.json")),
      transport: try json(directory.appendingPathComponent("transport.json")),
      vectors: vectors,
      payloadObligations: try String(contentsOf: directory.appendingPathComponent("payload.md"), encoding: .utf8))
  }

  private static func json(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
      throw Failure(description: "\(url.lastPathComponent) is not a JSON object")
    }
    return object
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// `"<sha256>  <path>"` lines in byte order of path, joined by "\n" without a
  /// trailing newline, hashed. The bundle's README fixes this definition.
  static func revisionOf(_ files: [String: String]) -> String {
    let lines = files.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
      .map { files[$0]! + "  " + $0 }
    return sha256(Data(lines.joined(separator: "\n").utf8))
  }

  private static func filesUnder(_ directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var found: [String] = []
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      let relative = url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1)
      found.append(String(relative))
    }
    return found
  }
}

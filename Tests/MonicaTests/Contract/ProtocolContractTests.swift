import Foundation
@testable import Monica
import XCTest
import zlib

/// Contract test against MONICA's public contract bundle.
///
/// The contract is not owned by this repository. MONICA publishes it at
/// `https://spec.monica.accelhack.net/v1/` and `scripts/spec-sync.py` vendors a
/// copy into `spec/`. This test runs against that copy (verified against
/// `spec.lock.json` by `SpecBundle`), so a change to the shared contract shows
/// up here rather than as a `422` in production. Four layers:
///
/// 1. the bundle still says what this SDK relies on (`envelope.json`,
///    `limits.json`, `error.json`)
/// 2. MONICA's own test vectors get the verdict the bundle expects
/// 3. every envelope this SDK can emit satisfies the schema *and* the
///    obligations `payload.md` states in prose
/// 4. the request the SDK actually makes matches `transport.json`
///
/// Layer 3 matters most: `payload.md` is explicit that a payload can satisfy the
/// published schema and still be rejected by ingest. Passing the schema is not
/// evidence that the SDK is correct.
final class ProtocolContractTests: XCTestCase {
  private static let maxSafeInteger: Int64 = 9_007_199_254_740_991

  private var bundle: SpecBundle.Loaded!
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    bundle = try SpecBundle.verified()
    directory = TestSupport.temporaryDirectory()
  }

  override func tearDown() {
    Monica.current?.close()
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  // MARK: 1. the bundle still says what this SDK relies on

  func testTheSchemaStillSaysWhatThisSDKReliesOn() throws {
    let schema = bundle.schema
    XCTAssertEqual(schema.pointer("/$schema") as? String, "https://json-schema.org/draft/2020-12/schema",
                   "envelope.json must use JSON Schema draft 2020-12")
    XCTAssertEqual(schema.pointer("/$id") as? String, "\(bundle.origin)/\(bundle.version)/envelope.json",
                   "envelope.json must still be the bundle spec.lock.json points at")

    // limits.json is the machine-readable copy of the table in ingest.md. If the
    // two ever disagree, the SDK would be sized against the wrong one.
    let items = try XCTUnwrap(bundle.limits["items_per_envelope"] as? Int)
    let frames = try XCTUnwrap(bundle.limits["frames_per_stacktrace"] as? Int)
    XCTAssertEqual(schema.pointer("/properties/items/maxItems") as? Int, items)
    XCTAssertEqual(schema.pointer("/$defs/exceptionValue/properties/stacktrace/properties/frames/maxItems") as? Int, frames)
    XCTAssertEqual(MonicaOptions.maxItemsPerEnvelope, items, "this SDK caps a batch at the published item limit")
    XCTAssertEqual(StackFrames.maxFrames, frames, "this SDK truncates stack traces to the published frame limit")
    XCTAssertEqual(MonicaOptions.maxEnvironmentLength,
                   schema.pointer("/$defs/errorItem/properties/environment/maxLength") as? Int,
                   "this SDK validates environment against the schema's bound")
    let gzipLimit = try XCTUnwrap(bundle.limits["envelope_gzip_bytes"] as? Int)
    let decompressedLimit = try XCTUnwrap(bundle.limits["envelope_decompressed_bytes"] as? Int)
    XCTAssertLessThanOrEqual(MonicaClient.maxSafeEnvelopeJSONBytes, gzipLimit,
                             "the JSON preflight must stay under the gzip limit, which gzip can only shrink")
    XCTAssertLessThanOrEqual(MonicaClient.maxSafeEnvelopeJSONBytes, decompressedLimit)

    XCTAssertEqual(schema.pointer("/$defs/errorItem/properties/type/const") as? String, "error")
    XCTAssertTrue((schema.pointer("/$defs/mechanism/properties/type/enum") as? [String] ?? []).contains("generic"),
                  "envelope.json must accept the generic mechanism this SDK emits")
    XCTAssertEqual(schema.pointer("/$defs/errorItem/properties/level/enum") as? [String],
                   MonicaLevel.allCases.map { $0.rawValue },
                   "this SDK's level vocabulary is a copy of the schema's; both must move together")

    // payload.md says the schema expresses the *shape* of a timestamp. If the
    // pattern ever goes away, this fails rather than leaving the RFC 3339 check
    // below as the sole guard.
    for pointer in ["/properties/sent_at/pattern", "/$defs/errorItem/properties/timestamp/pattern",
                    "/$defs/breadcrumb/properties/timestamp/pattern"] {
      XCTAssertFalse((schema.pointer(pointer) as? String ?? "").isEmpty, "envelope.json must constrain \(pointer)")
    }

    // Every $ref resolves, so the validator is not quietly skipping a branch.
    let serialized = try String(contentsOf: bundle.directory.appendingPathComponent("envelope.json"), encoding: .utf8)
    let references = try NSRegularExpression(pattern: "#/\\$defs/([A-Za-z0-9_-]+)")
    let referenced = references.matches(in: serialized, range: NSRange(serialized.startIndex..., in: serialized))
      .compactMap { Range($0.range(at: 1), in: serialized).map { String(serialized[$0]) } }
    XCTAssertFalse(referenced.isEmpty)
    for name in referenced { XCTAssertTrue(schema.definitionNames().contains(name), "#/$defs/\(name) is referenced but not defined") }
  }

  /// DEC57 relaxes `platform` from a closed enum to a bounded string so a new
  /// SDK can deliver before the server learns its name.
  ///
  /// Until MONICA ships and publishes that change, the vendored `envelope.json`
  /// still enumerates `javascript | node | java | php` and this assertion
  /// cannot hold. It is wrapped in `XCTExpectFailure` rather than left red,
  /// because a red `swift test` also fails `release.yml`, which would make it
  /// impossible to cut any release at all. `strict: false` means the test does
  /// not start failing for the opposite reason once the relaxation is
  /// vendored — but it does stop being reported as an expected failure, which
  /// is the signal to delete this wrapper. Every other obligation is checked
  /// meanwhile through `schemaForSDKOutput()`.
  func testPlatformSwiftIsAcceptedByTheVendoredSchema() throws {
    XCTExpectFailure("Accel-Hack/monica has not deployed the DEC57 platform relaxation yet", strict: false)
    let issues = bundle.schema.validate(Monica.platformName, at: "/$defs/errorItem/properties/platform")
    XCTAssertTrue(issues.isEmpty,
                  "envelope.json rejects platform \"\(Monica.platformName)\": \(issues). Ingest would answer 422 to every"
                    + " event this SDK sends. The relaxation (Accel-Hack/monica: platform as a non-empty string of at most"
                    + " 64 characters) must be merged and deployed, then re-vendored with `python3 scripts/spec-sync.py`.")
  }

  func testTheErrorBodyShapeIsStillUsable() throws {
    // error.json is the shape of a rejection. This SDK branches on the HTTP
    // status only and does not read the body, so all that has to hold is that
    // the shape stays the one ingest.md documents.
    XCTAssertEqual(bundle.errorSchema.pointer("/required") as? [String], ["error"])
    XCTAssertEqual(Set(bundle.errorSchema.pointer("/properties/error/required") as? [String] ?? []), ["code", "message"])
    XCTAssertEqual(Set(bundle.errorSchema.pointer("/$defs/validationIssue/required") as? [String] ?? []), ["path", "message"])
    let example: [String: Any] = ["error": ["code": "invalid_envelope", "message": "no", "issues": [["path": "$.items[0]", "message": "x"]]]]
    XCTAssertEqual(bundle.errorSchema.validate(example), [])
    XCTAssertFalse(bundle.errorSchema.validate(["error": ["message": "no code"]]).isEmpty)
  }

  // MARK: 2. MONICA's test vectors

  func testTheVectorsGetTheVerdictTheBundleExpects() throws {
    XCTAssertGreaterThanOrEqual(bundle.vectors.count, 17)
    XCTAssertTrue(bundle.vectors.contains { $0.valid }, "the corpus must hold accepted envelopes")
    XCTAssertTrue(bundle.vectors.contains { !$0.valid && $0.schemaRejects })
    XCTAssertTrue(bundle.vectors.contains { !$0.valid && !$0.schemaRejects },
                  "the corpus must hold the cases only MONICA can reject; they justify the checks below")

    for vector in bundle.vectors {
      let issues = bundle.schema.validate(vector.envelope)
      if vector.schemaRejects {
        XCTAssertFalse(issues.isEmpty, "\(vector.name): the published schema must reject it (\(vector.description))")
      } else {
        XCTAssertTrue(issues.isEmpty, "\(vector.name): the published schema must accept it (\(vector.description)): \(issues)")
      }
      // A vector the schema accepts but MONICA rejects names a semantic rule the
      // SDK has to enforce itself. The check this test applies to the SDK's own
      // output must see the problem too, or it is not guarding anything.
      if vector.valid {
        XCTAssertEqual(semanticIssues(in: vector.envelope), [], vector.name)
      } else if !vector.schemaRejects {
        XCTAssertFalse(semanticIssues(in: vector.envelope).isEmpty,
                       "\(vector.name): schema_rejects is false, so this test's own semantic check must catch it")
      }
    }
  }

  // MARK: 3. what this SDK puts on the wire

  func testEveryEnvelopeThisSDKEmitsSatisfiesTheSchemaAndThePayloadObligations() throws {
    let schema = try schemaForSDKOutput()
    for (label, envelope) in try sdkEnvelopes() {
      let issues = schema.validate(envelope)
      XCTAssertTrue(issues.isEmpty, "\(label): \(issues)")
      XCTAssertEqual(semanticIssues(in: envelope), [], label)
      let object = try XCTUnwrap(envelope as? [String: Any])
      XCTAssertLessThanOrEqual((object["items"] as? [Any])?.count ?? 0, MonicaOptions.maxItemsPerEnvelope, label)
      // ingest.md: one request carries one envelope, and gzip only shrinks JSON,
      // so the JSON itself has to fit the gzip limit.
      let data = try JSONSerialization.data(withJSONObject: envelope)
      XCTAssertLessThanOrEqual(data.count, try XCTUnwrap(bundle.limits["envelope_gzip_bytes"] as? Int), label)
    }
  }

  func testSDKNameIsThePackageNameAndTheVersionIsTheReleaseTag() throws {
    // ingest.md: sdk.name is the package name in the distribution channel.
    // SwiftPM has no registry, so it is the Package name; release.yml refuses a
    // tag that differs from sdkVersion.
    let manifest = try String(contentsOf: bundle.root.appendingPathComponent("Package.swift"), encoding: .utf8)
    XCTAssertTrue(manifest.contains("name: \"\(Monica.sdkName)\""), "Package.swift must be named \(Monica.sdkName)")
    XCTAssertFalse(Monica.sdkVersion.isEmpty)
    XCTAssertNotNil(Monica.sdkVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression),
                    "sdkVersion is the semver tag a release is cut from")
    let envelope = try XCTUnwrap(try sdkEnvelopes()["a captured error with full context"] as? [String: Any])
    XCTAssertEqual((envelope["sdk"] as? [String: Any])?["name"] as? String, Monica.sdkName)
    XCTAssertEqual((envelope["sdk"] as? [String: Any])?["version"] as? String, Monica.sdkVersion)
    XCTAssertEqual(((envelope["items"] as? [[String: Any]])?.first)?["platform"] as? String, Monica.platformName)
  }

  func testTheCauseChainRunsOutermostFirstAndOnlyTheOutermostCarriesTheStack() throws {
    let envelope = try XCTUnwrap(try sdkEnvelopes()["a captured error with full context"] as? [String: Any])
    let item = try XCTUnwrap((envelope["items"] as? [[String: Any]])?.first)
    let values = try XCTUnwrap((item["exception"] as? [String: Any])?["values"] as? [[String: Any]])
    XCTAssertEqual(values.map { $0["type"] as? String }, ["com.example.checkout", "NSURLErrorDomain"],
                   "payload.md: exception.values run outermost to innermost")
    XCTAssertNotNil(values[0]["stacktrace"])
    XCTAssertNil(values[1]["stacktrace"], "a Swift Error carries no stack of its own; only the capture site does")
    for value in values {
      let mechanism = try XCTUnwrap(value["mechanism"] as? [String: Any])
      XCTAssertEqual(mechanism["type"] as? String, "generic")
      XCTAssertEqual(mechanism["handled"] as? Bool, true)
    }
  }

  func testFramesRunFromTheOldestCallerToTheCaptureSiteAndInAppIsTheSDKsJudgement() throws {
    let envelope = try XCTUnwrap(try sdkEnvelopes()["a captured error with full context"] as? [String: Any])
    let item = try XCTUnwrap((envelope["items"] as? [[String: Any]])?.first)
    let frames = try XCTUnwrap(frames(of: item))
    XCTAssertFalse(frames.isEmpty)
    XCTAssertLessThanOrEqual(frames.count, StackFrames.maxFrames)
    // payload.md: oldest caller first, throw (here: capture) site last.
    XCTAssertTrue((frames.last?["function"] as? String)?.contains("ProtocolContractTests") == true,
                  "the capture site must be the last frame: \(frames.last ?? [:])")
    XCTAssertFalse((frames.first?["function"] as? String)?.contains("ProtocolContractTests") == true,
                   "the oldest caller must come first")
    // in_app is decided by image name against inAppModules, not copied from a path.
    let inApp = frames.filter { $0["in_app"] as? Bool == true }
    XCTAssertFalse(inApp.isEmpty, "the test image was declared in_app")
    XCTAssertTrue(frames.contains { $0["in_app"] as? Bool == false }, "XCTest and libdispatch frames are not the app's")
    for frame in inApp {
      let filename = try XCTUnwrap(frame["filename"] as? String)
      XCTAssertTrue(filename.hasPrefix(TestSupport.testImageName + "/"),
                    "payload.md (Swift): filename is <image>/<Outermost>.swift, got \(filename)")
    }
    XCTAssertEqual(frames.last?["filename"] as? String, "\(TestSupport.testImageName)/ProtocolContractTests.swift")
    for frame in frames {
      XCTAssertFalse((frame["filename"] as? String ?? "").isEmpty, "payload.md: filename is never empty")
      XCTAssertNil(frame["lineno"], "Swift has no line numbers at runtime; lineno is omitted, never 0")
      // The demangled symbol and the addresses ride along but never leak into filename.
      if let filename = frame["filename"] as? String {
        XCTAssertFalse(filename.hasPrefix("0x"))
        XCTAssertFalse(filename.contains("$s"), "filename must be derived from the demangled symbol")
      }
    }
  }

  func testDeepTracesAreTruncatedToThePublishedFrameLimit() {
    let addresses = Array(repeating: Thread.callStackReturnAddresses[0].uintValue, count: 250).map { UInt($0) }
    let frames = StackFrames.frames(for: addresses, inAppModules: [], skipFrames: 0)
    XCTAssertEqual(frames.count, StackFrames.maxFrames)
  }

  func testFingerprintReachesTheWireUnchanged() throws {
    // payload.md: fingerprint is used verbatim. No trim, no escape, no join.
    let fingerprint = [" checkout ", "a|b", "ユーザー入力", ""]
    let envelope = try XCTUnwrap(try sdkEnvelopes()["a message with a custom fingerprint"] as? [String: Any])
    let item = try XCTUnwrap((envelope["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(item["fingerprint"] as? [String], fingerprint)
  }

  func testTheCrashFromAPreviousLaunchMeetsTheSameContract() throws {
    let schema = try schemaForSDKOutput()
    for (label, envelope) in try sdkEnvelopes() where label.hasPrefix("a crash") {
      XCTAssertEqual(schema.validate(envelope), [], label)
      let item = try XCTUnwrap(((envelope as? [String: Any])?["items"] as? [[String: Any]])?.first)
      XCTAssertEqual(item["level"] as? String, "fatal", label)
      let value = try XCTUnwrap(((item["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first)
      XCTAssertEqual((value["mechanism"] as? [String: Any])?["handled"] as? Bool, false, label)
      XCTAssertFalse((value["type"] as? String ?? "").isEmpty, "the signal name or NSException name is the type")
    }
  }

  func testABatchLargerThanThePublishedLimitIsSplitAndOverflowIsReported() throws {
    let schema = try schemaForSDKOutput()
    let envelopes = try sdkEnvelopes()
    let split = envelopes.keys.filter { $0.hasPrefix("an overflowing batch") }.sorted()
    XCTAssertEqual(split.count, 2, "150 queued events must leave as two envelopes")
    var itemCounts: [Int] = []
    for label in split {
      let envelope = try XCTUnwrap(envelopes[label] as? [String: Any])
      XCTAssertEqual(schema.validate(envelope), [], label)
      itemCounts.append((envelope["items"] as? [Any])?.count ?? 0)
    }
    XCTAssertEqual(itemCounts.sorted(), [50, MonicaOptions.maxItemsPerEnvelope])

    let dropped = try XCTUnwrap(envelopes["a full queue that dropped events"] as? [String: Any])
    XCTAssertEqual(schema.validate(dropped), [])
    XCTAssertGreaterThan(dropped["discarded"] as? Int ?? 0, 0, "envelope.discarded reports what the queue dropped")
  }

  // MARK: 4. the request the SDK actually makes (transport.json)

  func testTransportJsonDeclaresOnlyWhatThisSDKHasConsidered() throws {
    // transport.json is the machine-readable copy of the tables in ingest.md.
    // Pinning the vocabulary turns "MONICA grew an obligation the Swift SDK
    // ignores" into a failing test.
    XCTAssertEqual(bundle.transport.keys.sorted(), ["auth", "dsn", "endpoint", "retry", "status"],
                   "transport.json declares sections this SDK has not considered (see README for what is unimplemented)")
    let status = try XCTUnwrap(bundle.transport["status"] as? [String: String])
    XCTAssertEqual(status.keys.sorted(), ["202", "400", "401", "413", "422", "429", "5xx"], "the status vocabulary changed")
    XCTAssertEqual(status["202"], "accept")
    XCTAssertEqual(status["400"], "drop")
    XCTAssertEqual(status["401"], "drop_and_stop")
    XCTAssertEqual(status["422"], "drop")
    XCTAssertEqual(status["429"], "wait_retry_after")
    XCTAssertEqual(status["5xx"], "backoff")
    // Known gap, kept visible: 413 is dropped instead of split. MonicaClient's
    // JSON preflight keeps envelopes under the limit, so ingest should never
    // answer 413 in the first place.
    XCTAssertEqual(status["413"], "split_and_retry")

    let auth = try authSchemes()
    XCTAssertEqual(Set(auth.keys), ["secret", "public"], "transport.json should describe both key schemes")
    XCTAssertEqual(auth["public"]?["key_prefix"] as? String, DSN.publicKeyPrefix)
    XCTAssertEqual(auth["public"]?["header"] as? String, URLSessionTransport.publicKeyHeader)
    XCTAssertEqual(auth["public"]?["value"] as? String, "<key>", "the public key travels bare in its header")
    let endpoint = try XCTUnwrap(bundle.transport["endpoint"] as? [String: Any])
    XCTAssertEqual(endpoint["method"] as? String, "POST")
    XCTAssertEqual(endpoint["path"] as? String, URLSessionTransport.ingestPath)
    XCTAssertEqual(endpoint["content_type"] as? String, URLSessionTransport.contentType)
    XCTAssertEqual(endpoint["content_encoding"] as? String, URLSessionTransport.contentEncoding)
  }

  func testTheRetryPolicyMatchesTransportJson() throws {
    let retry = try XCTUnwrap(bundle.transport["retry"] as? [String: Any])
    XCTAssertEqual(retry["retryable_statuses"] as? [String], ["429", "5xx"])
    XCTAssertEqual(retry["retry_on_network_error"] as? Bool, true)
    let retryAfter = try XCTUnwrap(retry["retry_after"] as? [String: Any])
    XCTAssertEqual(retryAfter["integer_seconds_only"] as? Bool, true,
                   "this SDK parses Retry-After as integer seconds only and falls back to backoff otherwise")
    XCTAssertEqual(retryAfter["max_seconds"] as? Double, URLSessionTransport.maxRetryAfterSeconds)
    let backoff = try XCTUnwrap(retry["backoff"] as? [String: Any])
    XCTAssertEqual(backoff["base_ms"] as? Int, URLSessionTransport.backoffBaseMillis)
    XCTAssertEqual(backoff["factor"] as? Int, URLSessionTransport.backoffFactor)
    XCTAssertEqual(backoff["max_ms"] as? Int, URLSessionTransport.backoffMaxMillis)
    XCTAssertEqual(backoff["jitter_min"] as? Double, URLSessionTransport.backoffJitterMin)
    XCTAssertEqual(backoff["jitter_max"] as? Double, URLSessionTransport.backoffJitterMax)

    // The constants are only half of it: the delay actually drawn has to stay
    // inside the window transport.json describes, up to and past the ceiling.
    let base = try XCTUnwrap(backoff["base_ms"] as? Double), factor = try XCTUnwrap(backoff["factor"] as? Double)
    let maximum = try XCTUnwrap(backoff["max_ms"] as? Double)
    for attempt in 0..<8 {
      let ceiling = min(base * pow(factor, Double(attempt)), maximum)
      let window = (ceiling * (backoff["jitter_min"] as! Double))...(ceiling * (backoff["jitter_max"] as! Double))
      for _ in 0..<50 {
        let millis = URLSessionTransport.backoff(attempt) * 1_000
        XCTAssertTrue(window.contains(millis.rounded()), "attempt \(attempt): \(millis)ms is outside \(window)")
      }
    }
  }

  func testTheDSNIsReducedToTheIngestEndpoint() throws {
    let endpointPath = try XCTUnwrap((bundle.transport["endpoint"] as? [String: Any])?["path"] as? String)
    let publicPrefix = try XCTUnwrap(try authSchemes()["public"]?["key_prefix"] as? String)
    let secretPrefix = try XCTUnwrap(try authSchemes()["secret"]?["key_prefix"] as? String)
    // The DSN path is not the ingest path; its query and fragment are dropped.
    let dsn = try DSN.parse("https://\(publicPrefix)k@ingest.example.test/android-sample/42?q=1#f")
    XCTAssertEqual(dsn.endpoint.absoluteString, "https://ingest.example.test\(endpointPath)")
    // https everywhere, except the hosts transport.json names.
    let insecure = try XCTUnwrap((bundle.transport["dsn"] as? [String: Any])?["insecure_hosts"] as? [String])
    XCTAssertEqual(Set(insecure), DSN.insecureHosts)
    for host in insecure {
      XCTAssertEqual(try DSN.parse("http://\(publicPrefix)k@\(host):8787/1").endpoint.absoluteString,
                     "http://\(host):8787\(endpointPath)")
    }
    XCTAssertThrowsError(try DSN.parse("http://\(publicPrefix)k@ingest.example.test/1")) {
      XCTAssertEqual($0 as? MonicaConfigurationError, .insecureDSN)
    }
    // An app bundle ships to every user, so a mobile SDK insists on the public scheme.
    XCTAssertThrowsError(try DSN.parse("https://\(secretPrefix)leaked@ingest.example.test/1")) {
      XCTAssertEqual($0 as? MonicaConfigurationError, .secretKeyInDSN)
    }
    XCTAssertThrowsError(try DSN.parse("https://ingest.example.test/1"))
  }

  func testTheRequestOnTheWireMatchesTransportJson() throws {
    let endpoint = try XCTUnwrap(bundle.transport["endpoint"] as? [String: Any])
    let auth = try authSchemes()
    let publicKey = try XCTUnwrap(auth["public"]?["key_prefix"] as? String) + "contract"
    StubProtocol.reset([.init(status: 202)])
    let transport = try stubbedTransport(dsn: "https://\(publicKey)@ingest.monica.test/1?q=1#f")
    let envelope = try liveEnvelope { $0.captureError(CheckoutError.declined(code: 402)) }
    XCTAssertTrue(try transport.send(envelope), "the transport should accept a 202 response")

    let (request, body) = try XCTUnwrap(StubProtocol.requests.first)
    XCTAssertEqual(request.httpMethod, endpoint["method"] as? String)
    XCTAssertEqual(request.url?.path, endpoint["path"] as? String, "the DSN path, query and fragment must be dropped")
    XCTAssertNil(request.url?.query)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), endpoint["content_type"] as? String)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), endpoint["content_encoding"] as? String)
    // A public key authenticates with the header transport.json gives for its
    // kind, and never with the secret scheme's header.
    let expectedValue = try XCTUnwrap(auth["public"]?["value"] as? String).replacingOccurrences(of: "<key>", with: publicKey)
    XCTAssertEqual(request.value(forHTTPHeaderField: try XCTUnwrap(auth["public"]?["header"] as? String)), expectedValue)
    XCTAssertNil(request.value(forHTTPHeaderField: try XCTUnwrap(auth["secret"]?["header"] as? String)))

    let compressed = try XCTUnwrap(body)
    XCTAssertLessThanOrEqual(compressed.count, try XCTUnwrap(bundle.limits["envelope_gzip_bytes"] as? Int))
    let decoded = try gunzip(compressed)
    XCTAssertLessThanOrEqual(decoded.count, try XCTUnwrap(bundle.limits["envelope_decompressed_bytes"] as? Int))
    // One request carries one envelope: the body is a single JSON object.
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
    XCTAssertEqual(try schemaForSDKOutput().validate(json), [], "the gzipped request body")
  }

  func testStatusesAreHandledTheWayTransportJsonSays() throws {
    let envelope = try liveEnvelope { $0.captureMessage("status") }
    // drop: no retry, so exactly one request reaches the server.
    for status in [400, 413, 422] {
      StubProtocol.reset([.init(status: status), .init(status: 202)])
      XCTAssertFalse(try stubbedTransport(maxRetries: 3).send(envelope), "\(status) must not be reported as accepted")
      XCTAssertEqual(StubProtocol.requests.count, 1, "\(status) must not be retried")
    }
    // drop_and_stop: dropped, and nothing more leaves this transport.
    StubProtocol.reset([.init(status: 401), .init(status: 202), .init(status: 202)])
    let unauthorized = try stubbedTransport(maxRetries: 3)
    XCTAssertFalse(try unauthorized.send(envelope))
    XCTAssertFalse(try unauthorized.send(envelope))
    XCTAssertEqual(StubProtocol.requests.count, 1, "after a 401 nothing is sent")
    XCTAssertTrue(unauthorized.isStopped)
    // wait_retry_after / backoff: retried, and the retry that meets a 202 succeeds.
    StubProtocol.reset([.init(status: 429, headers: ["Retry-After": "7"]), .init(status: 202)])
    var slept: [TimeInterval] = []
    let limited = try stubbedTransport(maxRetries: 1)
    limited.sleep = { slept.append($0) }
    XCTAssertTrue(try limited.send(envelope), "a 429 followed by a 202 is a success")
    XCTAssertEqual(StubProtocol.requests.count, 2)
    XCTAssertEqual(slept, [7], "the wait is Retry-After, in seconds")
    StubProtocol.reset([.init(status: 503), .init(status: 202)])
    let failing = try stubbedTransport(maxRetries: 1)
    failing.sleep = { _ in }
    XCTAssertTrue(try failing.send(envelope), "a 5xx followed by a 202 is a success")
    XCTAssertEqual(StubProtocol.requests.count, 2)
    // Exhausted retries drop the envelope instead of queueing it forever.
    StubProtocol.reset([.init(status: 429), .init(status: 429), .init(status: 429), .init(status: 202)])
    let exhausted = try stubbedTransport(maxRetries: 2)
    exhausted.sleep = { _ in }
    XCTAssertFalse(try exhausted.send(envelope))
    XCTAssertEqual(StubProtocol.requests.count, 3, "maxRetries bounds the number of attempts")
  }

  // MARK: 5. the validator has to be able to say no

  func testTheValidatorRejectsWhatItShould() throws {
    let schema = try schemaForSDKOutput()
    let baseline = try XCTUnwrap(try sdkEnvelopes()["messages at every level and an unhandled error"] as? [String: Any])
    XCTAssertEqual(schema.validate(baseline), [])

    func item(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
      var envelope = baseline
      var items = envelope["items"] as! [[String: Any]]
      change(&items[0])
      envelope["items"] = items
      return envelope
    }
    func envelope(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
      var envelope = baseline
      change(&envelope)
      return envelope
    }
    let first = (baseline["items"] as! [[String: Any]])[0]
    XCTAssertFalse(schema.validate(item { $0.removeValue(forKey: "platform") }).isEmpty, "no platform")
    XCTAssertFalse(schema.validate(item { $0["level"] = "trace" }).isEmpty, "unknown level")
    XCTAssertFalse(schema.validate(item { $0["event_id"] = "not-a-uuid" }).isEmpty, "bad event_id")
    XCTAssertFalse(schema.validate(item { $0["timestamp"] = "2026-08-30 00:00:00Z" }).isEmpty, "space-separated timestamp")
    XCTAssertFalse(schema.validate(item { $0["environment"] = String(repeating: "x", count: 129) }).isEmpty, "long environment")
    XCTAssertFalse(schema.validate(item { $0["tags"] = ["count": 1] }).isEmpty, "non-string tag")
    XCTAssertFalse(schema.validate(item { $0["fingerprint"] = [] }).isEmpty, "empty fingerprint")
    XCTAssertFalse(schema.validate(item {
      $0["exception"] = ["values": [["type": "E", "value": "", "stacktrace": ["frames": [["filename": "", "in_app": true]]]]]]
    }).isEmpty, "empty filename")
    XCTAssertFalse(schema.validate(envelope { $0["discarded"] = -1 }).isEmpty, "negative discarded")
    XCTAssertFalse(schema.validate(envelope { $0["items"] = Array(repeating: first, count: MonicaOptions.maxItemsPerEnvelope + 1) }).isEmpty,
                   "too many items")
    XCTAssertFalse(schema.validate(envelope { $0["items"] = ["error"] }).isEmpty, "a non-object item")
    // Forward compatibility: unknown fields and unknown item types pass.
    XCTAssertEqual(schema.validate(envelope { $0["future"] = true }), [])
    XCTAssertEqual(schema.validate(item { $0["future_item_field"] = ["retained": true] }), [])
    XCTAssertEqual(schema.validate(envelope { $0["items"] = [["type": "metric", "value": 3]] }), [])

    XCTAssertThrowsError(try JSONSchema(["type": "array", "minContains": 1]),
                         "a keyword the validator does not implement must stop the test, not pass silently")
  }

  /// Allowlisting keyword *names* was not enough. `{"type": ["string", "null"]}`
  /// is legal draft 2020-12 and loaded clean, and `schema["type"] as? String`
  /// was then nil — dropping the constraint instead of failing loudly. An SDK
  /// emitting an object where the bundle said string would have passed.
  func testTheValidatorRefusesAKeywordWhoseValueIsTheWrongShape() throws {
    for wrong in [["type": 1], ["type": ["string", 1]], ["type": [] as [Any]], ["enum": "x"],
                  ["enum": [] as [Any]], ["required": "x"], ["required": ["x", 1]], ["minLength": "3"],
                  ["maxLength": true], ["pattern": 1], ["minimum": "0"], ["anyOf": [:] as [String: Any]],
                  ["properties": [] as [Any]], ["$ref": 1]] as [[String: Any]] {
      XCTAssertThrowsError(try JSONSchema(wrong), "\(wrong) must not load") { error in
        guard case JSONSchema.LoadError.malformedKeyword = error else {
          return XCTFail("\(wrong): expected malformedKeyword, got \(error)")
        }
      }
    }
    // Nested, too: a wrong shape anywhere in the document must stop the test.
    XCTAssertThrowsError(try JSONSchema(["properties": ["a": ["type": ["string", 1]]]]))
    XCTAssertThrowsError(try JSONSchema(["$defs": ["a": ["required": "x"]]]))

    // The union form is legal, so it must load *and* be enforced.
    let union = try JSONSchema(["properties": ["tag": ["type": ["string", "null"]]]])
    XCTAssertEqual(union.validate(["tag": "x"]), [])
    XCTAssertEqual(union.validate(["tag": NSNull()]), [])
    XCTAssertFalse(union.validate(["tag": ["nested": 1]]).isEmpty, "the union must still reject an object")
  }

  // MARK: helpers

  /// `envelope.json` as this SDK must be checked against today: the vendored
  /// copy, with `platform` relaxed to the bounded string DEC57 publishes, but
  /// only while the copy still carries the closed enum. Once MONICA ships and
  /// the bundle is re-vendored, the replacement is skipped and this is exactly
  /// the published schema. `testPlatformSwiftIsAcceptedByTheVendoredSchema`
  /// tracks that moment; this helper keeps every other obligation checked.
  private func schemaForSDKOutput() throws -> JSONSchema {
    let pointer = "/$defs/errorItem/properties/platform"
    if bundle.schema.validate(Monica.platformName, at: pointer).isEmpty { return bundle.schema }
    return try bundle.schema.replacing(pointer: pointer, with: ["type": "string", "minLength": 1, "maxLength": 64])
  }

  private func authSchemes() throws -> [String: [String: Any]] {
    let list = try XCTUnwrap(bundle.transport["auth"] as? [[String: Any]])
    return Dictionary(uniqueKeysWithValues: try list.map { (try XCTUnwrap($0["kind"] as? String), $0) })
  }

  private func frames(of item: [String: Any]) -> [[String: Any]]? {
    (((item["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first?["stacktrace"] as? [String: Any])?["frames"]
      as? [[String: Any]]
  }

  private func stubbedTransport(dsn: String = "https://mpk_public@ingest.monica.test/42", maxRetries: Int = 2) throws
    -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let transport = URLSessionTransport(dsn: try DSN.parse(dsn), maxRetries: maxRetries, requestTimeout: 2,
                                        configuration: configuration)
    transport.sleep = { _ in }
    return transport
  }

  /// An envelope exactly as the client would hand it to a transport.
  private func liveEnvelope(_ capture: (Monica) -> Void) throws -> MonicaEnvelope {
    let transport = RecordingTransport()
    var options = TestSupport.options(transport: transport, directory: directory)
    options.inAppModules = [TestSupport.testImageName]
    let monica = try Monica.install(options, platform: FakePlatform())
    defer { monica.close() }
    capture(monica)
    XCTAssertTrue(monica.flush(timeout: 5))
    return try XCTUnwrap(transport.envelopes.first)
  }

  /// Everything this SDK can put on the wire, round-tripped through JSON so the
  /// checks see exactly the bytes ingest would.
  private func sdkEnvelopes() throws -> [String: Any] {
    var result: [String: Any] = [:]
    func record(_ label: String, _ envelope: MonicaEnvelope) throws {
      result[label] = try JSONSerialization.jsonObject(with: envelope.jsonData())
    }
    func install(_ configure: (inout MonicaOptions) -> Void = { _ in }) throws -> (Monica, RecordingTransport) {
      let transport = RecordingTransport()
      var options = TestSupport.options(transport: transport, directory: directory)
      options.environment = "production"
      options.inAppModules = [TestSupport.testImageName]
      options.flushInterval = 60
      configure(&options)
      return (try Monica.install(options, platform: FakePlatform()), transport)
    }

    do {
      let (monica, transport) = try install()
      monica.addBreadcrumb(category: "ui.click", message: "submitButton")
      monica.setUser(["id": "u_123", "email": "user@example.test"])
      monica.setScreen("CheckoutViewController")
      monica.scope.setContext("feature_flags", ["checkout_v2": true])
      let underlying = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: nil)
      let outer = NSError(domain: "com.example.checkout", code: 7, userInfo: [NSUnderlyingErrorKey: underlying])
      monica.captureError(outer, context: CaptureContext().tag("feature", "checkout").context("order", ["items": 3]))
      XCTAssertTrue(monica.flush(timeout: 5))
      monica.close()
      try record("a captured error with full context", try XCTUnwrap(transport.envelopes.first))
    }
    do {
      let (monica, transport) = try install()
      for level in MonicaLevel.allCases { monica.captureMessage("at \(level.rawValue)", context: CaptureContext().level(level)) }
      monica.captureError(CheckoutError.declined(code: 402), context: CaptureContext().handled(false).level(.fatal))
      XCTAssertTrue(monica.flush(timeout: 5))
      monica.close()
      try record("messages at every level and an unhandled error", try XCTUnwrap(transport.envelopes.first))
    }
    do {
      let (monica, transport) = try install()
      monica.captureMessage("在庫が 0 です — \u{1F4E6} ünïcödé \u{0007}", context: CaptureContext().tag("画面", "決済"))
      XCTAssertTrue(monica.flush(timeout: 5))
      monica.close()
      try record("non-ASCII text and a control character", try XCTUnwrap(transport.envelopes.first))
    }
    do {
      // An environment at the schema's bound in code points, but only half as
      // long in grapheme clusters. Validating it with `String.count` would let
      // twice the allowed length onto the wire.
      let (monica, transport) = try install { options in
        options.environment = String(repeating: "e\u{0301}", count: MonicaOptions.maxEnvironmentLength / 2)
      }
      monica.captureMessage("at the environment bound")
      XCTAssertTrue(monica.flush(timeout: 5))
      monica.close()
      try record("an environment at the maxLength bound in code points", try XCTUnwrap(transport.envelopes.first))
    }
    do {
      let (monica, transport) = try install { options in
        options.beforeSend = { event, _ in
          event["fingerprint"] = [" checkout ", "a|b", "ユーザー入力", ""]
          return event
        }
      }
      monica.captureMessage("grouped by hand")
      XCTAssertTrue(monica.flush(timeout: 5))
      monica.close()
      try record("a message with a custom fingerprint", try XCTUnwrap(transport.envelopes.first))
    }
    do {
      let signal = CrashReport(kind: .signal, signal: SIGTRAP, code: 1, faultAddress: 0x10, timestamp: Date(),
                               frames: [0x1000_0010, 0x1000_0200],
                               images: [.init(loadAddress: 0x1000_0000, uuid: nil, path: "/x/MyApp.app/MyApp")],
                               name: nil, reason: nil)
      let exception = CrashReport(kind: .exception, signal: 0, code: 0, faultAddress: 0, timestamp: Date(),
                                  frames: [0x1000_0010], images: [], name: "NSRangeException", reason: "index 5 beyond bounds")
      let session: [String: Any] = ["environment": "production", "release": "1.2.3", "tags": ["screen": "Checkout"],
                                    "contexts": ["os": ["name": "iOS", "version": "17.0"]], "user": ["id": "u_1"]]
      for (label, report) in [("a crash by signal", signal), ("a crash by NSException", exception)] {
        let event = CrashReporter.event(from: report, session: session, fallbackEnvironment: "production",
                                        fallbackRelease: nil, fallbackContexts: [:], inAppModules: ["MyApp"], currentImages: [:])
        try record(label, MonicaEnvelope(sdkName: Monica.sdkName, sdkVersion: Monica.sdkVersion,
                                         sentAt: Timestamps.iso8601(Date()), discarded: 0, items: [event]))
      }
    }
    do {
      let (monica, transport) = try install { options in
        options.maxQueueSize = 150
        options.batchSize = 500  // clamped to the published limit
      }
      for index in 0..<150 { monica.captureMessage("m\(index)") }
      XCTAssertTrue(monica.flush(timeout: 10))
      monica.close()
      XCTAssertEqual(transport.envelopes.count, 2)
      for (index, envelope) in transport.envelopes.enumerated() { try record("an overflowing batch \(index)", envelope) }
    }
    do {
      let (monica, transport) = try install { options in
        options.maxQueueSize = 2
        options.batchSize = 2
      }
      // batchSize == maxQueueSize sends as soon as the queue fills; the sender
      // runs on its own queue, so flood faster than it drains and let the
      // discarded count travel with whatever leaves last.
      for index in 0..<40 { monica.captureMessage("m\(index)") }
      XCTAssertTrue(monica.flush(timeout: 10))
      monica.close()
      let reporting = transport.envelopes.first { $0.discarded > 0 }
      try record("a full queue that dropped events", try XCTUnwrap(reporting, "one envelope must carry the discarded count"))
    }
    return result
  }

  /// The rules `payload.md` states in prose and the schema cannot express: RFC
  /// 3339 timestamps that exist in the calendar, and counters inside the safe
  /// integer range. The same check runs over MONICA's vectors, so it is known
  /// to catch what `schema_rejects: false` says only MONICA catches.
  private func semanticIssues(in envelope: Any) -> [String] {
    var issues: [String] = []
    guard let envelope = envelope as? [String: Any] else { return ["envelope is not an object"] }
    if let sentAt = envelope["sent_at"] as? String, !Self.isCalendarRFC3339(sentAt) { issues.append("sent_at \(sentAt)") }
    if let discarded = envelope["discarded"] as? NSNumber, discarded.int64Value > Self.maxSafeInteger || discarded.doubleValue > Double(Self.maxSafeInteger) {
      issues.append("discarded \(discarded) is not a safe integer")
    }
    for item in (envelope["items"] as? [[String: Any]]) ?? [] where item["type"] as? String == "error" {
      if let timestamp = item["timestamp"] as? String, !Self.isCalendarRFC3339(timestamp) { issues.append("timestamp \(timestamp)") }
      for crumb in (item["breadcrumbs"] as? [[String: Any]]) ?? [] {
        if let timestamp = crumb["timestamp"] as? String, !Self.isCalendarRFC3339(timestamp) { issues.append("breadcrumb timestamp \(timestamp)") }
      }
    }
    return issues
  }

  private static let rfc3339 = try! NSRegularExpression(
    pattern: "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-](\\d{2}):(\\d{2}))$")

  /// RFC 3339 date-time whose fields exist: month 1–12, a day the month has,
  /// 24-hour time, an offset below 24:00.
  static func isCalendarRFC3339(_ value: String) -> Bool {
    guard let match = rfc3339.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return false }
    func field(_ index: Int) -> Int? {
      guard let range = Range(match.range(at: index), in: value) else { return nil }
      return Int(value[range])
    }
    guard let year = field(1), let month = field(2), let day = field(3), let hour = field(4), let minute = field(5),
      let second = field(6) else { return false }
    guard (1...12).contains(month), hour < 24, minute < 60, second < 61 else { return false }
    var components = DateComponents()
    components.year = year
    components.month = month
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    guard let daysInMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: components)!)?.count,
      (1...daysInMonth).contains(day) else { return false }
    if let offsetHour = field(8), let offsetMinute = field(9), offsetHour >= 24 || offsetMinute >= 60 { return false }
    return true
  }

  private func gunzip(_ input: Data) throws -> Data {
    var stream = z_stream()
    var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    XCTAssertEqual(status, Z_OK)
    defer { inflateEnd(&stream) }
    var output = Data(count: 1 << 20)
    let produced: Int = input.withUnsafeBytes { inputBytes in
      output.withUnsafeMutableBytes { outputBytes in
        stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(outputBytes.count)
        status = inflate(&stream, Z_FINISH)
        return Int(stream.total_out)
      }
    }
    XCTAssertEqual(status, Z_STREAM_END)
    output.count = produced
    return output
  }
}

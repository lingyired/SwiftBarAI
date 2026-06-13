// RemoteAIPluginGeneratorTests.swift
// menubar01 — AI Plugin Generator (M2+)
//
// Swift Testing coverage for the `RemoteTransport`-backed
// `RemoteAIPluginGenerator`. The generator's HTTP call goes
// through a `RemoteTransport` protocol (see
// `RemoteAIPluginGenerator.swift`); the test bundle uses a
// `StubRemoteTransport` keyed by a per-test UUID, so:
//   * tests do not touch the network,
//   * tests are immune to Swift Testing's parallel execution
//     racing `URLSession` worker threads,
//   * the test surface is independent of the
//     `URLSessionConfiguration.protocolClasses` /
//     `URLProtocol.registerClass` quirks that the macOS
//     `URLSession` stack has had for HTTPS.

import Foundation
import Testing

@testable import menubar01

// MARK: - Stub transport

/// `RemoteTransport` that returns a pre-registered canned
/// response for a single request. Tests construct a fresh stub
/// per test and configure it with a single `(Data,
/// HTTPURLResponse)` pair. The stub is `@unchecked Sendable`
/// because the test framework creates the stub on the test's
/// thread and the generator reads it on the URLSession worker
/// thread.
private final class StubRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var response: (Data, URLResponse)?
    private var capturedRequest: URLRequest?

    init() {}

    /// Register the canned response.
    func register(data: Data, response: URLResponse) {
        lock.lock(); defer { lock.unlock() }
        self.response = (data, response)
    }

    /// The most recent `URLRequest` the generator sent. Tests
    /// assert on URL, method, headers, and body without
    /// threading the value through the generator's public API.
    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequest
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        self.capturedRequest = request
        let canned = self.response
        lock.unlock()
        guard let (data, response) = canned else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

// MARK: - Helpers

/// A canned `PluginManifest` JSON body used by the success-path
/// test. Keys are kept alphabetically sorted to match the
/// `JSONEncoder.OutputFormatting.sortedKeys` invariant used by
/// `makeOpenAISuccessBody`.
///
/// Note: `"type"` is `"Executable"` (capital E), matching the
/// `PluginType` raw value defined in `Plugin.swift`. The
/// manifest's `PluginType` enum's `Codable` conformance uses the
/// raw value verbatim, so the JSON must match.
private let validManifestJSON = """
{
  "author": "remote model",
  "description": "Shows battery percentage",
  "entry": "battery.sh",
  "name": "Battery",
  "refreshInterval": 30,
  "runInBash": true,
  "type": "Executable",
  "version": "1.0.0"
}
"""

/// Builds a canned `Data` body that matches the OpenAI chat-
/// completion envelope the generator decodes.
private func makeOpenAISuccessBody(
    manifestJSON: String,
    entryScript: String,
    explanation: String
) -> Data {
    let payload: [String: Any] = [
        "manifest": jsonObject(from: manifestJSON),
        "entryScript": entryScript,
        "explanation": explanation
    ]
    let payloadData = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
    let content = String(data: payloadData, encoding: .utf8) ?? ""
    let envelope: [String: Any] = [
        "choices": [
            ["message": ["role": "assistant", "content": content]]
        ]
    ]
    return try! JSONSerialization.data(
        withJSONObject: envelope,
        options: [.sortedKeys]
    )
}

/// Parses a JSON string into an untyped object suitable for
/// embedding inside another `JSONSerialization` payload.
private func jsonObject(from jsonString: String) -> Any {
    let data = Data(jsonString.utf8)
    return try! JSONSerialization.jsonObject(with: data, options: [])
}

/// Returns a fresh `URL` whose path includes a UUID, so each
/// test's stub registration is independent of every other
/// test's even when the tests run in parallel.
private func makeUniqueEndpoint(
    host: String = "api.example.com",
    suffix: String = "/v1/chat/completions"
) -> URL {
    let uuid = UUID().uuidString
    return URL(string: "https://\(host)/\(uuid)\(suffix)")!
}

// MARK: - Request shape

struct RemoteAIPluginGeneratorRequestShapeTests {

    @Test func testGenerate_postsCorrectRequestShape() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let apiKey = "test-key-1234567890"
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        transport.register(
            data: makeOpenAISuccessBody(
                manifestJSON: validManifestJSON,
                entryScript: "#!/bin/bash\necho battery\n",
                explanation: "Battery watcher."
            ),
            response: response
        )

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: apiKey,
            model: "gpt-4o-mini",
            transport: transport
        )

        _ = try await generator.generate(
            request: "show battery",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        )

        let captured = try #require(transport.lastRequest)

        // URL is the endpoint's full path (no `/v1/chat/completions`
        // appended because the endpoint already includes it).
        #expect(captured.url?.absoluteString == endpoint.absoluteString)
        #expect(captured.httpMethod == "POST")

        // Authorization header is the bearer with the apiKey
        // verbatim.
        let auth = try #require(captured.value(forHTTPHeaderField: "Authorization"))
        #expect(auth == "Bearer \(apiKey)")

        // Content-Type and Accept are application/json.
        #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(captured.value(forHTTPHeaderField: "Accept") == "application/json")

        // Body decodes to the expected request envelope.
        let bodyData = try #require(captured.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let envelope = try #require(decoded)
        #expect(envelope["model"] as? String == "gpt-4o-mini")
        #expect(envelope["temperature"] as? Double == 0.2)
        let responseFormat = try #require(envelope["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_object")

        let messages = try #require(envelope["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        let userContent = try #require(messages[1]["content"] as? String)
        #expect(userContent == "show battery")
    }

    @Test func testGenerate_appendsPathWhenEndpointIsBare() async throws {
        let transport = StubRemoteTransport()
        let bare = URL(string: "https://api.openai.com")!
        // The generator will dial the bare origin with
        // `/v1/chat/completions` appended. We register the
        // response for that exact URL.
        let expectedDialedURL = URL(
            string: "https://api.openai.com/v1/chat/completions"
        )!
        let response = HTTPURLResponse(
            url: expectedDialedURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: makeOpenAISuccessBody(
                manifestJSON: validManifestJSON,
                entryScript: "#!/bin/bash\n",
                explanation: "n/a"
            ),
            response: response
        )

        let generator = RemoteAIPluginGenerator(
            endpoint: bare,
            apiKey: "k",
            transport: transport
        )
        _ = try await generator.generate(
            request: "x",
            context: AIGeneratorContext.empty
        )
        let captured = try #require(transport.lastRequest)
        #expect(captured.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }
}

// MARK: - Happy path

struct RemoteAIPluginGeneratorHappyPathTests {

    @Test func testGenerate_decodesValidResponse() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: makeOpenAISuccessBody(
                manifestJSON: validManifestJSON,
                entryScript: "#!/bin/bash\necho battery\n",
                explanation: "Battery watcher."
            ),
            response: response
        )

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        let plugin = try await generator.generate(
            request: "show battery",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        )

        #expect(plugin.manifest.name == "Battery")
        #expect(plugin.manifest.entry == "battery.sh")
        #expect(plugin.entryScript.contains("echo battery"))
        #expect(plugin.explanation.contains("Battery watcher"))
        #expect(plugin.promptVersion == RemoteAIPluginGenerator.remotePromptVersion)
    }
}

// MARK: - Error mapping

struct RemoteAIPluginGeneratorErrorMappingTests {

    @Test func testGenerate_throwsUnauthorizedOn401() async throws {
        try await assertError(
            status: 401,
            body: "{\"error\": \"unauthorized\"}",
            expected: .unauthorized
        )
    }

    @Test func testGenerate_throwsUnauthorizedOn403() async throws {
        try await assertError(
            status: 403,
            body: "forbidden",
            expected: .unauthorized
        )
    }

    @Test func testGenerate_throwsRateLimitedOn429() async throws {
        try await assertError(
            status: 429,
            body: "rate limited",
            expected: .rateLimited
        )
    }

    @Test func testGenerate_throwsTransportErrorOn5xx() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data("internal error".utf8),
            response: response
        )
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected .transportError, got success")
        } catch let error as AIGeneratorError {
            guard case .transportError(let reason) = error else {
                Issue.record("expected .transportError, got \(error)")
                return
            }
            #expect(reason.contains("500"))
            #expect(reason.contains("internal error"))
        }
    }

    @Test func testGenerate_throwsProviderFailureOnOther4xx() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data("bad request".utf8),
            response: response
        )
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            guard case .providerFailure(let reason) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(reason.contains("400"))
            #expect(reason.contains("bad request"))
        }
    }

    @Test func testGenerate_throwsMalformedResponseOnBadJSON() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data("not valid json".utf8),
            response: response
        )
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected .malformedResponse, got success")
        } catch let error as AIGeneratorError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test func testGenerate_throwsTransportErrorOnUnderlyingURLError() async throws {
        final class AlwaysFailTransport: RemoteTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
                throw URLError(.notConnectedToInternet)
            }
        }
        let transport = AlwaysFailTransport()
        let endpoint = makeUniqueEndpoint()
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected .transportError, got success")
        } catch let error as AIGeneratorError {
            // Assert the case is correct and the reason is
            // non-empty. The exact wording of the reason comes
            // from `URLError.localizedDescription` which is
            // system-language-dependent, so we deliberately do
            // not assert on specific substrings.
            guard case .transportError(let reason) = error else {
                Issue.record("expected .transportError, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
        }
    }

    // MARK: - Shared error-assertion helper

    private func assertError(
        status: Int,
        body: String,
        expected: AIGeneratorError
    ) async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data(body.utf8),
            response: response
        )
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected \(expected), got success")
        } catch let error as AIGeneratorError {
            #expect(error == expected)
        }
    }
}

// MARK: - Contract

struct RemoteAIPluginGeneratorContractTests {

    @Test func testPromptId_isDeterministicForSameRequest() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let body = makeOpenAISuccessBody(
            manifestJSON: validManifestJSON,
            entryScript: "#!/bin/bash\n",
            explanation: "n/a"
        )
        transport.register(data: body, response: response)

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: "k",
            transport: transport
        )
        let context = AIGeneratorContext(model: "gpt-4o-mini")
        let first = try await generator.generate(request: "show battery", context: context)
        let second = try await generator.generate(request: "show battery", context: context)
        #expect(first.promptId == second.promptId)
        #expect(first.promptId == MockAIPluginGenerator.promptId(for: "show battery", model: "gpt-4o-mini"))
    }

    @Test func testExplanation_neverContainsApiKey() async throws {
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let apiKey = "sk-supersecret-1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: makeOpenAISuccessBody(
                manifestJSON: validManifestJSON,
                entryScript: "#!/bin/bash\n",
                explanation: "Battery watcher."
            ),
            response: response
        )
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: apiKey,
            transport: transport
        )
        let plugin = try await generator.generate(
            request: "show battery",
            context: AIGeneratorContext.empty
        )
        #expect(!plugin.explanation.contains(apiKey))
        // Belt-and-braces: assert that no 8+ char prefix of the
        // key appears anywhere in the explanation, defending
        // against the key being chunked into a longer string.
        let probe = String(apiKey.prefix(8))
        #expect(!plugin.explanation.contains(probe))
    }
}

// MARK: - Retry policy

/// `RemoteTransport` that returns a pre-registered sequence of
/// responses, one per call. The first call returns `responses[0]`,
/// the second `responses[1]`, and so on. If `send` is called more
/// times than there are responses (i.e. the generator retried
/// past the script), the stub throws `URLError(.badServerResponse)`
/// so the test can distinguish "stopped retrying because the
/// status was non-retryable" from "ran out of canned responses
/// because the retry budget was wrong".
///
/// The transport also records the timestamp of every call so
/// `testGenerate_respectsRetryAfterHeader` can assert on the
/// delay between calls without mocking the clock.
private final class SequencedStubRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, URLResponse)]
    private var capturedRequests: [URLRequest] = []
    private var callTimestamps: [Date] = []

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callTimestamps.count
    }

    var timestamps: [Date] {
        lock.lock(); defer { lock.unlock() }
        return callTimestamps
    }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests.last
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        capturedRequests.append(request)
        callTimestamps.append(Date())
        guard !responses.isEmpty else {
            lock.unlock()
            throw URLError(.badServerResponse)
        }
        let next = responses.removeFirst()
        lock.unlock()
        return next
    }
}

struct RemoteAIPluginGeneratorRetryTests {

    // MARK: - Retry on 429 / 5xx

    @Test func testGenerate_retriesOn429_thenSucceeds() async throws {
        let endpoint = makeUniqueEndpoint()
        let response429 = HTTPURLResponse(
            url: endpoint, statusCode: 429,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let response200 = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let body = makeOpenAISuccessBody(
            manifestJSON: validManifestJSON,
            entryScript: "#!/bin/bash\necho battery\n",
            explanation: "Battery watcher."
        )
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("rate limited".utf8), response429),
            (body, response200)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        let plugin = try await generator.generate(
            request: "show battery",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        )
        #expect(plugin.manifest.name == "Battery")
        #expect(transport.callCount == 2)
    }

    @Test func testGenerate_retriesOn5xx_thenSucceeds() async throws {
        let endpoint = makeUniqueEndpoint()
        let response500 = HTTPURLResponse(
            url: endpoint, statusCode: 500,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let response200 = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let body = makeOpenAISuccessBody(
            manifestJSON: validManifestJSON,
            entryScript: "#!/bin/bash\n",
            explanation: "n/a"
        )
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("internal error".utf8), response500),
            (body, response200)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k", transport: transport
        )
        let plugin = try await generator.generate(
            request: "x", context: AIGeneratorContext.empty
        )
        #expect(plugin.manifest.name == "Battery")
        #expect(transport.callCount == 2)
    }

    // MARK: - No-retry paths

    @Test func testGenerate_doesNotRetryOn401() async throws {
        let endpoint = makeUniqueEndpoint()
        let response401 = HTTPURLResponse(
            url: endpoint, statusCode: 401,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        // Only one response is registered. If the generator
        // were to retry on 401, the second call would throw
        // `URLError(.badServerResponse)` from the stub, which
        // the generator would surface as `.transportError` —
        // not `.unauthorized`. The `unauthorized` assertion
        // below is therefore the "did not retry" check; the
        // `callCount` is a belt-and-braces second check.
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("unauthorized".utf8), response401)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k", transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x", context: AIGeneratorContext.empty
            )
            Issue.record("expected .unauthorized, got success")
        } catch let error as AIGeneratorError {
            #expect(error == .unauthorized)
        }
        #expect(transport.callCount == 1)
    }

    @Test func testGenerate_doesNotRetryOnOther4xx() async throws {
        let endpoint = makeUniqueEndpoint()
        let response400 = HTTPURLResponse(
            url: endpoint, statusCode: 400,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("bad request".utf8), response400)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k", transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x", context: AIGeneratorContext.empty
            )
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            #expect(error == .providerFailure(
                reason: "400 bad request"
            ))
        }
        #expect(transport.callCount == 1)
    }

    @Test func testGenerate_doesNotRetryOnTransportError() async throws {
        final class AlwaysFailTransport: RemoteTransport, @unchecked Sendable {
            var callCount = 0
            func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
                callCount += 1
                throw URLError(.notConnectedToInternet)
            }
        }
        let transport = AlwaysFailTransport()
        let endpoint = makeUniqueEndpoint()
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k", transport: transport
        )
        do {
            _ = try await generator.generate(
                request: "x", context: AIGeneratorContext.empty
            )
            Issue.record("expected .transportError, got success")
        } catch let error as AIGeneratorError {
            guard case .transportError(let reason) = error else {
                Issue.record("expected .transportError, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
        }
        #expect(transport.callCount == 1)
    }

    // MARK: - Retry budget

    @Test func testGenerate_givesUpAfterMaxRetries() async throws {
        let endpoint = makeUniqueEndpoint()
        let response429 = HTTPURLResponse(
            url: endpoint, statusCode: 429,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        // `maxRetries: 2` → up to 3 total calls (initial + 2
        // retries). All three return 429, so the generator
        // surfaces `.rateLimited` after the third call.
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("rate limited".utf8), response429),
            (Data("rate limited".utf8), response429),
            (Data("rate limited".utf8), response429)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            transport: transport, maxRetries: 2
        )
        do {
            _ = try await generator.generate(
                request: "x", context: AIGeneratorContext.empty
            )
            Issue.record("expected .rateLimited, got success")
        } catch let error as AIGeneratorError {
            #expect(error == .rateLimited)
        }
        #expect(transport.callCount == 3)
    }

    @Test func testGenerate_initialResponseCountsAsAttempt() async throws {
        // The first call (the "initial response") is the
        // first of the `maxRetries + 1` total calls. With
        // `maxRetries: 2`, the generator makes exactly 3
        // calls before giving up — not 2, not 4.
        let endpoint = makeUniqueEndpoint()
        let response429 = HTTPURLResponse(
            url: endpoint, statusCode: 429,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("rate limited".utf8), response429),
            (Data("rate limited".utf8), response429),
            (Data("rate limited".utf8), response429)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            transport: transport, maxRetries: 2
        )
        do {
            _ = try await generator.generate(
                request: "x", context: AIGeneratorContext.empty
            )
        } catch {
            // Ignore — we're asserting on callCount below.
        }
        #expect(transport.callCount == 3)
    }

    // MARK: - Retry-After

    @Test func testGenerate_respectsRetryAfterHeader() async throws {
        let endpoint = makeUniqueEndpoint()
        // `Retry-After: 2` → the generator should wait 2
        // seconds (not the default 1s exponential) before the
        // first retry. The exponential path would still cap at
        // ≤ 1s, so the test only passes if the header is being
        // honoured.
        let response429 = HTTPURLResponse(
            url: endpoint, statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "2"]
        )!
        let response200 = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let body = makeOpenAISuccessBody(
            manifestJSON: validManifestJSON,
            entryScript: "#!/bin/bash\n",
            explanation: "n/a"
        )
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("rate limited".utf8), response429),
            (body, response200)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k", transport: transport
        )
        _ = try await generator.generate(
            request: "x", context: AIGeneratorContext.empty
        )
        let timestamps = transport.timestamps
        #expect(timestamps.count == 2)
        // Allow 0.5s tolerance: the header is "2" seconds, and
        // `Task.sleep` rounds down to the scheduler's
        // resolution. We don't enforce a tight upper bound
        // because CI runners are occasionally slow.
        let delay = timestamps[1].timeIntervalSince(timestamps[0])
        #expect(delay >= 1.5)
    }

    @Test func testGenerate_capsRetryAfterAt60Seconds() async throws {
        let endpoint = makeUniqueEndpoint()
        // A hostile / misconfigured server asking the client
        // to wait ~2.7 hours. The cap at 60s means the test
        // completes in a reasonable time; without the cap the
        // CI runner would block until the global timeout.
        let response429 = HTTPURLResponse(
            url: endpoint, statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "9999"]
        )!
        let response200 = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let body = makeOpenAISuccessBody(
            manifestJSON: validManifestJSON,
            entryScript: "#!/bin/bash\n",
            explanation: "n/a"
        )
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("rate limited".utf8), response429),
            (body, response200)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k", transport: transport
        )
        _ = try await generator.generate(
            request: "x", context: AIGeneratorContext.empty
        )
        let timestamps = transport.timestamps
        #expect(timestamps.count == 2)
        // 65s upper bound: cap is 60s, with a small tolerance
        // for scheduler jitter and the time spent in the
        // transport / decoder between the two calls. If the
        // cap were broken, the second timestamp would be ~9999
        // seconds after the first and this test would
        // time-out the entire suite.
        let delay = timestamps[1].timeIntervalSince(timestamps[0])
        #expect(delay < 65)
    }
}

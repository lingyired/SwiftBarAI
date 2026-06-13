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

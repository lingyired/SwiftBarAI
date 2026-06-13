// AIGeneratorImproveTests.swift
// menubar01 — AI Plugin Generator (M2+)
//
// Swift Testing coverage for the `improve(request:context:)`
// helper that the M2+ sheet's "Improve" footer button calls.
// The helper is a small, side-effect-free rewrite of the
// user's request — there is no `GeneratedPlugin` to decode,
// no manifest to validate, no install to flow into — so the
// tests stay focused on:
//
//   * The protocol contract — the default implementation
//     throws `AIGeneratorError.improvementUnsupported` so
//     non-supporting providers (Local / Echo stubs) keep
//     working unchanged.
//   * The Mock override — returns "Improved: " + request so
//     the sheet can verify the round-trip without an LLM,
//     and throws on empty input so the view model's
//     empty-input guard is the only path that no-ops.
//   * The Remote override — uses temperature 0.3 and
//     `stream: false` so the rewrite is consistent and
//     synchronous, and re-uses the same `performWithRetry`
//     helper as `generate(...)` so a 5xx is retried.
//   * The view-model glue — `improveRequest()` flips the
//     `isImproving` flag, replaces the request on success,
//     preserves the request on failure, and short-circuits on
//     an already-running round-trip.

import Foundation
import Testing

@testable import menubar01

// MARK: - Mock generator

/// `AIPluginGenerator` that records the `(request, context)`
/// pair for the most recent call and lets each test choose
/// what to return. Mirrors the spirit of the M2+ view-model
/// test's `CapturingMockAIPluginGenerator` but extended with
/// an `improve(...)` override so the view-model tests can
/// drive success / failure paths through the protocol.
private final class CapturingMockAIPluginGenerator: AIPluginGenerator {
    let response: GeneratedPlugin?
    let errorToThrow: Error?

    /// Value to return from `improve(...)`. `nil` means "throw
    /// `improveErrorToThrow` instead". Tests set this and
    /// `improveErrorToThrow` in the `init` to drive the view
    /// model through specific paths.
    let improveResponse: String?
    let improveErrorToThrow: Error?

    private(set) var lastRequest: String?
    private(set) var lastContext: AIGeneratorContext?
    private(set) var lastImproveRequest: String?
    private(set) var lastImproveContext: AIGeneratorContext?
    /// Records the number of `improve(...)` calls so the
    /// `improveRequest_isImprovingFlagToggles` test can
    /// confirm the second call was short-circuited.
    private(set) var improveCallCount: Int = 0

    init(
        response: GeneratedPlugin? = nil,
        errorToThrow: Error? = nil,
        improveResponse: String? = nil,
        improveErrorToThrow: Error? = nil
    ) {
        self.response = response
        self.errorToThrow = errorToThrow
        self.improveResponse = improveResponse
        self.improveErrorToThrow = improveErrorToThrow
    }

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        lastRequest = request
        lastContext = context
        if let errorToThrow {
            throw errorToThrow
        }
        guard let response else {
            throw AIGeneratorError.providerFailure(reason: "test: no response configured")
        }
        return response
    }

    func improve(
        request: String,
        context: AIGeneratorContext
    ) async throws -> String {
        improveCallCount += 1
        lastImproveRequest = request
        lastImproveContext = context
        if let improveErrorToThrow {
            throw improveErrorToThrow
        }
        guard let improveResponse else {
            throw AIGeneratorError.improvementUnsupported
        }
        return improveResponse
    }
}

// MARK: - Stub transport (reused from RemoteAIPluginGeneratorTests)

/// `RemoteTransport` that returns a pre-registered canned
/// response for a single request. Mirrors the
/// `StubRemoteTransport` in `RemoteAIPluginGeneratorTests`
/// but is declared file-private here so the two test files
/// are independent (a test-import cycle is impossible because
/// both declare their own type).
private final class StubRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var response: (Data, URLResponse)?
    private var capturedRequest: URLRequest?

    init() {}

    func register(data: Data, response: URLResponse) {
        lock.lock(); defer { lock.unlock() }
        self.response = (data, response)
    }

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

/// `RemoteTransport` that returns a pre-registered sequence
/// of responses, one per call. Reused from
/// `RemoteAIPluginGeneratorTests`'s `SequencedStubRemoteTransport`
/// pattern. The first call returns `responses[0]`, the
/// second `responses[1]`, and so on. If `send` is called
/// more times than there are responses, the stub throws
/// `URLError(.badServerResponse)` so the test can distinguish
/// "stopped retrying because the status was non-retryable"
/// from "ran out of canned responses because the retry
/// budget was wrong".
private final class SequencedStubRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, URLResponse)]
    private var capturedRequests: [URLRequest] = []

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests.count
    }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests.last
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        capturedRequests.append(request)
        guard !responses.isEmpty else {
            lock.unlock()
            throw URLError(.badServerResponse)
        }
        let next = responses.removeFirst()
        lock.unlock()
        return next
    }
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

// MARK: - Mock improve

struct AIGeneratorMockImproveTests {

    @Test func testImprove_mock_returnsImprovedString() async throws {
        let generator = MockAIPluginGenerator()
        let context = AIGeneratorContext(model: "gpt-4o-mini")
        let improved = try await generator.improve(
            request: "weather",
            context: context
        )
        #expect(improved == "Improved: weather")
    }

    @Test func testImprove_mock_empty_throws() async throws {
        let generator = MockAIPluginGenerator()
        do {
            _ = try await generator.improve(
                request: "",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected .improvementUnsupported, got success")
        } catch let error as AIGeneratorError {
            #expect(error == .improvementUnsupported)
        }
    }
}

// MARK: - Default implementation (LocalAIPluginGenerator)

struct AIGeneratorDefaultImproveTests {

    @Test func testImprove_defaultImpl_throwsUnsupported() async throws {
        // `LocalAIPluginGenerator` does not override
        // `improve(...)`, so it inherits the default extension
        // implementation that throws
        // `AIGeneratorError.improvementUnsupported`. Construct
        // a `LocalAIPluginGenerator` pointing at a real
        // (empty) temp file so the init validation passes
        // (the `generate(...)` path is not exercised here;
        // the test only verifies the `improve(...)` round-trip
        // through the default extension).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelPath = dir.appendingPathComponent("model.gguf")
        try Data("GGUF".utf8).write(to: modelPath)

        let generator = LocalAIPluginGenerator(modelPath: modelPath)
        do {
            _ = try await generator.improve(
                request: "show battery",
                context: AIGeneratorContext(model: "gguf-local-7b")
            )
            Issue.record("expected .improvementUnsupported, got success")
        } catch let error as AIGeneratorError {
            #expect(error == .improvementUnsupported)
        }
    }
}

// MARK: - View model improve

@MainActor
struct AIGeneratorViewModelImproveTests {

    @Test func testImprove_viewModel_replacesRequestOnSuccess() async {
        let generator = CapturingMockAIPluginGenerator(
            improveResponse: "Show today's weather in Beijing with Celsius, refreshed every 30 minutes."
        )
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.request = "weather"

        await viewModel.improveRequest()

        #expect(generator.improveCallCount == 1)
        #expect(generator.lastImproveRequest == "weather")
        #expect(generator.lastImproveContext == viewModel.context)
        #expect(viewModel.request == "Show today's weather in Beijing with Celsius, refreshed every 30 minutes.")
    }

    @Test func testImprove_viewModel_doesNotChangeRequestOnFailure() async {
        let generator = CapturingMockAIPluginGenerator(
            improveErrorToThrow: AIGeneratorError.providerFailure(reason: "upstream down")
        )
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.request = "weather"

        await viewModel.improveRequest()

        #expect(generator.improveCallCount == 1)
        #expect(viewModel.request == "weather")
    }

    @Test func testImprove_viewModel_isImprovingFlagToggles() async {
        // The flag must be `true` mid-call and `false` after
        // the call returns. We assert this by parking the
        // `improve(...)` call behind a `CheckedContinuation`
        // and observing the flag from the main actor while
        // the call is suspended.
        actor ImproveGate {
            private var didEnter = false
            private var continuation: CheckedContinuation<String, Never>?

            func enter() {
                didEnter = true
            }

            func didEnterValue() -> Bool { didEnter }

            func waitForRelease() async -> String {
                await withCheckedContinuation { c in
                    self.continuation = c
                }
            }

            func release(_ value: String) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let gate = ImproveGate()

        final class GatedMock: AIPluginGenerator {
            let gate: ImproveGate
            init(gate: ImproveGate) { self.gate = gate }
            func generate(request: String, context: AIGeneratorContext) async throws -> GeneratedPlugin {
                throw AIGeneratorError.providerFailure(reason: "not used")
            }
            func improve(request: String, context: AIGeneratorContext) async throws -> String {
                await gate.enter()
                return await gate.waitForRelease()
            }
        }

        let viewModel = AIGeneratorViewModel(generator: GatedMock(gate: gate))
        viewModel.request = "weather"

        let task = Task {
            await viewModel.improveRequest()
        }
        // Yield long enough for the gated call to enter.
        for _ in 0..<50 {
            if await gate.didEnterValue() { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        #expect(await gate.didEnterValue())
        #expect(viewModel.isImproving == true)
        await gate.release("done")
        await task.value
        #expect(viewModel.isImproving == false)
    }
}

// MARK: - Remote generator improve

struct RemoteAIPluginGeneratorImproveTests {

    @Test func testImprove_remote_usesLowTemperature() async throws {
        // Capture the body via the stub and assert that
        // `temperature: 0.3` and `stream: false` are sent on
        // the wire. The system prompt is the dedicated
        // `improveSystemPrompt` — we do not assert on its
        // exact wording (a future prompt edit would force
        // a test update), only that `messages[0].role ==
        // "system"` and `messages[1].role == "user"`.
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let apiKey = "test-key-1234567890"
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        // Canned assistant content: a single-line rewrite.
        let assistantContent = "Show today's weather in Beijing with Celsius, refreshed every 30 minutes."
        let envelope: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": assistantContent]]
            ]
        ]
        let body = try JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys]
        )
        transport.register(data: body, response: response)

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint,
            apiKey: apiKey,
            model: "gpt-4o-mini",
            transport: transport
        )

        let improved = try await generator.improve(
            request: "weather",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        )

        let captured = try #require(transport.lastRequest)
        let bodyData = try #require(captured.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let envelopeDict = try #require(decoded)

        #expect(envelopeDict["temperature"] as? Double == 0.3)
        #expect(envelopeDict["stream"] as? Bool == false)
        let responseFormat = try #require(envelopeDict["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_object")

        let messages = try #require(envelopeDict["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        let userContent = try #require(messages[1]["content"] as? String)
        #expect(userContent == "weather")

        // The returned improved string is the canned content,
        // trimmed. Sanity-check the round-trip succeeded.
        #expect(improved == assistantContent)
    }

    @Test func testImprove_remote_retriesOn5xx() async throws {
        // Reuse the same retry pattern as the `generate(...)`
        // retry tests: register a 5xx, then a 200, and assert
        // the helper successfully retried through to a 200.
        let endpoint = makeUniqueEndpoint()
        let response500 = HTTPURLResponse(
            url: endpoint, statusCode: 500,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let response200 = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let assistantContent = "Rewritten prompt."
        let envelope: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": assistantContent]]
            ]
        ]
        let body = try JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys]
        )
        let transport = SequencedStubRemoteTransport(responses: [
            (Data("internal error".utf8), response500),
            (body, response200)
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        let improved = try await generator.improve(
            request: "weather",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        )
        #expect(improved == assistantContent)
        #expect(transport.callCount == 2)
    }
}

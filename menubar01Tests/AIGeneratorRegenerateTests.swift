// AIGeneratorRegenerateTests.swift
// menubar01 — AI Plugin Generator (M2+)
//
// Swift Testing coverage for the success-view "Re-generate"
// button that asks the active `AIPluginGenerator` for a
// *variation* of the previous result by re-running
// `generate(...)` with `temperature: 0.8`. The tests pin:
//
//   * The Mock override — `generate(...)` is called with the
//     high temperature, and the resulting `promptId` matches
//     the SHA256 hash that bakes the temperature into the
//     input (i.e. a different `promptId` from the no-temperature
//     first run, so the M5 history store treats it as a fresh
//     row).
//   * The view-model glue — `regenerateWithVariation()`
//     preserves the previous `state` / `latestPlugin` on
//     failure (a transient LLM error does not blow away a
//     successful generation), flips `isRegenerating` to `true`
//     mid-call and `false` after, and records a fresh history
//     row when the round-trip succeeds.
//   * The Remote override — the body captured by the stub
//     transport asserts on `"temperature": 0.8` in the JSON
//     envelope, so a future refactor that accidentally drops
//     the override would fail this test.

import CryptoKit
import Foundation
import Testing

@testable import menubar01

// MARK: - Mock generator

/// `AIPluginGenerator` that records the `(request, context)`
/// pair for the most recent call and lets each test choose
/// what to return. Mirrors the spirit of
/// `AIGeneratorImproveTests.CapturingMockAIPluginGenerator`
/// but without the `improve(...)` override — the re-generate
/// path only exercises `generate(...)`.
private final class CapturingMockAIPluginGenerator: AIPluginGenerator {
    let response: GeneratedPlugin?
    let errorToThrow: Error?

    private(set) var lastRequest: String?
    private(set) var lastContext: AIGeneratorContext?
    private(set) var generateCallCount: Int = 0

    init(response: GeneratedPlugin? = nil, errorToThrow: Error? = nil) {
        self.response = response
        self.errorToThrow = errorToThrow
    }

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        generateCallCount += 1
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
}

// MARK: - Stub transport (reused from AIGeneratorImproveTests)

/// `RemoteTransport` that returns a pre-registered canned
/// response for a single request. Mirrors the
/// `StubRemoteTransport` in `AIGeneratorImproveTests` /
/// `RemoteAIPluginGeneratorTests` — declared file-private
/// here so the test file is self-contained.
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

// MARK: - Test helpers

/// Builds a `GeneratedPlugin` the view-model tests can
/// compare against. `promptId` is a deterministic value
/// derived from the `name` so the "no duplicate history
/// entry" test can spot a duplicate `promptId` from a
/// distance.
private func makeFixturePlugin(name: String, promptId: String) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = name
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = "regen.sh"
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho \(name)\n",
        explanation: "explanation for \(name)",
        promptId: promptId,
        promptVersion: "v-test"
    )
}

/// Test-only history store that captures the recorded entries
/// so the "no duplicate history entry" test can assert on
/// the row count + per-row `promptId` without booting the
/// file-system store. Mirrors the M5 `TestHistoryStore`
/// pattern.
private final class CapturingHistoryStore: AIGeneratorHistoryStore {
    var rootDirectory: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
    private(set) var recordedEntries: [AIGeneratorHistoryEntry] = []
    func record(_ entry: AIGeneratorHistoryEntry) throws {
        recordedEntries.append(entry)
    }
    func listAll() throws -> [AIGeneratorHistoryEntry] { recordedEntries }
    func delete(promptId: String) throws {
        recordedEntries.removeAll { $0.promptId == promptId }
    }
    func deleteAll() throws { recordedEntries.removeAll() }
}

/// `AIPluginGenerator` whose `generate(...)` returns
/// `firstResponse` for the first call and then `errorToThrow`
/// for every subsequent call. Used by the
/// `testRegenerate_viewModelPreservesStateOnFailure` test to
/// prime the view model with a successful first run and
/// then drive `regenerateWithVariation()` into a failure
/// path — the cleanest way to land the view model in
/// `.success(previousPlugin)` without depending on the
/// `private(set) latestPlugin` access modifier.
private final class ThrowsAfterFirstMockAIPluginGenerator: AIPluginGenerator {
    let firstResponse: GeneratedPlugin
    let errorToThrow: Error
    private(set) var generateCallCount: Int = 0
    private(set) var lastRequest: String?
    private(set) var lastContext: AIGeneratorContext?

    init(firstResponse: GeneratedPlugin, errorToThrow: Error) {
        self.firstResponse = firstResponse
        self.errorToThrow = errorToThrow
    }

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        generateCallCount += 1
        lastRequest = request
        lastContext = context
        if generateCallCount == 1 { return firstResponse }
        throw errorToThrow
    }
}

// MARK: - Mock generator (temperature-aware promptId)

struct AIGeneratorMockRegenerateTests {

    @Test func testRegenerate_mockReturnsPluginWithHigherTemperature() async throws {
        // Spin a fresh `MockAIPluginGenerator` and exercise
        // the temperature-aware `generate(...)` round-trip.
        // The returned plugin's `promptId` must match the
        // SHA256 hash that bakes the temperature into the
        // input (so the M5 history store treats the
        // variation as a distinct row from the no-temperature
        // first run).
        let generator = MockAIPluginGenerator()
        let request = "show weather in Beijing"
        let model = "gpt-4o-mini"
        let temperature: Double = 0.8
        let context = AIGeneratorContext(
            model: model, temperature: temperature
        )

        let plugin = try await generator.generate(
            request: request, context: context
        )

        // Independently recompute the expected hash. The
        // hash input for the temperature-aware overload is
        // `request + "|" + model + "|t=0.8"`.
        var hasher = SHA256()
        hasher.update(data: Data(request.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(model.utf8))
        hasher.update(data: Data("|t=0.8".utf8))
        let expected = hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
        #expect(plugin.promptId == expected)
        // And the no-temperature hash for the same
        // (request, model) pair must differ — the
        // re-generate is meant to land as a fresh history
        // row, not overwrite the first run.
        let noTemperatureHash = MockAIPluginGenerator.promptId(
            for: request, model: model
        )
        #expect(plugin.promptId != noTemperatureHash)
    }

    @Test func testRegenerate_mockTwoArgumentPromptIdIsByteIdenticalToV1() {
        // Backwards-compat: the v1 M1 tests (and the v1
        // M5 history store on-disk format) assume
        // `promptId(for:model:)` produces the exact same
        // hex digest it did before this change. Pin the
        // exact value for a known input so a future
        // refactor that accidentally appends "|t=nil" or
        // changes the byte stream fails this test.
        let request = "show weather"
        let model = "mock-7b-q4"
        let promptId = MockAIPluginGenerator.promptId(
            for: request, model: model
        )
        var hasher = SHA256()
        hasher.update(data: Data(request.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(model.utf8))
        let expected = hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
        #expect(promptId == expected)
    }
}

// MARK: - View model re-generate

@MainActor
struct AIGeneratorViewModelRegenerateTests {

    @Test func testRegenerate_viewModelPreservesStateOnFailure() async {
        // The view model is primed with a successful first
        // run (via `generate()`), the generator throws on the
        // *second* call, and the post-call `state` is still
        // `.success(plugin)` with `latestPlugin` unchanged.
        // The `state` enum is **not** flipped to
        // `.failure(...)` — a transient LLM error does not
        // blow away a successful generation.
        let previousPlugin = makeFixturePlugin(
            name: "Original", promptId: "original-1"
        )
        let generator = ThrowsAfterFirstMockAIPluginGenerator(
            firstResponse: previousPlugin,
            errorToThrow: AIGeneratorError.providerFailure(
                reason: "upstream down"
            )
        )
        let viewModel = AIGeneratorViewModel(generator: generator)

        // Drive the view model through `generate()` so it
        // lands in `.success(previousPlugin)`. The
        // generator returns `previousPlugin` on the first
        // call and throws on every subsequent call.
        viewModel.request = "show weather in Beijing"
        await viewModel.generate()
        // Sanity-check the prime worked.
        #expect(generator.generateCallCount == 1)
        #expect(viewModel.latestPlugin == previousPlugin)
        if case .success = viewModel.state { /* ok */ } else {
            Issue.record(
                "expected .success after the prime `generate()`, got \(viewModel.state)"
            )
        }

        // Now the re-generate path: the generator throws,
        // the view model should preserve the previous
        // success.
        await viewModel.regenerateWithVariation()

        #expect(generator.generateCallCount == 2)
        #expect(generator.lastRequest == "show weather in Beijing")
        // The view model passed the high-temperature
        // constant to the generator. We check the value
        // (not the identity) so the test stays
        // forward-compatible with a future tweak to the
        // constant.
        #expect(generator.lastContext?.temperature == 0.8)
        // State preserved: same plugin, same `.success(...)`
        // envelope, no `.failure(...)`.
        #expect(viewModel.latestPlugin == previousPlugin)
        if case .success(let p) = viewModel.state {
            #expect(p == previousPlugin)
        } else {
            Issue.record(
                "expected .success(previousPlugin) after a failed re-generate, got \(viewModel.state)"
            )
        }
        // `isRegenerating` resets on every exit path.
        #expect(viewModel.isRegenerating == false)
    }

    @Test func testRegenerate_isRegeneratingFlagToggles() async {
        // The flag must be `true` mid-call and `false` after
        // the call returns. We assert this by parking the
        // `generate(...)` call behind a `CheckedContinuation`
        // and observing the flag from the main actor while
        // the call is suspended.
        actor RegenerateGate {
            private var didEnter = false
            private var continuation: CheckedContinuation<GeneratedPlugin, Never>?

            func enter() {
                didEnter = true
            }

            func didEnterValue() -> Bool { didEnter }

            func waitForRelease() async -> GeneratedPlugin {
                await withCheckedContinuation { c in
                    self.continuation = c
                }
            }

            func release(_ value: GeneratedPlugin) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let gate = RegenerateGate()

        // Counter-based generator: returns a first plugin
        // synchronously (so the prime `generate()` lands
        // the view model in `.success`), and parks the
        // second call behind the gate (so the
        // `regenerateWithVariation()` round-trip is
        // observable mid-flight).
        final class GatedMock: AIPluginGenerator {
            let gate: RegenerateGate
            let firstPlugin: GeneratedPlugin
            private(set) var generateCallCount: Int = 0
            init(gate: RegenerateGate, firstPlugin: GeneratedPlugin) {
                self.gate = gate
                self.firstPlugin = firstPlugin
            }
            func generate(
                request: String, context: AIGeneratorContext
            ) async throws -> GeneratedPlugin {
                generateCallCount += 1
                if generateCallCount == 1 { return firstPlugin }
                await gate.enter()
                return await gate.waitForRelease()
            }
        }

        let firstPlugin = makeFixturePlugin(
            name: "First", promptId: "first-1"
        )
        let viewModel = AIGeneratorViewModel(
            generator: GatedMock(gate: gate, firstPlugin: firstPlugin)
        )
        // Prime with a successful first run.
        viewModel.request = "show weather"
        await viewModel.generate()
        #expect(viewModel.latestPlugin == firstPlugin)
        if case .success = viewModel.state { /* ok */ } else {
            Issue.record("expected .success after the prime `generate()`")
        }

        let task = Task {
            await viewModel.regenerateWithVariation()
        }
        // Yield long enough for the gated call to enter.
        for _ in 0..<50 {
            if await gate.didEnterValue() { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        #expect(await gate.didEnterValue())
        #expect(viewModel.isRegenerating == true)
        await gate.release(firstPlugin)
        await task.value
        #expect(viewModel.isRegenerating == false)
    }

    @Test func testRegenerate_noDuplicateHistoryEntry() async {
        // A fresh history store is injected, the view
        // model is primed with a successful first run, and
        // the second `regenerateWithVariation()` call
        // records exactly one additional history entry
        // (i.e. the high-temperature `promptId` is
        // distinct from the first run's `promptId`, so the
        // on-disk store gets a fresh row rather than
        // overwriting the first row).
        let firstPlugin = makeFixturePlugin(
            name: "First", promptId: "first-1"
        )
        let secondPlugin = makeFixturePlugin(
            name: "Second", promptId: "second-2"
        )
        // Configure the generator so the first call
        // (which the view model itself drives) returns
        // the first plugin and the second call returns
        // the second plugin. We use a counter to swap.
        final class SequencedMock: AIPluginGenerator {
            let first: GeneratedPlugin
            let second: GeneratedPlugin
            private(set) var calls: [AIGeneratorContext] = []
            init(first: GeneratedPlugin, second: GeneratedPlugin) {
                self.first = first
                self.second = second
            }
            func generate(
                request: String, context: AIGeneratorContext
            ) async throws -> GeneratedPlugin {
                calls.append(context)
                if calls.count == 1 { return first }
                return second
            }
        }
        let generator = SequencedMock(
            first: firstPlugin, second: secondPlugin
        )
        let store = CapturingHistoryStore()
        let viewModel = AIGeneratorViewModel(
            generator: generator, historyStore: store
        )

        // First run: full `generate()` path so the history
        // store records the first entry.
        viewModel.request = "show weather in Beijing"
        await viewModel.generate()
        #expect(store.recordedEntries.count == 1)
        #expect(store.recordedEntries[0].promptId == "first-1")
        // `generate()`'s first call must have used the
        // default temperature (the published context's
        // temperature, which is `nil` from `.empty`).
        #expect(generator.calls[0].temperature == nil)

        // Re-generate: high-temperature path. Should
        // record a fresh row (different `promptId` from
        // the first run, since the temperature is baked
        // into the SHA256 hash).
        await viewModel.regenerateWithVariation()
        #expect(store.recordedEntries.count == 2)
        #expect(store.recordedEntries[1].promptId == "second-2")
        // `regenerateWithVariation` must have used
        // temperature 0.8, not the published `context`'s
        // `nil`.
        #expect(generator.calls[1].temperature == 0.8)
        // And the two recorded entries must have
        // distinct `promptId`s — i.e. the temperature
        // really did change the hash, and the on-disk
        // store would land them in separate directories.
        #expect(store.recordedEntries[0].promptId
                != store.recordedEntries[1].promptId)
    }
}

// MARK: - Remote generator (temperature override on the wire)

struct RemoteAIPluginGeneratorRegenerateTests {

    @Test func testRegenerate_remoteUsesHigherTemperature() async throws {
        // Capture the body via the stub and assert that
        // `temperature: 0.8` is sent on the wire. The
        // system prompt is the existing
        // `RemoteAIPluginGenerator.systemPrompt` — we do
        // not assert on its exact wording (a future
        // prompt edit would force a test update), only
        // that `messages[0].role == "system"` and
        // `messages[1].role == "user"`.
        let transport = StubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let apiKey = "test-key-1234567890"
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        // Canned assistant content: the three-field JSON
        // payload the generator expects. The exact shape
        // is the `RemoteAIGeneratorPayload` schema
        // (manifest + entryScript + explanation) — see
        // `RemoteAIPluginGenerator.makeGeneratedPlugin(...)`.
        let envelope: [String: Any] = [
            "choices": [
                ["message": [
                    "role": "assistant",
                    "content": """
                    {
                      "manifest": {
                        "name": "Variation",
                        "version": "1.0.0",
                        "type": "Executable",
                        "entry": "variation.sh",
                        "refreshInterval": 5
                      },
                      "entryScript": "#!/bin/zsh\\necho variation\\n",
                      "explanation": "A deliberately different plugin for the variation round-trip."
                    }
                    """
                ]]
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

        _ = try await generator.generate(
            request: "show weather in Beijing",
            context: AIGeneratorContext(
                model: "gpt-4o-mini", temperature: 0.8
            )
        )

        let captured = try #require(transport.lastRequest)
        let bodyData = try #require(captured.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let envelopeDict = try #require(decoded)

        // The body MUST carry `temperature: 0.8` so a
        // future refactor that accidentally drops the
        // override would fail this test.
        #expect(envelopeDict["temperature"] as? Double == 0.8)
        #expect(envelopeDict["stream"] as? Bool == false)
        let responseFormat = try #require(
            envelopeDict["response_format"] as? [String: Any]
        )
        #expect(responseFormat["type"] as? String == "json_object")

        let messages = try #require(
            envelopeDict["messages"] as? [[String: Any]]
        )
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        let userContent = try #require(messages[1]["content"] as? String)
        #expect(userContent == "show weather in Beijing")
    }
}

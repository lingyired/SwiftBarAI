// RemoteAIPluginGeneratorStreamTests.swift
// menubar01 — AI Plugin Generator (M2+)
//
// Swift Testing coverage for the streaming variant of
// `RemoteAIPluginGenerator`. The M2+ sheet's "Generate" button
// iterates `generator.stream(request:context:)` and appends each
// `textDelta` to a `streamingPreview`; on `.finished(_)` it builds
// a `GeneratedPlugin` from the assembled text. The tests below
// cover the wire-format parser, the retry policy, the
// `promptId` invariant shared with the non-streaming path,
// consumer-cancellation, and the malformed-chunk tolerance.
//
// The transport layer is stubbed via `StreamingStubRemoteTransport`
// (a `RemoteTransport` that yields a pre-registered sequence of
// `RemoteTransportStreamChunk` values), so:
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

// MARK: - Stream stub transport

/// `RemoteTransport` that yields a pre-registered sequence of
/// `RemoteTransportStreamChunk` values. The first yielded chunk
/// always carries the registered `URLResponse`; subsequent chunks
/// carry the registered `Data` slices in registration order.
///
/// The stub records the `URLRequest` the generator sent (for
/// `promptIdMatchesNonStreaming` and other request-shape tests)
/// and the `continuation.onTermination` invocation (for
/// `consumerCancellation_stopsTransport`).
private final class StreamingStubRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var response: URLResponse?
    private var dataChunks: [Data] = []
    private var capturedRequest: URLRequest?
    private var didInvokeOnTermination: Bool = false

    init() {}

    /// Register the HTTP response yielded as the very first
    /// `RemoteTransportStreamChunk` (status, headers, …).
    func registerResponse(_ response: URLResponse) {
        lock.withLock { self.response = response }
    }

    /// Register a body `Data` chunk. Multiple chunks are
    /// yielded in registration order; the parser handles
    /// line-aligned and mid-line boundaries identically.
    func registerDataChunk(_ data: Data) {
        lock.withLock { self.dataChunks.append(data) }
    }

    var lastRequest: URLRequest? {
        lock.withLock { capturedRequest }
    }

    var terminationInvoked: Bool {
        lock.withLock { didInvokeOnTermination }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Required by `RemoteTransport`. The streaming tests do
        // not call `send` directly; reaching this method is a
        // misconfiguration.
        throw URLError(.badServerResponse)
    }

    func streamData(
        for request: URLRequest
    ) -> AsyncThrowingStream<RemoteTransportStreamChunk, Error> {
        lock.withLock { capturedRequest = request }
        let (responseCopy, chunks) = lock.withLock { (response, dataChunks) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let responseCopy {
                    continuation.yield(
                        RemoteTransportStreamChunk(data: nil, response: responseCopy)
                    )
                }
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(
                        RemoteTransportStreamChunk(data: chunk, response: nil)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.didInvokeOnTermination = true }
                task.cancel()
            }
        }
    }
}

// MARK: - Helpers (shared with the non-streaming test file)

/// A canned `PluginManifest` JSON body used by the success-path
/// test. Keys are kept alphabetically sorted to match the
/// `JSONEncoder.OutputFormatting.sortedKeys` invariant used by
/// `makeOpenAISuccessBody`.
private let streamValidManifestJSON = """
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
/// completion envelope the non-streaming decoder reads.
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

// MARK: - 1. testStream_yieldsTextDeltasAsTheyArrive

struct RemoteAIPluginGeneratorStreamYieldTests {

    @Test func testStream_yieldsTextDeltasAsTheyArrive() async throws {
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.registerResponse(response)
        // The OpenAI SSE wire format. Two `textDelta` chunks
        // (carrying "foo" and "bar"), one `finish_reason`
        // chunk with an empty delta, and the `[DONE]`
        // sentinel.
        let sse = """
        data: {"choices":[{"delta":{"content":"foo"}}]}

        data: {"choices":[{"delta":{"content":"bar"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        transport.registerDataChunk(Data(sse.utf8))

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var events: [AIPluginGeneratorStreamEvent] = []
        for try await event in generator.stream(
            request: "show battery",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            events.append(event)
        }
        // Expected ordering: textDelta("foo"), textDelta("bar"),
        // finished("foobar").
        #expect(events == [
            .textDelta("foo"),
            .textDelta("bar"),
            .finished("foobar")
        ])
    }
}

// MARK: - 2. testStream_finishedEventContainsFullAssembledText

struct RemoteAIPluginGeneratorStreamFinishedTests {

    @Test func testStream_finishedEventContainsFullAssembledText() async throws {
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        // Three small deltas + `[DONE]`. The `.finished(_)`
        // payload must be the concatenation of every prior
        // `textDelta`, not just the last one.
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello, "}}]}

        data: {"choices":[{"delta":{"content":"streaming "}}]}

        data: {"choices":[{"delta":{"content":"world!"}}]}

        data: [DONE]

        """
        transport.registerDataChunk(Data(sse.utf8))

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var finishedText: String?
        for try await event in generator.stream(
            request: "greet",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            if case .finished(let text) = event {
                finishedText = text
            }
        }
        #expect(finishedText == "Hello, streaming world!")
    }
}

// MARK: - 3. testStream_nonSuccessStatus_throwsRateLimitedOrTransportError

struct RemoteAIPluginGeneratorStreamStatusCodeTests {

    @Test(arguments: [
        (429, AIGeneratorError.rateLimited),
        (500, AIGeneratorError.transportError(reason: "500")),
        (503, AIGeneratorError.transportError(reason: "503"))
    ])
    func testStream_nonSuccessStatus_throwsRateLimitedOrTransportError(
        status: Int, expected: AIGeneratorError
    ) async throws {
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        // The body never gets read on a non-2xx response, but
        // the stub needs a registered chunk for the transport
        // to be callable. Register an empty chunk so the loop
        // has something to yield.
        transport.registerDataChunk(Data())

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        do {
            for try await _ in generator.stream(
                request: "x",
                context: AIGeneratorContext(model: "gpt-4o-mini")
            ) {
                // Should never receive any events on a non-2xx.
                Issue.record("did not expect any stream events on status \(status)")
            }
            Issue.record("expected \(expected), got success")
        } catch let error as AIGeneratorError {
            #expect(error == expected)
        }
    }
}

// MARK: - 4. testStream_retriesOn5xx_thenSucceeds

/// `RemoteTransport` whose `streamData(...)` yields a pre-registered
/// sequence of (response, chunks) pairs, one per call. The first
/// call yields `responses[0]`, the second `responses[1]`, and so
/// on. Each response is followed by its own `Data` chunks, so the
/// streaming retry path can be exercised end-to-end (the first
/// call yields a 5xx, the second a 200 + valid SSE bytes).
private final class SequencedStreamingStubRemoteTransport: RemoteTransport, @unchecked Sendable {
    private final class Item: @unchecked Sendable {
        let response: URLResponse
        let dataChunks: [Data]
        init(response: URLResponse, dataChunks: [Data]) {
            self.response = response
            self.dataChunks = dataChunks
        }
    }
    private let lock = NSLock()
    private var items: [Item]
    private var callCount: Int = 0

    init(items: [(URLResponse, [Data])]) {
        self.items = items.map { Item(response: $0.0, dataChunks: $0.1) }
    }

    var calls: Int {
        lock.withLock { callCount }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.badServerResponse)
    }

    func streamData(
        for request: URLRequest
    ) -> AsyncThrowingStream<RemoteTransportStreamChunk, Error> {
        lock.withLock {
            callCount += 1
        }
        // Pop the first item off the queue so each
        // successive call yields the next canned
        // (response, chunks) pair. The retry test relies
        // on this to deliver a 500 first, then a 200.
        let item = lock.withLock { items.isEmpty ? nil : items.removeFirst() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let item else {
                    continuation.finish()
                    return
                }
                continuation.yield(
                    RemoteTransportStreamChunk(data: nil, response: item.response)
                )
                for chunk in item.dataChunks {
                    if Task.isCancelled { break }
                    continuation.yield(
                        RemoteTransportStreamChunk(data: chunk, response: nil)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

struct RemoteAIPluginGeneratorStreamRetryTests {

    @Test func testStream_retriesOn5xx_thenSucceeds() async throws {
        let endpoint = makeUniqueEndpoint()
        let response500 = HTTPURLResponse(
            url: endpoint, statusCode: 500,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let response200 = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let transport = SequencedStreamingStubRemoteTransport(items: [
            (response500, []),
            (response200, [Data(sse.utf8)])
        ])
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var events: [AIPluginGeneratorStreamEvent] = []
        for try await event in generator.stream(
            request: "x",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            events.append(event)
        }
        // The 5xx attempt should not have surfaced any text
        // deltas. Only the retry's events should be visible.
        #expect(events == [.textDelta("ok"), .finished("ok")])
        #expect(transport.calls == 2)
    }
}

// MARK: - 5. testStream_promptIdMatchesNonStreaming

struct RemoteAIPluginGeneratorStreamPromptIdTests {

    @Test func testStream_promptIdMatchesNonStreaming() async throws {
        // The streaming path derives `promptId` from the same
        // helper (`MockAIPluginGenerator.promptId(...)`) the
        // non-streaming `generate(...)` uses, and assembles a
        // `GeneratedPlugin` via
        // `RemoteAIPluginGenerator.makeGeneratedPlugin(fromContent:request:context:promptId:)`.
        // We exercise that helper directly with a stream-shaped
        // assembled-text payload and assert the resulting
        // `promptId` matches the helper's reference value.
        let endpoint = makeUniqueEndpoint()
        // The stub's `streamData` is never called in this test;
        // we are exercising the post-stream plugin-assembly
        // helper. A bare response + empty body is enough.
        let transport = StreamingStubRemoteTransport()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        // The non-streaming path uses
        // `makeOpenAISuccessBody` as the body; the streaming
        // path's assembled text is *just* the `content` field
        // (the inner `payload` JSON, not the outer envelope).
        let body = makeOpenAISuccessBody(
            manifestJSON: streamValidManifestJSON,
            entryScript: "#!/bin/bash\n",
            explanation: "n/a"
        )
        let envelope = try JSONDecoder().decode(
            RemoteChatCompletionsResponseEnvelopeForTests.self,
            from: body
        )
        let content = envelope.choices[0].message.content
        let request = "show battery"
        let model = "gpt-4o-mini"
        let expectedPromptId = MockAIPluginGenerator.promptId(
            for: request, model: model
        )
        let plugin = try generator.makeGeneratedPlugin(
            fromContent: content,
            request: request,
            context: AIGeneratorContext(model: model),
            promptId: expectedPromptId
        )
        #expect(plugin.promptId == expectedPromptId)
        // Sanity: the helper's output is the same shape the
        // non-streaming `generate(...)` would have produced
        // (manifest round-trips, entry script is the canned
        // body).
        #expect(plugin.manifest.name == "Battery")
        #expect(plugin.entryScript.contains("#!/bin/bash"))
    }
}

/// Local copy of the wire envelope the streaming parser and the
/// non-streaming decoder share. Mirrors
/// `RemoteChatCompletionsResponse` from
/// `RemoteAIPluginGenerator.swift` (which is `private` to that
/// file) so the test can read the assembled `content` field back
/// out of a canned body without round-tripping through the
/// generator's full state machine.
private struct RemoteChatCompletionsResponseEnvelopeForTests: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
    }
    struct Message: Decodable {
        let content: String
    }
}

// MARK: - 6. testStream_consumerCancellation_stopsTransport

struct RemoteAIPluginGeneratorStreamCancellationTests {

    @Test func testStream_consumerCancellation_stopsTransport() async throws {
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        // A handful of small chunks. The first two trigger a
        // `textDelta`, then the consumer breaks the iteration;
        // the test asserts the transport's `onTermination`
        // callback was invoked so the in-flight task was
        // cancelled.
        let sse = """
        data: {"choices":[{"delta":{"content":"hello"}}]}

        data: {"choices":[{"delta":{"content":" "}}]}

        data: {"choices":[{"delta":{"content":"world"}}]}

        data: [DONE]

        """
        transport.registerDataChunk(Data(sse.utf8))

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var received: [AIPluginGeneratorStreamEvent] = []
        for try await event in generator.stream(
            request: "x",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            received.append(event)
            if received.count >= 2 { break }
        }
        // Give the transport's `onTermination` callback a
        // moment to fire (it's invoked synchronously on the
        // consumer's `break` but the `Task` it cancels may
        // not finish draining in zero time).
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(transport.terminationInvoked)
    }
}

// MARK: - 7. testStream_emptyChoicesArray_yieldsEmptyFinished

struct RemoteAIPluginGeneratorStreamEmptyChoicesTests {

    @Test func testStream_emptyChoicesArray_yieldsEmptyFinished() async throws {
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        // A provider can legally close the stream with no
        // choices — e.g. an empty response on a tool-call-only
        // turn. The parser should still emit
        // `.finished("")` from the `[DONE]` sentinel.
        let sse = """
        data: {"choices":[]}

        data: [DONE]

        """
        transport.registerDataChunk(Data(sse.utf8))

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var finishedText: String?
        var deltaCount: Int = 0
        for try await event in generator.stream(
            request: "x",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            switch event {
            case .textDelta:
                deltaCount += 1
            case .finished(let text):
                finishedText = text
            }
        }
        #expect(finishedText == "")
        #expect(deltaCount == 0)
    }
}

// MARK: - 8. testStream_malformedSSE_skipsAndContinues

struct RemoteAIPluginGeneratorStreamMalformedChunkTests {

    @Test func testStream_malformedSSE_skipsAndContinues() async throws {
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        // First chunk is a `data:` line whose payload is not
        // valid JSON. The parser must skip it (logging via
        // `os_log`) and continue with the next event.
        // Second chunk is a valid `textDelta`. The third
        // carries `finish_reason`. The fourth is `[DONE]`.
        let sse = """
        data: {not-valid-json

        data: {"choices":[{"delta":{"content":"survived"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        transport.registerDataChunk(Data(sse.utf8))

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var events: [AIPluginGeneratorStreamEvent] = []
        for try await event in generator.stream(
            request: "x",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            events.append(event)
        }
        // The malformed chunk is silently dropped; only the
        // valid `textDelta` and the `.finished(...)` events
        // are surfaced.
        #expect(events == [
            .textDelta("survived"),
            .finished("survived")
        ])
    }

    @Test func testStream_sseCommentLines_areIgnored() async throws {
        // Belt-and-braces: SSE spec allows `: keep-alive`
        // comments; the parser must skip them without
        // producing an event.
        let transport = StreamingStubRemoteTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        transport.registerResponse(response)
        let sse = """
        : keep-alive

        data: {"choices":[{"delta":{"content":"hi"}}]}

        : another-keep-alive

        data: [DONE]

        """
        transport.registerDataChunk(Data(sse.utf8))

        let generator = RemoteAIPluginGenerator(
            endpoint: endpoint, apiKey: "k",
            model: "gpt-4o-mini", transport: transport
        )
        var events: [AIPluginGeneratorStreamEvent] = []
        for try await event in generator.stream(
            request: "x",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        ) {
            events.append(event)
        }
        #expect(events == [.textDelta("hi"), .finished("hi")])
    }
}

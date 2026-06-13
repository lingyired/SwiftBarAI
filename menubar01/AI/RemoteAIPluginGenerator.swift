// RemoteAIPluginGenerator.swift
// menubar01 — AI Plugin Generator (M2+)
//
// URLSession-backed implementation of `AIPluginGenerator` that POSTs
// to an OpenAI-compatible `/v1/chat/completions` endpoint and
// decodes the model's response into a `GeneratedPlugin`.
//
// This is the file-for-file replacement of the M2+
// `RemoteEchoAIPluginGenerator` placeholder. The factory at
// `AIPluginGeneratorFactory.makeRemote(endpoint:apiKey:prefs:)`
// now returns this type when both arguments are non-nil. The mock
// fallback path for nil arguments is unchanged.
//
// Architecture:
//   The actual HTTP call goes through a `RemoteTransport`
//   protocol so tests can inject a stub that captures the
//   request and returns a canned response without ever
//   touching the network. The default `URLSessionRemoteTransport`
//   is what production code uses; the test bundle uses a
//   `StubRemoteTransport` keyed by a per-test UUID.
//
// Security:
//   * The `apiKey` is held in memory only and is **never** embedded
//     in `GeneratedPlugin.explanation` or logged in plain text.
//   * The diagnostic `os_log` line in `init` shows the endpoint
//     host, the model name, and a redacted key (last two chars
//     only) so a system-report dump or future M5 history view can
//     never surface the secret in clear text.
//   * The `promptId` is `SHA256(request + "|" + context.model)`,
//     mirroring `MockAIPluginGenerator.promptId(for:model:)`, so
//     the existing test suite and any future history-persistence
//     code treats payloads uniformly across providers.

import CryptoKit
import Foundation
import os

// MARK: - RemoteTransport

/// Sends a `URLRequest` and returns the `(Data, URLResponse)`
/// pair. Production uses `URLSessionRemoteTransport` (wrapping
/// `URLSession`); tests use a stub implementation that captures
/// the request and returns a canned response without touching
/// the network.
///
/// Splitting the HTTP call behind a protocol keeps the
/// generator hermetic for unit tests: Swift Testing's parallel
/// execution does not play nicely with per-session
/// `URLSessionConfiguration.protocolClasses` on macOS, and
/// `URLSession.shared` ignores globally-registered
/// `URLProtocol` subclasses for HTTPS. Routing through a
/// protocol sidesteps both issues.
public protocol RemoteTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)

    /// Streaming counterpart of `send(_:)`. Yields the response
    /// body as one or more `Data` chunks, then a final empty
    /// `Data` sentinel followed by the `URLResponse`. The
    /// implementation is expected to honour
    /// `AsyncThrowingStream.onTermination` so a cancelled
    /// consumer (the M2 sheet's `for await ... break` path)
    /// tears down the in-flight `URLSession` data task and
    /// releases the underlying socket.
    ///
    /// The split into (chunks…, sentinel) + response mirrors
    /// the `URLSession.AsyncBytes` semantics so the production
    /// `URLSessionRemoteTransport` can wrap
    /// `URLSession.bytes(for:)` without buffering the whole
    /// body in memory.
    ///
    /// The default implementation throws
    /// `AIGeneratorError.streamingUnsupported` so the existing
    /// test stubs (which only implement `send(_:)`) keep
    /// working; the M2+ `RemoteAIPluginGenerator` falls back to
    /// a non-streaming `generate(...)` round-trip when the
    /// transport cannot stream.
    func streamData(
        for request: URLRequest
    ) -> AsyncThrowingStream<RemoteTransportStreamChunk, Error>
}

/// A single chunk produced by `RemoteTransport.streamData(for:)`.
///
/// The pair is `(Data?, URLResponse?)` rather than a tagged
/// enum so the `URLSession`-backed production implementation
/// can deliver the final `(Data?, URLResponse?)` atomically
/// when the response fits in a single chunk (small bodies,
/// 4xx error responses) without a separate "I'm done" signal.
public struct RemoteTransportStreamChunk: Sendable, Equatable {
    /// The next body chunk. `nil` when this is the terminal
    /// "no more body data" marker.
    public let data: Data?
    /// The HTTP response. Non-nil exactly once per stream —
    /// on the chunk that carries the first body bytes (or the
    /// terminal chunk for empty bodies). Subsequent chunks
    /// carry `response == nil` and just deliver more `data`.
    public let response: URLResponse?

    public init(data: Data?, response: URLResponse? = nil) {
        self.data = data
        self.response = response
    }
}

/// Production `RemoteTransport` that wraps `URLSession`.
public final class URLSessionRemoteTransport: RemoteTransport, @unchecked Sendable {
    public let urlSession: URLSession
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await urlSession.data(for: request)
    }

    public func streamData(
        for request: URLRequest
    ) -> AsyncThrowingStream<RemoteTransportStreamChunk, Error> {
        let session = urlSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    // First chunk carries the response so the
                    // consumer can read the HTTP status before
                    // any body bytes arrive.
                    continuation.yield(
                        RemoteTransportStreamChunk(data: nil, response: response)
                    )
                    // `URLSession.AsyncBytes` is a sequence of
                    // `UInt8` on macOS 12+. We batch the bytes
                    // into `Data` slices cut on the SSE line
                    // delimiter (`\n`) so the consumer sees
                    // line-aligned chunks the way OpenAI's
                    // wire format actually delivers them.
                    // The trailing partial line (no `\n` yet)
                    // is yielded on stream termination so no
                    // bytes are dropped.
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A { // '\n'
                            let chunk = buffer
                            buffer.removeAll(keepingCapacity: true)
                            continuation.yield(
                                RemoteTransportStreamChunk(
                                    data: chunk,
                                    response: nil
                                )
                            )
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(
                            RemoteTransportStreamChunk(
                                data: buffer,
                                response: nil
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

public extension RemoteTransport {
    /// Default `streamData(for:)` that throws
    /// `AIGeneratorError.streamingUnsupported` on the first
    /// iteration. Mirrors the default `stream(...)` on
    /// `AIPluginGenerator` so the existing test stubs (which
    /// only implement `send(_:)`) keep compiling and the M2
    /// sheet can fall back to a non-streaming `generate(...)`
    /// round-trip on transports that do not implement
    /// streaming.
    func streamData(
        for request: URLRequest
    ) -> AsyncThrowingStream<RemoteTransportStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIGeneratorError.streamingUnsupported)
        }
    }
}

// MARK: - Generator

/// Real remote-provider `AIPluginGenerator` that POSTs a chat-
/// completion request to the user-configured endpoint and decodes
/// the response into a `GeneratedPlugin`.
///
/// The endpoint is treated as either:
///   * a bare origin like `https://api.openai.com` — the generator
///     appends `/v1/chat/completions`, or
///   * a fully-qualified URL that already includes
///     `/v1/chat/completions` — used as-is.
///
/// The request body uses OpenAI's `response_format: json_object`
/// mode and asks the model to return a JSON object with three
/// fields: a `PluginManifest` JSON object, the entry script body,
/// and a one-to-two-sentence `explanation`.
///
/// HTTP status codes map to `AIGeneratorError` cases:
///   * 401 / 403 → `.unauthorized` (not retried)
///   * 429 → `.rateLimited` (retried up to `maxRetries` times)
///   * 5xx → `.transportError(reason: "<status> <body>")`
///     (retried up to `maxRetries` times)
///   * other 4xx → `.providerFailure(reason: "<status> <body>")`
///     (not retried)
///   * `URLError` → `.transportError(reason: …)` (not retried)
///   * decode failures → `.malformedResponse(reason: …)` (not
///     retried; the request succeeded, the body was bad)
///
/// Retries use exponential backoff: 1s, 2s, 4s (base 1s, factor
/// 2). If the response carries a `Retry-After` header (parsed
/// as delta-seconds or RFC 7231 HTTP-date), that value is used
/// instead and is capped at 60s. The default `maxRetries` is
/// `3` (so up to 4 total calls); pass `0` to disable retry.
public final class RemoteAIPluginGenerator: AIPluginGenerator {
    /// Version string reported in `GeneratedPlugin.promptVersion`.
    /// Distinguishes the real HTTP-backed payload from
    /// `MockAIPluginGenerator.mockPromptVersion`
    /// (`"v1.0-mock"`) and from the M2+ placeholder
    /// `RemoteEchoAIPluginGenerator.remoteEchoPromptVersion`
    /// (`"v1.0-echo-remote"`).
    public static let remotePromptVersion = "v1.0-remote"

    /// The remote endpoint URL the user picked in the Preferences →
    /// AI pane. Stored verbatim so tests can assert on the exact
    /// URL the generator dials.
    public let endpoint: URL

    /// The user's API key. Stored in-memory only; never serialised
    /// to `GeneratedPlugin.explanation`, never logged in plain
    /// text, and never returned through any public accessor. The
    /// redacted log line in `init` is the only place this value is
    /// mentioned.
    public let apiKey: String

    /// The model identifier sent in the request body and used as
    /// the second half of the `SHA256` `promptId` hash. Defaults
    /// to `"gpt-4o-mini"` to match the `AIGeneratorContext.empty`
    /// default and the example used throughout
    /// `AI_PLUGIN_ARCHITECTURE.md` §7.
    public let model: String

    /// The transport used to perform the request. Defaults to
    /// `URLSessionRemoteTransport()` (which wraps
    /// `URLSession.shared`); tests inject a stub that returns a
    /// canned `(Data, URLResponse)` without touching the network.
    public let transport: RemoteTransport

    /// Maximum number of additional attempts the generator will
    /// make after a 429 or 5xx response. The default of `3` means
    /// up to 4 total HTTP calls (the initial call + 3 retries)
    /// with delays of 1s, 2s, and 4s between them (exponential
    /// backoff, base 1s, factor 2). If the response carries a
    /// `Retry-After` header, that value is used in place of the
    /// exponential delay and is capped at 60s. Other status codes
    /// (2xx, 401, 403, other 4xx) and `URLError` are **not**
    /// retried — the user has to fix their API key or address a
    /// provider-side bug.
    public let maxRetries: Int

    /// Host portion of the endpoint the generator dials, exposed
    /// so the M5 history UI can render "Generated by `<model>` at
    /// `<host>`" alongside each entry without leaking the full
    /// URL or the apiKey. Overrides the `nil` default from
    /// `AIPluginGenerator`; returns `endpoint.host` verbatim
    /// (which may be `nil` for malformed endpoints, matching
    /// `URL.host`'s contract).
    public var endpointHost: String? { endpoint.host }

    /// Stable label the M5 history-UI filter picker groups
    /// remote entries under. Mirrors the placeholder
    /// `RemoteEchoAIPluginGenerator`'s label so the picker
    /// treats both implementations the same way.
    public static let providerDisplayName = "Remote"

    /// `providerName` for the remote generator. Mirrors the
    /// static `providerDisplayName` so the M5 history filter
    /// picker can group remote entries together independent
    /// of the actual `endpoint.host`.
    public var providerName: String? { Self.providerDisplayName }

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    /// Build a real remote-provider generator.
    ///
    /// - Parameters:
    ///   - endpoint: The user-configured endpoint URL. May be a
    ///     bare origin (e.g. `https://api.openai.com`) — the
    ///     generator appends `/v1/chat/completions` — or a
    ///     fully-qualified URL that already includes
    ///     `/v1/chat/completions`.
    ///   - apiKey: The user's API key. Held in memory only.
    ///   - model: The model identifier sent in the request body.
    ///     Defaults to `"gpt-4o-mini"`.
    ///   - transport: The transport used to perform the HTTP call.
    ///     Defaults to `URLSessionRemoteTransport()`. Tests inject
    ///     a stub transport that captures the request and returns
    ///     a canned response.
    ///   - maxRetries: Maximum number of automatic retries on 429
    ///     or 5xx responses. Defaults to `3` (so up to 4 total
    ///     calls). Set to `0` to disable retry entirely.
    public init(
        endpoint: URL,
        apiKey: String,
        model: String = "gpt-4o-mini",
        transport: RemoteTransport = URLSessionRemoteTransport(),
        maxRetries: Int = 3
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.maxRetries = maxRetries
        // Log the endpoint host (not the full URL — paths and
        // queries may carry the apiKey as a query param on some
        // providers), the model, and a redacted key so the
        // diagnostic dump shows what the factory did without ever
        // exposing the secret.
        let host = endpoint.host ?? "<no-host>"
        let redactedKey = Self.redact(apiKey: apiKey)
        os_log(
            "AIPluginGenerator: RemoteAI picked endpoint host=%{public}@ model=%{public}@ (apiKey=%{public}@)",
            log: Self.log, type: .info, host, model, redactedKey
        )
    }

    public func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        // Deterministic promptId, matching the Mock / Echo
        // contract so the existing test suite (and any future
        // history-persistence code keyed on promptId) treats
        // remote payloads uniformly. The temperature-aware
        // overload appends "|t=<value>" to the hash when
        // `context.temperature != nil`, so a high-temperature
        // re-generate (the M2+ "Re-generate" button) gets its
        // own `promptId` and lands in history as a fresh row.
        let promptId = MockAIPluginGenerator.promptId(
            for: request,
            model: context.model,
            temperature: context.temperature
        )

        // Encode the request body. `JSONEncoder` defaults use the
        // property name verbatim, so `response_format` is emitted
        // as `response_format` and the `Message` struct is encoded
        // as `{"role": …, "content": …}`. The temperature is read
        // from the context when present (M2+ "Re-generate" path
        // sets it to 0.8) and falls back to the historical 0.2
        // default for the first-run / normal-generate path.
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(
                RemoteChatCompletionsRequest(
                    model: context.model,
                    systemPrompt: Self.systemPrompt,
                    userPrompt: request,
                    temperature: context.temperature ?? 0.2
                )
            )
        } catch {
            throw AIGeneratorError.malformedResponse(
                reason: "could not encode request: \(error.localizedDescription)"
            )
        }

        // Build the URLRequest.
        var urlRequest = URLRequest(url: Self.requestURL(for: endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = bodyData

        // Perform the call (with retry on 429 / 5xx — see
        // `performWithRetry`).
        let data: Data
        let response: URLResponse
        (data, response) = try await performWithRetry(
            urlRequest: urlRequest,
            remaining: maxRetries
        )

        // A successful retry already validated the status code
        // in `performWithRetry`, so a 2xx response is guaranteed
        // by the time we get here.
        _ = response

        // Decode the OpenAI chat-completion envelope.
        let envelope: RemoteChatCompletionsResponse
        do {
            envelope = try JSONDecoder().decode(
                RemoteChatCompletionsResponse.self,
                from: data
            )
        } catch {
            throw AIGeneratorError.malformedResponse(
                reason: error.localizedDescription
            )
        }
        guard let content = envelope.choices.first?.message.content,
              !content.isEmpty
        else {
            throw AIGeneratorError.malformedResponse(
                reason: "missing or empty choices[0].message.content"
            )
        }

        return try makeGeneratedPlugin(
            fromContent: content,
            request: request,
            context: context,
            promptId: promptId
        )
    }

    public func stream(
        request: String,
        context: AIGeneratorContext
    ) -> AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // Compute the same deterministic promptId the
            // non-streaming `generate(...)` would, so the M5
            // history store treats streamed and non-streamed
            // runs as the same logical event. The
            // temperature-aware overload appends "|t=<value>"
            // to the hash when `context.temperature != nil`,
            // so a high-temperature re-generate gets its own
            // `promptId` and a fresh history row.
            let promptId = MockAIPluginGenerator.promptId(
                for: request, model: context.model,
                temperature: context.temperature
            )

            // Encode the request body once, here, so the
            // stream can re-issue it after a 429 / 5xx retry
            // without rebuilding the JSONEncoder from scratch.
            // The temperature is read from the context when
            // present (M2+ "Re-generate" path sets it to 0.8)
            // and falls back to the historical 0.2 default.
            let bodyData: Data
            do {
                bodyData = try JSONEncoder().encode(
                    RemoteChatCompletionsRequest(
                        model: context.model,
                        systemPrompt: Self.systemPrompt,
                        userPrompt: request,
                        stream: true,
                        temperature: context.temperature ?? 0.2
                    )
                )
            } catch {
                continuation.finish(throwing: AIGeneratorError.malformedResponse(
                    reason: "could not encode request: \(error.localizedDescription)"
                ))
                return
            }

            // Build the URLRequest with `stream: true` in the
            // body so the OpenAI-compatible provider emits
            // SSE chunks instead of one big JSON envelope.
            var urlRequest = URLRequest(url: Self.requestURL(for: endpoint))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.httpBody = bodyData

            // Mutable state threaded through the SSE parser.
            // The parser reassembles partial JSON objects
            // across chunk boundaries; the buffer holds the
            // unconsumed tail of the body stream.
            var buffer = ""
            // `sawFinish` flips to `true` when an SSE chunk
            // carries `choices[0].finish_reason`; the next
            // `[DONE]` sentinel terminates the stream.
            var sawFinish = false
            // Total assembled text the consumer will see in
            // the `.finished(_)` payload.
            var assembled = ""

            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    // Walk the per-attempt stream. Each
                    // attempt re-runs the SSE parser; on a
                    // 429 / 5xx we re-issue the request after
                    // a backoff sleep, identical to
                    // `performWithRetry`.
                    try await self.runStreamingAttempts(
                        urlRequest: urlRequest,
                        remaining: self.maxRetries,
                        buffer: &buffer,
                        sawFinish: &sawFinish,
                        assembled: &assembled,
                        continuation: continuation
                    )
                    // If the stream ended without a
                    // `.finished(_)` event (provider closed
                    // the connection early, or the response
                    // had no `choices[].finish_reason`), fall
                    // back to a synthetic `.finished(_)` from
                    // whatever was assembled. An empty
                    // assembled text is treated as a
                    // malformed response.
                    if !sawFinish {
                        if assembled.isEmpty {
                            continuation.finish(throwing: AIGeneratorError.malformedResponse(
                                reason: "stream ended without a finish event"
                            ))
                        } else {
                            continuation.yield(.finished(assembled))
                            continuation.finish()
                        }
                    } else {
                        continuation.finish()
                    }
                    // `promptId` is unused at the
                    // stream level — the `.finished(_)`
                    // payload is the assembled text, and the
                    // consumer (M2 sheet / view model) runs
                    // `makeGeneratedPlugin` on the main
                    // actor to derive the final
                    // `GeneratedPlugin` with the same
                    // `promptId` and `promptVersion` the
                    // non-streaming `generate(...)` would
                    // have produced. Reference `promptId`
                    // here to silence the "unused" warning
                    // and make the contract explicit.
                    _ = promptId
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// M2+ "Improve" helper. POSTs the user's request to the
    /// remote provider with a dedicated system prompt that asks
    /// the model to rewrite the request as a single, specific
    /// instruction a menubar01 plugin generator could act on,
    /// and returns the trimmed
    /// `choices[0].message.content`. Uses a low temperature
    /// (`0.3`) so the rewrite is consistent across clicks, and
    /// `stream: false` because the consumer (the M2 sheet's
    /// `improveRequest()` view-model method) just needs the
    /// final string — there is no UI to stream into.
    ///
    /// Re-uses the same `performWithRetry` helper as
    /// `generate(...)` so a 429 / 5xx response is retried with
    /// the same exponential-backoff / `Retry-After` policy. 401
    /// / 403 / other 4xx are surfaced as
    /// `AIGeneratorError.unauthorized` / `.providerFailure`
    /// without retry, identical to the `generate(...)` path.
    public func improve(
        request: String,
        context: AIGeneratorContext
    ) async throws -> String {
        // Encode the request body with a temperature of 0.3 and
        // `stream: false`. `response_format: json_object` is kept
        // so the model cannot leak prose around the rewritten
        // prompt; the consumer (the view model) trims the
        // returned string anyway.
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(
                RemoteChatCompletionsRequest(
                    model: context.model,
                    systemPrompt: Self.improveSystemPrompt,
                    userPrompt: request,
                    stream: false,
                    temperature: 0.3
                )
            )
        } catch {
            throw AIGeneratorError.malformedResponse(
                reason: "could not encode improve request: \(error.localizedDescription)"
            )
        }

        var urlRequest = URLRequest(url: Self.requestURL(for: endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = bodyData

        let data: Data
        let response: URLResponse
        (data, response) = try await performWithRetry(
            urlRequest: urlRequest,
            remaining: maxRetries
        )
        _ = response

        let envelope: RemoteChatCompletionsResponse
        do {
            envelope = try JSONDecoder().decode(
                RemoteChatCompletionsResponse.self,
                from: data
            )
        } catch {
            throw AIGeneratorError.malformedResponse(
                reason: error.localizedDescription
            )
        }
        guard let content = envelope.choices.first?.message.content,
              !content.isEmpty
        else {
            throw AIGeneratorError.malformedResponse(
                reason: "missing or empty choices[0].message.content"
            )
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers (shared with stream)

    /// Builds a `GeneratedPlugin` from the model's assembled
    /// content string. Shared between the non-streaming
    /// `generate(...)` (which calls it with the full envelope's
    /// `choices[0].message.content`) and the streaming
    /// `stream(...)` (which calls it on the consumer side from
    /// the M2 sheet's `generateStreaming()` view-model method
    /// with the assembled text from `.finished(_)`). Keeping
    /// the two paths routed through the same helper guarantees
    /// the same `explanation`, `promptId`, and `promptVersion`
    /// for any given `(request, context)` pair.
    func makeGeneratedPlugin(
        fromContent content: String,
        request: String,
        context: AIGeneratorContext,
        promptId: String
    ) throws -> GeneratedPlugin {
        let contentData = Data(content.utf8)
        let parsed: RemoteAIGeneratorPayload
        do {
            parsed = try JSONDecoder().decode(
                RemoteAIGeneratorPayload.self,
                from: contentData
            )
        } catch {
            throw AIGeneratorError.malformedResponse(
                reason: error.localizedDescription
            )
        }
        let host = endpoint.host ?? "<no-host>"
        let explanation = """
        \(parsed.explanation)

        Generated by the remote model at \(host) using \(context.model) \
        (promptVersion=\(Self.remotePromptVersion)).
        """
        return GeneratedPlugin(
            manifest: parsed.manifest,
            entryScript: parsed.entryScript,
            explanation: explanation,
            promptId: promptId,
            promptVersion: Self.remotePromptVersion
        )
    }

    /// The system prompt sent as the first message in the
    /// `messages` array. Asks the model for a three-field JSON
    /// object (manifest, entryScript, explanation) and nothing
    /// else; the `response_format: json_object` mode on the
    /// request body ensures the model can honour this without
    /// leaking prose into the content string.
    static let systemPrompt: String = """
    You are a menubar01 plugin generator. Reply with a single JSON
    object (no surrounding prose, no markdown fences) with exactly
    three fields:

    1. "manifest" — a JSON object matching the menubar01
       PluginManifest shape. Use these keys where they apply: name,
       version, description, author, type, entry, refreshInterval,
       runInBash, parameters.
    2. "entryScript" — a string containing the body of the entry
       script. Do not include a shebang line; menubar01's install
       flow adds one. Use bash, zsh, python3, or node as fits the
       task. Echo values from the script's environment
       (MENUBAR01_PARAM_<NAME>) rather than hard-coding them.
    3. "explanation" — a one-or-two-sentence human-readable note
       describing what the plugin does and how to use it.

    Do not include any text outside the JSON object.
    """

    /// The system prompt sent as the first message in the
    /// `messages` array by `improve(request:context:)`. Asks
    /// the model to rewrite the user's natural-language
    /// request as a single, specific instruction a menubar01
    /// plugin generator could act on, and to return only the
    /// rewritten prompt — no surrounding prose, no JSON
    /// envelope, no markdown fences. The consumer
    /// (`AIGeneratorViewModel.improveRequest()`) trims the
    /// result and splats it straight into the request editor.
    static let improveSystemPrompt: String = """
    You are a prompt rewriter for the menubar01 AI plugin generator. \
    The user will give you a short, often vague, natural-language \
    description of a macOS menu bar plugin. Rewrite it as a single, \
    clear, specific instruction that another LLM (the plugin \
    generator) could act on to produce a working menubar01 plugin.

    Make the rewrite:
      * Specific — name the data source (e.g. weather, battery, \
        calendar, current track, system status), the unit (Celsius \
        vs Fahrenheit, hours vs minutes), and the refresh cadence \
        when it matters.
      * Concrete — describe the menu layout the user probably \
        wants (top-level line, submenu, submenu items) in one \
        sentence.
      * Single-paragraph — one paragraph, no bullet points, no \
        numbered list, no leading phrases like "Rewrite: " or \
        "Improved: ".

    Reply with the rewritten prompt only — no surrounding prose, \
    no markdown fences, no JSON envelope. The whole response will \
    be dropped into a text editor and reviewed by the user.
    """

    /// Resolves the request URL. If the endpoint's path already
    /// ends in `/v1/chat/completions`, the endpoint is used
    /// verbatim; otherwise `/v1/chat/completions` is appended.
    /// Exposed internally so the test can assert the same
    /// resolution the runtime uses without duplicating the rule.
    static func requestURL(for endpoint: URL) -> URL {
        let path = endpoint.path
        if path.hasSuffix("/v1/chat/completions") {
            return endpoint
        }
        if path.isEmpty || path == "/" {
            return endpoint.appendingPathComponent("v1/chat/completions")
        }
        if path.hasSuffix("/v1") {
            return endpoint.appendingPathComponent("chat/completions")
        }
        return endpoint.appendingPathComponent("v1/chat/completions")
    }

    /// Returns a fixed-width redacted representation of the
    /// apiKey for diagnostic logging. Empty keys become
    /// `"(empty)"`, short keys become a single asterisk so the
    /// log line still conveys "a key was set" without giving
    /// away the value, and longer keys show only the last two
    /// characters. Same shape as
    /// `RemoteEchoAIPluginGenerator.redact(apiKey:)` so the
    /// diagnostic output is consistent between the placeholder
    /// and the real client.
    static func redact(apiKey: String) -> String {
        if apiKey.isEmpty { return "(empty)" }
        if apiKey.count <= 4 { return "***" }
        return "***\(apiKey.suffix(2))"
    }

    // MARK: - Retry

    /// Sends `urlRequest` and, on a 429 or 5xx response with
    /// `remaining > 0`, sleeps for the appropriate delay and
    /// retries. Maps the final response to an
    /// `AIGeneratorError` if no retry is possible (or if the
    /// status is non-retryable: 401 / 403 / other 4xx / non-HTTP
    /// / `URLError`).
    ///
    /// On a 2xx response the `(Data, URLResponse)` pair is
    /// returned verbatim and the caller decodes it.
    ///
    /// - Parameters:
    ///   - urlRequest: The fully-built request to send. Sent
    ///     verbatim on every attempt — no body rewriting, no
    ///     header stripping, so a server that signs the body
    ///     will validate the same payload each time.
    ///   - remaining: Number of retries left. The initial call
    ///     is made with `remaining == maxRetries`; each retry
    ///     decrements by one. A value of `0` means "no more
    ///     retries, surface the final error".
    private func performWithRetry(
        urlRequest: URLRequest,
        remaining: Int
    ) async throws -> (Data, URLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch {
            // URLError (and any other transport-level throw)
            // is **not** retried — these signal a problem on
            // the user's end (DNS, TLS, offline) that a fresh
            // call is unlikely to fix in the next few seconds.
            throw AIGeneratorError.transportError(
                reason: error.localizedDescription
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIGeneratorError.transportError(reason: "non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            return (data, response)

        case 429, 500...599:
            guard remaining > 0 else {
                // Out of retries — surface the same error a
                // non-retrying client would have.
                if http.statusCode == 429 {
                    throw AIGeneratorError.rateLimited
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                throw AIGeneratorError.transportError(
                    reason: "\(http.statusCode) \(body)"
                )
            }
            // `attempt` is the 0-based retry index. The first
            // retry sleeps for `2^0 == 1` second, the second
            // for `2^1 == 2` seconds, and the third for
            // `2^2 == 4` seconds, matching the exponential
            // backoff described on `maxRetries`.
            let attempt = maxRetries - remaining
            let delay = retryDelay(for: http, attempt: attempt)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await performWithRetry(
                urlRequest: urlRequest,
                remaining: remaining - 1
            )

        case 401, 403:
            throw AIGeneratorError.unauthorized

        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIGeneratorError.providerFailure(
                reason: "\(http.statusCode) \(body)"
            )
        }
    }

    /// Returns the delay (in seconds) to wait before the next
    /// retry attempt. Honours the `Retry-After` response header
    /// (parsed as delta-seconds first, then as RFC 7231
    /// HTTP-date) and caps the result at 60s so a hostile or
    /// misconfigured server can't block the UI indefinitely.
    /// Falls back to `pow(2.0, Double(attempt))` (1s, 2s, 4s,
    /// …) when no header is present.
    private func retryDelay(
        for response: HTTPURLResponse,
        attempt: Int
    ) -> TimeInterval {
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(raw) {
                return min(seconds, 60.0)
            }
            if let date = Self.httpDateFormatter.date(from: raw) {
                return min(max(date.timeIntervalSinceNow, 0), 60.0)
            }
        }
        return pow(2.0, Double(attempt))
    }

    /// RFC 7231 IMF-fixdate formatter used to parse
    /// `Retry-After` HTTP-date values. Lazily built and shared
    /// across calls; `DateFormatter` is expensive to
    /// construct and the spec format is fixed.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    // MARK: - Streaming

    /// Drives the SSE stream from the remote provider, with the
    /// same exponential-backoff retry policy as
    /// `performWithRetry`. On a 429 / 5xx the entire body is
    /// discarded (the provider's stream is half-formed) and a
    /// fresh request is issued. The `buffer`, `sawFinish`, and
    /// `assembled` parameters are inout so the parser's
    /// reassembly state survives across attempts.
    ///
    /// On a 2xx the chunks are fed through `parseStreamingChunk(...)`
    /// which calls `continuation.yield(.textDelta(...))` for
    /// each new text fragment and yields `.finished(assembled)`
    /// on the `[DONE]` sentinel. The method returns when the
    /// stream ends naturally or after the retry budget is
    /// exhausted.
    private func runStreamingAttempts(
        urlRequest: URLRequest,
        remaining: Int,
        buffer: inout String,
        sawFinish: inout Bool,
        assembled: inout String,
        continuation: AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error>.Continuation
    ) async throws {
        // The first attempt re-uses the same mutable parser
        // state; retries re-initialise the buffer so a
        // half-formed previous attempt cannot leak into the
        // fresh response.
        var attemptBuffer = ""
        var attemptAssembled = ""
        var attemptSawFinish = false
        var responseHeaders: HTTPURLResponse?
        var attemptStatusCode: Int = 0
        var attemptRetryAfter: String?
        do {
            for try await chunk in transport.streamData(for: urlRequest) {
                if Task.isCancelled { break }
                // First chunk carries the HTTP response.
                if let response = chunk.response {
                    guard let http = response as? HTTPURLResponse else {
                        throw AIGeneratorError.transportError(
                            reason: "non-HTTP response"
                        )
                    }
                    responseHeaders = http
                    attemptStatusCode = http.statusCode
                    attemptRetryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    if !(200...299).contains(http.statusCode) {
                        // Stop reading the body; the caller
                        // will decide whether to retry.
                        break
                    }
                    continue
                }
                guard let data = chunk.data, !data.isEmpty else { continue }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                Self.parseStreamingChunk(
                    incomingText: text,
                    buffer: &attemptBuffer,
                    sawFinish: &attemptSawFinish,
                    assembled: &attemptAssembled,
                    continuation: continuation
                )
                if attemptSawFinish {
                    break
                }
            }
        } catch let error as AIGeneratorError {
            throw error
        } catch {
            // Treat `URLError` and other transport-level
            // throws identically to the non-streaming path:
            // not retried, mapped to `.transportError`.
            throw AIGeneratorError.transportError(
                reason: error.localizedDescription
            )
        }

        // A successful attempt ends the method. A failed
        // attempt falls into the retry path.
        if (200...299).contains(attemptStatusCode) {
            buffer = attemptBuffer
            sawFinish = attemptSawFinish
            assembled = attemptAssembled
            return
        }
        guard remaining > 0 else {
            // Out of retries — surface the same error a
            // non-retrying client would have.
            if attemptStatusCode == 429 {
                throw AIGeneratorError.rateLimited
            }
            if attemptStatusCode == 401 || attemptStatusCode == 403 {
                throw AIGeneratorError.unauthorized
            }
            if (500...599).contains(attemptStatusCode) {
                throw AIGeneratorError.transportError(
                    reason: "\(attemptStatusCode)"
                )
            }
            throw AIGeneratorError.providerFailure(
                reason: "\(attemptStatusCode)"
            )
        }
        let attempt = maxRetries - remaining
        let delay: TimeInterval
        if let retryAfter = attemptRetryAfter,
           let seconds = TimeInterval(retryAfter)
        {
            delay = min(seconds, 60.0)
        } else if let retryAfter = attemptRetryAfter,
                  let date = Self.httpDateFormatter.date(from: retryAfter)
        {
            delay = min(max(date.timeIntervalSinceNow, 0), 60.0)
        } else {
            delay = pow(2.0, Double(attempt))
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        _ = responseHeaders
        return try await runStreamingAttempts(
            urlRequest: urlRequest,
            remaining: remaining - 1,
            buffer: &buffer,
            sawFinish: &sawFinish,
            assembled: &assembled,
            continuation: continuation
        )
    }

    /// Parses one (or more) SSE lines from `incomingText`,
    /// updates the buffer / assembled-text state, and yields
    /// `AIPluginGeneratorStreamEvent` values on `continuation`.
    ///
    /// The OpenAI-compatible SSE wire format is:
    ///
    ///     data: {"id":"chatcmpl-…","choices":[{"delta":{"content":"Hello"}}]}
    ///
    ///     data: {"id":"chatcmpl-…","choices":[{"delta":{"content":" world"}}]}
    ///
    ///     data: {"id":"chatcmpl-…","choices":[{"delta":{},"finish_reason":"stop"}]}
    ///
    ///     data: [DONE]
    ///
    /// Lines that are empty, that start with `:` (SSE
    /// comments — used by some providers as keep-alives), or
    /// that don't start with `data: ` are skipped. Malformed
    /// JSON inside a `data:` payload is also skipped (logged
    /// via `os_log` at `.error` level) so a single bad chunk
    /// cannot terminate the stream.
    static func parseStreamingChunk(
        incomingText: String,
        buffer: inout String,
        sawFinish: inout Bool,
        assembled: inout String,
        continuation: AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error>.Continuation
    ) {
        buffer.append(incomingText)
        // SSE events are separated by a blank line. A
        // single chunk can carry many events; a chunk can
        // also end mid-line, so we work on the buffer up to
        // the last newline and keep the tail for the next
        // call.
        let lines = buffer.components(separatedBy: "\n")
        // `components(separatedBy:)` always returns at least
        // one element. The last element is the partial line
        // (possibly empty) that has not yet been terminated
        // by a newline; keep it in the buffer.
        buffer = lines.last ?? ""
        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(":") { continue }
            guard trimmed.hasPrefix("data:") else { continue }
            // Strip the `data:` prefix. Tolerate one or
            // more spaces, per the SSE spec.
            var payload = trimmed
            payload.removeFirst("data:".count)
            if payload.first == " " { payload.removeFirst() }
            if payload == "[DONE]" {
                // Emit `.finished(_)` with whatever has
                // been assembled so far. Even on a stream
                // with no `choices[].finish_reason` the
                // `[DONE]` sentinel is the canonical end
                // marker.
                continuation.yield(.finished(assembled))
                sawFinish = true
                continue
            }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let envelope = try? JSONDecoder().decode(
                StreamChunkEnvelope.self, from: data
            ) else {
                os_log(
                    "RemoteAIPluginGenerator: skipping malformed SSE chunk: %{public}@",
                    log: Self.log,
                    type: .error,
                    String(data: data, encoding: .utf8) ?? "<undecodable>"
                )
                continue
            }
            for choice in envelope.choices {
                if let delta = choice.delta?.content {
                    assembled.append(delta)
                    continuation.yield(.textDelta(delta))
                }
                if choice.finishReason != nil {
                    sawFinish = true
                }
            }
        }
    }
}

/// Mirrors one Server-Sent Event's JSON body for the
/// OpenAI-compatible streaming `/v1/chat/completions`
/// endpoint. Only the `choices[].delta.content` and
/// `choices[].finish_reason` fields are read; everything
/// else (`id`, `model`, `usage`, …) is ignored so the
/// parser keeps working as the API grows new fields.
private struct StreamChunkEnvelope: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }
}

// `RemoteAIPluginGenerator.log` is `private static let` on the
// class itself (see line ~267), so the static `parseStreamingChunk`
// method declared inside the class body can reach it as
// `Self.log` without an extra accessor.

// MARK: - Request body

/// Mirrors the OpenAI `/v1/chat/completions` request body that
/// `RemoteAIPluginGenerator` POSTs. Encoded with
/// `JSONEncoder` defaults; property names are already
/// snake_case so the wire format matches the API spec verbatim.
private struct RemoteChatCompletionsRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let response_format: ResponseFormat
    /// `true` to ask the OpenAI-compatible provider to stream
    /// the response as SSE chunks (`data: {…}\n\n`) instead of
    /// a single JSON envelope. Always encoded so the wire
    /// format is stable across the streaming and non-streaming
    /// paths.
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    init(model: String, systemPrompt: String, userPrompt: String, stream: Bool = false, temperature: Double = 0.2) {
        self.model = model
        self.messages = [
            Message(role: "system", content: systemPrompt),
            Message(role: "user", content: userPrompt)
        ]
        self.temperature = temperature
        self.response_format = ResponseFormat(type: "json_object")
        self.stream = stream
    }
}

// MARK: - Response envelope

/// Mirrors the OpenAI `/v1/chat/completions` response envelope.
/// Only the `choices[0].message.content` field is read; everything
/// else (`id`, `model`, `usage`, …) is ignored so the
/// generator keeps working as the API grows new fields.
private struct RemoteChatCompletionsResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

// MARK: - Decoded content

/// The three-field JSON object the LLM is asked to produce.
/// `manifest` decodes directly into the internal `PluginManifest`
/// type — `PluginManifest` is `Codable` and lives in the same
/// module, so no shim is needed. `explanation` is appended to
/// the generator's own user-facing explanation by `generate`;
/// it is never used as a place to surface the apiKey.
private struct RemoteAIGeneratorPayload: Decodable {
    let manifest: PluginManifest
    let entryScript: String
    let explanation: String
}

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
///   * 401 / 403 → `.unauthorized`
///   * 429 → `.rateLimited`
///   * 5xx → `.transportError(reason: "<status> <body>")`
///   * other 4xx → `.providerFailure(reason: "<status> <body>")`
///   * `URLError` → `.transportError(reason: …)`
///   * decode failures → `.malformedResponse(reason: …)`
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

    /// Host portion of the endpoint the generator dials, exposed
    /// so the M5 history UI can render "Generated by `<model>` at
    /// `<host>`" alongside each entry without leaking the full
    /// URL or the apiKey. Overrides the `nil` default from
    /// `AIPluginGenerator`; returns `endpoint.host` verbatim
    /// (which may be `nil` for malformed endpoints, matching
    /// `URL.host`'s contract).
    public var endpointHost: String? { endpoint.host }

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
    public init(
        endpoint: URL,
        apiKey: String,
        model: String = "gpt-4o-mini",
        transport: RemoteTransport = URLSessionRemoteTransport()
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
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
        // remote payloads uniformly.
        let promptId = MockAIPluginGenerator.promptId(for: request, model: context.model)

        // Encode the request body. `JSONEncoder` defaults use the
        // property name verbatim, so `response_format` is emitted
        // as `response_format` and the `Message` struct is encoded
        // as `{"role": …, "content": …}`.
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(
                RemoteChatCompletionsRequest(
                    model: context.model,
                    systemPrompt: Self.systemPrompt,
                    userPrompt: request
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

        // Perform the call.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch {
            throw AIGeneratorError.transportError(reason: error.localizedDescription)
        }

        // Map the HTTP status to an AIGeneratorError. The body
        // is only included in the error message for 4xx / 5xx
        // (success bodies are parsed below and any error there
        // is reported with a different reason).
        guard let http = response as? HTTPURLResponse else {
            throw AIGeneratorError.transportError(reason: "non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw AIGeneratorError.unauthorized
        case 429:
            throw AIGeneratorError.rateLimited
        case 500...599:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIGeneratorError.transportError(
                reason: "\(http.statusCode) \(body)"
            )
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIGeneratorError.providerFailure(
                reason: "\(http.statusCode) \(body)"
            )
        }

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

        // Decode the content as the LLM's three-field payload.
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

        // Build a user-visible explanation that records the
        // endpoint host and the model, but never the apiKey. The
        // host is informational only; the model is the same value
        // already in `context.model`.
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

    // MARK: - Helpers

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
}

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

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    init(model: String, systemPrompt: String, userPrompt: String) {
        self.model = model
        self.messages = [
            Message(role: "system", content: systemPrompt),
            Message(role: "user", content: userPrompt)
        ]
        self.temperature = 0.2
        self.response_format = ResponseFormat(type: "json_object")
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

// AIGenerator.swift
// menubar01 — AI Plugin Generator (M1)
//
// Public value types and protocol for the AI-assisted plugin generator
// module. Mirrors the public API sketch in
// `AI_PLUGIN_ARCHITECTURE.md` §1.5 and §7. M1 is a skeleton: the data
// shapes, the protocol, and a deterministic mock implementation. The
// real LLM-backed `makeLocal` / `makeRemote` paths land in M2+.

import Foundation
import os

// MARK: - Context

/// Pre-filled parameters that flow into `AIPluginGenerator.generate(...)`.
///
/// Mirrors the public API sketch in
/// [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §7. The
/// context is intentionally small for v1 — M2 will grow it with things
/// like locale, units, and the user's currently selected plugin folder.
public struct AIGeneratorContext: Equatable {
    /// Identifier of the model the caller wants to target. For the
    /// remote path this is something like `"gpt-4o-mini"`; for local
    /// models it is the on-disk alias of the GGUF.
    public var model: String

    /// Optional pre-filled city for weather-style requests.
    public var city: String?

    /// Optional pre-filled refresh interval in seconds.
    public var refreshIntervalSeconds: Int?

    /// Language tag for the script's comments and any user-facing
    /// explanation text. Defaults to `"en"`.
    public var language: String

    public init(
        model: String,
        city: String? = nil,
        refreshIntervalSeconds: Int? = nil,
        language: String = "en"
    ) {
        self.model = model
        self.city = city
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.language = language
    }

    /// Default context used by callers that don't carry any pre-filled
    /// preferences. Model is pinned to the same default the architecture
    /// doc uses in §7.
    public static let empty = AIGeneratorContext(model: "gpt-4o-mini")
}

// MARK: - Result

/// A plugin returned by `AIPluginGenerator.generate(...)`.
///
/// Holds the two files the future M3 install flow will need to write
/// to disk: a populated `PluginManifest` and the body of the entry
/// script. `promptId` is a stable hash that the user can use to
/// reproduce, audit, or downgrade a generated plugin; `promptVersion`
/// is bumped when the generator's prompt template or generation logic
/// changes.
public struct GeneratedPlugin {
    /// Fully populated manifest. `manifest.entry` is the filename the
    /// entry script should be written as inside the plugin bundle.
    ///
    /// `manifest` is intentionally `internal` so the type does not
    /// leak `PluginManifest`'s access level — callers reach the
    /// manifest via the JSON returned by `encodedAsBundle()`.
    let manifest: PluginManifest

    /// Body of the entry script. No shebang or executable bit — those
    /// are added at install time by the M3 install flow.
    public var entryScript: String

    /// Human-readable rationale for the user, shown in the generator
    /// UI alongside the manifest and the script body.
    public var explanation: String

    /// Stable hash of `(request, context.model)` — see
    /// `MockAIPluginGenerator` for the exact construction.
    public var promptId: String

    /// Generator version string. The mock implementation always
    /// reports `"v1.0-mock"`; real providers will report a
    /// semver-style tag.
    public var promptVersion: String

    /// The init is `internal` because `PluginManifest` is internal —
    /// exposing a public initializer that takes an internal parameter
    /// is a hard error in Swift. The factory in this module
    /// (`MockAIPluginGenerator`) is the only intended constructor.
    init(
        manifest: PluginManifest,
        entryScript: String,
        explanation: String,
        promptId: String,
        promptVersion: String
    ) {
        self.manifest = manifest
        self.entryScript = entryScript
        self.explanation = explanation
        self.promptId = promptId
        self.promptVersion = promptVersion
    }

    /// Encodes this generated plugin as a `(manifest, entry)` bundle
    /// the future M3 install flow can drop into the Plugin Folder.
    ///
    /// - Returns: `manifestData` (pretty-printed JSON for human
    ///   readability), `entryFilename` (mirrors `manifest.entry`,
    ///   defaulting to `"plugin.sh"`), and `entryData` (UTF-8 bytes
    ///   of the script body).
    public func encodedAsBundle() -> (manifestData: Data, entryFilename: String, entryData: Data) {
        let entryFilename = (manifest.entry?.isEmpty == false ? manifest.entry : nil) ?? "plugin.sh"
        var manifestCopy = manifest
        if manifestCopy.entry == nil || manifestCopy.entry?.isEmpty == true {
            manifestCopy.entry = entryFilename
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifestCopy)
        } catch {
            // Fall back to an empty payload — the caller (M3 install
            // flow) is expected to surface a friendly error rather
            // than crash on a partial bundle.
            os_log("AIPluginGenerator: failed to encode manifest.json: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            manifestData = Data()
        }
        let entryData = Data(entryScript.utf8)
        return (manifestData, entryFilename, entryData)
    }

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")
}

extension GeneratedPlugin: Equatable {
    /// Manual `==` because `PluginManifest` is not `Equatable`.
    /// Compares the manifest by re-encoding both sides with
    /// `[.sortedKeys]` so the comparison is byte-stable.
    public static func == (lhs: GeneratedPlugin, rhs: GeneratedPlugin) -> Bool {
        guard
            lhs.entryScript == rhs.entryScript,
            lhs.explanation == rhs.explanation,
            lhs.promptId == rhs.promptId,
            lhs.promptVersion == rhs.promptVersion
        else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let l = try? encoder.encode(lhs.manifest),
            let r = try? encoder.encode(rhs.manifest)
        else { return false }
        return l == r
    }
}

// MARK: - Errors

/// Errors thrown by `AIPluginGenerator` implementations. The cases
/// mirror §1.5 of `AI_PLUGIN_ARCHITECTURE.md`.
public enum AIGeneratorError: Error, Equatable, LocalizedError {
    /// The model produced a manifest that declares capabilities it
    /// does not have. v1 has no capability-gate enforcement; this
    /// case is reserved for M3.
    case unsafeRequest
    /// The model produced no parseable menu output during a
    /// sandboxed dry-run. Reserved for M2+.
    case unrenderableMenu
    /// The provider's rate limit was hit. v1 stubs this — the mock
    /// generator never throws it.
    case rateLimited
    /// The provider returned an error that we should surface to the
    /// user verbatim.
    case providerFailure(reason: String)
    /// The remote provider returned a 401 / 403 — the user's API
    /// key is missing, wrong, or no longer valid. Surfaced as a
    /// distinct case so the Preferences → AI pane can prompt the
    /// user to re-enter the key without conflating the failure
    /// with a generic provider error.
    case unauthorized
    /// The HTTP layer could not complete the request (DNS, TLS,
    /// connection reset, timeout, …). The `reason` is the
    /// `URLError` / `Error.localizedDescription` string.
    case transportError(reason: String)
    /// The provider returned a 200 with a body the generator
    /// could not parse as the expected JSON shape. The `reason`
    /// is the underlying `DecodingError` description.
    case malformedResponse(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsafeRequest:
            return "The generator produced a plugin that requests capabilities it cannot prove it needs."
        case .unrenderableMenu:
            return "The generator produced a script that could not be rendered into a menu tree."
        case .rateLimited:
            return "The provider rate-limited the request. Please wait a moment and try again."
        case .providerFailure(let reason):
            return "Provider error: \(reason)"
        case .unauthorized:
            return "The remote provider rejected the API key. Open Preferences → AI and verify the key is still valid."
        case .transportError(let reason):
            return "Could not reach the remote provider: \(reason)"
        case .malformedResponse(let reason):
            return "The remote provider returned an unparseable response: \(reason)"
        }
    }
}

// MARK: - Protocol

/// The contract every AI plugin generator must satisfy.
///
/// Implementations are expected to be deterministic for a given
/// `(request, context.model)` pair — `MockAIPluginGenerator` achieves
/// this by SHA256-hashing the inputs into `GeneratedPlugin.promptId`.
public protocol AIPluginGenerator {
    /// Host portion of the endpoint that produced `plugin`, or
    /// `nil` for providers that do not dial out (Mock / Local /
    /// Echo). The M5 history UI uses this to render
    /// "Generated by `<model>` at `<host>`" alongside each entry
    /// without leaking the full URL or the apiKey. The default
    /// implementation returns `nil`; `RemoteAIPluginGenerator`
    /// is the only v1 provider that overrides it.
    var endpointHost: String? { get }

    /// Build a plugin from a natural-language request.
    ///
    /// - Parameters:
    ///   - request: Free-form text such as
    ///     `"show today's weather in the menu bar"`.
    ///   - context: Pre-filled parameters from the generator UI.
    ///     Implementations must read at least `context.model` to
    ///     derive a stable `promptId`.
    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin
}

public extension AIPluginGenerator {
    /// Default `endpointHost` for providers that do not dial a
    /// remote endpoint (Mock, Local, Echo, …). `RemoteAIPluginGenerator`
    /// is the only v1 provider that overrides it.
    var endpointHost: String? { nil }

    /// Convenience overload that fills `context` with `.empty`.
    /// Mirrors the default-parameter sketch in
    /// `AI_PLUGIN_ARCHITECTURE.md` §7.
    func generate(request: String) async throws -> GeneratedPlugin {
        try await generate(request: request, context: .empty)
    }
}

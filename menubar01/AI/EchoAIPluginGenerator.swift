// EchoAIPluginGenerator.swift
// menubar01 — AI Plugin Generator (M2+ factory wiring)
//
// Placeholder `AIPluginGenerator` implementations for the local
// (`LocalEchoAIPluginGenerator`) and remote (`RemoteEchoAIPluginGenerator`)
// providers introduced by the M2+ factory. They behave like a
// real-provider call (record the inputs, return a deterministic
// `GeneratedPlugin` with the inputs embedded in the
// `explanation` string) without actually shelling out to an LLM.
//
// Why placeholders? The v1 contract is "the factory must hand the
// view model a working `AIPluginGenerator` for every provider the
// user can pick". Shipping the wiring before the real on-device
// inference and the URLSession-backed HTTP client lets the
// Preferences → AI pane ship in M2+ without being blocked on
// those two larger pieces. Both placeholders respect the same
// `AIPluginGenerator` contract as `MockAIPluginGenerator`:
//
//   - `promptId` is `SHA256(request + "|" + context.model)`, the
//     same algorithm `MockAIPluginGenerator` uses, so the test
//     suite that asserts on `(request, model) → promptId` continues
//     to hold for any generator the factory produces.
//   - The `GeneratedPlugin` is a valid "Echo" plugin (so the M2
//     sheet's preview renders the same way regardless of
//     provider), with the configured modelPath / endpoint recorded
//     in `explanation` for the user's audit trail.
//
// Future-proofing: when the real `LocalAIPluginGenerator` (real
// on-device GGUF inference) and `RemoteAIPluginGenerator`
// (URLSession-backed HTTP client) land, they replace these two
// classes file-for-file — the factory and the view model do not
// change.

import CryptoKit
import Foundation
import os

// MARK: - LocalEchoAIPluginGenerator

/// Placeholder for the on-device local-model provider.
///
/// Behaves like a real local-model call would: the user's chosen
/// `modelPath` is recorded (logged via `os_log` and embedded in
/// the returned `GeneratedPlugin.explanation` so the user can see
/// which model the result came from), and the generated
/// `promptId` is the same `SHA256(request + "|" + context.model)`
/// the mock generator uses. No file is read from disk and no
/// inference is performed — the placeholder returns the canonical
/// "Echo" plugin from `MockAIPluginGenerator.makeMockPlugin` so
/// the M2 sheet's preview is identical regardless of provider.
public final class LocalEchoAIPluginGenerator: AIPluginGenerator {
    /// Version string reported in `GeneratedPlugin.promptVersion`.
    /// Distinguishes the placeholder's payload from
    /// `MockAIPluginGenerator`'s `"v1.0-mock"` and from the future
    /// real local-inference provider's semver tag.
    public static let localEchoPromptVersion = "v1.0-echo-local"

    /// Stable label the M5 history-UI filter picker groups
    /// local-model placeholder entries under. Mirrors
    /// `LocalAIPluginGenerator.providerDisplayName` so the
    /// picker treats both implementations the same way.
    public static let providerDisplayName = "Local"

    /// The on-disk model path the user picked in the Preferences →
    /// AI pane. Stored verbatim so a follow-up real local-inference
    /// provider can adopt the same `init` and start loading from
    /// the same path with no factory change.
    public let modelPath: URL

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    public init(modelPath: URL) {
        self.modelPath = modelPath
        os_log(
            "AIPluginGenerator: LocalEcho picked modelPath=%{public}@",
            log: Self.log, type: .info, modelPath.path
        )
    }

    /// `providerName` for the local-echo placeholder. Mirrors
    /// the static `providerDisplayName` so the M5 history
    /// filter picker groups these entries under the same
    /// "Local" bucket as real `LocalAIPluginGenerator` runs.
    public var providerName: String? { Self.providerDisplayName }

    public func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        // Deterministic promptId, matching the Mock contract so the
        // existing test suite (and any future history-persistence
        // code keyed on promptId) treats Echo payloads uniformly.
        let promptId = MockAIPluginGenerator.promptId(for: request, model: context.model)
        var plugin = MockAIPluginGenerator.makeMockPlugin(promptId: promptId, context: context)
        // Re-stamp the version so the user can tell the provider
        // apart in the M2 sheet's promptId/promptVersion row.
        plugin = GeneratedPlugin(
            manifest: plugin.manifest,
            entryScript: plugin.entryScript,
            explanation: """
            \(plugin.explanation)

            Local model placeholder — would call into \(modelPath.path) on a real
            on-device inference runtime. The modelPath above is recorded
            verbatim so the M3+ history view can show the user which
            local model produced this result.
            """,
            promptId: plugin.promptId,
            promptVersion: Self.localEchoPromptVersion
        )
        return plugin
    }
}

// MARK: - RemoteEchoAIPluginGenerator

/// Placeholder for the remote (HTTP) provider.
///
/// Like `LocalEchoAIPluginGenerator`, this is a real-type name
/// that ships in v1 with no actual HTTP call. The user's
/// `endpoint` is recorded in `explanation` so the user can see
/// which remote server the result came from, and `apiKey` is
/// recorded via `os_log` only (with the value redacted) — the
/// `apiKey` deliberately does **not** leak into the
/// `GeneratedPlugin.explanation` so a future system-report dump
/// or M5 history view can never surface the key in plain text.
public final class RemoteEchoAIPluginGenerator: AIPluginGenerator {
    /// Version string reported in `GeneratedPlugin.promptVersion`.
    public static let remoteEchoPromptVersion = "v1.0-echo-remote"

    /// Stable label the M5 history-UI filter picker groups
    /// remote-placeholder entries under. Mirrors the real
    /// `RemoteAIPluginGenerator`'s label so the picker
    /// treats both implementations the same way.
    public static let providerDisplayName = "Remote"

    /// The remote endpoint URL the user picked in the Preferences →
    /// AI pane. Stored verbatim so the future real HTTP client can
    /// adopt the same `init` and start sending requests to the
    /// same URL with no factory change.
    public let endpoint: URL

    /// The user's API key. Stored in-memory only; never serialised
    /// to the `GeneratedPlugin.explanation`, never logged in plain
    /// text, and never returned through any public accessor. The
    /// redacted log line is the only place this value is mentioned.
    public let apiKey: String

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    public init(endpoint: URL, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        // Log the endpoint host (not the full URL — paths and
        // queries may carry the apiKey as a query param on some
        // providers) and a redacted key so the diagnostic dump
        // shows what the factory did without ever exposing the
        // secret.
        let host = endpoint.host ?? "<no-host>"
        let redactedKey = Self.redact(apiKey: apiKey)
        os_log(
            "AIPluginGenerator: RemoteEcho picked endpoint host=%{public}@ (apiKey=%{public}@)",
            log: Self.log, type: .info, host, redactedKey
        )
    }

    /// `providerName` for the remote-echo placeholder. Mirrors
    /// the static `providerDisplayName` so the M5 history
    /// filter picker groups these entries under the same
    /// "Remote" bucket as real `RemoteAIPluginGenerator` runs.
    public var providerName: String? { Self.providerDisplayName }

    public func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        // Same SHA256-based promptId as Mock + LocalEcho so the
        // test suite and any future history-persistence code keyed
        // on promptId treats Echo payloads uniformly.
        let promptId = MockAIPluginGenerator.promptId(for: request, model: context.model)
        let base = MockAIPluginGenerator.makeMockPlugin(promptId: promptId, context: context)
        // Build an explanation that records the endpoint but never
        // the apiKey. The apiKey is intentionally absent from the
        // user-visible surface; the diagnostic `os_log` line in
        // `init` is the only place the redacted key is mentioned.
        let explanation = """
        \(base.explanation)

        Remote endpoint placeholder — would POST to \(endpoint.absoluteString) on a
        real URLSession-backed HTTP client. The apiKey is held in memory
        only and is never embedded in the user-visible result.
        """
        return GeneratedPlugin(
            manifest: base.manifest,
            entryScript: base.entryScript,
            explanation: explanation,
            promptId: base.promptId,
            promptVersion: Self.remoteEchoPromptVersion
        )
    }

    // MARK: - Helpers

    /// Returns a fixed-width redacted representation of the apiKey
    /// for diagnostic logging. Empty keys become `"(empty)"`,
    /// short keys become a single asterisk so the log line still
    /// conveys "a key was set" without giving away the value.
    private static func redact(apiKey: String) -> String {
        if apiKey.isEmpty { return "(empty)" }
        if apiKey.count <= 4 { return "***" }
        return "***\(apiKey.suffix(2))"
    }
}

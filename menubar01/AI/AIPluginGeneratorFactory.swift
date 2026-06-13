// AIPluginGeneratorFactory.swift
// menubar01 — AI Plugin Generator (M2+ factory wiring)
//
// Integration surface the Plugin Repository window calls in M2.
// M1 (commit ef7702c) shipped the public API surface with three
// factory methods that all returned `MockAIPluginGenerator`:
// the real provider code was deliberately stubbed to keep the
// M2 sheet's call site stable.
//
// M2+ lifts the stub without breaking the M2 view-model contract:
// `makeDefault()` is now config-driven — it consults a
// `PreferencesStore` key and returns the right `AIPluginGenerator`
// for the user-selected provider — and `makeLocal(...)` /
// `makeRemote(...)` are non-throwing, both returning either a
// real `LocalEchoAIPluginGenerator` / `RemoteEchoAIPluginGenerator`
// (placeholder types that record the inputs and return a
// deterministic `GeneratedPlugin`) or a `MockAIPluginGenerator`
// when the user has not yet configured the inputs. The real
// on-device inference and the URLSession-backed HTTP client
// land as file-for-file replacements of the two placeholders.

import Foundation
import os

// MARK: - Provider selection

/// Which `AIPluginGenerator` the factory should hand the view model.
///
/// The raw values double as the persisted-pref-key values the
/// factory reads from `PreferencesStore`. The mapping is
/// intentional: a user who hand-edits
/// `defaults write com.lingyi.menubar01 AIPluginGenerator.provider -string local`
/// gets the same behaviour as a future Preferences → AI pane
/// toggling a picker to "local".
///
/// The enum is `String, Codable, Equatable, Sendable, CaseIterable`
/// so the upcoming Preferences pane can iterate `allCases` to
/// render a picker and so a future M5 history entry can record
/// which provider produced a result.
public enum AIPluginGeneratorProvider: String, Codable, Equatable, Sendable, CaseIterable {
    /// The deterministic, network-free mock from M1. Default
    /// when the prefs key is missing or unparseable.
    case mock
    /// On-device local model. The M2+ placeholder is
    /// `LocalEchoAIPluginGenerator`; a real
    /// `LocalAIPluginGenerator` (GGUF / llama.cpp) lands in a
    /// follow-up.
    case local
    /// Remote (HTTP) provider. The M2+ placeholder is
    /// `RemoteEchoAIPluginGenerator`; a real
    /// `RemoteAIPluginGenerator` (URLSession-backed) lands in a
    /// follow-up.
    case remote
}

// MARK: - Factory

/// Builds `AIPluginGenerator` instances for the rest of the app.
///
/// The three entry points in the public API sketch in
/// [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.5
/// and §7 are:
/// - `makeDefault(prefs:)` — the production M2 sheet's call site.
///   Reads `AIPluginGenerator.provider` from the supplied
///   `PreferencesStore` (or the shared singleton) and dispatches
///   to the matching branch.
/// - `makeLocal(modelPath:prefs:)` — the on-device provider.
///   Returns a `LocalEchoAIPluginGenerator` when `modelPath` is
///   non-nil; falls back to the mock (with an `os_log` warning)
///   when the caller has not yet configured a path.
/// - `makeRemote(endpoint:apiKey:prefs:)` — the remote provider.
///   Returns a `RemoteEchoAIPluginGenerator` when both arguments
///   are non-nil; falls back to the mock (with an `os_log`
///   warning) when either is missing.
///
/// All three are non-throwing. The factory logs a warning rather
/// than throwing when the prefs key is missing or malformed, so
/// the M2 sheet's "click Generate" path never crashes from a
/// misconfigured provider.
public enum AIPluginGeneratorFactory {

    // MARK: Prefs keys

    /// Prefs key for the active provider (`mock` / `local` / `remote`).
    public static let providerKey = "AIPluginGenerator.provider"
    /// Prefs key for the on-device model path used by the
    /// `local` provider. String form (a filesystem path) so the
    /// `UserDefaults` value is human-readable in `defaults read`.
    public static let localModelPathKey = "AIPluginGenerator.localModelPath"
    /// Prefs key for the remote endpoint URL used by the
    /// `remote` provider. String form.
    public static let remoteEndpointKey = "AIPluginGenerator.remoteEndpoint"
    /// Prefs key for the remote API key used by the `remote`
    /// provider. The factory reads this value but **never**
    /// returns it from a public accessor, and the diagnostic log
    /// line always shows a redacted form.
    public static let remoteAPIKeyKey = "AIPluginGenerator.remoteAPIKey"

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    // MARK: makeDefault

    /// The default generator. Resolves the active provider from
    /// `prefs[providerKey]` (defaulting to `.mock`) and dispatches
    /// to the matching `makeLocal(...)` / `makeRemote(...)` /
    /// `MockAIPluginGenerator()` branch.
    ///
    /// The production M2 sheet call site is unaffected by the
    /// new config-driven behaviour: it still calls
    /// `AIPluginGeneratorFactory.makeDefault()` and gets back a
    /// generator. The user's choice of provider is read at call
    /// time, not at module-load time, so toggling the prefs key
    /// (or the future Preferences → AI pane picker) flips the
    /// next "click Generate" to use the new provider.
    public static func makeDefault(
        prefs: PreferencesStore? = nil
    ) -> AIPluginGenerator {
        let resolvedPrefs = prefs ?? .shared
        let provider = readProvider(from: resolvedPrefs)
        switch provider {
        case .mock:
            os_log(
                "AIPluginGenerator: makeDefault → MockAIPluginGenerator (provider=%{public}@)",
                log: log, type: .info, provider.rawValue
            )
            return MockAIPluginGenerator()
        case .local:
            return makeLocal(
                modelPath: readLocalModelPath(from: resolvedPrefs),
                prefs: resolvedPrefs
            )
        case .remote:
            return makeRemote(
                endpoint: readRemoteEndpoint(from: resolvedPrefs),
                apiKey: readRemoteAPIKey(from: resolvedPrefs),
                prefs: resolvedPrefs
            )
        }
    }

    // MARK: makeLocal

    /// Build a generator backed by an on-device model at `modelPath`.
    ///
    /// When `modelPath` is non-nil, returns a
    /// `LocalEchoAIPluginGenerator` (the M2+ placeholder that
    /// records the path and returns a deterministic
    /// `GeneratedPlugin`). When `modelPath` is nil, logs a
    /// warning and falls back to `MockAIPluginGenerator()` so the
    /// view model's "click Generate" path still produces a
    /// usable result.
    public static func makeLocal(
        modelPath: URL?,
        prefs: PreferencesStore? = nil
    ) -> AIPluginGenerator {
        if let modelPath {
            os_log(
                "AIPluginGenerator: makeLocal → LocalEchoAIPluginGenerator(modelPath=%{public}@)",
                log: log, type: .info, modelPath.path
            )
            return LocalEchoAIPluginGenerator(modelPath: modelPath)
        }
        os_log(
            "AIPluginGenerator: makeLocal falling back to MockAIPluginGenerator — no modelPath configured",
            log: log, type: .default
        )
        return MockAIPluginGenerator()
    }

    // MARK: makeRemote

    /// Build a generator that calls a remote model provider.
    ///
    /// When both `endpoint` and `apiKey` are non-nil, returns a
    /// `RemoteEchoAIPluginGenerator` (the M2+ placeholder that
    /// records the inputs and returns a deterministic
    /// `GeneratedPlugin`). When either argument is nil, logs a
    /// warning and falls back to `MockAIPluginGenerator()` so the
    /// view model's "click Generate" path still produces a
    /// usable result.
    static func makeRemote(
        endpoint: URL?,
        apiKey: String?,
        prefs: PreferencesStore? = nil
    ) -> AIPluginGenerator {
        if let endpoint, let apiKey {
            os_log(
                "AIPluginGenerator: makeRemote → RemoteEchoAIPluginGenerator(endpoint host=%{public}@)",
                log: log, type: .info, endpoint.host ?? "<no-host>"
            )
            return RemoteEchoAIPluginGenerator(endpoint: endpoint, apiKey: apiKey)
        }
        os_log(
            "AIPluginGenerator: makeRemote falling back to MockAIPluginGenerator — endpoint=%{public}@ apiKeySet=%{public}@",
            log: log, type: .default,
            endpoint != nil ? "yes" : "no",
            (apiKey?.isEmpty == false) ? "yes" : "no"
        )
        return MockAIPluginGenerator()
    }

    // MARK: - Prefs read helpers

    /// Reads the provider key from `prefs` and parses it. Any
    /// parse failure (missing key, wrong type, unknown raw value)
    /// collapses to `.mock` with a warning log so a malformed
    /// hand-edit never crashes the factory.
    private static func readProvider(from prefs: PreferencesStore) -> AIPluginGeneratorProvider {
        guard let raw = prefs.defaults.string(forKey: providerKey) else {
            return .mock
        }
        guard let provider = AIPluginGeneratorProvider(rawValue: raw) else {
            os_log(
                "AIPluginGenerator: unknown provider value=%{public}@ — falling back to .mock",
                log: log, type: .default, raw
            )
            return .mock
        }
        return provider
    }

    /// Reads the local-model path key and converts it to a URL.
    /// Returns `nil` (and lets `makeLocal` warn) when the key is
    /// missing, the wrong type, or empty.
    private static func readLocalModelPath(from prefs: PreferencesStore) -> URL? {
        guard let path = prefs.defaults.string(forKey: localModelPathKey),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Reads the remote endpoint key and parses it. Returns `nil`
    /// (and lets `makeRemote` warn) when the key is missing, the
    /// wrong type, or not a valid URL.
    private static func readRemoteEndpoint(from prefs: PreferencesStore) -> URL? {
        guard let raw = prefs.defaults.string(forKey: remoteEndpointKey),
              !raw.isEmpty,
              let url = URL(string: raw)
        else { return nil }
        return url
    }

    /// Reads the remote API key. Returns `nil` (and lets
    /// `makeRemote` warn) when the key is missing or empty. The
    /// value is never logged in plain text.
    private static func readRemoteAPIKey(from prefs: PreferencesStore) -> String? {
        guard let key = prefs.defaults.string(forKey: remoteAPIKeyKey),
              !key.isEmpty
        else { return nil }
        return key
    }
}

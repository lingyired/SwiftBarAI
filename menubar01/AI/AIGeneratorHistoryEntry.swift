// AIGeneratorHistoryEntry.swift
// menubar01 — AI Plugin Generator (M5)
//
// Persisted record of a single `AIPluginGenerator` run. The on-disk
// layout is one subdirectory per run, keyed by the stable `promptId`:
// a `request.txt`, a self-describing `response.json`, and an optional
// `menu.json`. This file defines the in-memory value type the store
// shuttles between the generator UI and the file system.

import Foundation
import os

/// A single recorded run of `AIPluginGenerator`.
///
/// `id` is the stable `promptId` so SwiftUI lists can `ForEach` over
/// the entries without an extra `KeyPath`. The on-disk directory name
/// is also `promptId` — see
/// `FileSystemAIGeneratorHistoryStore` for the layout.
///
/// `plugin` is a `GeneratedPlugin` (M1). The `manifest` field of
/// `GeneratedPlugin` is `internal` (because `PluginManifest` is), so
/// `Codable` and `Equatable` are implemented by hand to keep them
/// inside the `menubar01` module — external callers never need to see
/// the flattened form.
public struct AIGeneratorHistoryEntry: Codable, Identifiable, Equatable {
    /// Stable identifier (= `promptId`). Used as the on-disk directory
    /// name and as the SwiftUI list key.
    public var id: String { promptId }

    /// `SHA256(request + "|" + model)` per
    /// `MockAIPluginGenerator.promptId(for:model:)` — a single entry
    /// directory per hash keeps re-runs idempotent and lets the user
    /// spot duplicates from the file system.
    public let promptId: String

    /// Wall-clock time the run was recorded. Used to sort `listAll()`
    /// newest-first.
    public let createdAt: Date

    /// The user's natural-language request, verbatim. Also written
    /// verbatim to `<promptId>/request.txt` so the user can `cat` it
    /// without decoding the JSON.
    public let request: String

    /// Model identifier that produced `plugin`. Mirrors
    /// `AIGeneratorContext.model`.
    public let model: String

    /// The generated plugin payload (manifest + entry script +
    /// explanation + `promptVersion`).
    public let plugin: GeneratedPlugin

    /// Serialised menu tree, if the generator had access to a
    /// sandboxed dry-run. `nil` in v1 because the sandboxed executor
    /// is out of scope for M5 — the field exists so the v1 store can
    /// round-trip the data without a schema break when M5+ starts
    /// filling it in.
    public let menuTreeJSON: Data?

    public init(
        promptId: String,
        createdAt: Date,
        request: String,
        model: String,
        plugin: GeneratedPlugin,
        menuTreeJSON: Data? = nil
    ) {
        self.promptId = promptId
        self.createdAt = createdAt
        self.request = request
        self.model = model
        self.plugin = plugin
        self.menuTreeJSON = menuTreeJSON
    }

    // MARK: - Codable

    /// Custom `Codable` because `GeneratedPlugin` is not `Codable` and
    /// the on-disk shape flattens the plugin's `manifest` field
    /// alongside its script/explanation/version so the response is
    /// self-describing — see `AI_PLUGIN_ARCHITECTURE.md` §4.
    private enum CodingKeys: String, CodingKey {
        case promptId
        case createdAt
        case request
        case model
        case pluginManifest
        case pluginEntryScript
        case pluginExplanation
        case pluginPromptVersion
        case menuTreeJSON
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let promptId = try c.decode(String.self, forKey: .promptId)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        let request = try c.decode(String.self, forKey: .request)
        let model = try c.decode(String.self, forKey: .model)
        let manifest = try c.decode(PluginManifest.self, forKey: .pluginManifest)
        let entryScript = try c.decode(String.self, forKey: .pluginEntryScript)
        let explanation = try c.decode(String.self, forKey: .pluginExplanation)
        let promptVersion = try c.decode(String.self, forKey: .pluginPromptVersion)
        let menuTreeJSON = try c.decodeIfPresent(Data.self, forKey: .menuTreeJSON)

        self.promptId = promptId
        self.createdAt = createdAt
        self.request = request
        self.model = model
        self.plugin = GeneratedPlugin(
            manifest: manifest,
            entryScript: entryScript,
            explanation: explanation,
            promptId: promptId,
            promptVersion: promptVersion
        )
        self.menuTreeJSON = menuTreeJSON
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptId, forKey: .promptId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(request, forKey: .request)
        try c.encode(model, forKey: .model)
        try c.encode(plugin.manifest, forKey: .pluginManifest)
        try c.encode(plugin.entryScript, forKey: .pluginEntryScript)
        try c.encode(plugin.explanation, forKey: .pluginExplanation)
        try c.encode(plugin.promptVersion, forKey: .pluginPromptVersion)
        try c.encodeIfPresent(menuTreeJSON, forKey: .menuTreeJSON)
    }

    // MARK: - Equatable

    /// Hand-rolled equality: `GeneratedPlugin` is not `Equatable` and
    /// `PluginManifest` is not `Equatable`, so we compare the
    /// flattened fields directly and round-trip the manifest through
    /// `JSONEncoder` to compare its bytes (sorted keys keeps the
    /// comparison stable across runs).
    public static func == (lhs: AIGeneratorHistoryEntry, rhs: AIGeneratorHistoryEntry) -> Bool {
        guard lhs.promptId == rhs.promptId,
              lhs.createdAt == rhs.createdAt,
              lhs.request == rhs.request,
              lhs.model == rhs.model,
              lhs.menuTreeJSON == rhs.menuTreeJSON else {
            return false
        }
        guard lhs.plugin.entryScript == rhs.plugin.entryScript,
              lhs.plugin.explanation == rhs.plugin.explanation,
              lhs.plugin.promptVersion == rhs.plugin.promptVersion else {
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let lhsManifest = try? encoder.encode(lhs.plugin.manifest),
              let rhsManifest = try? encoder.encode(rhs.plugin.manifest) else {
            return false
        }
        return lhsManifest == rhsManifest
    }
}

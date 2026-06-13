// AIGeneratorViewModel.swift
// menubar01 — AI Plugin Generator (M2)
//
// View model backing `AIGeneratorSheet`. Owns the user's request text,
// the current loading state, the latest `GeneratedPlugin`, and any
// error from the generator. Drives the SwiftUI sheet through
// `@Published` properties and is `@MainActor` so all mutations land
// on the main thread without an extra hop. The actual
// `AIPluginGenerator.generate(request:context:)` call is injected as
// a protocol property so the test suite can swap in a
// `MockAIPluginGenerator` without touching the factory.

import Foundation
import os
import SwiftUI

/// State of the generator sheet. Mirrors the §2 end-to-end flow in
/// `AI_PLUGIN_ARCHITECTURE.md` — the user types a request, sees a
/// spinner, then sees a `GeneratedPlugin` (or an error). v1 does not
/// auto-retry or iterate; "Re-generate" is an explicit button press
/// that re-runs the protocol with the latest request text.
enum AIGeneratorState: Equatable {
    case idle
    case loading
    case success(GeneratedPlugin)
    case failure(String)
}

/// View model for the AI plugin generator sheet.
///
/// `AIGeneratorViewModel` is `@MainActor` because every `@Published`
/// property drives a SwiftUI view; mutating them off the main thread
/// would require an explicit `DispatchQueue.main.async` hop in the
/// protocol completion path. M1's `AIPluginGenerator.generate` is
/// already `async`/`await`; we run the call inside a `Task` and
/// assign the result back on the main actor.
@MainActor
final class AIGeneratorViewModel: ObservableObject {

    // MARK: - Published State

    /// The natural-language request the user typed. Bound to the
    /// text editor in the sheet.
    @Published var request: String = ""

    /// Current state of the generator. When `.success(...)` we also
    /// populate `latestPlugin` for convenience so views that want to
    /// bind to the value (rather than pattern-match on the state)
    /// don't have to repeat themselves.
    @Published internal(set) var state: AIGeneratorState = .idle

    /// Convenience accessor: the most recent successful
    /// `GeneratedPlugin`, or `nil` if the user has not yet generated
    /// one (or the last attempt failed).
    @Published private(set) var latestPlugin: GeneratedPlugin?

    /// Pre-filled context for the generator. Editable from the
    /// sheet's "Advanced" disclosure. Defaults to the protocol's
    /// `.empty` so the visible "language" is always "en".
    @Published var context: AIGeneratorContext = .empty

    /// Set to `true` after a successful install initiated by the
    /// `AIGeneratorInstallPromptSheet` completion handler. The sheet
    /// reads this to show the "Installed!" success banner. Reset to
    /// `false` when a re-generate lands (see `generate()`) or when an
    /// install fails (see `didFailInstall(reason:)`).
    @Published var didRequestSave: Bool = false

    /// URL of the directory the most recent successful install wrote
    /// the plugin into. Set by `didCompleteInstall(at:)`; cleared by
    /// `didFailInstall(reason:)` and `reset()`. Read by
    /// `AIGeneratorSheet` to render the success banner.
    @Published var installedPluginURL: URL?

    // MARK: - Dependencies

    /// The generator used by `generate()`. Default factory comes
    /// from `AIPluginGeneratorFactory.makeDefault()`. Tests
    /// overwrite this with a `MockAIPluginGenerator` to control
    /// behaviour without going through the protocol's real
    /// implementation.
    let generator: AIPluginGenerator

    /// M3 capability gate used by the install-prompt sheet to read
    /// / grant the per-plugin capability set. Default points at
    /// `PluginManager.shared.pluginCapabilityGate` so the
    /// production sheet uses the same store the loader reads from
    /// on next refresh. Tests inject a fresh instance backed by an
    /// isolated `UserDefaults(suiteName:)` via the
    /// `internal(set)` setter.
    var pluginCapabilityGate: PluginCapabilityGate = PluginManager.shared.pluginCapabilityGate

    /// M5 history store. Persists every successful `generate()`
    /// result so the user can audit, re-generate, or downgrade a
    /// generated plugin later. The default factory points at the
    /// file-system store rooted at
    /// `~/Library/Application Support/menubar01/AIGenerator/` so
    /// the production call site stays a one-liner; tests inject a
    /// fresh `FileSystemAIGeneratorHistoryStore` rooted at a temp
    /// dir to keep assertions hermetic.
    let historyStore: AIGeneratorHistoryStore

    /// M2 logs through this category. Mirrors `GeneratedPlugin.log`
    /// in `AIGenerator.swift` so the two flows' log messages show up
    /// under the same subsystem / split out by category.
    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    // MARK: - Init

    /// Default initializer. Pulls a generator from
    /// `AIPluginGeneratorFactory.makeDefault()` and a history store
    /// from `AIGeneratorHistoryStoreFactory.makeDefault()` so the
    /// production sheet call site can stay one-liner.
    init(
        generator: AIPluginGenerator = AIPluginGeneratorFactory.makeDefault(),
        historyStore: AIGeneratorHistoryStore = AIGeneratorHistoryStoreFactory.makeDefault()
    ) {
        self.generator = generator
        self.historyStore = historyStore
    }

    // MARK: - Derived State

    /// `true` when the sheet is in the middle of a generator call.
    /// Exposed as a computed property so the SwiftUI button can
    /// disable itself without pattern-matching the enum.
    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// `true` when the user has typed a non-empty request. The
    /// "Generate" button is disabled otherwise so we never burn a
    /// generator round-trip on an empty prompt.
    var canGenerate: Bool {
        !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    /// Pretty-printed JSON body of the most recent
    /// `GeneratedPlugin.manifest`. `nil` until the first
    /// successful generation. Computed on demand so we always
    /// reflect the latest `latestPlugin` and never cache a stale
    /// serialization.
    var manifestJSON: String? {
        guard let plugin = latestPlugin else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(EncodedManifest(manifest: plugin.manifest)),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    // MARK: - Actions

    /// Run the generator with the current `request` and `context`.
    ///
    /// Marks the state `.loading`, then awaits the protocol
    /// `generate(request:context:)` call. On success transitions
    /// to `.success(plugin)` and stores the value in
    /// `latestPlugin`. On failure transitions to `.failure(reason)`
    /// using the error's `localizedDescription`. The
    /// `didRequestSave` flag is reset so a re-generation lets the
    /// user save again.
    func generate() async {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .loading
        didRequestSave = false
        installedPluginURL = nil
        do {
            let plugin = try await generator.generate(request: trimmed, context: context)
            latestPlugin = plugin
            state = .success(plugin)
            // Build a synthetic menu tree from the entry script.
            // v1 is intentionally lightweight: a real sandboxed
            // dry-run would replace `parseEntryScript(_:)` with a
            // stdout-capture-and-rebuild step. The result feeds
            // straight into `AIGeneratorHistoryEntry.menuTreeJSON`
            // so the M5 history sheet can decode and render it.
            let menuTreeJSON = AIGeneratorViewModel.encodeMenuTree(
                from: plugin.entryScript
            )
            // Persist the result so the user can audit, re-generate, or
            // downgrade a generated plugin later (AI_PLUGIN_ARCHITECTURE.md §4).
            do {
                try historyStore.record(AIGeneratorHistoryEntry(
                    promptId: plugin.promptId,
                    createdAt: Date(),
                    request: trimmed,
                    model: context.model,
                    plugin: plugin,
                    menuTreeJSON: menuTreeJSON
                ))
            } catch {
                os_log("AIGenerator: failed to record history entry: %{public}@",
                       log: Self.log, type: .error, error.localizedDescription)
                // Non-fatal: the user still sees the generated plugin.
            }
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    /// Trigger the install flow.
    ///
    /// In M2's first cut this performed the install directly
    /// (`PluginManager.shared.installGeneratedPlugin(plugin)` and
    /// flipped `didRequestSave`). The M2-install-prompt
    /// follow-up replaces that contract: the
    /// `AIGeneratorInstallPromptSheet` (presented by the parent
    /// `AIGeneratorSheet`) drives the flow, and on completion calls
    /// `didCompleteInstall(at:)` / `didFailInstall(reason:)` to
    /// update the published state. This method is now a deliberate
    /// no-op kept for API stability so the older call site
    /// (`AIGeneratorSheet` used to invoke it from the footer
    /// button) compiles without modification.
    func requestSaveToPluginFolder() {
        // No-op: the install-prompt sheet owns the flow. See
        // `AIGeneratorInstallPromptSheet` / `didCompleteInstall(at:)`.
    }

    // MARK: - Install-prompt integration

    /// Capabilities the current `latestPlugin.manifest` declares.
    /// Empty when there is no `latestPlugin` — the parent sheet
    /// reads this to decide whether to even open the install-prompt
    /// sub-sheet.
    var installPromptCapabilities: [PluginCapability] {
        latestPlugin?.manifest.resolvedCapabilities ?? []
    }

    /// Pre-flight check: `true` when every declared capability is
    /// already granted (no prompt needed), `false` when at least
    /// one capability is ungranted. Used by the parent sheet to
    /// skip the prompt when the user has already accepted
    /// everything in a previous round-trip.
    var installPromptIsPreApproved: Bool {
        let pluginName = latestPlugin?.manifest.name ?? ""
        let granted = pluginCapabilityGate.granted(for: pluginName)
        return installPromptCapabilities.allSatisfy { capability in
            granted.contains(capability)
        }
    }

    /// Called by `AIGeneratorInstallPromptSheet`'s completion
    /// handler after a successful install. Stores the destination
    /// URL and flips `didRequestSave` so the parent sheet shows
    /// the success banner. v1 just sets the flag and stores the
    /// URL; future versions can fire a system notification here.
    func didCompleteInstall(at url: URL) {
        installedPluginURL = url
        didRequestSave = true
        os_log("AIGenerator: installed plugin at %{public}@",
               log: Self.log, type: .info, url.path)
    }

    /// Called by `AIGeneratorInstallPromptSheet`'s completion
    /// handler after a failed install (or a Cancel). Resets the
    /// published state so the parent sheet's banner goes back to
    /// its idle state and `didRequestSave` does not show a
    /// misleading "Saved" hint.
    func didFailInstall(reason: String) {
        installedPluginURL = nil
        didRequestSave = false
        os_log("AIGenerator: install did not complete: %{public}@",
               log: Self.log, type: .info, reason)
    }

    /// Reset the sheet back to its initial state. Useful for the
    /// "Try a different request" path the view wires to the
    /// "Re-generate" button when the user is already on a
    /// successful result.
    func reset() {
        state = .idle
        latestPlugin = nil
        didRequestSave = false
        installedPluginURL = nil
    }
}

// MARK: - Menu Tree Encoding

extension AIGeneratorViewModel {

    /// Encode the generator's `entryScript` as a JSON byte payload
    /// suitable for `AIGeneratorHistoryEntry.menuTreeJSON`.
    ///
    /// v1 path: a *synthetic* parse that walks the entry script
    /// line-by-line and builds a flat tree of `AIGeneratorMenuNode`s
    /// (see `AIGeneratorMenuNode.parseEntryScript(_:)`). Returns
    /// `nil` when the script is empty or only contains blank lines
    /// / comments — the caller treats `nil` as "unparseable" and
    /// leaves the history entry's `menuTreeJSON` at its default
    /// `nil` value, matching the M5 v1 contract.
    ///
    /// The encoder uses pretty-printed, sorted-key output with
    /// `withoutEscapingSlashes` so the `menu.json` file is
    /// human-readable when the user opens it in an editor.
    static func encodeMenuTree(from entryScript: String) -> Data? {
        guard let nodes = AIGeneratorMenuNode.parseEntryScript(entryScript),
              !nodes.isEmpty
        else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(nodes)
    }
}

// MARK: - Manifest Encoding Helper

/// Wrapper that exposes the `internal` `manifest` field on
/// `GeneratedPlugin` to `JSONEncoder`. `GeneratedPlugin.manifest` is
/// `internal` to keep `PluginManifest`'s `internal` access level from
/// leaking through the public type. The view model lives in the
/// same module so it can reach the field directly through this
/// tiny adapter.
private struct EncodedManifest: Encodable {
    let manifest: PluginManifest
    func encode(to encoder: Encoder) throws {
        try manifest.encode(to: encoder)
    }
}

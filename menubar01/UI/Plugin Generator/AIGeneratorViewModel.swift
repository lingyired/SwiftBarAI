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

    /// Set to `true` after a successful `PluginManager.installGeneratedPlugin`
    /// call. The sheet reads this to show the "Saved" confirmation
    /// alert and to swap the button label back to its "Save to Plugin
    /// Folder" idle state. Reset to `false` when a re-generate lands
    /// (see `generate()`) or when an install fails (see
    /// `requestSaveToPluginFolder()`).
    @Published var didRequestSave: Bool = false

    // MARK: - Dependencies

    /// The generator used by `generate()`. Default factory comes
    /// from `AIPluginGeneratorFactory.makeDefault()`. Tests
    /// overwrite this with a `MockAIPluginGenerator` to control
    /// behaviour without going through the protocol's real
    /// implementation.
    let generator: AIPluginGenerator

    /// M2 logs through this category. Mirrors `GeneratedPlugin.log`
    /// in `AIGenerator.swift` so the two flows' log messages show up
    /// under the same subsystem / split out by category.
    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    // MARK: - Init

    /// Default initializer. Pulls a generator from
    /// `AIPluginGeneratorFactory.makeDefault()` so the production
    /// sheet call site can stay one-liner.
    init(generator: AIPluginGenerator = AIPluginGeneratorFactory.makeDefault()) {
        self.generator = generator
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
        do {
            let plugin = try await generator.generate(request: trimmed, context: context)
            latestPlugin = plugin
            state = .success(plugin)
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    /// Install the most recent `latestPlugin` into the user's Plugin
    /// Folder by handing it to `PluginManager.installGeneratedPlugin`.
    ///
    /// The M2 stub simply flipped `didRequestSave`; M2-install-flow
    /// replaces that with a real install so the user sees the new
    /// plugin appear in the menu bar (via `PluginManager.loadPlugins`
    /// firing on the directory observer) without an extra "Confirm"
    /// step. The explicit install-prompt sheet (capability grant +
    /// user confirmation) is a follow-up — for v1, "I just generated
    /// this" is treated as a reasonable provenance for the manifest's
    /// `capabilities`. See `changes/2026-06-13-m2-install-flow.md`
    /// for the full rationale.
    func requestSaveToPluginFolder() {
        guard let plugin = latestPlugin else { return }
        switch PluginManager.shared.installGeneratedPlugin(plugin) {
        case .success(let url):
            os_log("AIGenerator: installed plugin at %{public}@", log: Self.log, type: .info, url.path)
            didRequestSave = true
        case .failure(let error):
            os_log("AIGenerator: install failed: %{public}@", log: Self.log, type: .error, String(describing: error))
            didRequestSave = false
        }
    }

    /// Reset the sheet back to its initial state. Useful for the
    /// "Try a different request" path the view wires to the
    /// "Re-generate" button when the user is already on a
    /// successful result.
    func reset() {
        state = .idle
        latestPlugin = nil
        didRequestSave = false
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

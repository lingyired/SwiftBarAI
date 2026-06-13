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

    /// Accumulated text from `generator.stream(...)` deltas while
    /// the generator is running. Reset to `""` on every new
    /// `generate()` / `generateStreaming()` call so the streaming
    /// preview never carries over text from a previous prompt.
    /// Bound to a monospaced scrollable view in the M2 sheet —
    /// `AIGeneratorSheet` shows it only while `isStreaming` is
    /// `true` and the overall `state` is `.loading`.
    @Published private(set) var streamingPreview: String = ""

    /// `true` while the streaming generator is mid-flight (i.e.
    /// between the moment `generateStreaming()` flipped the state
    /// to `.loading` and the `.finished(_)` / error event that
    /// transitions out of `.loading`). Used by `AIGeneratorSheet`
    /// to decide whether to show the streaming preview area.
    /// Always `false` when the state is `.idle`, `.success(_)`,
    /// or `.failure(_)`.
    @Published private(set) var isStreaming: Bool = false

    /// `true` while the "Improve" helper is mid-flight. The
    /// M2+ sheet's footer "Improve" button flips this on click
    /// and shows a small spinner next to the label; a second
    /// click while `true` is a no-op (see `improveRequest()`).
    /// Always `false` when the helper is idle. Independent of
    /// `isStreaming` / `isLoading` so the spinner never races
    /// with the streaming-preview spinner.
    @Published private(set) var isImproving: Bool = false

    /// `true` while the M2+ "Re-generate" button is mid-flight
    /// (the user clicked the success-view "Re-generate" button
    /// to ask the LLM for a variation of the previous result).
    /// The M2 sheet's success view flips this on click and
    /// shows a small spinner next to the button; a second click
    /// while `true` is a no-op (see `regenerateWithVariation()`).
    /// Independent of `isLoading`, `isStreaming`, and
    /// `isImproving` so the spinner never races with the
    /// streaming-preview / improve / first-run spinners.
    @Published private(set) var isRegenerating: Bool = false

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

    /// Temperature the M2+ "Re-generate" button asks the model
    /// to use. `0.8` is high enough to produce a clearly
    /// different plugin from the first run (the first run uses
    /// the Remote generator's `0.2` default) but low enough to
    /// stay coherent — the user is asking for a *variation* of
    /// the previous result, not a random unrelated plugin.
    /// Pinned as a `static let` on the view model so the SwiftUI
    /// button, the test suite, and the Remote generator's
    /// `temperature` payload all read the same constant.
    static let regenerateTemperature: Double = 0.8

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
                    menuTreeJSON: menuTreeJSON,
                    endpointHost: generator.endpointHost,
                    providerName: generator.providerName
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

    /// M2+ "Improve" helper. Asks the active generator to
    /// rewrite the user's current `request` as a single, more
    /// specific instruction and, on success, replaces the
    /// request text in place so the user can immediately
    /// review and click "Generate".
    ///
    /// Concurrency: a second click while `isImproving` is
    /// `true` is a no-op, so a user double-click does not
    /// fire two LLM round-trips.
    ///
    /// Empty-input guard: an empty / whitespace-only request
    /// short-circuits before the LLM call, mirroring the
    /// `canGenerate` rule. The guard exists so the footer
    /// button does not need its own disabled state — the
    /// SwiftUI button is bound to `request.isEmpty` and is
    /// already disabled in that case.
    ///
    /// Failure: any thrown error is **swallowed** (logged via
    /// `os_log` at `.error`) and the existing `request` is
    /// preserved. The user keeps typing; the failure is not
    /// surfaced through `state` so a stray "Improve" error
    /// does not overwrite a previous generation's banner.
    func improveRequest() async {
        guard !isImproving else { return }
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isImproving = true
        defer { isImproving = false }
        do {
            let improved = try await generator.improve(request: request, context: context)
            request = improved
        } catch {
            // Keep existing state, do not overwrite request.
            os_log("AIGenerator: improve failed: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
        }
    }

    /// M2+ "Re-generate" helper. Re-runs the active generator
    /// with the same `request` but a deliberately higher
    /// temperature (`Self.regenerateTemperature`, currently
    /// `0.8`) so the LLM produces a *variation* of the previous
    /// result. Designed for the success view's "Re-generate"
    /// button — the user already has a result they like, and
    /// clicking the button asks the model to "try again, but
    /// give me something different".
    ///
    /// Concurrency: a second click while `isRegenerating` is
    /// `true` is a no-op, so a user double-click does not fire
    /// two LLM round-trips. Empty / whitespace-only requests
    /// are short-circuited before the call (mirrors
    /// `canGenerate`).
    ///
    /// Success: the new plugin replaces `latestPlugin` and the
    /// state transitions to `.success(newPlugin)`. A new
    /// `AIGeneratorHistoryEntry` is recorded with the
    /// high-temperature `promptId` (the
    /// `MockAIPluginGenerator.promptId(for:model:temperature:)`
    /// overload bakes the temperature into the hash so the
    /// history row is distinct from the first run's row — no
    /// duplicate history entry).
    ///
    /// Failure: the existing `state` / `latestPlugin` are
    /// preserved (the error is logged via `os_log` at `.error`
    /// but not surfaced through `state`), so a transient LLM
    /// error does not blow away the previous successful
    /// generation. The success view keeps showing the last
    /// good plugin.
    func regenerateWithVariation() async {
        guard !isRegenerating else { return }
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        // Snapshot the previous state so we can roll back on
        // failure without the call site having to reason about
        // `latestPlugin` / `state` separately.
        let previousPlugin = latestPlugin
        let previousState = state
        // Build a fresh context that overrides the temperature
        // with the high-temperature constant. We do **not**
        // mutate the published `context` because the user's
        // chosen default temperature (when they have one)
        // should not flip just because they hit "Re-generate"
        // once — the override is scoped to this single call.
        var variationContext = context
        variationContext.temperature = Self.regenerateTemperature
        do {
            let newPlugin = try await generator.generate(
                request: request, context: variationContext
            )
            latestPlugin = newPlugin
            state = .success(newPlugin)
            // Record a fresh history row keyed on the
            // high-temperature `promptId`. The Mock / Remote
            // generators' `promptId(for:model:temperature:)`
            // overload bakes the temperature into the hash, so
            // the new entry is keyed on a different `promptId`
            // from the first run and lands as a separate row
            // in the on-disk history store. Mirrors the
            // streaming `recordHistory(...)` helper so the
            // menu-tree JSON and host/model attribution
            // behaviour is identical to the first-run path.
            recordHistory(plugin: newPlugin, request: request)
        } catch {
            // Preserve the previous success: roll `latestPlugin`
            // and `state` back to the snapshot taken at the
            // top of the call. The error is logged but not
            // surfaced through `state` so the success banner
            // and the `Save to Plugin Folder` button stay
            // available for the previous (good) plugin.
            latestPlugin = previousPlugin
            state = previousState
            os_log("AIGenerator: regenerate-with-variation failed: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
        }
    }

    /// Streaming counterpart of `generate()`. Marks the state
    /// `.loading`, flips `isStreaming` to `true`, then iterates
    /// `generator.stream(request:context:)` and appends each
    /// `textDelta` to `streamingPreview` on the main actor. On
    /// `.finished(_)` the assembled text is converted into a
    /// `GeneratedPlugin` via the same shared helper the
    /// non-streaming `generate()` path uses (`RemoteAIPluginGenerator`
    /// exposes `makeGeneratedPlugin(...)` for exactly this
    /// purpose; the Mock / Echo generators fall back to
    /// `generate()` — see below), and the state transitions to
    /// `.success(plugin)`. On any thrown error the state
    /// transitions to `.failure(reason)`.
    ///
    /// Streaming-unsupported fallback: if the active generator
    /// inherits the default `stream(...)` implementation and
    /// throws `AIGeneratorError.streamingUnsupported` on the
    /// first iteration, the method delegates to `generate()` so
    /// the UX is identical to today. The fallback is
    /// auto-detected — the M2 sheet's "Generate" button always
    /// calls `generateStreaming()`, never `generate()` directly.
    func generateStreaming() async {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .loading
        didRequestSave = false
        installedPluginURL = nil
        streamingPreview = ""
        isStreaming = true
        defer {
            isStreaming = false
        }
        // Probe whether the active generator supports streaming
        // by inspecting a one-shot async sequence. The probe
        // runs the same code path the streaming run would, but
        // on the first iteration we check whether the first
        // emitted value is an error and, if so, fall back to
        // `generate()`. We achieve this with a small wrapper
        // `for try await ... break` loop instead of a separate
        // protocol check: simpler, and it exercises the actual
        // code path the UI relies on.
        var didFallBack = false
        do {
            for try await event in generator.stream(request: trimmed, context: context) {
                switch event {
                case .textDelta(let delta):
                    // Append on the main actor — `generateStreaming`
                    // is `@MainActor` on the enclosing class, so the
                    // mutation is already on the main thread.
                    streamingPreview.append(delta)
                case .finished(let assembled):
                    // Build a `GeneratedPlugin` from the assembled
                    // text using the same contract the non-streaming
                    // path uses. The Mock / Echo / Local generators
                    // do not override `stream(...)`, so this branch
                    // is reachable only for the
                    // `RemoteAIPluginGenerator`. For other
                    // generators the default `stream(...)` throws
                    // `streamingUnsupported` before yielding any
                    // events, so we never get here.
                    let plugin = try buildPluginFromAssembledText(
                        assembled,
                        request: trimmed
                    )
                    latestPlugin = plugin
                    state = .success(plugin)
                    recordHistory(
                        plugin: plugin,
                        request: trimmed
                    )
                    // Stop iterating the stream. The M2 sheet
                    // hides the streaming preview as soon as
                    // `state` leaves `.loading`.
                    return
                }
            }
            // Stream ended without a `.finished(_)` — treat as
            // a malformed response.
            state = .failure(AIGeneratorError.malformedResponse(
                reason: "stream ended without a finish event"
            ).localizedDescription)
        } catch let AIGeneratorError.streamingUnsupported {
            // Auto-detect: the active generator does not support
            // streaming. Fall back to the non-streaming path so
            // the UX is unchanged for Mock / Echo / Local stub.
            didFallBack = true
        } catch {
            state = .failure(error.localizedDescription)
        }
        if didFallBack {
            await generate()
        }
    }

    /// Helper used by `generateStreaming()` to convert the
    /// assembled streaming text into a `GeneratedPlugin`. The
    /// M2+ `RemoteAIPluginGenerator` exposes
    /// `makeGeneratedPlugin(fromContent:request:context:promptId:)`
    /// for exactly this purpose. For generators that do not
    /// support streaming (Mock / Echo / Local stub), the
    /// streaming path falls back to `generate()` and this
    /// helper is never reached.
    private func buildPluginFromAssembledText(
        _ text: String,
        request: String
    ) throws -> GeneratedPlugin {
        if let remote = generator as? RemoteAIPluginGenerator {
            return try remote.makeGeneratedPlugin(
                fromContent: text,
                request: request,
                context: context,
                promptId: MockAIPluginGenerator.promptId(
                    for: request, model: context.model
                )
            )
        }
        // The default `stream(...)` throws
        // `streamingUnsupported` for any non-`Remote` generator,
        // so the caller has already fallen back to `generate()`
        // before reaching this point. Throwing here is a
        // defensive guard against a future generator that
        // streams but does not implement
        // `makeGeneratedPlugin(fromContent:...)`.
        throw AIGeneratorError.malformedResponse(
            reason: "active generator does not expose makeGeneratedPlugin"
        )
    }

    /// Helper that records an `AIGeneratorHistoryEntry` to the
    /// injected `historyStore`. Mirrors the trailing block in
    /// `generate()` so the streaming and non-streaming paths
    /// produce identical history rows.
    private func recordHistory(
        plugin: GeneratedPlugin,
        request: String
    ) {
        let menuTreeJSON = AIGeneratorViewModel.encodeMenuTree(
            from: plugin.entryScript
        )
        do {
            try historyStore.record(AIGeneratorHistoryEntry(
                promptId: plugin.promptId,
                createdAt: Date(),
                request: request,
                model: context.model,
                plugin: plugin,
                menuTreeJSON: menuTreeJSON,
                endpointHost: generator.endpointHost,
                providerName: generator.providerName
            ))
        } catch {
            os_log("AIGenerator: failed to record history entry: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            // Non-fatal: the user still sees the generated plugin.
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
        streamingPreview = ""
        isStreaming = false
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

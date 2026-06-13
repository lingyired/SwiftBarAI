// MarketplaceBrowserViewModel.swift
// menubar01 — PluginMarketplace (M5)
//
// View model backing `MarketplaceBrowserSheet`. Owns the catalogue,
// the currently selected entry, the loaded package, and the
// install state machine. All `@Published` mutations happen on the
// main actor so SwiftUI's bindings stay in lockstep with the
// underlying state without an explicit `DispatchQueue.main` hop.
//
// The VM is intentionally narrow: it glues three collaborators
// together (a `MarketplaceClient`, a `PluginManager`, and the
// pure `MarketplaceInstaller.plan(...)` helper) and exposes the
// four actions the view needs (load, select, install, reset).
// `installSelected(overwriteExisting:)` is the only one that does
// real work — and it follows the M4 plan-then-install split so
// the data layer stays unit-testable in isolation.

import Foundation
import SwiftUI

/// State machine for the marketplace browser sheet.
///
/// The cases mirror the user-visible lifecycle of the sheet:
/// `idle` (initial / reset), `loading` (catalogue fetch in
/// flight), `loaded` (catalogue fetched, no entry selected yet),
/// `installing` (install in flight), `installed(URL)` (success
/// path — carries the on-disk folder URL for the success
/// alert), and `error(String)` (failure path — carries a
/// human-readable message for the error banner).
enum MarketplaceBrowserState: Equatable {
    case idle
    case loading
    case loaded
    case installing
    case installed(URL)
    case error(String)
}

/// View model for the marketplace browser sheet.
///
/// M5 (this milestone) wires the M4 data layer to a SwiftUI
/// sheet. The VM is `@MainActor` because every `@Published`
/// property drives a SwiftUI view; mutating them off the main
/// thread would require explicit `Task { @MainActor in }` hops
/// inside the `client.fetchCatalogue()` completion path.
@MainActor
final class MarketplaceBrowserViewModel: ObservableObject {

    // MARK: - Published State

    /// Full catalogue as returned by the client. Populated by
    /// `loadCatalogue()`.
    @Published var entries: [MarketplaceEntry] = []

    /// The entry the user has clicked in the sidebar.
    @Published var selectedEntry: MarketplaceEntry?

    /// The `MarketplacePackage` for `selectedEntry`, fetched
    /// via `client.fetchPackage(id:)`. `nil` until the user
    /// selects an entry and the package fetch returns.
    @Published var package: MarketplacePackage?

    /// State machine — see `MarketplaceBrowserState` for the
    /// full case list. `internal(set)` so tests can set up
    /// preconditions (e.g. force `.installing` to verify the
    /// progress view is shown).
    @Published internal(set) var state: MarketplaceBrowserState = .idle

    // MARK: - Dependencies

    /// Catalogue + per-id package fetch. Default is
    /// `MarketplaceClientFactory.makeStub()` (the M4 in-memory
    /// client with the 3 seed entries). Tests inject a
    /// `CapturingMarketplaceClient` to control return values
    /// and assert on call arguments.
    let client: MarketplaceClient

    /// The plugin manager that owns the user's Plugin Folder.
    /// Default is the process-wide singleton; tests pass a
    /// per-test temp-dir-backed instance.
    let pluginManager: PluginManager?

    /// M3 capability gate used by the install-prompt sheet to read
    /// / grant the per-plugin capability set. Default points at
    /// `PluginManager.shared.pluginCapabilityGate` so the
    /// production sheet uses the same store the loader reads
    /// from on next refresh. Tests inject a fresh instance
    /// backed by an isolated `UserDefaults(suiteName:)` via
    /// the `internal(set)` setter, mirroring the DI pattern in
    /// `AIGeneratorViewModel.pluginCapabilityGate`.
    var pluginCapabilityGate: PluginCapabilityGate = PluginManager.shared.pluginCapabilityGate

    // MARK: - Init

    /// Designated init. `client` defaults to
    /// `MarketplaceClientFactory.makeStub()` so the production
    /// call site (`MarketplaceBrowserMenuCommand`) can stay
    /// one-liner. `pluginManager` defaults to
    /// `PluginManager.shared`. Both are `let` (not
    /// `@Published`) — the view never rebinds them.
    init(
        client: MarketplaceClient = MarketplaceClientFactory.makeStub(),
        pluginManager: PluginManager? = PluginManager.shared
    ) {
        self.client = client
        self.pluginManager = pluginManager
    }

    // MARK: - Derived State

    /// `true` while an install round-trip is in flight. The
    /// sheet reads this to disable the Install button and show
    /// a ProgressView in the footer.
    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    /// Pretty-printed JSON body of the loaded package's
    /// manifest. `nil` until `package` is set. Mirrors the
    /// `manifestJSON` computed property on
    /// `AIGeneratorViewModel` so the sheet can re-use the
    /// same monospaced-text idiom.
    var manifestJSON: String? {
        guard let package else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(EncodedManifest(manifest: package.manifest)),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Capabilities the currently loaded package's manifest
    /// declares. Empty when no package is loaded (e.g. the user
    /// has not yet selected an entry, or the package fetch is
    /// in flight). Mirrors `AIGeneratorViewModel.installPromptCapabilities`
    /// so both install flows expose the same shape and the
    /// `MarketplaceInstallPromptSheet` can render the same
    /// "list of toggles" UI the M2+ install-prompt sheet uses.
    var installPromptCapabilities: [PluginCapability] {
        package?.manifest.resolvedCapabilities ?? []
    }

    /// Pre-flight check: `true` when every declared capability
    /// is already granted (no prompt needed), `false` when at
    /// least one capability is ungranted. Used by the parent
    /// sheet to skip the prompt when the user has already
    /// accepted everything in a previous round-trip. Mirrors
    /// `AIGeneratorViewModel.installPromptIsPreApproved`.
    var installPromptIsPreApproved: Bool {
        let pluginName = package?.manifest.name ?? selectedEntry?.name ?? ""
        guard !pluginName.isEmpty else { return true }
        let granted = pluginCapabilityGate.granted(for: pluginName)
        return installPromptCapabilities.allSatisfy { capability in
            granted.contains(capability)
        }
    }

    /// Build the `MarketplaceInstallPromptContext` the parent
    /// sheet hands to the install-prompt sub-sheet. Returns
    /// `nil` when no package is loaded (e.g. the user has not
    /// yet selected an entry, or the package fetch is in
    /// flight) — the view should treat `nil` as "the install
    /// button stays disabled, do not present the prompt".
    ///
    /// Bundling the snapshot into a value type means the prompt
    /// sheet cannot accidentally read stale state if the user
    /// clicks around between the prompt being shown and the
    /// Install button being pressed. The view re-fetches the
    /// context on every presentation via
    /// `requestInstallPrompt(overwriteExisting:)`.
    func requestInstallPrompt(overwriteExisting: Bool) -> MarketplaceInstallPromptContext? {
        guard let package else { return nil }
        let pluginName = package.manifest.name ?? selectedEntry?.name ?? ""
        return MarketplaceInstallPromptContext(
            pluginName: pluginName,
            capabilities: installPromptCapabilities,
            isPreApproved: installPromptIsPreApproved,
            package: package,
            overwriteExisting: overwriteExisting
        )
    }

    // MARK: - Actions

    /// Load the catalogue from the client.
    ///
    /// Transitions:
    /// - `.idle | .loaded | .error → .loading`
    /// - on success: `.loading → .loaded` and `entries` is set
    /// - on failure: `.loading → .error(reason)` with the
    ///   upstream error's `localizedDescription`.
    ///
    /// `selectedEntry` and `package` are **not** cleared here —
    /// a re-fetch may legitimately leave the previous selection
    /// valid (the catalogue is rarely reshuffled between
    /// loads). Call `reset()` to clear everything.
    func loadCatalogue() async {
        state = .loading
        do {
            let catalogue = try await client.fetchCatalogue()
            entries = catalogue
            state = .loaded
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Fetch the `MarketplacePackage` for `entry` and remember
    /// it as the current selection.
    ///
    /// Sets `selectedEntry` and `package`. If the package fetch
    /// throws (e.g. `MarketplaceError.notFound(id:)`) the
    /// state lands in `.error(reason)` so the view can show
    /// the banner. `entries` is left untouched.
    func selectEntry(_ entry: MarketplaceEntry) async {
        selectedEntry = entry
        package = nil
        do {
            let fetched = try await client.fetchPackage(id: entry.id)
            package = fetched
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Install the currently selected entry. Combines the M4
    /// pure plan with the new `PluginManager.installMarketplacePlugin(...)`
    /// I/O helper.
    ///
    /// This is the **install primitive** the
    /// `MarketplaceInstallPromptSheet` calls after the user has
    /// ticked capabilities and the sheet has called
    /// `gate.grant(_:for:)`. It is intentionally renamed from
    /// the M5-first-cut `installSelected(...)` so the contract
    /// is clear: the sheet drives the flow, the VM does the
    /// install. The M5-first-cut `installSelected(...)` is
    /// kept as a thin wrapper for the existing
    /// `MarketplaceBrowserViewModelTests` assertions and for
    /// any future programmatic caller that has already
    /// pre-approved capabilities.
    ///
    /// Transitions:
    /// - `no entry selected` → returns without state change
    ///   (defensive — the Install button is disabled in this
    ///   case but a programmatic call should also no-op)
    /// - `state → .installing` → on success
    ///   `.installed(targetURL)` → on failure
    ///   `.error(reason)`.
    ///
    /// The success path does **not** clear `selectedEntry` or
    /// `package` — the user may want to install the same
    /// plugin again, or click "Install (overwrite)". Call
    /// `reset()` for a clean sheet.
    func _installSelectedAfterGrants(overwriteExisting: Bool) async {
        guard let entry = selectedEntry, let package else {
            return
        }
        state = .installing
        let plan: MarketplaceInstallPlan
        do {
            plan = try MarketplaceInstaller.plan(
                entry: entry,
                package: package,
                overwriteExisting: overwriteExisting
            )
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        guard let manager = pluginManager else {
            state = .error("Plugin manager is unavailable")
            return
        }

        let result = manager.installMarketplacePlugin(
            plan: plan,
            overwriteExisting: overwriteExisting
        )
        switch result {
        case .success(let targetURL):
            state = .installed(targetURL)
        case .failure(let error):
            state = .error(humanReadable(error))
        }
    }

    /// Install the currently selected entry. M5 install-prompt
    /// follow-up: this method is now a **no-op** — the
    /// `MarketplaceInstallPromptSheet` (presented by the parent
    /// `MarketplaceBrowserSheet`) drives the flow, grants the
    /// user-enabled capabilities, and then calls
    /// `_installSelectedAfterGrants(overwriteExisting:)`. Kept
    /// as a thin forwarder so the existing
    /// `MarketplaceBrowserViewModelTests` assertions and any
    /// future programmatic caller continue to compile without
    /// modification.
    func installSelected(overwriteExisting: Bool) async {
        await _installSelectedAfterGrants(overwriteExisting: overwriteExisting)
    }

    /// Reset the sheet back to its initial state. Clears
    /// `entries`, `selectedEntry`, `package`, and sets
    /// `state = .idle`. Useful when the user clicks "Close"
    /// and reopens the sheet, or when a test wants a fresh
    /// fixture between assertions.
    func reset() {
        entries = []
        selectedEntry = nil
        package = nil
        state = .idle
    }

    // MARK: - Private helpers

    /// Maps an `InstallMarketplacePluginError` to a
    /// human-readable string for the error banner. The cases
    /// are narrow enough that no further localisation is done
    /// in v1 — the messages match what the user would see if
    /// they tried the operation in Terminal.
    private func humanReadable(_ error: InstallMarketplacePluginError) -> String {
        switch error {
        case .pluginDirectoryUnavailable:
            return "No plugin folder is configured. Set one in Preferences → Plugins."
        case .writeFailed(let reason):
            return "Could not write plugin files: \(reason)"
        case .chmodFailed(let reason):
            return "Plugin was written but could not be made executable: \(reason). Run `chmod +x <script>` manually."
        case .planFailed(let reason):
            return "Install plan was invalid: \(reason)"
        }
    }
}

// MARK: - Manifest Encoding Helper

/// Wrapper that exposes the `internal` `manifest` field on
/// `MarketplacePackage` to `JSONEncoder`. Mirrors the
/// `EncodedManifest` adapter in `AIGeneratorViewModel.swift`
/// — same access-level workaround, same single-purpose
/// `Encodable` shim.
private struct EncodedManifest: Encodable {
    let manifest: PluginManifest
    func encode(to encoder: Encoder) throws {
        try manifest.encode(to: encoder)
    }
}

// MARK: - Install Prompt Context

/// Snapshot of the data `MarketplaceInstallPromptSheet` needs
/// to render and run an install. Built by
/// `MarketplaceBrowserViewModel.requestInstallPrompt(overwriteExisting:)`
/// so the prompt sheet does not have to reach into the view
/// model mid-flow. Value type so the prompt sheet cannot
/// accidentally mutate the parent state — the install itself
/// still goes through `_installSelectedAfterGrants(...)` on
/// the VM.
///
/// `Equatable` is hand-rolled rather than synthesized because
/// `MarketplacePackage` is intentionally not `Equatable` (its
/// embedded `PluginManifest` is not). The context treats the
/// package as an opaque payload and compares by `id` only —
/// callers that need full package equality should compare the
/// inner `package` separately.
struct MarketplaceInstallPromptContext: Equatable {
    /// Plugin name used as the gate key (`granted(for:)` /
    /// `grant(_:for:)`). Falls back to the catalogue entry's
    /// name when the manifest omits one.
    let pluginName: String
    /// Resolved capability list, in declaration order. Drives
    /// the toggles the prompt sheet renders.
    let capabilities: [PluginCapability]
    /// `true` when every capability is already granted. The
    /// prompt sheet uses this to decide whether to skip
    /// rendering the toggle list (none to grant) or just
    /// surface an informational "already approved" hint.
    let isPreApproved: Bool
    /// The package the user has selected. Held by the prompt
    /// sheet so the success-path completion handler can read
    /// the on-disk path directly off the result without going
    /// back through the VM. Not part of `==` (see type-level
    /// doc).
    let package: MarketplacePackage
    /// Whether the user asked to overwrite an existing install.
    /// The prompt sheet forwards this to
    /// `_installSelectedAfterGrants(overwriteExisting:)`.
    let overwriteExisting: Bool

    static func == (lhs: MarketplaceInstallPromptContext, rhs: MarketplaceInstallPromptContext) -> Bool {
        lhs.pluginName == rhs.pluginName
            && lhs.capabilities == rhs.capabilities
            && lhs.isPreApproved == rhs.isPreApproved
            && lhs.package.id == rhs.package.id
            && lhs.overwriteExisting == rhs.overwriteExisting
    }
}

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
    func installSelected(overwriteExisting: Bool) async {
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

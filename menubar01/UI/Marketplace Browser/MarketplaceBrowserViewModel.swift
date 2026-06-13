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
import os

/// State machine for the marketplace browser sheet.
///
/// The cases mirror the user-visible lifecycle of the sheet:
/// `idle` (initial / reset), `loading` (catalogue fetch in
/// flight), `loaded` (catalogue fetched, no entry selected yet),
/// `installing` (install in flight), `installed(URL)` (success
/// path — carries the on-disk folder URL for the success
/// alert), `uninstalling` (uninstall in flight), `uninstalled`
/// (uninstall success — carries the plugin name for the success
/// banner), `updating` (update in flight), `updated(URL)` (update
/// success — carries the on-disk folder URL for the success
/// banner), and `error(String)` (failure path — carries a
/// human-readable message for the error banner).
enum MarketplaceBrowserState: Equatable {
    case idle
    case loading
    case loaded
    case installing
    case installed(URL)
    case uninstalling
    case uninstalled(pluginName: String)
    case updating
    case updated(URL)
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

    /// `true` while an uninstall round-trip is in flight. The
    /// sheet reads this to disable the Uninstall button and
    /// show a ProgressView in the Installed tab.
    var isUninstalling: Bool {
        if case .uninstalling = state { return true }
        return false
    }

    /// `true` while an update round-trip is in flight. The
    /// sheet reads this to disable the Update button and
    /// show a ProgressView in the Installed tab.
    var isUpdating: Bool {
        if case .updating = state { return true }
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

    /// M5 install-gate follow-up: install through the new
    /// `PluginManager.installMarketplacePluginWithCapabilityGate(...)`
    /// overload. The overload:
    ///  1. auto-grants every `isGrantedByDefault == true`
    ///     capability silently,
    ///  2. surfaces the ungranted, non-default set to
    ///     `MarketplaceCapabilityPrompter.present(...)` via
    ///     the closure below,
    ///  3. on user grant, records the prompt set in the gate
    ///     and delegates to the I/O install,
    ///  4. on user decline, returns
    ///     `.capabilityDeclined(...)` without touching the
    ///     disk.
    ///
    /// The M5 install-prompt sheet still drives the legacy
    /// `_installSelectedAfterGrants(...)` path so the unit
    /// tests and any future programmatic caller continue to
    /// compile. The sheet is intentionally distinct from
    /// `MarketplaceCapabilityPromptSheet` — the sheet renders
    /// per-capability checkboxes; the prompter renders an
    /// all-or-nothing Grant/Decline because the install-gate
    /// overload has already filtered out the
    /// `isGrantedByDefault == true` capabilities.
    ///
    /// Mirrors the call site pattern from
    /// `AIGeneratorViewModel` / `AIGeneratorInstallPromptSheet`
    /// but uses the new closure-based install primitive.
    func installSelectedWithCapabilityGate(overwriteExisting: Bool) async {
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

        let result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: overwriteExisting,
            gate: pluginCapabilityGate,
            prompt: { pluginID, capabilities in
                await withCheckedContinuation { continuation in
                    MarketplaceCapabilityPrompter.present(
                        pluginID: pluginID,
                        capabilities: capabilities
                    ) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }
        )
        switch result {
        case .success(let targetURL):
            state = .installed(targetURL)
        case .failure(let error):
            if case .capabilityDeclined(_, _) = error {
                // The user declined the prompt — roll the
                // state back to `.loaded` so the install
                // button re-enables and the user can retry
                // without seeing the error banner.
                state = .loaded
            } else {
                state = .error(humanReadable(error))
            }
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
        installedPlugins = []
        state = .idle
    }

    // MARK: - Installed Plugins

    /// Snapshot of a marketplace plugin currently installed
    /// on disk. Built by
    /// `MarketplaceBrowserViewModel.refreshInstalledPlugins()`.
    /// The view renders one row per snapshot in the
    /// "Installed" sidebar tab. `Identifiable` is keyed on
    /// `id` so SwiftUI's `List` can drive selection and
    /// `onDelete` / `onMove` modifiers can address a row
    /// unambiguously.
    struct InstalledPluginSnapshot: Identifiable, Equatable {
        /// Folder name on disk (under
        /// `<pluginDirectoryURL>/_marketplace/`). The
        /// `id` is the absolute URL stringified so two
        /// installs with the same folder name (which is
        /// impossible in practice — the install path
        /// refuses collisions — but defensive nonetheless)
        /// would still get distinct rows.
        let id: String
        /// Absolute `file://` URL of the on-disk folder.
        let url: URL
        /// Plugin name from `manifest.json`. Falls back
        /// to the folder name when the manifest omits
        /// `name`.
        let name: String
        /// Version from `manifest.json` (e.g. `"1.0.0"`).
        /// `nil` when the manifest omits it.
        let version: String?
        /// Parsed `MarketplaceVersion` for
        /// `version`. `nil` when the manifest omits
        /// `version` or the string is unparseable. The
        /// M5 update-detection follow-up uses this to
        /// compute the "Update available" badge on
        /// the Installed tab — see
        /// `updateAvailability(for:)`.
        let manifestVersion: MarketplaceVersion?
        /// File modification date of the manifest, used
        /// as a "last updated" hint. `nil` when the
        /// attribute lookup fails.
        let lastUpdated: Date?
        /// `true` when the corresponding folder plugin
        /// is currently enabled in the user's
        /// `PreferencesStore.disabledPlugins` set. The
        /// Installed tab binds a SwiftUI `Toggle` to
        /// this flag so the user can disable a
        /// marketplace install without uninstalling
        /// it. Defaults to `true` (enabled) when the
        /// plugin has not yet been loaded into
        /// `PluginManager.plugins` (e.g. immediately
        /// after install before the next refresh) —
        /// the toggle will re-sync on the next
        /// `refreshInstalledPlugins()` pass.
        let isEnabled: Bool
    }

    /// Latest snapshot of the marketplace installs. The
    /// "Installed" sidebar tab reads this to render its
    /// list. Refreshed by
    /// `refreshInstalledPlugins()`. Initialised to `[]`
    /// so SwiftUI's `List` does not crash on first
    /// appearance; the sidebar's `.task` modifier drives
    /// the first refresh.
    @Published private(set) var installedPlugins: [InstalledPluginSnapshot] = []

    /// Re-read the on-disk marketplace installs and
    /// rebuild `installedPlugins`. Called by the view on
    /// appearance and after every install / uninstall /
    /// update round-trip so the sidebar stays in sync
    /// with the file system.
    ///
    /// The scan walks
    /// `<pluginDirectoryURL>/_marketplace/*` and keeps
    /// only the directories whose `manifest.json` loads
    /// via `PluginManifestLoader.loadManifest(from:)`. A
    /// corrupt directory is logged and skipped — the user
    /// can recover by uninstalling it manually from
    /// Finder (the marketplace uninstall refuses to
    /// touch a corrupt directory by design).
    func refreshInstalledPlugins() {
        guard let pluginDirectoryURL = pluginManager?.pluginDirectoryURL else {
            installedPlugins = []
            return
        }
        let marketplaceRoot = pluginDirectoryURL
            .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: marketplaceRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            installedPlugins = []
            return
        }
        var snapshots: [InstalledPluginSnapshot] = []
        for case let entryURL as URL in enumerator {
            // Top-level marketplace entries are always
            // directories — the install path refuses to
            // create anything else. Skip anything that
            // somehow is not a directory.
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entryURL.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }
            // Enumerate one level only: the marketplace
            // install is a self-contained folder plugin.
            enumerator.skipDescendants()
            guard let manifest = PluginManifestLoader.loadManifest(from: entryURL) else {
                os_log("refreshInstalledPlugins: skipping unparseable manifest at %{public}@",
                       log: Log.plugin, type: .info, entryURL.path)
                continue
            }
            let manifestURL = entryURL.appendingPathComponent(pluginManifestFileName)
            let modificationDate = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let name = manifest.name ?? entryURL.lastPathComponent
            // Parse the on-disk manifest's version into a
            // `MarketplaceVersion` so the Installed tab can
            // surface a "Update available" badge against
            // the catalogue row's `version` string. `nil`
            // when the manifest omits `version` or the
            // string is unparseable; the badge logic in
            // `updateAvailability(for:)` treats that as
            // "unknown".
            let parsedManifestVersion: MarketplaceVersion? = {
                guard let raw = manifest.version, !raw.isEmpty else { return nil }
                return MarketplaceVersion(parsing: raw)
            }()
            os_log("refreshInstalledPlugins: parsed manifestVersion=%{public}@ for %{public}@",
                   log: Log.plugin, type: .info,
                   parsedManifestVersion?.displayString ?? "nil", name)
            // Look up the plugin's enabled state via the
            // `PreferencesStore.disabledPlugins` set so the
            // Installed tab can render a SwiftUI `Toggle` that
            // reflects the current user preference. The folder
            // plugin's `id` is the symlink-resolved manifest
            // directory path — that is what `prefs.disablePlugin(_:)`
            // / `prefs.enablePlugin(_:)` write to, so the
            // membership check uses the same key. Falls back to
            // `true` (enabled) when `pluginManager` is nil (e.g.
            // tests that did not wire a manager) so the snapshot
            // still has a sensible value.
            let resolvedPath = entryURL.resolvingSymlinksInPath().path
            let isEnabled = pluginManager?.prefs.disabledPlugins.contains(resolvedPath) == false
            snapshots.append(InstalledPluginSnapshot(
                id: entryURL.standardizedFileURL.path,
                url: entryURL.standardizedFileURL,
                name: name,
                version: manifest.version,
                manifestVersion: parsedManifestVersion,
                lastUpdated: modificationDate,
                isEnabled: isEnabled
            ))
        }
        // Sort alphabetically by name so the sidebar
        // is stable across refreshes.
        installedPlugins = snapshots.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Uninstall

    /// Uninstall the marketplace plugin currently selected
    /// in the sidebar.
    ///
    /// Computes the on-disk URL via
    /// `PluginManager.marketplacePluginURL(pluginDirectoryURL:entryFilename:)`
    /// (the same sanitisation rules the install path uses)
    /// and delegates to
    /// `PluginManager.uninstallMarketplacePlugin(at:)`. The
    /// path-safety check inside the manager is the
    /// canonical "is this a marketplace install?" gate —
    /// the view model does not duplicate the check.
    ///
    /// Transitions:
    /// - `no entry selected` → returns
    ///   `.failure(.notAMarketplacePlugin(reason:))`. The
    ///   Uninstall button is disabled in this state but a
    ///   programmatic call should also fail loudly.
    /// - `state → .uninstalling` → on success
    ///   `.uninstalled(pluginName:)`. The success path
    ///   refreshes `installedPlugins` so the sidebar
    ///   drops the row.
    /// - on failure: `.error(reason)` so the banner
    ///   surfaces the underlying cause.
    @discardableResult
    func uninstallSelected() -> Result<Void, UninstallMarketplacePluginError> {
        guard let entry = selectedEntry else {
            return .failure(.notAMarketplacePlugin(
                reason: "no catalogue entry is selected"
            ))
        }
        // The entry filename is the manifest's `entry`
        // field. When the manifest omits it the
        // marketplace install path uses
        // `FolderPlugin.inferEntryFilename(in:)`, but at
        // uninstall time we only have the catalogue
        // row (no manifest). The catalogue's `id` is
        // the on-disk folder name's source of truth —
        // fall back to it when the entry filename is
        // empty.
        let entryFilename = package?.entryFilename
            ?? preferredEntryFilename(for: entry)
        guard let pluginDirectoryURL = pluginManager?.pluginDirectoryURL else {
            return .failure(.pluginDirectoryUnavailable)
        }
        guard let targetURL = PluginManager.marketplacePluginURL(
            pluginDirectoryURL: pluginDirectoryURL,
            entryFilename: entryFilename
        ) else {
            return .failure(.pluginDirectoryUnavailable)
        }
        guard let manager = pluginManager else {
            return .failure(.pluginDirectoryUnavailable)
        }
        state = .uninstalling
        let result = manager.uninstallMarketplacePlugin(at: targetURL)
        switch result {
        case .success:
            let pluginName = selectedEntry?.name ?? entry.id
            refreshInstalledPlugins()
            state = .uninstalled(pluginName: pluginName)
        case .failure(let error):
            state = .error(humanReadable(error))
        }
        return result
    }

    /// Best-effort entry filename for an uninstall /
    /// update when the package is not yet loaded. The
    /// catalogue's `id` matches the entry script's
    /// stem in the existing seed catalogue (`echo` →
    /// `echo.sh`, `battery-watch` → `battery-watch.sh`,
    /// `todays-date` → `todays-date.sh`); when the
    /// catalogue ships an entry with a different
    /// convention the package fetch supplies the real
    /// filename. The fallback to `id + ".sh"` is a
    /// safety net — the real caller always loads the
    /// package first.
    private func preferredEntryFilename(for entry: MarketplaceEntry) -> String {
        if !entry.id.isEmpty {
            return "\(entry.id).sh"
        }
        return "plugin.sh"
    }

    // MARK: - Enable / Disable

    /// Toggle a marketplace plugin's enabled state
    /// without uninstalling it. Looks the plugin up
    /// in `pluginManager.plugins` by the symlink-
    /// resolved folder path (the same key
    /// `FolderPlugin.id` uses, and the same key
    /// `PreferencesStore.disablePlugin(_:)` /
    /// `enablePlugin(_:)` writes) and routes through
    /// `manager.prefs.disablePlugin(_:)` /
    /// `enablePlugin(_:)` directly — those mutate
    /// the `disabledPlugins` set, fire the
    /// `disabledPluginsPublisher`, and trigger
    /// `pluginsDidChange()` on the next main-queue
    /// pass so the `NSStatusItem` is created /
    /// torn down without the view model having to
    /// duplicate any of that logic.
    ///
    /// Why not `PluginManager.disablePlugin(plugin:)`
    /// / `enablePlugin(plugin:)`? Those helpers
    /// delegate to the plugin's own `disable()` /
    /// `enable()`, which — for `FolderPlugin` —
    /// call `prefs.disablePlugin(id)` on
    /// `PreferencesStore.shared`, not the prefs the
    /// manager was wired with. In production both
    /// refs resolve to the same singleton, so the
    /// outcome is identical; routing through
    /// `pluginManager.prefs` instead keeps the
    /// test seam (per-test `UserDefaults(suiteName:)`
    /// backing the manager's `PreferencesStore`)
    /// functional and removes the hidden global
    /// state dependency. Behaviour-wise it is a no-
    /// op: the pref set mutation that flips the
    /// status item is the same call, just from a
    /// different reference.
    ///
    /// No-op when:
    /// - no `pluginManager` is wired (test seam);
    /// - no loaded `Plugin` matches the snapshot's
    ///   folder path (e.g. the user just installed
    ///   the plugin and the loader has not yet
    ///   picked it up; the next
    ///   `refreshInstalledPlugins()` pass will
    ///   surface the toggle in a disabled or
    ///   enabled state per the new preference);
    /// - the `pluginManager`'s `prefs` has been
    ///   replaced since the snapshot was built
    ///   (defensive — the helpers are idempotent,
    ///   so calling them is always safe).
    ///
    /// The method does not change the
    /// `MarketplaceBrowserState` machine — enable
    /// / disable is a regular in-app action that
    /// does not need a banner.
    func toggleEnabled(for snapshot: InstalledPluginSnapshot) {
        guard let manager = pluginManager else {
            os_log("toggleEnabled: no plugin manager available, ignoring",
                   log: Log.plugin, type: .info)
            return
        }
        let targetPath = snapshot.url.resolvingSymlinksInPath().path
        guard manager.plugins.contains(where: { $0.id == targetPath })
        else {
            os_log("toggleEnabled: no loaded plugin for %{public}@, ignoring",
                   log: Log.plugin, type: .info, targetPath)
            return
        }
        if snapshot.isEnabled {
            os_log("toggleEnabled: disabling %{public}@",
                   log: Log.plugin, type: .info, targetPath)
            manager.prefs.disablePlugin(targetPath)
        } else {
            os_log("toggleEnabled: enabling %{public}@",
                   log: Log.plugin, type: .info, targetPath)
            manager.prefs.enablePlugin(targetPath)
        }
        // The `disabledPlugins` `didSet` calls
        // `pluginsDidChange()` which creates /
        // tears down the `NSStatusItem` on the
        // next main-queue pass. Re-scan so the
        // next render of the Installed tab
        // reflects the new state. Cheap and
        // idempotent.
        refreshInstalledPlugins()
    }

    // MARK: - Update

    /// Re-install the currently selected entry in place
    /// through the M3 capability gate. Routes through
    /// `PluginManager.updateMarketplacePluginWithCapabilityGate(...)`,
    /// which runs `gate.verify(manifest:)` up-front so an
    /// update that asks for a new capability the user
    /// has not yet granted is refused with a
    /// `.planFailed(reason:)` error (no re-prompt — the
    /// user has to install the v2 separately and accept
    /// the new capabilities in the prompt sheet).
    ///
    /// Requires a loaded package (the update needs the
    /// manifest's bytes to write back to disk). The
    /// view disables the Update button when no package
    /// is loaded; a programmatic call without a
    /// package returns the same `.notAMarketplacePlugin`
    /// failure shape as the uninstall path.
    @discardableResult
    func updateSelectedWithCapabilityGate() async -> Result<URL, InstallMarketplacePluginError> {
        guard let entry = selectedEntry, let package else {
            return .failure(.planFailed(
                reason: "no catalogue entry is selected or no package is loaded"
            ))
        }
        guard let manager = pluginManager else {
            return .failure(.pluginDirectoryUnavailable)
        }
        state = .updating
        let result = await manager.updateMarketplacePluginWithCapabilityGate(
            entry: entry,
            package: package,
            gate: pluginCapabilityGate
        )
        switch result {
        case .success(let targetURL):
            refreshInstalledPlugins()
            state = .updated(targetURL)
        case .failure(let error):
            state = .error(humanReadable(error))
        }
        return result
    }

    // MARK: - Update detection (catalogue vs. installed)

    /// Outcome of comparing the on-disk manifest's
    /// `version` against the matching catalogue row's
    /// `version`. Drives the "Update available" pill
    /// on the Installed sidebar tab.
    ///
    /// The four cases mirror the four user-visible
    /// states we want to render:
    /// - `.unknown` — the version cannot be
    ///   determined (manifest omits version, catalogue
    ///   has no matching row, or the strings are
    ///   unparseable). The Installed row shows no
    ///   badge.
    /// - `.upToDate` — the on-disk version matches
    ///   the catalogue row's. No badge.
    /// - `.available(catalogueVersion:)` — the
    ///   catalogue is newer. The Installed row shows
    ///   a green "Update" pill that triggers
    ///   `updateSelectedWithCapabilityGate()` on
    ///   tap.
    /// - `.aheadOfCatalogue(catalogueVersion:)` —
    ///   the on-disk version is newer than the
    ///   catalogue. The Installed row shows a neutral
    ///   "Local is newer" hint so a power user is not
    ///   confused by the "no update" silence.
    public enum UpdateAvailability: Equatable {
        case unknown
        case upToDate
        case available(catalogueVersion: MarketplaceVersion)
        case aheadOfCatalogue(catalogueVersion: MarketplaceVersion)
    }

    /// Compare the on-disk manifest's parsed version
    /// against the catalogue row's version. Returns
    /// `.unknown` when either side is unparseable or
    /// the catalogue has no matching entry.
    ///
    /// The match is by `MarketplaceEntry.id` (the
    /// stable slug) with a case-insensitive `name`
    /// fallback — two plugins could share a
    /// human-readable name but the on-disk folder
    /// name is derived from the catalogue `id`
    /// (after sanitisation) by the install path, so
    /// looking up by `id` is the canonical match. The
    /// `name` fallback exists because the v1
    /// uninstall / update flows key the on-disk
    /// URL off the catalogue row's `name` when the
    /// package has not been loaded — keeping the
    /// lookup consistent with those flows means a
    /// row in the Installed tab always agrees with
    /// the "Update" button's destination.
    public func updateAvailability(
        for snapshot: InstalledPluginSnapshot
    ) -> UpdateAvailability {
        guard let installedVersion = snapshot.manifestVersion else {
            return .unknown
        }
        guard let catalogueEntry = entriesByFolder(for: snapshot) else {
            return .unknown
        }
        // The catalogue row's `version` is itself
        // optional (older catalogues ship without
        // the key). Treat missing / empty as
        // unparseable so the badge stays silent
        // rather than guessing.
        guard let rawCatalogueVersion = catalogueEntry.version,
              !rawCatalogueVersion.isEmpty,
              let catalogueVersion = MarketplaceVersion(parsing: rawCatalogueVersion)
        else {
            return .unknown
        }
        if catalogueVersion > installedVersion {
            return .available(catalogueVersion: catalogueVersion)
        }
        if catalogueVersion == installedVersion {
            return .upToDate
        }
        return .aheadOfCatalogue(catalogueVersion: catalogueVersion)
    }

    /// Resolve a `MarketplaceEntry` for an installed
    /// snapshot. Prefers a direct `id` match against
    /// the on-disk folder name (the install path
    /// writes the folder name from the entry
    /// filename's stem); falls back to a
    /// case-insensitive `name` match so a snapshot
    /// from the v1 uninstall path (which keys the
    /// target URL off `entry.name`) still resolves.
    /// Returns `nil` when no row matches — the
    /// caller surfaces `.unknown` in that case.
    private func entriesByFolder(
        for snapshot: InstalledPluginSnapshot
    ) -> MarketplaceEntry? {
        let folderName = snapshot.url.lastPathComponent
        if let match = entries.first(where: { $0.id == folderName }) {
            return match
        }
        return entries.first { entry in
            entry.name.localizedCaseInsensitiveCompare(snapshot.name) == .orderedSame
        }
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
        case .capabilityDeclined(let pluginID, let capabilities):
            // M5 install-gate follow-up: when the user
            // declines the capability prompt the
            // install-gate overload returns
            // `.capabilityDeclined(...)`. The parent
            // switch in `installSelectedWithCapabilityGate(...)`
            // rolls the state back to `.loaded` so the
            // error banner never shows this string —
            // `humanReadable` is still implemented for
            // defensive coverage in case a future caller
            // surfaces the error in a different way.
            return "Permission to install \(pluginID) was declined (\(capabilities.count) capabilities)."
        }
    }

    /// Maps an `UninstallMarketplacePluginError` to a
    /// human-readable string for the error banner. The
    /// messages are tuned for the "Installed" sidebar tab
    /// — `notAMarketplacePlugin` reads as "this is not a
    /// marketplace install" rather than dumping the path
    /// prefix the manager logs.
    private func humanReadable(_ error: UninstallMarketplacePluginError) -> String {
        switch error {
        case .pluginDirectoryUnavailable:
            return "No plugin folder is configured. Set one in Preferences → Plugins."
        case .notAMarketplacePlugin(let reason):
            return "Refusing to uninstall: \(reason)"
        case .notFound(let path):
            return "Plugin is no longer on disk at \(path)."
        case .removeFailed(let reason):
            return "Could not remove plugin: \(reason)"
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

// MarketplaceBrowserSheet.swift
// menubar01 — PluginMarketplace (M5)
//
// SwiftUI sheet that hosts the marketplace browser. Mirrors the
// M2 AI generator sheet's visual style: a header with the entry
// name, scrollable content with monospaced code blocks, a footer
// with action buttons. The window is hosted by an AppKit
// `NSWindowController` (not a SwiftUI `.sheet` modifier) so the
// deployment target can stay on macOS 12 —
// `@Environment(\.dismiss)` is macOS 13+.
//
// The view never holds state of its own; every piece of UI is a
// function of `viewModel.entries`, `viewModel.selectedEntry`,
// `viewModel.package`, and `viewModel.state`. Selection changes
// go through `viewModel.selectEntry(...)` so the package fetch
// happens in one place.
//
// On macOS 12, `NavigationSplitView` is not available — the
// existing `PluginRepositoryView` uses the older `NavigationView`
// + sidebar + detail idiom, which is the same pattern this
// sheet follows.

import SwiftUI

/// Marketplace browser sheet — a sidebar + detail layout with
/// a catalogue list on the left and the selected entry's
/// details (manifest + entry script + Install button) on the
/// right.
///
/// M5 surface:
/// - **Sidebar**: list of catalogue entries showing
///   `name` + `category` + `installCount`. Selection drives
///   `viewModel.selectedEntry` and triggers
///   `viewModel.selectEntry(...)` to fetch the package.
/// - **Detail**: large title (`name`), summary, category
///   subtitle, install count + rating metadata row, the entry
///   script body in a monospaced scrollable view, the manifest
///   JSON in a monospaced scrollable view, and an Install
///   button row (Install / Install overwrite toggle).
/// - **State banner**: ProgressView when `.installing`,
///   success alert when `.installed(URL)`, error banner when
///   `.error(String)`.
@MainActor
struct MarketplaceBrowserSheet: View {
    @StateObject private var viewModel: MarketplaceBrowserViewModel

    /// Backing state for the install-prompt sub-sheet. The
    /// `MarketplaceInstallPromptSheet` is presented as a
    /// SwiftUI `.sheet(...)` modal so it stacks cleanly on top
    /// of this sheet and dismisses independently. Mirrors the
    /// pattern in `AIGeneratorSheet.showingInstallPrompt`.
    @State private var showingInstallPrompt: Bool = false

    /// Cached prompt context built when the user clicks
    /// Install. `nil` until the first Install click; the parent
    /// rebuilds it on every presentation via
    /// `viewModel.requestInstallPrompt(overwriteExisting:)`.
    @State private var pendingPromptContext: MarketplaceInstallPromptContext?

    /// Designated init. Production callers (the menu command)
    /// construct a `MarketplaceBrowserViewModel` with the
    /// default dependencies; tests pass a hand-built VM that
    /// uses a `CapturingMarketplaceClient` and a temp-dir
    /// `PluginManager`. The default-value-parameter pattern
    /// used in `AIGeneratorSheet` is reused here for
    /// consistency.
    init(viewModel: MarketplaceBrowserViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    /// Which sidebar tab is currently active. Defaults to
    /// `.catalogue` so the existing M5 first-cut UX is
    /// preserved. Selected in `sidebarHeader` via the
    /// segmented control. Stored as `@State` on the sheet
    /// rather than on the VM so the choice does not
    /// survive a sheet close — the user re-opens the
    /// browser on the catalogue each time, which is the
    /// "browse, then manage" flow the M5 design calls for.
    @State private var selectedTab: SidebarTab = .catalogue

    /// Identifier for the sidebar tabs. Two cases: the
    /// remote catalogue (the M5 first-cut tab) and the
    /// locally installed plugins (the M5 uninstall /
    /// update follow-up).
    enum SidebarTab: String, CaseIterable, Identifiable {
        case catalogue
        case installed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .catalogue: return "Catalogue"
            case .installed: return "Installed"
            }
        }
    }

    /// Backing state for the uninstall confirmation alert.
    /// The alert is presented from a sidebar row; the
    /// `pendingUninstallSnapshot` carries the row the
    /// user clicked, and the alert's "Uninstall" button
    /// delegates back to the VM. `nil` until the first
    /// click; the parent rebuilds the snapshot on every
    /// presentation.
    @State private var pendingUninstallSnapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot?

    /// Backing state for the update success banner. The
    /// sheet shows a transient banner after a successful
    /// update; the banner reads its message from
    /// `pendingUpdateMessage` and dismisses after a
    /// short delay.
    @State private var pendingUpdateMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 520, idealHeight: 600)
        .task {
            // Load the catalogue once when the sheet first
            // appears. `.task` cancels the in-flight load
            // automatically if the view is dismissed.
            if viewModel.entries.isEmpty && viewModel.state == .idle {
                await viewModel.loadCatalogue()
            }
            // The "Installed" sidebar tab is also driven
            // off the file system. Refresh on every
            // appearance so a previous install / uninstall
            // / update round-trip is reflected without
            // requiring the user to click a refresh
            // button. Cheap (a single directory
            // enumerator) and idempotent.
            viewModel.refreshInstalledPlugins()
        }
        .onChange(of: selectedTab) { _ in
            // Refresh the Installed tab whenever the user
            // switches to it, in case the on-disk state
            // changed while the sheet was on the
            // Catalogue tab. Cheap and idempotent.
            if selectedTab == .installed {
                viewModel.refreshInstalledPlugins()
            }
        }
        .sheet(isPresented: $showingInstallPrompt) {
            if let context = pendingPromptContext {
                MarketplaceInstallPromptSheet(
                    context: context,
                    viewModel: viewModel
                ) { result in
                    // The sub-sheet's completion handler is
                    // the only path back into view-model
                    // state. Toggle the presentation binding
                    // first so the SwiftUI sheet dismisses,
                    // then drop the cached context.
                    showingInstallPrompt = false
                    pendingPromptContext = nil
                    switch result {
                    case .success:
                        // The VM's `.installed(URL)` state
                        // already drives the success alert in
                        // `.alert(...)`; nothing extra to do.
                        break
                    case .failure(let error):
                        switch error {
                        case .noSelectedPackage:
                            // User cancelled — roll the VM
                            // state back so a stale
                            // `.error(reason)` from a previous
                            // attempt does not linger in the
                            // error banner.
                            if case .error = viewModel.state {
                                viewModel.state = .loaded
                            }
                        case .installFailed:
                            // The VM state already carries
                            // `.error(reason)`; the banner
                            // is rendered by `stateBanner`.
                            break
                        }
                    }
                }
            }
        }
        .alert(
            "Plugin installed",
            isPresented: installedAlertBinding,
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                if case .installed(let url) = viewModel.state {
                    Text("Installed to:\n\(url.path)")
                }
            }
        )
        .alert(
            "Uninstall plugin?",
            isPresented: uninstallAlertBinding,
            actions: {
                Button("Uninstall", role: .destructive) {
                    confirmPendingUninstall()
                }
                Button("Cancel", role: .cancel) {
                    pendingUninstallSnapshot = nil
                }
            },
            message: {
                if let snapshot = pendingUninstallSnapshot {
                    Text("Uninstall \(snapshot.name)? This will delete the plugin folder. The plugin will no longer appear in your menu bar.")
                }
            }
        )
        // "Run diagnostics" sub-sheet. Presented when
        // `viewModel.pendingDiagnostics` is non-`nil`
        // (the VM assigns to it from the
        // `runDiagnostics(snapshot:)` round-trip).
        // The sheet renders stdout, stderr, exit
        // code, and timing for the entry script the
        // user just launched, and dismisses back to
        // the browser sheet on Close. The `.sheet`
        // binding is computed from
        // `pendingDiagnostics != nil` (not stored
        // on the VM) so a programmatic
        // `dismissPendingDiagnostics()` call from a
        // test does not need to round-trip through
        // the SwiftUI sheet machinery.
        .sheet(isPresented: diagnosticsSheetBinding) {
            if let pending = viewModel.pendingDiagnostics {
                MarketplaceDiagnosticsSheet(pending: pending) {
                    viewModel.dismissPendingDiagnostics()
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse Marketplace")
                    .font(.title3.weight(.semibold))
                Text("Pick a plugin to install into \(pluginFolderDescription).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var content: some View {
        // `NavigationView` (macOS 11+) is the macOS 12-friendly
        // split-view equivalent. The detail column is implicit
        // when only one root view is present. On macOS 12 the
        // default style renders a 2-column split for
        // List(selection:) + content, which is exactly what we
        // want.
        VStack(spacing: 0) {
            tabPicker
            Divider()
            NavigationView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                // Implicit detail column. SwiftUI's macOS 12
                // `NavigationView` shows only the root view by
                // default; the detail is rendered next to it via
                // the `List(selection:)` binding. We still need a
                // detail body to drive the layout, so the body is
                // appended below.
                detail
            }
        }
    }

    /// Segmented control that drives `selectedTab`. The
    /// control sits between the header and the
    /// split-view body so it is always visible regardless
    /// of which sidebar tab is active. The two-tab shape
    /// mirrors the M5 design ("browse, then manage").
    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(SidebarTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sidebar: some View {
        switch selectedTab {
        case .catalogue:
            catalogueSidebar
        case .installed:
            installedSidebar
        }
    }

    @ViewBuilder
    private var catalogueSidebar: some View {
        if viewModel.state == .loading && viewModel.entries.isEmpty {
            VStack {
                ProgressView()
                Text("Loading catalogue…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selectionBinding) {
                ForEach(viewModel.entries) { entry in
                    sidebarRow(for: entry)
                        .tag(entry.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var installedSidebar: some View {
        if viewModel.installedPlugins.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No marketplace plugins installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Browse the Catalogue tab to install your first plugin.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            List(selection: installedSelectionBinding) {
                ForEach(viewModel.installedPlugins) { snapshot in
                    installedRow(for: snapshot)
                        .tag(snapshot.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func installedRow(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(snapshot.name)
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
                if let version = snapshot.version {
                    Text(version)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                updateBadge(for: snapshot)
            }
            HStack(spacing: 6) {
                Text(snapshot.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let lastUpdated = snapshot.lastUpdated {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(lastUpdated, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                // Per-row "View source" button. Opens
                // the on-disk `manifest.json` for the
                // plugin in the user's default JSON
                // editor via
                // `viewModel.viewSource(snapshot:)`. The
                // button is intentionally icon-only at
                // `.mini` control size so it does not
                // push the Enable / Disable toggle off
                // the right edge of the sidebar on long
                // folder names; the tooltip spells out
                // the action.
                Button {
                    viewModel.viewSource(snapshot: snapshot)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("View manifest.json for \(snapshot.name)")
                // Per-row "Open data folder" button.
                // Reveals the per-plugin data directory
                // (the same `<AppShared.dataDirectory>/<id>/`
                // location the running plugin receives
                // as `$MENUBAR01_PLUGIN_DATA_PATH`) in
                // Finder via
                // `viewModel.openDataFolder(snapshot:)`.
                // The directory is created on-demand if
                // the user has not yet run the plugin.
                // Placed immediately after the "View
                // source" button so the two icon-only
                // actions cluster on the trailing edge
                // of the row. Same `.mini` /
                // `.borderless` shape as the sibling
                // button to keep the row compact and
                // the toggle on the right edge.
                Button {
                    viewModel.openDataFolder(snapshot: snapshot)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Open data folder for \(snapshot.name)")
                // Per-row "Run diagnostics" button.
                // Triggers
                // `viewModel.runDiagnostics(snapshot:)`,
                // which launches the entry script via
                // `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
                // and surfaces stdout / stderr / exit
                // code / timing in a separate modal
                // sheet. The icon is a SF Symbols
                // `stethoscope` so the user can tell it
                // apart from the sibling "View source"
                // and "Open data folder" actions at a
                // glance. The button is disabled while
                // a diagnostics round-trip is in flight
                // (mirroring the "Uninstall" /
                // "Update" disable pattern) so the user
                // cannot double-click while a slow
                // entry script is still running. Same
                // `.mini` / `.borderless` shape as the
                // sibling buttons to keep the row
                // compact and the toggle on the right
                // edge.
                Button {
                    viewModel.runDiagnostics(snapshot: snapshot)
                } label: {
                    if viewModel.isRunningDiagnostics {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "stethoscope")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(viewModel.isRunningDiagnostics)
                .help("Run diagnostics for \(snapshot.name)")
                // Per-row enable / disable toggle. Bound
                // to a Binding<Bool> that maps through
                // `viewModel.toggleEnabled(for:)` so the
                // SwiftUI `Toggle` can stay in lockstep
                // with the `PreferencesStore.disabledPlugins`
                // set without the parent sheet having to
                // re-render every time. The toggle is
                // placed on its own trailing line so a
                // long folder name never pushes it off
                // the right edge of the sidebar.
                Toggle(
                    isOn: installedRowEnabledBinding(for: snapshot)
                ) {
                    Text(snapshot.isEnabled ? "Enabled" : "Disabled")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(snapshot.isEnabled
                      ? "Disable \(snapshot.name) without uninstalling"
                      : "Enable \(snapshot.name)")
            }
        }
        .padding(.vertical, 2)
        // Dim the row when the plugin is disabled so
        // the user can scan the Installed tab and
        // tell at a glance which plugins are
        // currently active. The toggle stays
        // interactive even when dimmed (macOS
        // toggles do not inherit the opacity
        // modifier) so the user can re-enable
        // without an extra click.
        .opacity(snapshot.isEnabled ? 1.0 : 0.55)
    }

    /// `Binding<Bool>` for the Installed tab's per-row
    /// `Toggle`. Reads the snapshot's current
    /// `isEnabled` so SwiftUI's toggle stays
    /// accurate on every render, and writes
    /// route through `viewModel.toggleEnabled(for:)`
    /// which delegates to the existing
    /// `PluginManager.enablePlugin(plugin:)` /
    /// `disablePlugin(plugin:)` helpers. The
    /// `set:` side is intentionally not awaited —
    /// `toggleEnabled` is synchronous and the next
    /// `refreshInstalledPlugins()` re-populates the
    /// list before SwiftUI re-renders.
    private func installedRowEnabledBinding(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> Binding<Bool> {
        Binding(
            get: { snapshot.isEnabled },
            set: { _ in
                viewModel.toggleEnabled(for: snapshot)
            }
        )
    }

    /// Render the "Update available" / "Local is newer" /
    /// nothing pill on the Installed sidebar row. The badge
    /// reflects `viewModel.updateAvailability(for:)` so the
    /// sidebar stays in sync with the catalogue refresh
    /// without manual re-rendering. When the badge reflects
    /// an available update it is wired to
    /// `runUpdateForInstalledSnapshot(snapshot)` so a
    /// single tap on the pill kicks off the update flow
    /// (the pill acts as a shortcut for "click the row +
    /// click Update").
    @ViewBuilder
    private func updateBadge(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> some View {
        switch viewModel.updateAvailability(for: snapshot) {
        case .unknown, .upToDate:
            EmptyView()
        case .available(let catalogueVersion):
            Button {
                Task { await runUpdateForInstalledSnapshot(snapshot) }
            } label: {
                let installed = snapshot.version ?? "?"
                updatePill(
                    text: "\(installed) → \(catalogueVersion.displayString)",
                    systemImage: "arrow.up.circle.fill",
                    tint: .green
                )
            }
            .buttonStyle(.plain)
            .help("Update to \(catalogueVersion.displayString)")
            .disabled(viewModel.isUpdating)
        case .aheadOfCatalogue:
            updatePill(
                text: "Local is newer",
                systemImage: "checkmark.seal.fill",
                tint: .blue
            )
        }
    }

    /// Small pill view used for the "Update available" /
    /// "Local is newer" badges. Kept as a private helper
    /// so both `.available(...)` and
    /// `.aheadOfCatalogue(...)` cases share the same
    /// visual style.
    private func updatePill(
        text: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.15))
        .clipShape(Capsule())
    }

    private func sidebarRow(for entry: MarketplaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
                Text("\(entry.installCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.category)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case .catalogue:
            catalogueDetail
        case .installed:
            installedDetail
        }
    }

    @ViewBuilder
    private var catalogueDetail: some View {
        if let entry = viewModel.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(for: entry)
                    metadataRow(for: entry)
                    entryScriptSection(for: entry)
                    manifestSection
                    installControls(for: entry)
                    stateBanner
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Text("Select a plugin")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Pick a catalogue entry on the left to see its manifest and entry script.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var installedDetail: some View {
        if let snapshot = currentInstalledSnapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    installedDetailHeader(for: snapshot)
                    installedMetadataRow(for: snapshot)
                    installedControls(for: snapshot)
                    stateBanner
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Text("Select an installed plugin")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Pick a marketplace plugin on the left to see its details and manage it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func installedDetailHeader(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.name)
                .font(.title2.weight(.semibold))
            Text(snapshot.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func installedMetadataRow(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> some View {
        HStack(spacing: 16) {
            if let version = snapshot.version {
                Label("Version \(version)", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastUpdated = snapshot.lastUpdated {
                Label("Updated \(lastUpdated, style: .date)", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            updateDetailLabel(for: snapshot)
        }
    }

    /// Detail-pane counterpart to `updateBadge(for:)`. When
    /// a catalogue-side update is available, the metadata
    /// row surfaces a "v1.0.0 → v1.2.3" arrow so the user
    /// can read the version delta at a glance. The
    /// "Update" button below still drives the actual
    /// install — the label is read-only.
    @ViewBuilder
    private func updateDetailLabel(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> some View {
        switch viewModel.updateAvailability(for: snapshot) {
        case .available(let catalogueVersion):
            let installed = snapshot.version ?? "?"
            Label("\(installed) → \(catalogueVersion.displayString)",
                  systemImage: "arrow.up.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .aheadOfCatalogue:
            Label("Local is newer than catalogue", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        case .unknown, .upToDate:
            EmptyView()
        }
    }

    @ViewBuilder
    private func installedControls(
        for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                // Stage the snapshot and present the
                // confirmation alert via
                // `uninstallAlertBinding`. The alert
                // delegates back to
                // `confirmPendingUninstall()` on
                // confirmation.
                pendingUninstallSnapshot = snapshot
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
            .disabled(viewModel.isUninstalling)

            Button {
                Task { await runUpdateForInstalledSnapshot(snapshot) }
            } label: {
                Label("Update", systemImage: "arrow.down.circle")
            }
            .disabled(viewModel.isUpdating || !canUpdate(snapshot: snapshot))

            if viewModel.isUninstalling {
                ProgressView()
                    .controlSize(.small)
                Text("Uninstalling…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if viewModel.isUpdating {
                ProgressView()
                    .controlSize(.small)
                Text("Updating…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Returns `true` when the Installed tab's "Update"
    /// button can run. The update needs the user to
    /// have selected a matching catalogue row and a
    /// loaded package — when the snapshot's folder
    /// name is not in the catalogue (e.g. an install
    /// from a previous build whose entry was retired),
    /// the update is unavailable and the button is
    /// disabled.
    private func canUpdate(
        snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) -> Bool {
        guard let _ = viewModel.selectedEntry, viewModel.package != nil else {
            // No catalogue row is selected — try to
            // find a matching entry by folder name and
            // load it. The button stays disabled until
            // the user clicks the catalogue row, so
            // the v1 UX is "click the row, then click
            // Update".
            return false
        }
        return true
    }

    /// Run the update flow for the given Installed tab
    /// snapshot. Selects the matching catalogue entry
    /// (if any), fetches the package, then runs
    /// `viewModel.updateSelectedWithCapabilityGate()`.
    /// The selection is reset to the user's prior
    /// state on completion so the catalogue tab is
    /// not unexpectedly hijacked.
    private func runUpdateForInstalledSnapshot(
        _ snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
    ) async {
        // If the catalogue row is not currently
        // selected, look it up by folder name and
        // fetch the package. This is a best-effort
        // affordance: the Installed tab's "Update"
        // button does its own package fetch so the
        // user does not have to flip back to the
        // Catalogue tab and click the entry.
        if viewModel.selectedEntry?.name != snapshot.name {
            if let entry = viewModel.entries.first(where: { $0.name == snapshot.name }) {
                await viewModel.selectEntry(entry)
            } else {
                // No matching catalogue row — surface
                // an error banner via the state
                // machine.
                viewModel.state = .error(
                    "No matching catalogue entry for \(snapshot.name); the plugin may have been retired."
                )
                return
            }
        }
        guard viewModel.package != nil else {
            viewModel.state = .error("Package fetch failed for \(snapshot.name); please retry.")
            return
        }
        let result = await viewModel.updateSelectedWithCapabilityGate()
        if case .success(let url) = result {
            pendingUpdateMessage = "Updated \(snapshot.name) at \(url.path)"
        }
    }

    private func detailHeader(for entry: MarketplaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(.title2.weight(.semibold))
            Text(entry.summary)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(entry.category)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func metadataRow(for entry: MarketplaceEntry) -> some View {
        HStack(spacing: 16) {
            Label("\(entry.installCount) installs", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(ratingString(for: entry.rating), systemImage: "star")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let signedBy = entry.signedBy {
                Label("Signed by \(signedBy)", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryScriptSection(for entry: MarketplaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Entry script — \(entryFilenameForSelection)")
                .font(.headline)
            if let package = viewModel.package {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(package.entryScript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Loading entry script…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("manifest.json")
                .font(.headline)
            if let json = viewModel.manifestJSON {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("(manifest is not yet encodable)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func installControls(for _: MarketplaceEntry) -> some View {
        HStack(spacing: 12) {
            Button("Install") {
                // M5 install-prompt: opening the prompt sheet
                // here, not in the view model. The sub-sheet
                // reads `viewModel.installPromptCapabilities`
                // and `viewModel.installPromptIsPreApproved`,
                // grants the user-enabled capabilities via
                // `gate.grant(_:for:)`, and then calls
                // `viewModel._installSelectedAfterGrants(...)`
                // for the actual install. Mirrors the
                // `AIGeneratorSheet` "Save to Plugin Folder"
                // button flow.
                presentInstallPrompt(overwriteExisting: false)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canInstall)

            Button("Install (overwrite)") {
                presentInstallPrompt(overwriteExisting: true)
            }
            .disabled(!canInstall)

            if viewModel.isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Build a fresh `MarketplaceInstallPromptContext` and
    /// present the install-prompt sub-sheet. No-op when no
    /// package is loaded (the Install button is already
    /// disabled in that state but a programmatic call would
    /// also be a defensive no-op).
    private func presentInstallPrompt(overwriteExisting: Bool) {
        guard let context = viewModel.requestInstallPrompt(
            overwriteExisting: overwriteExisting
        ) else { return }
        pendingPromptContext = context
        showingInstallPrompt = true
    }

    @ViewBuilder
    private var stateBanner: some View {
        if case .error(let reason) = viewModel.state {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Operation failed")
                        .font(.subheadline.weight(.semibold))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if case .uninstalled(let pluginName) = viewModel.state {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Uninstalled \(pluginName).")
                    .font(.subheadline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if case .updated(let url) = viewModel.state {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updated to latest version.")
                        .font(.subheadline.weight(.semibold))
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let message = pendingUpdateMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(message)
                    .font(.subheadline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close", role: .cancel) {
                // M2 / M5 sheet is hosted in a standalone
                // `NSWindow` (not a SwiftUI `.sheet`), so
                // there is no `\.dismiss` environment to
                // call. Close the key window instead. The
                // `MarketplaceBrowserMenuCommand` keeps the
                // window controller alive for the next click.
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Bindings

    /// `List(selection:)` binding that pipes the user's
    /// sidebar click into the VM. SwiftUI requires
    /// `Hashable` selection keys; `MarketplaceEntry.id` is the
    /// natural choice (String).
    private var selectionBinding: Binding<MarketplaceEntry.ID?> {
        Binding(
            get: { viewModel.selectedEntry?.id },
            set: { newID in
                guard let newID,
                      let entry = viewModel.entries.first(where: { $0.id == newID })
                else { return }
                Task { await viewModel.selectEntry(entry) }
            }
        )
    }

    /// `Alert(isPresented:)` binding. Reads `viewModel.state`
    /// to surface the success alert. The alert's "is presented"
    /// flag is computed from the case, not stored on the VM —
    /// the VM only carries the `URL` payload.
    private var installedAlertBinding: Binding<Bool> {
        Binding(
            get: {
                if case .installed = viewModel.state { return true }
                return false
            },
            set: { presented in
                if !presented {
                    // Dismiss the alert by moving the state
                    // back to a non-installed case. We pick
                    // `.loaded` (we still have a catalogue)
                    // rather than `.idle` to preserve the
                    // user's selection for follow-up actions
                    // such as "Install (overwrite)".
                    viewModel.state = .loaded
                }
            }
        )
    }

    /// `Alert(isPresented:)` binding for the uninstall
    /// confirmation prompt. The alert is presented when
    /// `pendingUninstallSnapshot` is non-`nil` and the
    /// `Uninstall` button on the alert delegates back to
    /// `confirmPendingUninstall()`. Setting the binding
    /// to `false` (the alert's "Cancel" button) clears
    /// the staged snapshot.
    private var uninstallAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingUninstallSnapshot != nil },
            set: { presented in
                if !presented {
                    pendingUninstallSnapshot = nil
                }
            }
        )
    }

    /// `Sheet(isPresented:)` binding for the "Run
    /// diagnostics" sub-sheet. The sheet is presented
    /// when `viewModel.pendingDiagnostics` is non-`nil`
    /// and dismissed via the sheet's Close button (which
    /// calls `viewModel.dismissPendingDiagnostics()`).
    /// The binding's `set: { false }` path is a
    /// no-op — the dismiss is driven by the VM so a
    /// programmatic test can clear the state without
    /// racing the SwiftUI sheet machinery.
    private var diagnosticsSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDiagnostics != nil },
            set: { presented in
                if !presented {
                    viewModel.dismissPendingDiagnostics()
                }
            }
        )
    }

    /// `List(selection:)` binding for the "Installed"
    /// sidebar tab. We do not store the selected
    /// snapshot on the VM (the snapshot is read off
    /// `viewModel.installedPlugins` on every render);
    /// the binding keeps the user's selection in
    /// `@State` on the sheet so a switch back to the
    /// Catalogue tab does not clear it. The selection
    /// is keyed on `InstalledPluginSnapshot.id` (the
    /// stringified absolute URL).
    @State private var installedSelectionID: String?

    private var installedSelectionBinding: Binding<String?> {
        Binding(
            get: { installedSelectionID },
            set: { newID in
                installedSelectionID = newID
            }
        )
    }

    /// Resolves the `installedSelectionID` to a
    /// snapshot from `viewModel.installedPlugins`.
    /// Returns `nil` when no row is selected or when
    /// the selected id no longer matches a snapshot
    /// (e.g. after a refresh removed the row).
    private var currentInstalledSnapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot? {
        guard let id = installedSelectionID else { return nil }
        return viewModel.installedPlugins.first(where: { $0.id == id })
    }

    /// Confirm the pending uninstall alert. Sets the
    /// VM's `selectedEntry` from the staged snapshot
    /// (so the VM's `uninstallSelected()` can derive
    /// the on-disk URL), then runs the uninstall and
    /// rolls the selection state back to `.loaded` so
    /// the Installed tab refreshes.
    private func confirmPendingUninstall() {
        guard let snapshot = pendingUninstallSnapshot else { return }
        pendingUninstallSnapshot = nil
        // Try to set `selectedEntry` to a matching
        // catalogue row so the VM's
        // `uninstallSelected()` can find the on-disk
        // URL. If no catalogue row matches, the
        // VM still works — the URL is derived from
        // the entry filename and the install
        // directory, and the marketplace uninstall
        // path does not require a catalogue row.
        if let entry = viewModel.entries.first(where: { $0.name == snapshot.name }) {
            viewModel.selectedEntry = entry
        }
        viewModel.uninstallSelected()
        // After uninstall, the Installed tab is
        // refreshed by the VM; clear the local
        // selection so the detail column falls back
        // to the "Select an installed plugin"
        // placeholder.
        installedSelectionID = nil
    }

    // MARK: - Derived State

    /// Install buttons are enabled when we have both a selected
    /// entry and a loaded package, and we are not currently in
    /// the middle of an install round-trip.
    private var canInstall: Bool {
        viewModel.selectedEntry != nil
            && viewModel.package != nil
            && !viewModel.isInstalling
    }

    /// The entry filename for the currently loaded package, with
    /// a sensible fallback while the package is still loading.
    private var entryFilenameForSelection: String {
        viewModel.package?.entryFilename ?? "—"
    }

    /// Pretty-printed location of the user's Plugin Folder for
    /// the header subtitle. Falls back to a generic label when
    /// the manager / directory is not available (e.g. in a
    /// test that did not wire a `PluginManager`).
    private var pluginFolderDescription: String {
        guard let url = viewModel.pluginManager?.pluginDirectoryURL else {
            return "your Plugin Folder"
        }
        return url.path
    }

    /// Format a 0.0 – 5.0 rating as "4.5 ★" for the metadata row.
    private func ratingString(for rating: Double) -> String {
        let clamped = max(0, min(5, rating))
        return String(format: "%.1f ★", clamped)
    }
}

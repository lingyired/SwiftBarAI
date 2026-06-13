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

    private var sidebar: some View {
        Group {
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
                Task { await viewModel.installSelected(overwriteExisting: false) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canInstall)

            Button("Install (overwrite)") {
                Task { await viewModel.installSelected(overwriteExisting: true) }
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

    @ViewBuilder
    private var stateBanner: some View {
        if case .error(let reason) = viewModel.state {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install failed")
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

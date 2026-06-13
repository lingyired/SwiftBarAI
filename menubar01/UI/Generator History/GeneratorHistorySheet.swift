// GeneratorHistorySheet.swift
// menubar01 — AI Plugin Generator (M5 history UI)
//
// SwiftUI sheet that lists past AI generator runs and lets the user
// inspect, re-generate, or delete them. Backed by
// `GeneratorHistoryViewModel`, which in turn calls into the
// `AIGeneratorHistoryStore` data layer. The sheet is macOS 12
// compatible (uses `NavigationView`, not `NavigationStack`).
//
// Shape:
//   ┌──────────────────────────────────────────────┐
//   │ Header: "Generator History" + subtitle       │
//   ├─────────────────┬────────────────────────────┤
//   │ Sidebar List    │ Detail pane                │
//   │ (entries,       │ (selected entry metadata,  │
//   │  newest first)  │  manifest JSON, entry      │
//   │                 │  script, raw request)      │
//   ├─────────────────┴────────────────────────────┤
//   │ State banner / error / ProgressView         │
//   ├──────────────────────────────────────────────┤
//   │ Footer: Close / Re-generate / Delete /       │
//   │         Delete All                           │
//   └──────────────────────────────────────────────┘

import SwiftUI

@MainActor
struct GeneratorHistorySheet: View {

    /// The view model that owns the data layer round-trip.
    @StateObject private var viewModel: GeneratorHistoryViewModel

    /// Confirmation prompts. Each is gated by an `@State` so the
    /// destructive buttons don't trigger an `NSAlert` on every
    /// keystroke.
    @State private var showingDeleteConfirmation: Bool = false
    @State private var showingDeleteAllConfirmation: Bool = false

    /// Re-generate callback. Wired by the menu command so the
    /// "Re-generate" button can re-present the M2 sheet with the
    /// selected entry's request pre-filled. The full re-generate
    /// plumbing (open the sheet, swap in the request, hit
    /// Generate) is a follow-up — v1 just closes the history
    /// sheet and opens the M2 sheet, which the user drives from
    /// there.
    var onRegenerate: ((AIGeneratorHistoryEntry) -> Void)?

    init(
        viewModel: GeneratorHistoryViewModel? = nil,
        onRegenerate: ((AIGeneratorHistoryEntry) -> Void)? = nil
    ) {
        // Default-parameter expressions run in a non-isolated context
        // in Swift 5.7+, so we cannot call the @MainActor-isolated
        // `GeneratorHistoryViewModel.init` from a default. We work
        // around the SE-0376 / Swift 6.0 default-actor-isolation
        // rules by branching inside the `View.init` body, which is
        // itself @MainActor (the `View` protocol carries that
        // isolation).
        self._viewModel = StateObject(
            wrappedValue: viewModel ?? GeneratorHistoryViewModel()
        )
        self.onRegenerate = onRegenerate
    }

    var body: some View {
        NavigationView {
            content
                .frame(minWidth: 820, idealWidth: 880, minHeight: 540, idealHeight: 600)
        }
        .task {
            // Load on first appearance; the store is synchronous so
            // the await is just the suspension point.
            await viewModel.reload()
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let selected = viewModel.selectedEntry {
                Text("Removes the entry \"\(selected.request.prefix(60))\" from the on-disk history. The generated plugin folder is not touched.")
            } else {
                Text("No entry selected.")
            }
        }
        .confirmationDialog(
            "Delete every entry?",
            isPresented: $showingDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Task { await viewModel.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes every recorded AI generator run from disk. This cannot be undone.")
        }
    }

    // MARK: - Top-level layout

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            stateBanner
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Generator History")
                    .font(.title3.weight(.semibold))
                Text("Every successful AI plugin generator run is recorded here. Inspect, re-generate, or delete past results.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // M5 history filter picker. Pinned to the header so
            // it stays visible while the sidebar list scrolls.
            // Driven by a `Menu` (not a `Picker`) because the
            // available options are derived from the entries
            // themselves, and `Menu` makes the dynamic set of
            // "by provider" / "by host" options easier to
            // group under dividers than `Picker`'s flat
            // `ForEach` would.
            filterMenu
                .disabled(viewModel.entries.isEmpty || isMutating)
            // M5 history "Delete All" sits in the top-of-sheet
            // header (not the footer) so it stays reachable
            // when the user has scrolled the sidebar to the
            // bottom and the footer is off-screen. The footer
            // also exposes a "Delete All" so the two
            // surfaces (top / footer) both have a one-click
            // destructive action without forcing the user to
            // scroll. Both wire into the same confirmation
            // dialog so the destructive UX is consistent.
            Button(role: .destructive) {
                showingDeleteAllConfirmation = true
            } label: {
                Label("Delete All", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(viewModel.entries.isEmpty || isMutating)
        }
        .padding(20)
    }

    /// "Filter:" picker. The default item is "All" (resets
    /// `viewModel.filter` to `.all`); the next section groups
    /// one "Provider: <name>" item per distinct
    /// `entry.providerName` actually present, and the final
    /// section groups one "Host: <host>" item per distinct
    /// `entry.endpointHost` actually present. The visible
    /// summary line ("3 of 12") sits beneath the menu so the
    /// user can see how many entries the current filter
    /// admits without counting rows in the sidebar.
    @ViewBuilder
    private var filterMenu: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Menu {
                Button {
                    viewModel.filter = .all
                } label: {
                    Label("All", systemImage: viewModel.filter == .all ? "checkmark" : "")
                }
                if !viewModel.availableProviderNames.isEmpty {
                    Divider()
                    ForEach(viewModel.availableProviderNames, id: \.self) { name in
                        let active: Bool = viewModel.filter == .provider(name)
                        Button {
                            viewModel.filter = .provider(name)
                        } label: {
                            Label("Provider: \(name)", systemImage: active ? "checkmark" : "")
                        }
                    }
                }
                if !viewModel.availableEndpointHosts.isEmpty {
                    Divider()
                    ForEach(viewModel.availableEndpointHosts, id: \.self) { host in
                        let active: Bool = viewModel.filter == .host(host)
                        Button {
                            viewModel.filter = .host(host)
                        } label: {
                            Label("Host: \(host)", systemImage: active ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(filterMenuTitle)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text("\(viewModel.filteredCount) of \(viewModel.entries.count)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    /// Visible label for the filter menu. Pinned to "All" when
    /// `filter == .all`, otherwise echoes the active provider /
    /// host so the user can see at a glance which filter is in
    /// effect (matters when the menu is collapsed).
    private var filterMenuTitle: String {
        switch viewModel.filter {
        case .all:
            return "Filter: All"
        case .provider(let name):
            return "Filter: \(name)"
        case .host(let host):
            return "Filter: \(host)"
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if viewModel.entries.isEmpty {
            VStack {
                Spacer()
                if case .loading = viewModel.state {
                    ProgressView()
                    Text("Loading…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                } else {
                    Text("No history yet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("Generate a plugin to record an entry here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredEntries.isEmpty {
            // The user has narrowed the sidebar to a filter
            // (e.g. "Provider: Remote") that no longer
            // matches any entries. Show a small empty-state
            // rather than an empty list.
            VStack(spacing: 8) {
                Spacer()
                Text("No entries match this filter.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("Show all") {
                    viewModel.filter = .all
                }
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $viewModel.selectedPromptId) {
                ForEach(viewModel.filteredEntries) { entry in
                    row(for: entry)
                        .tag(entry.promptId)
                        // M5 history per-row delete: the
                        // context menu is the natural fit
                        // for a `.sidebar` `List` style
                        // (`.swipeActions` is unreliable on
                        // macOS sidebars), and mirrors the
                        // standard "right-click → Delete"
                        // pattern Finder / Mail use for
                        // the same operation.
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { await viewModel.deleteEntry(promptId: entry.promptId) }
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func row(for entry: AIGeneratorHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.promptId)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.request.prefix(60) + (entry.request.count > 60 ? "…" : ""))
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let entry = viewModel.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailHeader(for: entry)
                    Divider()
                    generatedBySection(for: entry)
                    Divider()
                    requestSection(for: entry)
                    Divider()
                    manifestSection(for: entry)
                    Divider()
                    entryScriptSection(for: entry)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text("Select an entry to inspect its manifest and entry script.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(for entry: AIGeneratorHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("promptId")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(entry.promptId)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("createdAt")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(entry.createdAt.formatted(date: .complete, time: .standard))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("model")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(entry.model)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    // "Generated by `<model>` at `<host>`" summary line. Renders a
    // small secondary-text section between the metadata header and
    // the request body. `endpointHost` falls back to
    // "local model" for Mock / Local / LocalEcho runs (and for any
    // pre-M5+ entry whose `response.json` predates the field).
    private func generatedBySection(for entry: AIGeneratorHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Generated by")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("Model")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(entry.model)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("From")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(entry.endpointHost ?? "local model")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func requestSection(for entry: AIGeneratorHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Request")
                .font(.headline)
            Text(entry.request)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private func manifestSection(for entry: AIGeneratorHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("manifest.json")
                .font(.headline)
            if let json = manifestJSON(for: entry) {
                ScrollView {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("(manifest is not encodable)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func entryScriptSection(for entry: AIGeneratorHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Entry script")
                .font(.headline)
            ScrollView {
                Text(entry.plugin.entryScript)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - State banner

    @ViewBuilder
    private var stateBanner: some View {
        switch viewModel.state {
        case .deleting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        case .error(let reason):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("History operation failed")
                        .font(.subheadline.weight(.semibold))
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Dismiss") {
                    viewModel.state = viewModel.entries.isEmpty ? .idle : .loaded
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
        case .loading, .loaded, .idle:
            EmptyView()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Delete All", role: .destructive) {
                showingDeleteAllConfirmation = true
            }
            .disabled(viewModel.entries.isEmpty || isMutating)
            Spacer()
            Button("Delete") {
                showingDeleteConfirmation = true
            }
            .disabled(viewModel.selectedEntry == nil || isMutating)
            Button("Re-generate") {
                if let entry = viewModel.selectedEntry {
                    onRegenerate?(entry)
                }
            }
            .disabled(viewModel.selectedEntry == nil || isMutating)
            // M5 history follow-up: surface the audit log as a
            // zip so the user can share a single run with
            // support. The button opens an `NSSavePanel` and
            // hands the chosen destination to `exportEntry(_:)`,
            // which shells out to `/usr/bin/zip` (macOS 12+
            // ships with it). Disabled when the selected entry's
            // directory does not exist on disk (a stale entry
            // from a deleted store, for example).
            Button("Export…") {
                if let entry = viewModel.selectedEntry {
                    exportEntry(entry)
                }
            }
            .disabled(viewModel.selectedEntry == nil || isMutating)
            Button("Close", action: closeWindow)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// `true` while a destructive action is in flight. Disables
    /// the buttons so the user cannot double-fire.
    private var isMutating: Bool {
        if case .deleting = viewModel.state { return true }
        return false
    }

    // MARK: - Actions

    /// Close the key window. Mirrors the M2 `AIGeneratorSheet`
    /// pattern: the sheet is hosted in a standalone `NSWindow`,
    /// not a SwiftUI `.sheet`, so there is no `\.dismiss`
    /// environment to call.
    private func closeWindow() {
        NSApp.keyWindow?.close()
    }

    /// Bundle the selected entry's on-disk audit log into a
    /// `.zip` and save it to the user-chosen destination. The
    /// `AIGeneratorHistoryStore` writes one subdirectory per
    /// `promptId` containing `request.txt`, `response.json`, and
    /// (when populated) `menu.json` — we zip the whole
    /// subdirectory so the bundle is self-describing without
    /// having to re-derive the on-disk shape. The actual
    /// `/usr/bin/zip` invocation lives in
    /// `GeneratorHistoryExporter` so the test bundle can drive
    /// the same code path without an `NSSavePanel`.
    private func exportEntry(_ entry: AIGeneratorHistoryEntry) {
        switch GeneratorHistoryExporter.exportEntry(entry, store: viewModel.store) {
        case .success(let destination):
            // The exporter already calls
            // `NSWorkspace.shared.activateFileViewerSelecting([destination])`
            // on success, so Finder pops up with the new zip
            // highlighted. Surface that in the alert copy so the
            // user knows what to look for. We use the
            // `lastPathComponent` (the file name) rather than the
            // full path because the alert already says where the
            // file is — "Finder has been opened to the file" —
            // and a full path in the same line is noise.
            showAlert(
                title: "Exported",
                message: "Exported to \(destination.lastPathComponent). Finder has been opened to the file."
            )
        case .cancelled:
            break
        case .missingDirectory(let reason):
            showAlert(
                title: "Export failed",
                message: "The entry \"\(entry.promptId)\" has no on-disk directory at \(reason)."
            )
        case .zipFailed(let reason), .launchFailed(let reason):
            showAlert(title: "Export failed", message: reason)
        }
    }

    /// Surface a success / failure alert on the main run loop.
    /// The sheet is hosted in a standalone `NSWindow`, so an
    /// `NSAlert` is the right tool — it stacks on top of the
    /// key window and the user can dismiss with Return / Escape.
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title == "Exported" ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Pretty-printed JSON body of `entry.plugin.manifest`. Mirrors
    /// the `EncodedManifest` adapter in `AIGeneratorViewModel` —
    /// the manifest is `internal`, so the view reaches it through
    /// this tiny adapter that re-uses the same trick.
    private func manifestJSON(for entry: AIGeneratorHistoryEntry) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(EncodedManifest(manifest: entry.plugin.manifest)),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }
}

// MARK: - Manifest Encoding Helper

/// Wrapper that exposes the `internal` `manifest` field on
/// `GeneratedPlugin` to `JSONEncoder`. `GeneratedPlugin.manifest` is
/// `internal` to keep `PluginManifest`'s `internal` access level from
/// leaking through the public type. The view lives in the same
/// module so it can reach the field directly through this tiny
/// adapter (mirrors the one in `AIGeneratorViewModel`).
private struct EncodedManifest: Encodable {
    let manifest: PluginManifest
    func encode(to encoder: Encoder) throws {
        try manifest.encode(to: encoder)
    }
}

// GeneratorHistoryViewModel.swift
// menubar01 — AI Plugin Generator (M5 history UI)
//
// View model backing `GeneratorHistorySheet`. Drives the SwiftUI
// sheet through `@Published` properties and is `@MainActor` so every
// mutation lands on the main thread without an extra hop. The
// M5 data layer (`AIGeneratorHistoryStore` +
// `AIGeneratorHistoryEntry`) owns the on-disk format; this view
// model is a thin async wrapper that gives the sheet a stable
// `ObservableObject` contract.
//
// State machine:
//   .idle      — initial state, nothing loaded yet.
//   .loading   — `reload()` is in flight.
//   .loaded    — `entries` is up-to-date.
//   .deleting  — `deleteSelected()` / `deleteEntry(promptId:)` /
//                `deleteAll()` in flight.
//   .error(M)  — last operation failed; the sheet shows the banner.

import Foundation
import os

@MainActor
final class GeneratorHistoryViewModel: ObservableObject {

    // MARK: - Published State

    /// Every persisted entry, newest first (mirrors the store's
    /// own sort order). Empty before the first `reload()` finishes
    /// or after a successful `deleteAll()`.
    @Published private(set) var entries: [AIGeneratorHistoryEntry] = []

    /// Current state of the view model. Drives the sheet's
    /// ProgressView and error banner. Internal setter is `internal`
    /// so the SwiftUI sheet can clear `.error(...)` on a fresh
    /// `reload()` call without exposing a public write API.
    @Published internal(set) var state: HistoryState = .idle

    /// `promptId` of the entry the user has selected in the
    /// sidebar. `nil` when the user has not picked a row yet.
    /// SwiftUI's `List(selection:)` requires `Hashable`, and
    /// `AIGeneratorHistoryEntry` carries a non-`Hashable`
    /// `GeneratedPlugin`, so we track the selection by `promptId`
    /// and let the sheet derive the entry via `selectedEntry`.
    /// Driving the picker through this `String?` keeps the
    /// view-model state machine small and avoids forcing
    /// `GeneratedPlugin` / `PluginManifest` to conform to
    /// `Hashable` purely for SwiftUI plumbing.
    @Published var selectedPromptId: String?

    /// The entry the user has selected in the sidebar. Derived
    /// from `selectedPromptId` + `entries`. `nil` when no row is
    /// selected or the selected row was removed between loads.
    var selectedEntry: AIGeneratorHistoryEntry? {
        guard let selectedPromptId else { return nil }
        return entries.first { $0.promptId == selectedPromptId }
    }

    /// Current filter applied to the sidebar list. The M5
    /// history sheet's "Filter:" menu writes here and the
    /// SwiftUI list reads `filteredEntries` (not `entries`).
    /// `.all` is the default; the other cases narrow to a
    /// single provider name or a single endpoint host so the
    /// user can drill into a noisy history without losing
    /// their on-disk `response.json` files. The filter is
    /// in-memory only — a fresh sheet starts at `.all`.
    @Published var filter: HistoryFilter = .all

    /// Sidebar entries after the current `filter` is applied.
    /// Mirrors the on-disk ordering from `entries` (newest
    /// first) and applies the match rule from
    /// `HistoryFilter.matches(_:)`. The SwiftUI list binds
    /// to this computed property, so changing `filter` causes
    /// a re-render without a store round-trip.
    var filteredEntries: [AIGeneratorHistoryEntry] {
        entries.filter { filter.matches($0) }
    }

    /// Distinct provider names present in `entries`, in
    /// stable insertion order (so "Mock" / "Local" / "Remote"
    /// appear in the order they were first recorded). `nil`
    /// values (older entries written before the field was
    /// added) surface as `"Unknown"`. The sheet's "Filter:"
    /// menu iterates this to build the "by provider" options.
    var availableProviderNames: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in entries {
            let label = entry.providerName ?? "Unknown"
            if seen.insert(label).inserted {
                ordered.append(label)
            }
        }
        return ordered
    }

    /// Distinct non-nil `endpointHost` values present in
    /// `entries`, in stable insertion order. The sheet's
    /// "Filter:" menu iterates this to build the
    /// "by endpoint host" options. Hosts are returned as-is
    /// (no grouping / no truncation) so the user can tell
    /// `api.openai.com` apart from `api.anthropic.com` at
    /// a glance.
    var availableEndpointHosts: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in entries {
            guard let host = entry.endpointHost, !host.isEmpty else { continue }
            if seen.insert(host).inserted {
                ordered.append(host)
            }
        }
        return ordered
    }

    /// Count of entries visible under the current `filter`.
    /// Surfaced in the sheet header so the user can see "12
    /// of 47" at a glance without reading the list.
    var filteredCount: Int {
        filteredEntries.count
    }

    // MARK: - Dependencies

    /// The history store. Defaults to
    /// `AIGeneratorHistoryStoreFactory.makeDefault()` so the
    /// production call site stays a one-liner; tests inject a
    /// fresh `FileSystemAIGeneratorHistoryStore` rooted at a temp
    /// dir (or a test-only throwing store).
    let store: AIGeneratorHistoryStore

    // MARK: - State Type

    /// State machine for the history sheet. Conforms to `Equatable`
    /// so SwiftUI tests can `XCTAssertEqual` against it. The error
    /// case is an associated `String` (the underlying error's
    /// `localizedDescription`) so the view model never holds onto a
    /// non-`Equatable` `Error` reference.
    enum HistoryState: Equatable {
        case idle
        case loading
        case loaded
        case deleting
        case error(String)
    }

    // MARK: - Filter Type

    /// Filter applied to the sidebar list.
    ///
    /// The three cases mirror the three branches the M5 history
    /// UI's "Filter:" picker surfaces:
    /// - `.all` — every entry (the default)
    /// - `.provider(String)` — only entries whose
    ///   `entry.providerName == p`. The `String` is one of the
    ///   `availableProviderNames` values (e.g. `"Mock"`,
    ///   `"Local"`, `"Remote"`, or a custom label a future
    ///   generator reports).
    /// - `.host(String)` — only entries whose
    ///   `entry.endpointHost == h`. The `String` is one of the
    ///   `availableEndpointHosts` values (e.g.
    ///   `"api.openai.com"`).
    ///
    /// The `Equatable` conformance is hand-rolled (Swift derives
    /// it for `String`-bearing enums automatically, but pinning
    /// the conformance here makes the contract explicit and
    /// matches the style of the surrounding `HistoryState` /
    /// `HistoryEntry` types).
    enum HistoryFilter: Equatable {
        case all
        case provider(String)
        case host(String)

        /// Returns `true` when `entry` should be visible under
        /// this filter. `.all` is unconditional; the
        /// provider / host cases are exact string matches so
        /// the picker does not have to be lossy (e.g.
        /// substring matching would conflate `api.openai.com`
        /// with `api.openai.com.evil.example`).
        func matches(_ entry: AIGeneratorHistoryEntry) -> Bool {
            switch self {
            case .all:
                return true
            case .provider(let name):
                return entry.providerName == name
            case .host(let host):
                return entry.endpointHost == host
            }
        }
    }

    // MARK: - Init

    init(store: AIGeneratorHistoryStore = AIGeneratorHistoryStoreFactory.makeDefault()) {
        self.store = store
    }

    // MARK: - Actions

    /// Reload `entries` from the store. Sets `state = .loading`,
    /// then `.loaded` on success or `.error(reason)` on failure.
    /// Called once from the sheet's `task` modifier and again from
    /// the destructive action handlers.
    func reload() async {
        state = .loading
        do {
            let all = try store.listAll()
            entries = all
            state = .loaded
            // If the previously-selected entry was removed between
            // loads, clear the selection so the detail pane doesn't
            // dangle. Otherwise preserve it.
            if let promptId = selectedPromptId, !all.contains(where: { $0.promptId == promptId }) {
                selectedPromptId = nil
            }
        } catch {
            state = .error(Self.errorReason(from: error))
        }
    }

    /// Remove `selectedEntry.promptId` from the store and reload.
    /// No-op when no entry is selected. The deletion is in
    /// `.deleting` state for the whole round-trip so the sheet
    /// disables the destructive buttons.
    func deleteSelected() async {
        guard let promptId = selectedPromptId else { return }
        await deleteEntry(promptId: promptId)
    }

    /// Remove a single entry from the store and reload. The
    /// M5 history sheet's per-row context-menu / swipe-to-delete
    /// actions call into this method with the row's
    /// `promptId`. No-op when `promptId` is empty. The deletion
    /// runs in `.deleting` state so the sheet disables the
    /// other destructive buttons until the reload finishes.
    func deleteEntry(promptId: String) async {
        guard !promptId.isEmpty else { return }
        state = .deleting
        do {
            try store.delete(promptId: promptId)
            await reload()
        } catch {
            state = .error(Self.errorReason(from: error))
        }
    }

    /// Wipe every entry from the store and reload. Same state
    /// transitions as `deleteSelected()`. Wires the
    /// "Wipe All Generator History" Preferences → Advanced button
    /// to a callable method, and is reachable from the sheet's
    /// own "Delete All" footer button.
    func deleteAll() async {
        state = .deleting
        do {
            try store.deleteAll()
            await reload()
        } catch {
            state = .error(Self.errorReason(from: error))
        }
    }

    /// Extract a human-readable reason from the store error.
    /// `AIGeneratorHistoryError` does not conform to
    /// `LocalizedError`, so we pattern-match on the enum cases to
    /// pull out the wrapped `reason` string. For any non-enum
    /// error, fall back to `error.localizedDescription`.
    private static func errorReason(from error: Error) -> String {
        if let historyError = error as? AIGeneratorHistoryError {
            return historyError.reason
        }
        return error.localizedDescription
    }

    /// Reset the view model back to its initial state. Useful for
    /// the sheet's `task` modifier so a second presentation
    /// starts from a clean slate.
    func reset() {
        state = .idle
        entries = []
        selectedPromptId = nil
        filter = .all
    }
}

// MARK: - Log

extension GeneratorHistoryViewModel {
    /// M5 history UI logger. Mirrors the M2 `AIGenerator` log
    /// category so failures show up in the same subsystem.
    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "GeneratorHistory")
}

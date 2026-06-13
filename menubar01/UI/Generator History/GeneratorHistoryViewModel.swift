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
//   .deleting  — `deleteSelected()` / `deleteAll()` in flight.
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
    }
}

// MARK: - Log

extension GeneratorHistoryViewModel {
    /// M5 history UI logger. Mirrors the M2 `AIGenerator` log
    /// category so failures show up in the same subsystem.
    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "GeneratorHistory")
}

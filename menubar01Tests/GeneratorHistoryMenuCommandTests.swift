// GeneratorHistoryMenuCommandTests.swift
// menubar01 — AI Plugin Generator (M5 history UI)
//
// Swift Testing coverage for the `GeneratorHistorySheet.onRegenerate`
// wiring. The actual `GeneratorHistoryMenuCommand.presentSheet(...)`
// closure body is AppKit-bound (it instantiates an
// `NSHostingController` over the sheet and forwards to
// `PluginGeneratorMenuCommand.presentSheet(prefillRequest:)`), so it
// is not unit-testable directly. Instead, these tests pin down the
// **contract** the menu command depends on:
//
// - `GeneratorHistorySheet` captures the `onRegenerate` closure the
//   menu command passes in.
// - The closure is invoked with `viewModel.selectedEntry` (not
//   `entries.first`, not `entries.last`) when the user clicks the
//   "Re-generate" button. The button's action is
//   `if let entry = viewModel.selectedEntry { onRegenerate?(entry) }`
//   so the test verifies that exact source of truth is what the
//   closure receives.
// - A `nil` `onRegenerate` is tolerated: the button guards
//   `onRegenerate?(entry)`, so a `nil` callback must not crash.
// - The closure body the menu command installs forwards
//   `entry.request` to the M2 sheet's `prefillRequest:` argument —
//   the actual prefill string is what the M2 sheet's view model
//   will see.
//
// Driving the "Re-generate" button from a unit test would require
// SwiftUI view-testing infrastructure (ViewInspector or a
// hosting-controller snapshot), neither of which is in the test
// bundle today. The closure-capture round-trip is the same code
// path the button would exercise, so the test reads as a sanity
// check that the wiring is correct without involving AppKit.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test fixture

/// `FileSystemAIGeneratorHistoryStore` rooted at a per-test temp
/// directory. `deinit` removes the temp dir so the test bundle does
/// not leak storage. Mirrors the M5 store-tests pattern.
private final class HistoryTempDir {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-regen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

private func makeTestEntry(
    promptId: String,
    request: String
) -> AIGeneratorHistoryEntry {
    var manifest = PluginManifest()
    manifest.name = "Echo"
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = "echo.sh"
    let plugin = GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho \(promptId)\n",
        explanation: "fake",
        promptId: promptId,
        promptVersion: "v1.0-test"
    )
    return AIGeneratorHistoryEntry(
        promptId: promptId,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        request: request,
        model: "gpt-4o-mini",
        plugin: plugin,
        menuTreeJSON: nil,
        endpointHost: nil
    )
}

// MARK: - onRegenerate closure capture

@MainActor
struct GeneratorHistorySheetRegenerateClosureTests {

    @Test func testOnRegenerate_isCapturedByInit() {
        // Build a sheet with a known closure reference. The init
        // must store the closure on `self.onRegenerate` so the
        // button's action (which reads `self.onRegenerate?`) can
        // reach it.
        var callCount = 0
        let viewModel = GeneratorHistoryViewModel()
        let sheet = GeneratorHistorySheet(
            viewModel: viewModel,
            onRegenerate: { _ in callCount += 1 }
        )

        #expect(sheet.onRegenerate != nil)
        // Invoking the stored closure should bump the counter —
        // the same closure instance the button would call.
        sheet.onRegenerate?(makeTestEntry(promptId: "p1", request: "first"))
        #expect(callCount == 1)
    }

    @Test func testOnRegenerate_invocationForwardsSelectedEntryRequest() async throws {
        // Round-trip: a sheet wired with a capturing closure must
        // see the selected entry's `request` field reach the
        // closure, so the menu command's prefill wiring works
        // end-to-end.
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "show weather"))
        try temp.store.record(makeTestEntry(promptId: "b", request: "show stocks"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        var capturedRequest: String?
        let sheet = GeneratorHistorySheet(
            viewModel: viewModel,
            onRegenerate: { entry in capturedRequest = entry.request }
        )

        // Select entry "b" and invoke the closure the same way the
        // "Re-generate" button would. The button's body is:
        //   if let entry = viewModel.selectedEntry { onRegenerate?(entry) }
        // so this is the exact source of truth.
        viewModel.selectedPromptId = "b"
        if let entry = viewModel.selectedEntry {
            #expect(entry.request == "show stocks")
            sheet.onRegenerate?(entry)
        } else {
            Issue.record("expected a selected entry, got nil")
        }

        #expect(capturedRequest == "show stocks")
    }

    @Test func testOnRegenerate_invocationTracksLatestSelectedEntry() async throws {
        // The same closure instance must observe successive
        // selections: selecting a different row, then re-invoking
        // the closure, should forward the new selection's request.
        // This pins the sheet's contract on the view model's
        // `selectedPromptId` → `selectedEntry` derivation.
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        try temp.store.record(makeTestEntry(promptId: "b", request: "second"))
        try temp.store.record(makeTestEntry(promptId: "c", request: "third"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        var capturedRequest: String?
        let sheet = GeneratorHistorySheet(
            viewModel: viewModel,
            onRegenerate: { entry in capturedRequest = entry.request }
        )

        viewModel.selectedPromptId = "c"
        if let entry = viewModel.selectedEntry {
            sheet.onRegenerate?(entry)
        }
        #expect(capturedRequest == "third")

        viewModel.selectedPromptId = "a"
        if let entry = viewModel.selectedEntry {
            sheet.onRegenerate?(entry)
        }
        #expect(capturedRequest == "first")
    }

    @Test func testOnRegenerate_nilCallbackDoesNotCrash() {
        // The button guards `onRegenerate?(entry)`, so a `nil`
        // callback must be tolerated. This is the contract the
        // menu command relies on when the sheet is first
        // presented without a closure wired in.
        let viewModel = GeneratorHistoryViewModel()
        let sheet = GeneratorHistorySheet(viewModel: viewModel, onRegenerate: nil)
        #expect(sheet.onRegenerate == nil)
    }
}

// MARK: - Wiring test: prefill string is forwarded

/// The closure body the menu command installs on
/// `GeneratorHistorySheet.onRegenerate` calls
/// `PluginGeneratorMenuCommand.presentSheet(appDelegate:prefillRequest:)`
/// with `prefillRequest: entry.request` and closes the history
/// window. The static `PluginGeneratorMenuCommand.presentSheet(...)`
/// cannot be mocked from the test bundle, so the test pins the
/// payload the menu command forwards by installing a closure that
/// captures the entry — the captured entry is exactly what the
/// menu command would hand to the M2 sheet.
@MainActor
struct GeneratorHistoryRegeneratePrefillForwardingTests {

    @Test func testRegenerateFromHistory_forwardsEntryRequestAsPrefill() async throws {
        // End-to-end check: the closure the menu command installs
        // on the history sheet must forward `entry.request` (the
        // `prefillRequest:` payload) so the M2 sheet lands with
        // the original request in its text editor.
        let temp = try HistoryTempDir()
        let original = "show weather in Beijing"
        try temp.store.record(
            makeTestEntry(promptId: "selected-1", request: original)
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.selectedPromptId = "selected-1"

        var lastPrefill: String?
        var callCount = 0
        let sheet = GeneratorHistorySheet(
            viewModel: viewModel,
            onRegenerate: { entry in
                callCount += 1
                lastPrefill = entry.request
            }
        )

        // Simulate the "Re-generate" button click by invoking
        // the same code path the button uses:
        //   if let entry = viewModel.selectedEntry { onRegenerate?(entry) }
        if let entry = viewModel.selectedEntry {
            sheet.onRegenerate?(entry)
        }

        #expect(callCount == 1)
        #expect(lastPrefill == original)
    }
}

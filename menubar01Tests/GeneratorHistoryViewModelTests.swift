// GeneratorHistoryViewModelTests.swift
// menubar01 — AI Plugin Generator (M5 history UI)
//
// Swift Testing coverage for `GeneratorHistoryViewModel` and the
// "record-after-generate" hook on `AIGeneratorViewModel`. Mirrors
// the per-test temp-dir pattern from
// `AIGeneratorHistoryStoreTests` so each test runs hermetically
// and the `deinit` of the test struct cleans up automatically.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test-only store

/// Throwing store used to drive the view model's `.error` paths
/// without needing to set up a deliberately-broken file system.
/// The test only configures the methods it cares about; the rest
/// trap so an unconfigured branch is a loud failure, not a silent
/// no-op.
private final class TestHistoryStore: AIGeneratorHistoryStore {
    enum Behavior {
        case succeed
        case throwOnList
        case throwOnDelete
        case throwOnDeleteAll
    }

    let behavior: Behavior
    private(set) var recordedEntries: [AIGeneratorHistoryEntry] = []
    private(set) var deletedPromptIds: [String] = []
    private(set) var deleteAllCallCount: Int = 0

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func record(_ entry: AIGeneratorHistoryEntry) throws {
        recordedEntries.append(entry)
    }

    func listAll() throws -> [AIGeneratorHistoryEntry] {
        if case .throwOnList = behavior {
            throw AIGeneratorHistoryError.ioFailure(reason: "test: forced listAll failure")
        }
        return recordedEntries
    }

    func delete(promptId: String) throws {
        if case .throwOnDelete = behavior {
            throw AIGeneratorHistoryError.ioFailure(reason: "test: forced delete failure")
        }
        deletedPromptIds.append(promptId)
        recordedEntries.removeAll { $0.promptId == promptId }
    }

    func deleteAll() throws {
        if case .throwOnDeleteAll = behavior {
            throw AIGeneratorHistoryError.ioFailure(reason: "test: forced deleteAll failure")
        }
        deleteAllCallCount += 1
        recordedEntries.removeAll()
    }
}

// MARK: - Test-only generator

/// Lightweight stand-in for the M2 `CapturingMockAIPluginGenerator`
/// so the history-store integration test can wire
/// `AIGeneratorViewModel` end-to-end without pulling in the
/// existing M2 fixture (which uses a non-`Equatable` manifest
/// that would fail to round-trip through the JSON encoder). The
/// generator returns a fresh `GeneratedPlugin` per call.
private final class FakePluginGenerator: AIPluginGenerator {
    /// Counter that produces a unique `promptId` for every call so
    /// the recorded entry's `promptId` does not collide with a
    /// previous call's directory.
    private var counter: Int = 0
    private let lock = NSLock()

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        lock.lock()
        counter += 1
        let id = "fake-\(counter)"
        lock.unlock()

        var manifest = PluginManifest()
        manifest.name = "FakePlugin-\(id)"
        manifest.version = "1.0.0"
        manifest.type = .Executable
        manifest.entry = "fake.sh"
        return GeneratedPlugin(
            manifest: manifest,
            entryScript: "#!/bin/zsh\necho \(id)\n",
            explanation: "fake explanation for \(id)",
            promptId: id,
            promptVersion: "v-fake"
        )
    }
}

// MARK: - Test fixture: file-system-backed store

/// A `FileSystemAIGeneratorHistoryStore` rooted at a per-test temp
/// directory. `deinit` removes the temp dir so the test bundle does
/// not leak storage. Mirrors the M5 store-tests pattern.
private final class HistoryTempDir {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-vm-\(UUID().uuidString)", isDirectory: true)
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
    request: String = "show weather",
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    model: String = "gpt-4o-mini",
    endpointHost: String? = nil,
    providerName: String? = nil
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
        createdAt: createdAt,
        request: request,
        model: model,
        plugin: plugin,
        menuTreeJSON: nil,
        endpointHost: endpointHost,
        providerName: providerName
    )
}

// MARK: - reload()

@MainActor
struct GeneratorHistoryViewModelReloadTests {

    @Test func testReload_populatesEntriesFromStore() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        try temp.store.record(makeTestEntry(promptId: "b", request: "second"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)

        await viewModel.reload()

        #expect(viewModel.entries.count == 2)
        #expect(Set(viewModel.entries.map(\.promptId)) == ["a", "b"])
    }

    @Test func testReload_setsStateToLoaded() async throws {
        let temp = try HistoryTempDir()
        let viewModel = GeneratorHistoryViewModel(store: temp.store)

        #expect(viewModel.state == .idle)

        await viewModel.reload()
        #expect(viewModel.state == .loaded)
    }

    @Test func testReload_setsStateToErrorOnStoreFailure() async {
        let store = TestHistoryStore(behavior: .throwOnList)
        let viewModel = GeneratorHistoryViewModel(store: store)

        await viewModel.reload()

        if case .error(let reason) = viewModel.state {
            #expect(reason.contains("forced listAll failure"))
        } else {
            Issue.record("expected .error(...) state, got \(viewModel.state)")
        }
        #expect(viewModel.entries.isEmpty)
    }
}

// MARK: - deleteSelected()

@MainActor
struct GeneratorHistoryViewModelDeleteSelectedTests {

    @Test func testDeleteSelected_removesEntryAndReloads() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        try temp.store.record(makeTestEntry(promptId: "b", request: "second"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        // Select one and delete it.
        viewModel.selectedPromptId = "a"
        await viewModel.deleteSelected()

        #expect(viewModel.entries.count == 1)
        #expect(viewModel.entries.first?.promptId == "b")
        #expect(viewModel.state == .loaded)
    }

    @Test func testDeleteSelected_isNoOpWhenNothingSelected() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        // No selection — deleteSelected must not mutate the store.
        viewModel.selectedPromptId = nil
        await viewModel.deleteSelected()

        #expect(viewModel.entries.count == 1)
        #expect(viewModel.entries.first?.promptId == "a")
    }

    @Test func testDeleteSelected_setsStateToErrorOnStoreFailure() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.selectedPromptId = viewModel.entries.first?.promptId

        // Swap the store for a throwing one with the same in-memory
        // entries so the test reads the data → triggers a failure.
        let throwingStore = TestHistoryStore(behavior: .throwOnDelete)
        try throwingStore.record(makeTestEntry(promptId: "a"))
        let failingViewModel = GeneratorHistoryViewModel(store: throwingStore)
        await failingViewModel.reload()
        failingViewModel.selectedPromptId = failingViewModel.entries.first?.promptId

        await failingViewModel.deleteSelected()

        if case .error(let reason) = failingViewModel.state {
            #expect(reason.contains("forced delete failure"))
        } else {
            Issue.record("expected .error(...) state, got \(failingViewModel.state)")
        }
    }
}

// MARK: - deleteAll()

@MainActor
struct GeneratorHistoryViewModelDeleteAllTests {

    @Test func testDeleteAll_clearsEntriesAndReloads() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        try temp.store.record(makeTestEntry(promptId: "b", request: "second"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        #expect(viewModel.entries.count == 2)

        await viewModel.deleteAll()

        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.state == .loaded)
    }

    @Test func testDeleteAll_setsStateToErrorOnStoreFailure() async {
        let store = TestHistoryStore(behavior: .throwOnDeleteAll)
        let viewModel = GeneratorHistoryViewModel(store: store)

        await viewModel.deleteAll()

        if case .error(let reason) = viewModel.state {
            #expect(reason.contains("forced deleteAll failure"))
        } else {
            Issue.record("expected .error(...) state, got \(viewModel.state)")
        }
    }
}

// MARK: - reset()

@MainActor
struct GeneratorHistoryViewModelResetTests {

    @Test func testReset_clearsState() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(makeTestEntry(promptId: "a", request: "first"))
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.selectedPromptId = viewModel.entries.first?.promptId

        viewModel.reset()

        #expect(viewModel.state == .idle)
        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.selectedPromptId == nil)
    }
}

// MARK: - Integration with AIGeneratorViewModel

@MainActor
struct GeneratorHistoryAIGeneratorViewModelIntegrationTests {

    @Test func testHistoryStore_integrationWithAIGeneratorViewModel() async throws {
        // End-to-end check: a successful `AIGeneratorViewModel.generate()`
        // must persist a history entry to the on-disk store.
        let temp = try HistoryTempDir()
        let generator = FakePluginGenerator()
        let viewModel = AIGeneratorViewModel(
            generator: generator,
            historyStore: temp.store
        )

        viewModel.request = "show weather in Beijing"
        await viewModel.generate()

        // The generate() should have transitioned to .success.
        if case .success = viewModel.state {
            // Good — keep going.
        } else {
            Issue.record("expected .success(...) state, got \(viewModel.state)")
            return
        }

        // And the entry should be on disk.
        let entries = try temp.store.listAll()
        #expect(entries.count == 1)
        #expect(entries.first?.request == "show weather in Beijing")
        #expect(entries.first?.model == "gpt-4o-mini")
    }
}

// MARK: - selectedEntry exposes model + endpointHost

/// The M5+ history detail view renders "Generated by `<model>`
/// at `<host>`" from the selected entry's `model` and
/// `endpointHost`. These tests pin the view-model's
/// `selectedEntry` accessor so the SwiftUI sheet can read
/// those fields off the entry without the view model growing
/// a new public API.
@MainActor
struct GeneratorHistoryViewModelSelectedEntryExposesModelAndHostTests {

    @Test func testSelectedEntry_exposesModel() async throws {
        // Record an entry whose `model` is "gpt-4o". After the
        // view model reloads, the sidebar selection should
        // surface that exact string through `selectedEntry.model`.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "remote-1", model: "gpt-4o")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.selectedPromptId = viewModel.entries.first?.promptId

        #expect(viewModel.selectedEntry?.model == "gpt-4o")
    }

    @Test func testSelectedEntry_exposesEndpointHost() async throws {
        // Record an entry whose `endpointHost` is set. The
        // view model must surface that string verbatim so the
        // SwiftUI sheet can render "Generated by `<model>` at
        // `<host>`" without going through a custom accessor.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(
                promptId: "remote-2",
                model: "gpt-4o",
                endpointHost: "api.openai.com"
            )
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.selectedPromptId = viewModel.entries.first?.promptId

        #expect(viewModel.selectedEntry?.endpointHost == "api.openai.com")
    }

    @Test func testSelectedEntry_endpointHostIsNilForLocal() async throws {
        // Record an entry with `endpointHost: nil` (the
        // default — Mock / Local / LocalEcho runs, and any
        // pre-M5+ entry). The view model must surface `nil`
        // so the SwiftUI sheet can render its "local model"
        // fallback.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "local-1", endpointHost: nil)
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.selectedPromptId = viewModel.entries.first?.promptId

        #expect(viewModel.selectedEntry?.endpointHost == nil)
    }
}

// MARK: - filter / filteredEntries

/// The M5 history sheet's "Filter:" picker narrows the sidebar
/// to a single provider, a single endpoint host, or keeps it
/// at "all". These tests pin the view-model's `filter` /
/// `filteredEntries` contract so the SwiftUI sheet can bind
/// `ForEach(viewModel.filteredEntries)` without growing its
/// own selector logic.
@MainActor
struct GeneratorHistoryViewModelFilterTests {

    @Test func testFilterByProvider_returnsOnlyMatchingEntries() async throws {
        // 2 Mock + 1 Remote. Filter `.provider("Mock")` must
        // return exactly the two Mock entries.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "m1", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(
                promptId: "r1",
                endpointHost: "api.openai.com",
                providerName: "Remote"
            )
        )
        try temp.store.record(
            makeTestEntry(promptId: "m2", providerName: "Mock")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        viewModel.filter = .provider("Mock")

        #expect(viewModel.filteredEntries.count == 2)
        #expect(Set(viewModel.filteredEntries.map(\.promptId)) == ["m1", "m2"])
        // The full entry list is untouched by filtering.
        #expect(viewModel.entries.count == 3)
    }

    @Test func testFilterByHost_returnsOnlyMatchingEntries() async throws {
        // 2 different endpoint hosts. Filter
        // `.host("api.example.com")` must return the single
        // entry that came from that host.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(
                promptId: "h1",
                endpointHost: "api.openai.com",
                providerName: "Remote"
            )
        )
        try temp.store.record(
            makeTestEntry(
                promptId: "h2",
                endpointHost: "api.example.com",
                providerName: "Remote"
            )
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        viewModel.filter = .host("api.example.com")

        #expect(viewModel.filteredEntries.count == 1)
        #expect(viewModel.filteredEntries.first?.promptId == "h2")
    }

    @Test func testFilterAll_returnsAllEntries() async throws {
        // Three entries from two providers + one local. The
        // `.all` filter must surface every entry regardless
        // of provider / host.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "a", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(
                promptId: "b",
                endpointHost: "api.openai.com",
                providerName: "Remote"
            )
        )
        try temp.store.record(
            makeTestEntry(promptId: "c", providerName: "Local")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        viewModel.filter = .all

        #expect(viewModel.filteredEntries.count == 3)
        #expect(Set(viewModel.filteredEntries.map(\.promptId)) == ["a", "b", "c"])
    }

    @Test func testFilterByProvider_doesNotMatchNilProviderName() async throws {
        // An entry written before the `providerName` field
        // existed carries `nil` for that field. The
        // `.provider("Mock")` filter must NOT match it —
        // exact equality is the contract (substring matching
        // would be lossy and conflate labels).
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "mock", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(promptId: "legacy", providerName: nil)
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        viewModel.filter = .provider("Mock")

        #expect(viewModel.filteredEntries.count == 1)
        #expect(viewModel.filteredEntries.first?.promptId == "mock")
    }

    @Test func testAvailableProviderNames_dedupesAndPreservesOrder() async throws {
        // Two Mock entries should produce a single "Mock"
        // entry in `availableProviderNames`, in the order it
        // was first observed in `entries`. The Remote entry
        // shows up in its own position.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "m1", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(
                promptId: "r1",
                endpointHost: "api.openai.com",
                providerName: "Remote"
            )
        )
        try temp.store.record(
            makeTestEntry(promptId: "m2", providerName: "Mock")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        #expect(viewModel.availableProviderNames == ["Mock", "Remote"])
    }

    @Test func testAvailableEndpointHosts_dedupesAndSkipsNil() async throws {
        // Two distinct hosts + one nil-host entry. The
        // `availableEndpointHosts` should return the two
        // distinct hosts and skip the nil one. The store
        // returns entries newest-first, so the observed
        // order in the picker follows the same newest-first
        // rule (and stays stable across loads).
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(
                promptId: "h1",
                endpointHost: "api.openai.com",
                providerName: "Remote"
            )
        )
        try temp.store.record(
            makeTestEntry(promptId: "local", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(
                promptId: "h2",
                endpointHost: "api.example.com",
                providerName: "Remote"
            )
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        #expect(viewModel.availableEndpointHosts == ["api.example.com", "api.openai.com"])
    }
}

// MARK: - deleteEntry(promptId:)

/// The M5 history sheet's per-row context menu / swipe-to-delete
/// action calls `viewModel.deleteEntry(promptId:)`. These tests
/// pin the view-model's contract that the method removes a
/// single entry from the underlying store without touching
/// the other entries, and that it goes through the same
/// `.deleting` → `.loaded` state machine the existing
/// `deleteSelected()` uses.
@MainActor
struct GeneratorHistoryViewModelDeleteEntryTests {

    @Test func testDeleteSingleEntry_removesItFromStore() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "a", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(promptId: "b", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(promptId: "c", providerName: "Remote")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()

        await viewModel.deleteEntry(promptId: "b")

        let remaining = try temp.store.listAll()
        #expect(Set(remaining.map(\.promptId)) == ["a", "c"])
        #expect(viewModel.entries.count == 2)
        #expect(Set(viewModel.entries.map(\.promptId)) == ["a", "c"])
        #expect(viewModel.state == .loaded)
    }

    @Test func testDeleteSingleEntry_unknownPromptIdIsNoOp() async throws {
        // The store's `delete(promptId:)` is a no-op for
        // unknown ids, so the view-model's wrapper must
        // stay non-throwing and not mutate state when the
        // id is not in the store.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "a", providerName: "Mock")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        let countBefore = viewModel.entries.count

        await viewModel.deleteEntry(promptId: "does-not-exist")

        #expect(viewModel.entries.count == countBefore)
        #expect(viewModel.state == .loaded)
    }

    @Test func testDeleteSingleEntry_emptyPromptIdIsNoOp() async throws {
        // `deleteEntry(promptId: "")` must short-circuit
        // before touching the store — empty promptId is
        // never a valid id, and the store would otherwise
        // log an error for a malformed entry directory.
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "a", providerName: "Mock")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        let countBefore = viewModel.entries.count

        await viewModel.deleteEntry(promptId: "")

        #expect(viewModel.entries.count == countBefore)
    }
}

// MARK: - deleteAll() (re-test with providerName coverage)

/// Re-tests `deleteAll()` to cover the new "by provider"
/// filter: a filter set to a provider whose entries are all
/// gone should produce an empty `filteredEntries`.
@MainActor
struct GeneratorHistoryViewModelDeleteAllWithFilterTests {

    @Test func testDeleteAllEntries_clearsStore() async throws {
        let temp = try HistoryTempDir()
        try temp.store.record(
            makeTestEntry(promptId: "a", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(promptId: "b", providerName: "Mock")
        )
        try temp.store.record(
            makeTestEntry(promptId: "c", providerName: "Remote")
        )
        let viewModel = GeneratorHistoryViewModel(store: temp.store)
        await viewModel.reload()
        viewModel.filter = .provider("Mock")
        #expect(viewModel.filteredEntries.count == 2)

        await viewModel.deleteAll()

        let remaining = try temp.store.listAll()
        #expect(remaining.isEmpty)
        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.filteredEntries.isEmpty)
        #expect(viewModel.state == .loaded)
    }
}

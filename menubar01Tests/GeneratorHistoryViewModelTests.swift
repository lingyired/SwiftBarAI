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
    endpointHost: String? = nil
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
        endpointHost: endpointHost
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

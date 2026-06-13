// AIGeneratorHistoryStoreTests.swift
// menubar01 — AI Plugin Generator (M5)
//
// Swift Testing coverage for `FileSystemAIGeneratorHistoryStore`.
// Each test runs against a unique temp directory so they are
// hermetic, can run in parallel, and do not need a `setUp` /
// `tearDown` queue. The `deinit` of the test struct removes the
// temp dir after the test function returns — Swift Testing
// instantiates a fresh `AIGeneratorHistoryStoreTests` value per
// `@Test`, so this is the right granularity for per-test cleanup.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a known `GeneratedPlugin` value for tests. The fields
/// mirror `MockAIPluginGenerator`'s hard-coded "Echo" plugin so the
/// test is stable across M1 / M5 changes.
private func makeTestPlugin(
    promptId: String,
    explanation: String = "Test explanation"
) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = "Echo"
    manifest.version = "1.0.0"
    manifest.description = "Test description"
    manifest.author = "menubar01 tests"
    manifest.type = .Executable
    manifest.entry = "echo.sh"
    manifest.refreshInterval = 5
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho \(promptId)\n",
        explanation: explanation,
        promptId: promptId,
        promptVersion: "v1.0-test"
    )
}

private func makeTestEntry(
    promptId: String,
    request: String,
    model: String = "gpt-4o-mini",
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    menuTreeJSON: Data? = nil,
    endpointHost: String? = nil,
    providerName: String? = nil
) -> AIGeneratorHistoryEntry {
    AIGeneratorHistoryEntry(
        promptId: promptId,
        createdAt: createdAt,
        request: request,
        model: model,
        plugin: makeTestPlugin(promptId: promptId),
        menuTreeJSON: menuTreeJSON,
        endpointHost: endpointHost,
        providerName: providerName
    )
}

// MARK: - record + listAll

final class AIGeneratorHistoryStoreRecordTests {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        // Swift Testing deallocates the test struct after each
        // `@Test` returns, so the per-test temp dir is removed
        // automatically. Failures to clean up are non-fatal: a
        // `NSTemporaryDirectory()` leak is much less harmful than
        // swallowing a real assertion error.
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func testRecord_writesThreeFiles() throws {
        let entry = makeTestEntry(
            promptId: "abc123",
            request: "show weather"
        )

        try store.record(entry)

        let entryDir = rootDirectory.appendingPathComponent("abc123", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: entryDir.path))

        let requestURL = entryDir.appendingPathComponent("request.txt")
        let responseURL = entryDir.appendingPathComponent("response.json")
        #expect(FileManager.default.fileExists(atPath: requestURL.path))
        #expect(FileManager.default.fileExists(atPath: responseURL.path))

        // request.txt is the verbatim request bytes.
        let requestBytes = try Data(contentsOf: requestURL)
        #expect(String(data: requestBytes, encoding: .utf8) == "show weather")

        // response.json is non-empty JSON containing the promptId.
        let responseBytes = try Data(contentsOf: responseURL)
        #expect(!responseBytes.isEmpty)
        let responseString = try #require(String(data: responseBytes, encoding: .utf8))
        #expect(responseString.contains("\"promptId\" : \"abc123\""))
        #expect(responseString.contains("\"request\" : \"show weather\""))
    }

    @Test func testRecord_writesMenuFileWhenMenuTreeIsPresent() throws {
        let menuData = Data("[{\"label\":\"A\"}]".utf8)
        let entry = makeTestEntry(
            promptId: "with-menu",
            request: "list something",
            menuTreeJSON: menuData
        )

        try store.record(entry)

        let menuURL = rootDirectory
            .appendingPathComponent("with-menu", isDirectory: true)
            .appendingPathComponent("menu.json")
        #expect(FileManager.default.fileExists(atPath: menuURL.path))
        #expect(try Data(contentsOf: menuURL) == menuData)
    }

    @Test func testRecord_omitsMenuFileWhenMenuTreeIsNil() throws {
        let entry = makeTestEntry(
            promptId: "no-menu",
            request: "anything",
            menuTreeJSON: nil
        )

        try store.record(entry)

        let menuURL = rootDirectory
            .appendingPathComponent("no-menu", isDirectory: true)
            .appendingPathComponent("menu.json")
        #expect(!FileManager.default.fileExists(atPath: menuURL.path))
    }

    @Test func testRecord_overwritesExistingEntryOnSecondCall() throws {
        let first = makeTestEntry(
            promptId: "dup",
            request: "first",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let second = makeTestEntry(
            promptId: "dup",
            request: "second",
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        try store.record(first)
        try store.record(second)

        let entries = try store.listAll()
        #expect(entries.count == 1)
        #expect(entries.first?.request == "second")
    }
}

// MARK: - listAll

final class AIGeneratorHistoryStoreListAllTests {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func testListAll_emptyStoreReturnsEmptyArray() throws {
        let entries = try store.listAll()
        #expect(entries.isEmpty)
    }

    @Test func testListAll_missingRootDirectoryReturnsEmptyArray() throws {
        // Wipe the root directory; the store should still return []
        // rather than throw, so the first record() can succeed.
        try FileManager.default.removeItem(at: rootDirectory)
        let storeWithoutRoot = FileSystemAIGeneratorHistoryStore(
            rootDirectory: rootDirectory
        )

        let entries = try storeWithoutRoot.listAll()
        #expect(entries.isEmpty)
    }

    @Test func testListAll_sortsByCreatedAtDescending() throws {
        let older = makeTestEntry(
            promptId: "old",
            request: "first",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newest = makeTestEntry(
            promptId: "new",
            request: "third",
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let middle = makeTestEntry(
            promptId: "mid",
            request: "second",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        try store.record(older)
        try store.record(newest)
        try store.record(middle)

        let entries = try store.listAll()
        #expect(entries.map(\.promptId) == ["new", "mid", "old"])
    }

    @Test func testListAll_skipsSubdirectoriesWithoutResponseFile() throws {
        // Add a stray directory that has no response.json — it must
        // be silently skipped, not treated as an error.
        let stray = rootDirectory.appendingPathComponent("stray", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("not a manifest".utf8).write(to: stray.appendingPathComponent("README.txt"))

        let valid = makeTestEntry(promptId: "valid", request: "ok")
        try store.record(valid)

        let entries = try store.listAll()
        #expect(entries.map(\.promptId) == ["valid"])
    }
}

// MARK: - delete

final class AIGeneratorHistoryStoreDeleteTests {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func testDelete_removesOnlyTheRequestedEntry() throws {
        let keep = makeTestEntry(promptId: "keep", request: "stay")
        let drop = makeTestEntry(promptId: "drop", request: "go")
        try store.record(keep)
        try store.record(drop)

        try store.delete(promptId: "drop")

        let entries = try store.listAll()
        #expect(entries.map(\.promptId) == ["keep"])
        #expect(!FileManager.default.fileExists(
            atPath: rootDirectory.appendingPathComponent("drop").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: rootDirectory.appendingPathComponent("keep").path
        ))
    }

    @Test func testDelete_unknownPromptIdIsANoOp() throws {
        let entry = makeTestEntry(promptId: "exists", request: "r")
        try store.record(entry)

        // Should not throw even though the id is unknown.
        try store.delete(promptId: "does-not-exist")

        let entries = try store.listAll()
        #expect(entries.map(\.promptId) == ["exists"])
    }
}

// MARK: - deleteAll

final class AIGeneratorHistoryStoreDeleteAllTests {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func testDeleteAll_emptiesTheStore() throws {
        try store.record(makeTestEntry(promptId: "a", request: "1"))
        try store.record(makeTestEntry(promptId: "b", request: "2"))
        try store.record(makeTestEntry(promptId: "c", request: "3"))

        try store.deleteAll()

        let entries = try store.listAll()
        #expect(entries.isEmpty)
    }

    @Test func testDeleteAll_isANoOpWhenStoreIsEmpty() throws {
        // Should not throw, even though the root directory contains
        // no entries yet.
        try store.deleteAll()
        #expect(try store.listAll().isEmpty)
    }
}

// MARK: - File-system layout

final class AIGeneratorHistoryStoreLayoutTests {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func testLayout_oneSubdirectoryPerPromptId() throws {
        try store.record(makeTestEntry(promptId: "alpha", request: "a"))
        try store.record(makeTestEntry(promptId: "beta", request: "b"))

        let children = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )
        let names = Set(children.map(\.lastPathComponent))
        #expect(names == ["alpha", "beta"])
    }

    @Test func testLayout_eachSubdirectoryContainsRequestAndResponse() throws {
        let entry = makeTestEntry(promptId: "layout", request: "layout request")
        try store.record(entry)

        let entryDir = rootDirectory.appendingPathComponent("layout", isDirectory: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: entryDir,
            includingPropertiesForKeys: nil
        )
        let names = Set(children.map(\.lastPathComponent))
        #expect(names.contains("request.txt"))
        #expect(names.contains("response.json"))
    }
}

// MARK: - Round-trip

final class AIGeneratorHistoryStoreRoundTripTests {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = FileSystemAIGeneratorHistoryStore(rootDirectory: rootDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func testRecord_thenListAll_roundTripsFields() throws {
        let original = makeTestEntry(
            promptId: "roundtrip",
            request: "round-trip me",
            model: "gpt-4o-mini",
            createdAt: Date(timeIntervalSince1970: 1_700_123_456),
            menuTreeJSON: nil
        )

        try store.record(original)
        let loaded = try store.listAll()

        #expect(loaded.count == 1)
        let recovered = try #require(loaded.first)
        #expect(recovered == original)
    }

    @Test func testRecord_thenListAll_roundTripsMenuTree() throws {
        let menu = Data("[{\"label\":\"A\"},{\"label\":\"B\"}]".utf8)
        let original = makeTestEntry(
            promptId: "menu-roundtrip",
            request: "list two items",
            menuTreeJSON: menu
        )

        try store.record(original)
        let loaded = try store.listAll()
        let recovered = try #require(loaded.first)

        #expect(recovered.menuTreeJSON == menu)
    }

    @Test func testRecord_thenListAll_roundTripsProviderName() throws {
        // `providerName` was added together with the M5
        // history filter feature. The on-disk format must
        // round-trip the field through `response.json` so
        // the filter can read it back after a restart.
        let original = makeTestEntry(
            promptId: "provider-rt",
            request: "show weather",
            providerName: "Mock"
        )

        try store.record(original)
        let loaded = try store.listAll()
        let recovered = try #require(loaded.first)

        #expect(recovered.providerName == "Mock")
        #expect(recovered == original)
    }

    @Test func testListAll_decodesLegacyResponseJsonWithoutProviderName() throws {
        // Older `response.json` files predate the
        // `providerName` key. The store must still decode
        // them cleanly, with `providerName == nil`, so
        // upgrading from a pre-M5-history-filter build
        // does not crash `listAll()`.
        let legacyDir = rootDirectory
            .appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDir,
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        {
          "promptId" : "legacy",
          "createdAt" : "2023-11-14T22:13:20Z",
          "request" : "echo me",
          "model" : "gpt-4o-mini",
          "pluginManifest" : {
            "name" : "Echo",
            "version" : "1.0.0",
            "type" : "Executable",
            "entry" : "echo.sh",
            "refreshInterval" : 5
          },
          "pluginEntryScript" : "#!/bin/zsh\\necho legacy\\n",
          "pluginExplanation" : "legacy",
          "pluginPromptVersion" : "v1.0-test"
        }
        """
        try Data(legacyJSON.utf8).write(
            to: legacyDir.appendingPathComponent("response.json")
        )

        let entries = try store.listAll()
        let recovered = try #require(entries.first)
        #expect(recovered.promptId == "legacy")
        #expect(recovered.providerName == nil)
    }
}

// MARK: - Factory

struct AIGeneratorHistoryStoreFactoryTests {
    @Test func testMakeDefault_returnsFileSystemStore() {
        let store = AIGeneratorHistoryStoreFactory.makeDefault()
        // The concrete type is internal so the test uses the
        // protocol as the witness.
        #expect(store is FileSystemAIGeneratorHistoryStore)
    }
}

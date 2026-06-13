// AIGeneratorTemplateStoreTests.swift
// menubar01 — AI Plugin Generator (M2+ user-saved template store)
//
// Swift Testing coverage for `AIGeneratorTemplateStore` and the
// `AIGeneratorTemplateGallery.allTemplates(including:)` merge
// helper. All tests are pure (no AppKit, no SwiftUI, no
// networking) and run against per-test temp files so they are
// hermetic and can run in parallel without colliding. The
// `defer { try? FileManager.default.removeItem(at: testStoreURL) }`
// in each test cleans up the temp file before the test function
// returns, mirroring the pattern in
// `AIGeneratorHistoryStoreTests`.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a unique temp URL for the per-test `templates.json`
/// store. Each test gets its own file (and parent directory) so
/// the suite is hermetic and parallel-safe.
private func makeTempStoreURL(
    file: StaticString = #file,
    line: UInt = #line
) -> URL {
    let fileBase = (file.description as NSString)
        .lastPathComponent
        .replacingOccurrences(of: ".swift", with: "")
    let unique = "\(fileBase)-L\(line)-\(UUID().uuidString.prefix(8))"
    return FileManager.default.temporaryDirectory
        .appendingPathComponent("menubar01-AIGeneratorTemplateStoreTests", isDirectory: true)
        .appendingPathComponent(unique, isDirectory: true)
        .appendingPathComponent("templates.json")
}

// MARK: - AIGeneratorTemplateStore

struct AIGeneratorTemplateStoreTests {

    @Test func testLoadUserTemplates_fileDoesNotExist_returnsEmpty() throws {
        // The v1 contract: a fresh install (or a sheet open
        // before the user has saved any template) must not
        // crash; it must return an empty array so the gallery
        // can render with just the 6 built-ins.
        let storeURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(
            at: storeURL.deletingLastPathComponent()
        ) }

        let store = AIGeneratorTemplateStore(storeURL: storeURL)
        #expect(store.loadUserTemplates() == [])
    }

    @Test func testAddTemplate_persistsToDisk() throws {
        // Adding a template must round-trip through the file
        // system: a brand-new `AIGeneratorTemplateStore`
        // pointed at the same URL must observe the row on
        // the next `loadUserTemplates()` call.
        let storeURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(
            at: storeURL.deletingLastPathComponent()
        ) }

        let store = AIGeneratorTemplateStore(storeURL: storeURL)
        let template = AIGeneratorTemplate(
            id: "user-abcdef01",
            title: "Crypto price",
            description: "Saved from your request",
            prompt: "Show the current BTC price",
            systemImageName: "bitcoinsign.circle"
        )
        try store.addTemplate(template)

        // The file was created on disk.
        #expect(FileManager.default.fileExists(atPath: storeURL.path))

        // A second instance reads the same row back.
        let reloaded = AIGeneratorTemplateStore(storeURL: storeURL)
        let loaded = reloaded.loadUserTemplates()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "user-abcdef01")
        #expect(loaded.first?.title == "Crypto price")
    }

    @Test func testAddTemplate_duplicateIDOverwrites() throws {
        // The v1 contract: re-saving a template with the
        // same id replaces the previous record (so editing
        // and re-saving is idempotent). The store's
        // `addTemplate(_:)` is documented as an upsert.
        let storeURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(
            at: storeURL.deletingLastPathComponent()
        ) }

        let store = AIGeneratorTemplateStore(storeURL: storeURL)
        let original = AIGeneratorTemplate(
            id: "user-abc12345",
            title: "Original",
            description: "Saved from your request",
            prompt: "Original prompt",
            systemImageName: "doc.text"
        )
        let updated = AIGeneratorTemplate(
            id: "user-abc12345",
            title: "Updated",
            description: "Saved from your request",
            prompt: "Updated prompt",
            systemImageName: "pencil"
        )
        try store.addTemplate(original)
        try store.addTemplate(updated)

        let loaded = store.loadUserTemplates()
        #expect(loaded.count == 1, "duplicate id should overwrite, not append")
        #expect(loaded.first?.title == "Updated")
        #expect(loaded.first?.prompt == "Updated prompt")
        #expect(loaded.first?.systemImageName == "pencil")
    }

    @Test func testRemoveTemplate_removesFromDisk() throws {
        // `removeTemplate(id:)` must delete the row from
        // the on-disk array (and the array's only row, in
        // this test) so a subsequent `loadUserTemplates()`
        // returns an empty array.
        let storeURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(
            at: storeURL.deletingLastPathComponent()
        ) }

        let store = AIGeneratorTemplateStore(storeURL: storeURL)
        try store.addTemplate(AIGeneratorTemplate(
            id: "user-deadbeef",
            title: "Will be deleted",
            description: "Saved from your request",
            prompt: "Throwaway",
            systemImageName: "trash"
        ))
        #expect(store.loadUserTemplates().count == 1)

        try store.removeTemplate(id: "user-deadbeef")
        #expect(store.loadUserTemplates() == [])
    }

    @Test func testSaveUserTemplates_createsParentDirectory() throws {
        // The store must be able to write to a path whose
        // parent directory does not yet exist. The first
        // `addTemplate(_:)` (or `saveUserTemplates(_:)`)
        // call is the v1 moment that creates it.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "menubar01-AIGeneratorTemplateStoreTests",
                isDirectory: true
            )
            .appendingPathComponent(
                "createParent-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        let storeURL = parent.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("templates.json")
        defer { try? FileManager.default.removeItem(at: parent) }

        // Sanity check: the parent directory should not
        // exist yet (the test is meaningful only if we
        // observe creation).
        #expect(!FileManager.default.fileExists(atPath: parent.path))

        let store = AIGeneratorTemplateStore(storeURL: storeURL)
        try store.saveUserTemplates([
            AIGeneratorTemplate(
                id: "user-11111111",
                title: "First",
                description: "Saved from your request",
                prompt: "Hello",
                systemImageName: "doc.text"
            )
        ])

        // Parent directories were created and the file
        // round-trips on disk.
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(store.loadUserTemplates().count == 1)
    }
}

// MARK: - AIGeneratorTemplateGallery merging

struct AIGeneratorTemplateGalleryMergeTests {

    @Test func testGalleryAllTemplates_userOverridesBuiltIn() {
        // A user template with the same `id` as a built-in
        // shadows the built-in. This is the v1 contract for
        // power users who want to override a default prompt
        // without forking the gallery.
        let userSaved = [
            AIGeneratorTemplate(
                id: "weather",
                title: "User Weather",
                description: "Saved from your request",
                prompt: "Custom user prompt",
                systemImageName: "cloud.bolt"
            )
        ]
        let merged = AIGeneratorTemplateGallery.allTemplates(
            including: userSaved
        )
        #expect(merged.count == AIGeneratorTemplateGallery.builtInTemplates.count)
        let weatherEntry = merged.first(where: { $0.id == "weather" })
        #expect(weatherEntry?.title == "User Weather")
        #expect(weatherEntry?.systemImageName == "cloud.bolt")
    }

    @Test func testGalleryAllTemplates_userAppendsToBuiltIn() {
        // A user template with a fresh `user-…` id is
        // appended after the built-ins. The result must
        // have `builtInCount + userCount` rows.
        let userSaved = [
            AIGeneratorTemplate(
                id: "user-11111111",
                title: "User 1",
                description: "Saved from your request",
                prompt: "User 1 prompt",
                systemImageName: "doc.text"
            ),
            AIGeneratorTemplate(
                id: "user-22222222",
                title: "User 2",
                description: "Saved from your request",
                prompt: "User 2 prompt",
                systemImageName: "pencil"
            ),
        ]
        let merged = AIGeneratorTemplateGallery.allTemplates(
            including: userSaved
        )
        #expect(
            merged.count
                == AIGeneratorTemplateGallery.builtInTemplates.count + userSaved.count
        )
        // The user entries appear in the order they were
        // passed in (the merge is stable across calls).
        let userIDsInOrder = merged
            .filter { $0.id.hasPrefix("user-") }
            .map(\.id)
        #expect(userIDsInOrder == ["user-11111111", "user-22222222"])
    }
}

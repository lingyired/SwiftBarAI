// GeneratorHistoryExporterTests.swift
// menubar01 — AI Plugin Generator (M5 history follow-up)
//
// Swift Testing coverage for `GeneratorHistoryExporter`. The
// exporter's UI entry point drives an `NSSavePanel`, which is a
// modal we cannot run from the test bundle; the test exercises
// the lower-level `runZip(sourceDirectory:destination:)` helper
// directly so we can assert on the resulting archive without
// driving the panel.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// `AIGeneratorHistoryStore` backed by a per-test temp dir. Same
/// pattern as `AIGeneratorHistoryStoreTests` and
/// `GeneratorHistoryViewModelTests`.
private final class TempStore {
    let rootDirectory: URL
    let store: FileSystemAIGeneratorHistoryStore

    init() throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aigen-export-\(UUID().uuidString)", isDirectory: true)
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

private func makeEntry(
    promptId: String,
    request: String,
    menuTreeJSON: Data? = nil,
    endpointHost: String? = nil,
    model: String = "gpt-4o-mini"
) -> AIGeneratorHistoryEntry {
    var manifest = PluginManifest()
    manifest.name = "ExportTest"
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = "export.sh"
    let plugin = GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho \(promptId)\n",
        explanation: "export test",
        promptId: promptId,
        promptVersion: "v-export-test"
    )
    return AIGeneratorHistoryEntry(
        promptId: promptId,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        request: request,
        model: model,
        plugin: plugin,
        menuTreeJSON: menuTreeJSON,
        endpointHost: endpointHost
    )
}

/// Extract `zipURL` to a fresh temp directory using
/// `/usr/bin/unzip` and return the destination URL. The test
/// bundle uses this to assert on the zip's actual contents
/// (e.g. reading `MANIFEST.json` from the archive root) without
/// having to decode the `unzip -l` listing, which is only a
/// human-readable summary.
private func extractZip(
    _ zipURL: URL,
    to destinationParent: URL = URL(fileURLWithPath: NSTemporaryDirectory())
) throws -> URL {
    let extractDir = destinationParent
        .appendingPathComponent("export-extract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: extractDir,
        withIntermediateDirectories: true
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-o", zipURL.path, "-d", extractDir.path]
    try process.run()
    process.waitUntilExit()
    return extractDir
}

// MARK: - rootDirectory accessor

struct AIGeneratorHistoryStoreRootDirectoryTests {

    @Test func testRootDirectory_returnsConstructionPath() throws {
        let store = try TempStore()
        // The protocol's accessor must reflect the path the
        // store was actually constructed with, not the default
        // factory's `~/Library/Application Support/...` value.
        #expect(store.store.rootDirectory == store.rootDirectory)
        #expect(store.store.rootDirectory.lastPathComponent.isEmpty == false)
    }

    @Test func testRootDirectory_defaultForProtocol() {
        // The protocol extension falls through to the default
        // factory's path when a conforming type does not
        // override `rootDirectory`. We can't easily subclass a
        // `final` store in the test, but we can assert the
        // default factory's computed path is non-empty so a
        // future regression that returns `nil` is caught.
        let defaultPath = AIGeneratorHistoryStoreFactory.makeDefault().rootDirectory
        #expect(defaultPath.path.contains("AIGenerator"))
    }
}

// MARK: - exportEntry

struct GeneratorHistoryExporterTests {

    @Test func testExport_writesNonEmptyZipAndExitsZero() throws {
        let store = try TempStore()
        let entry = makeEntry(promptId: "export-1", request: "list two items")
        try store.store.record(entry)

        // Sanity check: the on-disk directory exists with the
        // expected files.
        let sourceDir = store.rootDirectory.appendingPathComponent("export-1")
        #expect(FileManager.default.fileExists(
            atPath: sourceDir.appendingPathComponent("request.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: sourceDir.appendingPathComponent("response.json").path
        ))

        // Zip into a sibling temp file.
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL
        )
        #expect(result == .success(destination: zipURL))
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attrs[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    @Test func testRunZip_succeeds_doesNotThrow() throws {
        // Sanity counterpart to `testExport_writesNonEmptyZipAndExitsZero`:
        // a happy-path source dir + destination must round-trip
        // through `runZip(...)` without throwing and must report
        // `.success`. This is the code path the new
        // reveal-in-Finder call lives on, so a regression that
        // broke the success branch would also break the UX
        // follow-up — keeping the test tiny and obvious.
        //
        // The reveal-in-Finder call itself is deliberately
        // not asserted on. NSWorkspace has no test seam (it is
        // a system singleton with no injection point in
        // `GeneratorHistoryExporter`), and adding a
        // `NSWorkspace` protocol abstraction for a single
        // one-liner would be over-engineering. The visible
        // behaviour (Finder pops up) is a UX nicety, not a
        // correctness requirement — the zip is still written
        // even if `activateFileViewerSelecting` is a no-op.
        let store = try TempStore()
        let entry = makeEntry(promptId: "export-sanity", request: "list two items")
        try store.store.record(entry)

        let sourceDir = store.rootDirectory.appendingPathComponent("export-sanity")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-sanity-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL
        )
        #expect(result == .success(destination: zipURL))
    }

    @Test func testExport_zipContainsRequestAndResponseFiles() throws {
        let store = try TempStore()
        let entry = makeEntry(
            promptId: "export-2",
            request: "show weather",
            menuTreeJSON: Data("[{\"title\":\"A\"}]".utf8)
        )
        try store.store.record(entry)

        let sourceDir = store.rootDirectory.appendingPathComponent("export-2")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL
        )
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        let listing = GeneratorHistoryExporter.listContents(ofZipAt: zipURL)
        #expect(listing.contains("request.txt"))
        #expect(listing.contains("response.json"))
        // The menu.json file is part of the audit log when
        // `menuTreeJSON` is non-nil. The listing should mention
        // it as one of the archived entries.
        #expect(listing.contains("menu.json"))
    }

    @Test func testExport_runZipFailsWhenSourceDirectoryIsMissing() throws {
        let store = try TempStore()
        // Do NOT record the entry — the on-disk directory does
        // not exist, so `/usr/bin/zip` exits non-zero and
        // `runZip(...)` surfaces `.zipFailed(reason:)`. The
        // sheet's UI-level `exportEntry(_:)` wrapper guards
        // against this with a pre-flight `fileExists` check
        // and returns `.missingDirectory(reason:)` instead,
        // but the test exercises the lower-level helper so
        // it does not need to drive an `NSSavePanel`.
        let phantom = store.rootDirectory.appendingPathComponent("ghost")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-ghost-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: phantom,
            destination: zipURL
        )
        // `zip` exits non-zero when the source directory does
        // not exist (`cannot open source directory: ...`),
        // which `runZip` translates to `.zipFailed(reason:)`.
        // The alternative `.launchFailed(reason:)` would only
        // be returned if `/usr/bin/zip` itself was missing —
        // macOS 12+ always ships it.
        switch result {
        case .zipFailed:
            break
        case .launchFailed:
            // Acceptable on a stripped-down system.
            break
        default:
            Issue.record("expected .zipFailed or .launchFailed, got \(result)")
        }
    }

    // MARK: - MANIFEST.json

    @Test func testExportEntry_zipContainsManifest() throws {
        let store = try TempStore()
        let entry = makeEntry(
            promptId: "export-manifest",
            request: "show weather",
            endpointHost: "api.openai.com"
        )
        try store.store.record(entry)

        let sourceDir = store.rootDirectory.appendingPathComponent("export-manifest")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-manifest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL,
            entry: entry
        )
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }

        // Unzip into a fresh temp dir and assert `MANIFEST.json`
        // is at the archive root (i.e. directly inside the
        // extraction directory, alongside the entry's files).
        let extractDir = try extractZip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let manifestURL = extractDir.appendingPathComponent("MANIFEST.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test func testExportEntry_manifestHasCorrectProvider() throws {
        let store = try TempStore()
        let entry = makeEntry(
            promptId: "export-remote",
            request: "show weather",
            endpointHost: "api.openai.com"
        )
        try store.store.record(entry)

        let sourceDir = store.rootDirectory.appendingPathComponent("export-remote")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-remote-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL,
            entry: entry
        )
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }

        let extractDir = try extractZip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let manifestURL = extractDir.appendingPathComponent("MANIFEST.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Remote runs serialise the provider as
        // `"remote:<endpointHost>"` so support tooling can
        // tell a remote bundle from a local / mock one
        // without having to crack open the entry's
        // `response.json`.
        #expect(json["provider"] as? String == "remote:api.openai.com")
    }

    @Test func testExportEntry_manifestProviderIsLocalForNilHost() throws {
        let store = try TempStore()
        let entry = makeEntry(
            promptId: "export-local",
            request: "show weather",
            endpointHost: nil,
            model: "local-model"
        )
        try store.store.record(entry)

        let sourceDir = store.rootDirectory.appendingPathComponent("export-local")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-local-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL,
            entry: entry
        )
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }

        let extractDir = try extractZip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let manifestURL = extractDir.appendingPathComponent("MANIFEST.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Local runs (no `endpointHost`) with a non-empty model
        // serialise the provider as `"local"`.
        #expect(json["provider"] as? String == "local")
    }

    @Test func testExportEntry_manifestHasCorrectEntryCount() throws {
        let store = try TempStore()
        let entry = makeEntry(promptId: "export-count", request: "show weather")
        try store.store.record(entry)

        let sourceDir = store.rootDirectory.appendingPathComponent("export-count")
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-count-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let result = GeneratorHistoryExporter.runZip(
            sourceDirectory: sourceDir,
            destination: zipURL,
            entry: entry
        )
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }

        let extractDir = try extractZip(zipURL)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let manifestURL = extractDir.appendingPathComponent("MANIFEST.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // The single-entry export path always sets
        // `entryCount: 1`; the multi-entry path is a follow-up
        // and will bump this when it lands.
        #expect(json["entryCount"] as? Int == 1)
    }
}

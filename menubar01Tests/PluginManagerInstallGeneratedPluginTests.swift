// PluginManagerInstallGeneratedPluginTests.swift
// menubar01 — AI Plugin Generator (M2 install flow)
//
// Swift Testing coverage for `PluginManager.installGeneratedPlugin(_:)`.
// Each test runs against a fresh per-test temp directory so the
// suite is hermetic, can run in parallel, and does not need a
// `setUp` / `tearDown` queue. The deinit of each test struct
// removes the temp dir after the `@Test` returns — Swift Testing
// instantiates a fresh value per test, so this is the right
// granularity for per-test cleanup.
//
// `PluginManager` is built with a per-test `PreferencesStore`
// backed by a per-test `UserDefaults(suiteName:)`. The shared
// singleton is intentionally NOT touched; the DI pattern mirrors
// the one in `PreferencesStore` so the test exercises the same
// surface the production app would after `PluginManager.shared`
// is wired up to a real prefs store.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a known `GeneratedPlugin` value for tests. Mirrors the
/// shape `MockAIPluginGenerator` produces (Echo) so the round-trip
/// is stable across M1 / M2 changes.
private func makeTestPlugin(
    promptId: String,
    entryFilename: String = "echo.sh",
    entryScript: String? = nil
) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = "Echo"
    manifest.version = "1.0.0"
    manifest.description = "Test description"
    manifest.author = "menubar01 tests"
    manifest.type = .Executable
    manifest.entry = entryFilename
    manifest.refreshInterval = 5
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: entryScript ?? "#!/bin/zsh\necho \(promptId)\n",
        explanation: "Test explanation",
        promptId: promptId,
        promptVersion: "v1.0-test"
    )
}

/// Build a fresh `PluginManager` whose `pluginDirectoryURL` is
/// pointed at `pluginDirectory` (a temp dir the caller has already
/// created). A per-test `UserDefaults(suiteName:)` isolates the
/// manager's prefs from any other test or the production app.
private func makeManager(
    pluginDirectory: URL?
) -> PluginManager {
    let suiteName = "menubar01.tests.install.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

// MARK: - installGeneratedPlugin success path

final class PluginManagerInstallGeneratedPluginSuccessTests {
    let pluginDirectory: URL
    let manager: PluginManager

    init() throws {
        pluginDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbar01-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        manager = makeManager(pluginDirectory: pluginDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: pluginDirectory)
    }

    @Test func testInstall_writesManifestAndEntryScriptUnderGeneratedFolder() throws {
        let plugin = makeTestPlugin(promptId: "abc123")

        let result = manager.installGeneratedPlugin(plugin)
        let url = try #require(try? result.get(), "install should succeed")

        // The subfolder is _generated/<sanitizedPromptId>.
        #expect(url.lastPathComponent == "abc123")
        #expect(url.deletingLastPathComponent().lastPathComponent == "_generated")

        // The manifest and entry script live next to each other.
        let manifestURL = url.appendingPathComponent("manifest.json")
        let entryURL = url.appendingPathComponent("echo.sh")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: entryURL.path))

        // manifest.json is the verbatim, pretty-printed bytes from
        // GeneratedPlugin.encodedAsBundle().
        let manifestData = try Data(contentsOf: manifestURL)
        #expect(!manifestData.isEmpty)
        let manifestString = try #require(String(data: manifestData, encoding: .utf8))
        #expect(manifestString.contains("Echo"))
        #expect(manifestString.contains("echo.sh"))

        // The entry script content round-trips verbatim.
        let entryData = try Data(contentsOf: entryURL)
        let entryString = try #require(String(data: entryData, encoding: .utf8))
        #expect(entryString.contains("abc123"))

        // The +x bit must be set so the script can be invoked by
        // the regular plugin runner.
        #expect(FileManager.default.isExecutableFile(atPath: entryURL.path))
    }

    @Test func testInstall_isIdempotentForSamePromptId() throws {
        let first = makeTestPlugin(
            promptId: "dup",
            entryFilename: "echo.sh",
            entryScript: "#!/bin/zsh\necho first\n"
        )
        let second = makeTestPlugin(
            promptId: "dup",
            entryFilename: "echo.sh",
            entryScript: "#!/bin/zsh\necho second\n"
        )

        let firstResult = manager.installGeneratedPlugin(first)
        let firstURL = try #require(try? firstResult.get(), "first install should succeed")
        let secondResult = manager.installGeneratedPlugin(second)
        let secondURL = try #require(try? secondResult.get(), "second install should succeed")

        // Same promptId → same subfolder, in-place overwrite.
        #expect(firstURL == secondURL)

        // The on-disk entry script is the second version, not the first.
        let entryURL = secondURL.appendingPathComponent("echo.sh")
        let entryData = try Data(contentsOf: entryURL)
        let entryString = try #require(String(data: entryData, encoding: .utf8))
        #expect(entryString.contains("second"))
        #expect(!entryString.contains("first"))
    }

    @Test func testInstall_sanitizesPathTraversalInPromptId() throws {
        let plugin = makeTestPlugin(promptId: "../../../etc/passwd")
        let result = manager.installGeneratedPlugin(plugin)
        let url = try #require(try? result.get(), "install should succeed")

        // The resolved subfolder stays under the plugin directory —
        // `..` and `/` must have been neutralized.
        let resolvedRoot = pluginDirectory.standardizedFileURL.path
        let resolvedTarget = url.standardizedFileURL.path
        #expect(resolvedTarget.hasPrefix(resolvedRoot))

        // No `..` or `/` survives in the subfolder name itself.
        #expect(!url.lastPathComponent.contains(".."))
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test func testInstall_replacesForwardSlashesInPromptId() throws {
        let plugin = makeTestPlugin(promptId: "sub/dir/name")
        let result = manager.installGeneratedPlugin(plugin)
        let url = try #require(try? result.get(), "install should succeed")
        #expect(url.lastPathComponent == "sub_dir_name")
    }

    @Test func testInstall_emptyPromptIdFallsBackToUnnamed() throws {
        let plugin = makeTestPlugin(promptId: "")
        let result = manager.installGeneratedPlugin(plugin)
        let url = try #require(try? result.get(), "install should succeed")
        #expect(url.lastPathComponent == "unnamed")
    }

    @Test func testInstall_promptIdLongerThan64CharsIsClipped() throws {
        let longId = String(repeating: "a", count: 100)
        let plugin = makeTestPlugin(promptId: longId)
        let result = manager.installGeneratedPlugin(plugin)
        let url = try #require(try? result.get(), "install should succeed")
        #expect(url.lastPathComponent.count == 64)
    }
}

// MARK: - installGeneratedPlugin failure path

final class PluginManagerInstallGeneratedPluginFailureTests {
    @Test func testInstall_returnsPluginDirectoryUnavailableWhenPrefsAreNil() throws {
        // No pluginDirectoryPath set → pluginDirectoryURL is nil
        // → install should refuse cleanly.
        let manager = makeManager(pluginDirectory: nil)

        let plugin = makeTestPlugin(promptId: "abc")
        let result = manager.installGeneratedPlugin(plugin)

        #expect(result == .failure(.pluginDirectoryUnavailable))
    }
}

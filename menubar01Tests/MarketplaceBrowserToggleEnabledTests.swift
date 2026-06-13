// MarketplaceBrowserToggleEnabledTests.swift
// menubar01 — PluginMarketplace (M5 enable/disable follow-up)
//
// Swift Testing coverage for the new
// `MarketplaceBrowserViewModel.toggleEnabled(for:)` method
// and the `isEnabled` field on `InstalledPluginSnapshot`.
// Pins down the contract:
//
//   1. A freshly-installed marketplace plugin is reported
//      as enabled (`snapshot.isEnabled == true`).
//   2. After the user disables a marketplace plugin
//      (the folder path is in
//      `PreferencesStore.disabledPlugins`), a refresh
//      surfaces `snapshot.isEnabled == false`.
//   3. `toggleEnabled(for:)` on a snapshot with
//      `isEnabled == true` adds the folder path to
//      `PreferencesStore.disabledPlugins` and re-emits a
//      snapshot with `isEnabled == false`.
//   4. `toggleEnabled(for:)` on a snapshot with
//      `isEnabled == false` removes the folder path
//      from `PreferencesStore.disabledPlugins` and
//      re-emits a snapshot with `isEnabled == true`.
//   5. `toggleEnabled(for:)` on a snapshot whose URL
//      matches no loaded `Plugin` in
//      `PluginManager.plugins` is a no-op — the
//      `disabledPlugins` set is not mutated.
//
// All tests are pure: each one wires a fresh
// `PluginManager` rooted at a per-test temp directory,
// a fresh `PreferencesStore` backed by an isolated
// `UserDefaults(suiteName:)`, and uses
// `manager.loadPlugin(fileURL:)` to construct a real
// `FolderPlugin` from the on-disk marketplace install
// (no script-execution dependency — the operation is
// enqueued and the test does not wait for the script
// to finish; the test only needs the plugin in
// `manager.plugins` so the toggle can find it).
//
// Target: 5 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test helpers

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at `pluginDirectory`. Mirrors the helper in
/// `MarketplaceBrowserViewModelTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.toggle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

/// Build a fresh temp directory for the toggle tests,
/// registers a deinit-time cleanup, and returns the URL
/// alongside a `PluginManager` rooted there.
private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-toggle-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Write a marketplace install's `manifest.json` + entry
/// script to
/// `<tempDir>/_marketplace/<folder>/...`. Mirrors the
/// layout `installMarketplacePlugin(plan:overwriteExisting:)`
/// produces so the existing `manager.loadPlugin(fileURL:)`
/// path can build a real `FolderPlugin` from it (which
/// the toggle test then injects into
/// `manager.plugins`).
@discardableResult
private func stageMarketplaceInstall(
    in tempDir: URL,
    folder: String = "battery-watch",
    manifestJSON: String? = nil,
    entryScript: String? = nil,
    entryFilename: String = "battery-watch.sh"
) throws -> URL {
    let marketplaceRoot = tempDir
        .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
    let installDir = marketplaceRoot.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
    let manifestURL = installDir.appendingPathComponent(pluginManifestFileName)
    // The default manifest mirrors the M5 install path's
    // layout: it declares `entry` explicitly so
    // `FolderPlugin.init?(manifestDirectory:manifest:)` does
    // not fall through to the `plugin.*` filename
    // discovery. The toggle test's `loadPlugin` call would
    // otherwise refuse to build a `FolderPlugin` because
    // the script is named `battery-watch.sh`, not
    // `plugin.sh`.
    let body = manifestJSON ?? """
    {
      "name": "Battery Watch",
      "version": "1.0.0",
      "entry": "\(entryFilename)"
    }
    """
    try body.write(to: manifestURL, atomically: true, encoding: .utf8)
    let scriptURL = installDir.appendingPathComponent(entryFilename)
    let script = entryScript ?? "#!/bin/zsh\necho Battery\n"
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    // The marketplace install path marks the entry
    // script executable; the test mirrors that so
    // `makeScriptExecutable(file:)` inside FolderPlugin
    // is a no-op (and a `chmod` failure in a temp dir
    // is also a no-op).
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path
    )
    return installDir
}

// MARK: - Tests

@MainActor
struct MarketplaceBrowserToggleEnabledTests {

    // 1

    @Test func testInstalledSnapshot_isEnabledByDefault() {
        // Stage a marketplace install. With the prefs
        // store empty, `refreshInstalledPlugins()`
        // should report the plugin as enabled (no
        // folder path in `disabledPlugins`).
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let installURL = try! stageMarketplaceInstall(in: tempDir)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        #expect(snapshot.url == installURL.standardizedFileURL)
        #expect(snapshot.isEnabled == true)
        // Sanity: the pref has not been touched.
        #expect(manager.prefs.disabledPlugins.isEmpty)
    }

    // 2

    @Test func testInstalledSnapshot_disabledAfterPrefSet() {
        // Stage a marketplace install, manually add
        // the folder's resolved path to
        // `disabledPlugins`, then refresh — the
        // snapshot's `isEnabled` must flip to
        // `false`.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let installURL = try! stageMarketplaceInstall(in: tempDir)
        let resolvedPath = installURL.resolvingSymlinksInPath().path

        manager.prefs.disablePlugin(resolvedPath)
        #expect(manager.prefs.disabledPlugins == [resolvedPath])

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        #expect(snapshot.isEnabled == false)
    }

    // 3

    @Test func testToggleEnabled_disablesLoadedPlugin() throws {
        // Stage a marketplace install, load it via
        // `manager.loadPlugin(fileURL:)` to build a
        // real `FolderPlugin`, then inject the
        // plugin into `manager.plugins` so the
        // toggle's lookup finds it. Call
        // `toggleEnabled(for:)` on the snapshot and
        // verify the pref set now contains the
        // folder path and the snapshot's
        // `isEnabled` is `false`.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let installURL = try! stageMarketplaceInstall(in: tempDir)
        let resolvedPath = installURL.resolvingSymlinksInPath().path

        // The directory observer is configured in
        // `#if !MAC_APP_STORE`; clean it up after
        // the test so subsequent tests in the same
        // process do not see a stale observer.
        defer { manager.directoryObserver = nil }

        guard let loadedPlugin = manager.loadPlugin(fileURL: installURL) else {
            Issue.record("loadPlugin returned nil for a staged install at \(installURL.path)")
            return
        }
        // Inject the plugin so `toggleEnabled`'s
        // `manager.plugins.first(where:)` lookup
        // succeeds. The `plugins` setter fires
        // `pluginsDidChange()` which creates a
        // MenubarItem; that path is safe in tests
        // (NSStatusItem is permitted in xctest
        // hosts) but it does enqueue an
        // `invokeQueue` operation. The operation
        // runs the script asynchronously; we do
        // not wait for it because the test only
        // cares about the `prefs.disabledPlugins`
        // mutation.
        manager.plugins = [loadedPlugin]
        defer { manager.plugins.removeAll() }
        defer { manager.menuBarItems.removeAll() }

        // Sanity check before refresh: the plugin
        // should be in `manager.plugins` with id
        // matching the symlink-resolved folder path.
        // This is the same key the toggle's lookup
        // will use.
        #expect(manager.plugins.contains(where: { $0.id == resolvedPath }),
                "Expected manager.plugins to contain a plugin with id \(resolvedPath) — got ids \(manager.plugins.map(\.id))")

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let enabledSnapshot = viewModel.installedPlugins[0]
        #expect(enabledSnapshot.isEnabled == true)
        // Pref is empty before the toggle.
        #expect(manager.prefs.disabledPlugins.isEmpty)

        // Sanity check after refresh too — the
        // `manager.plugins = [loadedPlugin]` setter
        // fired `pluginsDidChange()` which can
        // mutate `manager.plugins` indirectly (e.g.
        // if a plugin was filtered out as
        // non-loadable). The id is what the toggle
        // looks up; if it has drifted, the toggle
        // is a no-op.
        #expect(manager.plugins.contains(where: { $0.id == resolvedPath }),
                "After refresh: Expected manager.plugins to contain a plugin with id \(resolvedPath) — got ids \(manager.plugins.map(\.id))")

        viewModel.toggleEnabled(for: enabledSnapshot)

        // Pref now contains the folder path; the
        // snapshot has flipped to disabled.
        #expect(manager.prefs.disabledPlugins == [resolvedPath])
        #expect(viewModel.installedPlugins.count == 1)
        #expect(viewModel.installedPlugins[0].isEnabled == false)
    }

    // 4

    @Test func testToggleEnabled_enablesDisabledPlugin() throws {
        // Same shape as test 3, but the pref is
        // pre-populated with the folder path so
        // `toggleEnabled` re-enables the plugin.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let installURL = try! stageMarketplaceInstall(in: tempDir)
        let resolvedPath = installURL.resolvingSymlinksInPath().path

        defer { manager.directoryObserver = nil }

        // Pre-disable the plugin in the pref so
        // the snapshot is built with
        // `isEnabled == false`.
        manager.prefs.disablePlugin(resolvedPath)
        #expect(manager.prefs.disabledPlugins == [resolvedPath])

        guard let loadedPlugin = manager.loadPlugin(fileURL: installURL) else {
            Issue.record("loadPlugin returned nil for a staged install at \(installURL.path)")
            return
        }
        manager.plugins = [loadedPlugin]
        defer { manager.plugins.removeAll() }
        defer { manager.menuBarItems.removeAll() }

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let disabledSnapshot = viewModel.installedPlugins[0]
        #expect(disabledSnapshot.isEnabled == false)

        viewModel.toggleEnabled(for: disabledSnapshot)

        // Pref no longer contains the folder path;
        // the snapshot has flipped to enabled.
        #expect(manager.prefs.disabledPlugins.isEmpty)
        #expect(viewModel.installedPlugins.count == 1)
        #expect(viewModel.installedPlugins[0].isEnabled == true)
    }

    // 5

    @Test func testToggleEnabled_noMatchingPluginIsNoOp() {
        // Build a snapshot whose URL points at a
        // directory that does not exist (and was
        // never loaded into `manager.plugins`).
        // `toggleEnabled(for:)` must be a defensive
        // no-op — the pref set is not mutated.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        // No marketplace install staged. The
        // manager has no plugins.
        let ghost = tempDir
            .appendingPathComponent("_marketplace", isDirectory: true)
            .appendingPathComponent("ghost", isDirectory: true)
        let snapshot = MarketplaceBrowserViewModel.InstalledPluginSnapshot(
            id: ghost.standardizedFileURL.path,
            url: ghost.standardizedFileURL,
            name: "Ghost",
            version: nil,
            manifestVersion: nil,
            lastUpdated: nil,
            isEnabled: true
        )

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )

        viewModel.toggleEnabled(for: snapshot)

        // Pref is still empty — the toggle did not
        // mutate anything.
        #expect(manager.prefs.disabledPlugins.isEmpty)
    }
}

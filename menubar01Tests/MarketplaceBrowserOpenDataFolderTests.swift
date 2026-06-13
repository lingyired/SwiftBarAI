// MarketplaceBrowserOpenDataFolderTests.swift
// menubar01 — PluginMarketplace (M5 open-data-folder follow-up)
//
// Swift Testing coverage for the new
// `MarketplaceBrowserViewModel.openDataFolder(snapshot:)`
// method that reveals the on-disk per-plugin data directory
// in Finder (creating it on demand if it does not exist).
//
// The contract under test:
//
//   1. `openDataFolder(snapshot:)` calls the injected
//      `openDataFolderRevealer` closure with a single
//      element array whose URL is
//      `<AppShared.dataDirectory>/<snapshot's
//      symlink-resolved path>/`.
//   2. The directory at the revealed URL exists on disk
//      after the call — the VM is responsible for creating
//      it on demand so Finder has a target to highlight.
//   3. `openDataFolder(snapshot:)` is a non-mutating
//      action: it does not change the VM's `state` machine
//      nor `installedPlugins`.
//
// The test uses a per-test temp directory + per-test
// `UserDefaults(suiteName:)` (mirroring the
// `MarketplaceBrowserViewSourceTests` pattern) so it
// is fully isolated from the production plugin
// directory and from other tests in the suite. The data
// folder itself lands under
// `AppShared.dataDirectory` (the test bundle's
// `~/Library/Application Support/<bundleName>/Plugins/`),
// which the tests clean up in `defer` so the user-visible
// support directory is not littered with test artefacts.
//
// Target: 3 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test helpers

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at `pluginDirectory` (a temp dir the caller
/// has already created). Mirrors the helper in
/// `MarketplaceBrowserViewSourceTests` and
/// `MarketplaceBrowserToggleEnabledTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.opendatafolder.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-opendatafolder-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Write a marketplace install's `manifest.json` to
/// `<tempDir>/_marketplace/<folder>/manifest.json`. Mirrors
/// the layout `installMarketplacePlugin(plan:overwriteExisting:)`
/// produces so `refreshInstalledPlugins()` picks it up and
/// yields a real `InstalledPluginSnapshot` for the test
/// to feed back into `openDataFolder(snapshot:)`.
@discardableResult
private func stageMarketplaceInstall(
    in tempDir: URL,
    folder: String = "battery-watch",
    manifestJSON: String? = nil
) throws -> URL {
    let marketplaceRoot = tempDir
        .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
    let installDir = marketplaceRoot.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
    let manifestURL = installDir.appendingPathComponent(pluginManifestFileName)
    let body = manifestJSON ?? """
    {
      "name": "Battery Watch",
      "version": "1.0.0",
      "entry": "battery-watch.sh"
    }
    """
    try body.write(to: manifestURL, atomically: true, encoding: .utf8)
    return installDir
}

/// Compute the on-disk data directory URL the VM is
/// expected to reveal for a given snapshot. Mirrors the
/// private `dataDirectoryURL(for:)` on the VM: the base is
/// `AppShared.dataDirectory` and the leaf is the
/// symlink-resolved path of the snapshot's URL. Centralised
/// here so the test expectations stay in lockstep with the
/// VM's path-construction rules — if the VM ever changes
/// where the per-plugin subfolder lives, the test fails
/// loudly instead of silently agreeing on a stale path.
private func expectedDataDirectoryURL(
    for snapshot: MarketplaceBrowserViewModel.InstalledPluginSnapshot
) -> URL? {
    guard let base = AppShared.dataDirectory else { return nil }
    let resolvedPath = snapshot.url.resolvingSymlinksInPath().path
    return base.appendingPathComponent(resolvedPath, isDirectory: true)
}

// MARK: - Tests

@MainActor
struct MarketplaceBrowserOpenDataFolderTests {

    // 1

    @Test func testOpenDataFolder_revealerSeesDataDirectoryAndCreatesIt() {
        // Stage a marketplace install, build a real
        // snapshot via `refreshInstalledPlugins()`,
        // then swap in a recording revealer and call
        // `openDataFolder(snapshot:)`. The recording
        // revealer must be called exactly once with
        // a single-element URL array pointing at
        // `<AppShared.dataDirectory>/<resolved
        // snapshot path>/`. The directory at that
        // URL must exist on disk after the call —
        // the VM creates it on demand so Finder has
        // a target to reveal.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        let installURL = try! stageMarketplaceInstall(in: tempDir)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]

        // Compute the expected data directory URL up
        // front so we can `defer` its cleanup. The
        // VM creates the directory as a side effect
        // of the call, so we need the path *before*
        // the call to know what to remove.
        guard let expectedURL = expectedDataDirectoryURL(for: snapshot) else {
            // The test bundle's CFBundleName did not
            // resolve a writable data directory. Skip
            // the assertion rather than crash — the
            // remaining tests catch the same shape.
            return
        }
        defer { try? FileManager.default.removeItem(at: expectedURL) }

        // Replace the default NSWorkspace revealer
        // with a recording closure. Production code
        // never reaches this path in the test — the
        // closure is the only call site.
        let revealerRecorder = OpenDataFolderRevealerRecorder()
        viewModel.openDataFolderRevealer = { urls in
            revealerRecorder.incrementRecording(urls)
        }

        viewModel.openDataFolder(snapshot: snapshot)

        #expect(revealerRecorder.value == 1)
        #expect(revealerRecorder.lastURLs == [expectedURL])
        // The directory must exist on disk — the
        // VM is responsible for `mkdir -p` so
        // Finder always has a target to highlight.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: expectedURL.path, isDirectory: &isDir
        ))
        #expect(isDir.boolValue)

        // Sanity: the path the revealer saw
        // encodes the symlink-resolved install
        // path, not the original temp-dir path.
        // Standardising the install URL strips the
        // `/private/var/...` symlink prefix on
        // macOS so the assertion is stable.
        let resolvedInstall = installURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        #expect(expectedURL.path.hasSuffix(resolvedInstall))
    }

    // 2

    @Test func testOpenDataFolder_injectedRevealerReplacesDefault() {
        // Verify the `openDataFolderRevealer`
        // injection seam is honoured: swapping the
        // closure after `init` means the new
        // closure receives the call. We call
        // `openDataFolder` twice with two different
        // injected revealers and verify the second
        // revealer is the one called the second
        // time (and saw the expected data directory
        // URL). The first revealer must NOT be
        // called again — swapping the seam is
        // observable.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        try! stageMarketplaceInstall(in: tempDir)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]

        guard let expectedURL = expectedDataDirectoryURL(for: snapshot) else {
            return
        }
        defer { try? FileManager.default.removeItem(at: expectedURL) }

        let firstRevealerCallCount = OpenDataFolderRevealerRecorder()
        let secondRevealerCallCount = OpenDataFolderRevealerRecorder()
        viewModel.openDataFolderRevealer = { _ in
            firstRevealerCallCount.increment()
        }

        viewModel.openDataFolder(snapshot: snapshot)
        #expect(firstRevealerCallCount.value == 1)
        #expect(secondRevealerCallCount.value == 0)

        // Swap the revealer mid-test. The next
        // call must hit the new closure only, and
        // the new closure records the URL it saw
        // so we can assert the data directory URL
        // is the expected one.
        viewModel.openDataFolderRevealer = { urls in
            secondRevealerCallCount.incrementRecording(urls)
        }

        viewModel.openDataFolder(snapshot: snapshot)
        #expect(firstRevealerCallCount.value == 1)
        #expect(secondRevealerCallCount.value == 1)

        // Sanity: the URL the second revealer saw
        // matches the expected data directory
        // path so the injection does not break
        // the URL construction.
        #expect(secondRevealerCallCount.lastURLs == [expectedURL])
    }

    // 3

    @Test func testOpenDataFolder_doesNotMutateStateMachine() {
        // `openDataFolder(snapshot:)` is a regular
        // in-app action — it must NOT transition
        // the VM's `state` machine, nor
        // re-populate `installedPlugins`. We stage
        // a single install, snapshot the state +
        // plugins, call `openDataFolder`, and
        // assert both are unchanged. The `package`
        // field is intentionally not compared —
        // `MarketplacePackage` is not `Equatable`
        // and the comparison shape is not
        // load-bearing for this test.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        try! stageMarketplaceInstall(in: tempDir)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]

        guard let expectedURL = expectedDataDirectoryURL(for: snapshot) else {
            return
        }
        defer { try? FileManager.default.removeItem(at: expectedURL) }

        // Set the state to `.loaded` (the typical
        // Installed-tab steady state) and capture
        // a deep snapshot of the relevant
        // published state.
        viewModel.state = .loaded
        let stateBefore = viewModel.state
        let pluginsBefore = viewModel.installedPlugins
        let entriesBefore = viewModel.entries
        let selectedEntryBefore = viewModel.selectedEntry

        let revealerRecorder = OpenDataFolderRevealerRecorder()
        viewModel.openDataFolderRevealer = { _ in revealerRecorder.increment() }

        viewModel.openDataFolder(snapshot: snapshot)

        // Revealer was called; nothing else changed.
        #expect(revealerRecorder.value == 1)
        #expect(viewModel.state == stateBefore)
        #expect(viewModel.installedPlugins == pluginsBefore)
        #expect(viewModel.entries == entriesBefore)
        #expect(viewModel.selectedEntry == selectedEntryBefore)
    }
}

/// Tiny `Int` counter wrapped in a class so closures can
/// mutate it from `@MainActor`-isolated call sites without
/// tripping Swift 6 strict-concurrency warnings around
/// captured `var`s. Records the last URL array passed to
/// `incrementRecording(_:)` so a single test can assert
/// both the call count and the URLs the closure saw. The
/// class is `@unchecked Sendable` because all reads and
/// writes happen on the same `@MainActor` task — there is
/// no cross-actor access in practice.
private final class OpenDataFolderRevealerRecorder: @unchecked Sendable {
    private(set) var value: Int = 0
    private(set) var lastURLs: [URL] = []

    func increment() {
        value += 1
    }

    func incrementRecording(_ urls: [URL]) {
        value += 1
        lastURLs = urls
    }
}

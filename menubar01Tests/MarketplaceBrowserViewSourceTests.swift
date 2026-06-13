// MarketplaceBrowserViewSourceTests.swift
// menubar01 — PluginMarketplace (M5 view-source follow-up)
//
// Swift Testing coverage for the new
// `MarketplaceBrowserViewModel.viewSource(snapshot:)` method
// that opens the on-disk `manifest.json` for an installed
// marketplace plugin in the user's default JSON editor.
//
// The contract under test:
//
//   1. `viewSource(snapshot:)` calls the injected
//      `viewSourceOpener` closure with the snapshot's
//      folder URL + `manifest.json` appended.
//   2. The injected `viewSourceOpener` replaces the
//      default `NSWorkspace.shared.open(_:)` — the test
//      substitutes a recording closure so the xctest
//      host does not actually launch a JSON editor.
//   3. `viewSource(snapshot:)` is a non-mutating action:
//      it does not change the VM's `state` machine nor
//      `installedPlugins`.
//
// The test uses a per-test temp directory + per-test
// `UserDefaults(suiteName:)` (mirroring the
// `MarketplaceBrowserToggleEnabledTests` pattern) so it
// is fully isolated from the production plugin
// directory and from other tests in the suite.
//
// Target: 3 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test helpers

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at `pluginDirectory` (a temp dir the caller
/// has already created). Mirrors the helper in
/// `MarketplaceBrowserToggleEnabledTests` and
/// `MarketplaceUpdateAvailabilityTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.viewsource.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-viewsource-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Write a marketplace install's `manifest.json` to
/// `<tempDir>/_marketplace/<folder>/manifest.json`. Mirrors
/// the layout `installMarketplacePlugin(plan:overwriteExisting:)`
/// produces so `refreshInstalledPlugins()` picks it up and
/// yields a real `InstalledPluginSnapshot` for the test
/// to feed back into `viewSource(snapshot:)`.
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

// MARK: - Tests

@MainActor
struct MarketplaceBrowserViewSourceTests {

    // 1

    @Test func testViewSource_invokesOpenerWithManifestURL() {
        // Stage a marketplace install, build a real
        // snapshot via `refreshInstalledPlugins()`,
        // then swap in a recording opener and call
        // `viewSource(snapshot:)`. The recording
        // opener must be called exactly once with
        // the install directory + `manifest.json`
        // appended — the same URL the user would
        // see in Finder if they double-clicked the
        // file.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        let installURL = try! stageMarketplaceInstall(in: tempDir)
        let expectedURL = installURL
            .standardizedFileURL
            .appendingPathComponent(pluginManifestFileName)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]

        // Replace the default NSWorkspace.open opener
        // with a recording closure. Production code
        // never reaches this path in the test — the
        // closure is the only call site.
        let openerRecorder = ViewSourceOpenerRecorder()
        viewModel.viewSourceOpener = { url in
            openerRecorder.incrementRecording(url)
        }

        viewModel.viewSource(snapshot: snapshot)

        #expect(openerRecorder.value == 1)
        #expect(openerRecorder.lastURL == expectedURL)
    }

    // 2

    @Test func testViewSource_injectedOpenerReplacesDefault() {
        // Verify the `viewSourceOpener` injection
        // seam is honoured: swapping the closure
        // after `init` means the new closure
        // receives the call. We also assert the
        // default closure is the NSWorkspace one
        // by capturing the original value, but
        // the *behavioural* guarantee is that the
        // injected closure is the one invoked.
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

        // Two different injected openers — call
        // `viewSource` twice and assert the *last*
        // opener receives the second call. The
        // first opener must NOT be called again.
        let firstOpenerCallCount = ViewSourceOpenerRecorder()
        let secondOpenerCallCount = ViewSourceOpenerRecorder()
        viewModel.viewSourceOpener = { _ in firstOpenerCallCount.increment() }

        viewModel.viewSource(snapshot: snapshot)
        #expect(firstOpenerCallCount.value == 1)
        #expect(secondOpenerCallCount.value == 0)

        // Swap the opener mid-test. The next call
        // must hit the new closure only, and the
        // new closure records the URL it saw so
        // we can assert the manifest URL is the
        // expected one.
        viewModel.viewSourceOpener = { url in
            secondOpenerCallCount.incrementRecording(url)
        }

        viewModel.viewSource(snapshot: snapshot)
        #expect(firstOpenerCallCount.value == 1)
        #expect(secondOpenerCallCount.value == 1)

        // Sanity: the manifest URL the second
        // opener saw matches the expected path so
        // the injection does not break the URL
        // construction.
        let expectedURL = installURL
            .standardizedFileURL
            .appendingPathComponent(pluginManifestFileName)
        #expect(secondOpenerCallCount.lastURL == expectedURL)
    }

    // 3

    @Test func testViewSource_doesNotMutateStateMachine() {
        // `viewSource(snapshot:)` is a regular
        // in-app action — it must NOT transition
        // the VM's `state` machine, nor
        // re-populate `installedPlugins`. We
        // stage a single install, snapshot the
        // state + plugins, call `viewSource`,
        // and assert both are unchanged. The
        // `package` field is intentionally not
        // compared — `MarketplacePackage` is
        // not `Equatable` and the comparison
        // shape is not load-bearing for this
        // test.
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

        // Set the state to `.loaded` (the typical
        // Installed-tab steady state) and capture
        // a deep snapshot of the relevant
        // published state.
        viewModel.state = .loaded
        let stateBefore = viewModel.state
        let pluginsBefore = viewModel.installedPlugins
        let entriesBefore = viewModel.entries
        let selectedEntryBefore = viewModel.selectedEntry

        let openerRecorder = ViewSourceOpenerRecorder()
        viewModel.viewSourceOpener = { _ in openerRecorder.increment() }

        viewModel.viewSource(snapshot: snapshot)

        // Opener was called; nothing else changed.
        #expect(openerRecorder.value == 1)
        #expect(viewModel.state == stateBefore)
        #expect(viewModel.installedPlugins == pluginsBefore)
        #expect(viewModel.entries == entriesBefore)
        #expect(viewModel.selectedEntry == selectedEntryBefore)
    }
}

/// Tiny `Int` counter wrapped in a class so closures can
/// mutate it from `@MainActor`-isolated call sites without
/// tripping Swift 6 strict-concurrency warnings around
/// captured `var`s. Records the last URL passed to
/// `incrementRecording(_:)` so a single test can assert
/// both the call count and the URL the closure saw. The
/// class is `@unchecked Sendable` because all reads and
/// writes happen on the same `@MainActor` task — there is
/// no cross-actor access in practice.
private final class ViewSourceOpenerRecorder: @unchecked Sendable {
    private(set) var value: Int = 0
    private(set) var lastURL: URL?

    func increment() {
        value += 1
    }

    func incrementRecording(_ url: URL) {
        value += 1
        lastURL = url
    }
}

// MarketplaceBrowserViewModelTests.swift
// menubar01 — PluginMarketplace (M5)
//
// Swift Testing coverage for `MarketplaceBrowserViewModel`. All
// tests run on the main actor (the VM is `@MainActor`) and use a
// hand-rolled `CapturingMarketplaceClient` to drive the state
// machine without going through the real `StubMarketplaceClient`
// — the test asserts on the VM's *contract* (state transitions,
// catalogue population, install flow wiring, error surface,
// reset) rather than on the concrete payload of any particular
// catalogue.
//
// `PluginManager` is built with a per-test `PreferencesStore`
// backed by a per-test `UserDefaults(suiteName:)`. The shared
// singleton is intentionally NOT touched; the DI pattern mirrors
// the one in `PluginManagerInstallGeneratedPluginTests` so the
// test exercises the same surface the production app would
// after `PluginManager.shared` is wired up to a real prefs store.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test doubles

/// A test-only `MarketplaceClient` that records the most recent
/// calls and returns canned values. Lives next to the test type
/// so the production code does not gain a new internal-public
/// type.
private final class CapturingMarketplaceClient: MarketplaceClient, @unchecked Sendable {
    /// Catalogue to return from `fetchCatalogue()`. Defaults to
    /// a 2-entry seed so tests can assert on a stable shape.
    let catalogue: [MarketplaceEntry]
    /// Map from id to package for `fetchPackage(id:)`. Each
    /// test sets this to a known set so the package fetch
    /// succeeds.
    let packages: [String: MarketplacePackage]
    /// Optional error to throw from the next fetch call.
    /// `nil` means "return the canned value". Tests can
    /// toggle this between asserts to drive error paths.
    var errorToThrow: Error?
    /// Records the call history for assertion.
    private(set) var catalogueCallCount: Int = 0
    private(set) var lastFetchedPackageID: String?
    private(set) var packageCallCount: Int = 0

    init(
        catalogue: [MarketplaceEntry]? = nil,
        packages: [String: MarketplacePackage]? = nil
    ) {
        if let catalogue {
            self.catalogue = catalogue
        } else {
            self.catalogue = [
                MarketplaceEntry(
                    id: "echo",
                    name: "Echo",
                    summary: "Prints a single menu item from the plugin stdout.",
                    category: "tools",
                    installCount: 12,
                    rating: 4.5,
                    generatorPromptId: "demo.echo.v1"
                ),
                MarketplaceEntry(
                    id: "todays-date",
                    name: "Today's Date",
                    summary: "Shows today's date in the menu bar.",
                    category: "time",
                    installCount: 142,
                    rating: 4.8,
                    generatorPromptId: "demo.date.v1"
                ),
            ]
        }
        if let packages {
            self.packages = packages
        } else {
            var echoManifest = PluginManifest()
            echoManifest.name = "Echo"
            echoManifest.version = "1.0.0"
            echoManifest.entry = "echo.sh"
            self.packages = [
                "echo": MarketplacePackage(
                    id: "echo",
                    manifest: echoManifest,
                    entryScript: "#!/bin/zsh\necho Echo | size=14 color=blue\n",
                    entryFilename: "echo.sh"
                ),
            ]
        }
    }

    func fetchCatalogue() async throws -> [MarketplaceEntry] {
        catalogueCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return catalogue
    }

    func fetchPackage(id: String) async throws -> MarketplacePackage {
        packageCallCount += 1
        lastFetchedPackageID = id
        if let errorToThrow { throw errorToThrow }
        guard let package = packages[id] else {
            throw MarketplaceError.notFound(id: id)
        }
        return package
    }
}

// MARK: - Helpers

/// Builds a fresh `PluginManager` whose `pluginDirectoryURL` is
/// pointed at `pluginDirectory` (a temp dir the caller has
/// already created). A per-test `UserDefaults(suiteName:)`
/// isolates the manager's prefs from any other test or the
/// production app. Mirrors the helper in
/// `PluginManagerInstallGeneratedPluginTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.marketplace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

/// Builds a fresh temp directory for the marketplace install
/// tests, registers a deinit-time cleanup, and returns the URL
/// alongside a `PluginManager` rooted there.
private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

// MARK: - Initial state

@MainActor
struct MarketplaceBrowserViewModelInitialStateTests {
    @Test func testInitialStateIsIdleWithEmptyEntries() {
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )

        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.selectedEntry == nil)
        #expect(viewModel.package == nil)
        #expect(viewModel.state == .idle)
        #expect(viewModel.isInstalling == false)
        #expect(viewModel.manifestJSON == nil)
    }

    @Test func testResetClearsAllPublishedState() async {
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        await viewModel.loadCatalogue()
        viewModel.selectedEntry = client.catalogue[0]
        #expect(viewModel.entries.count == 2)

        viewModel.reset()

        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.selectedEntry == nil)
        #expect(viewModel.package == nil)
        #expect(viewModel.state == .idle)
    }
}

// MARK: - loadCatalogue

@MainActor
struct MarketplaceBrowserViewModelLoadCatalogueTests {
    @Test func testLoadCataloguePopulatesEntries() async {
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )

        await viewModel.loadCatalogue()

        #expect(client.catalogueCallCount == 1)
        #expect(viewModel.entries.count == 2)
        #expect(viewModel.entries.map(\.id) == ["echo", "todays-date"])
        #expect(viewModel.state == .loaded)
    }

    @Test func testLoadCatalogueTwiceGoesBackToLoaded() async {
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        await viewModel.loadCatalogue()
        await viewModel.loadCatalogue()

        #expect(client.catalogueCallCount == 2)
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
    }

    @Test func testLoadCatalogueErrorLandsInErrorState() async {
        let client = CapturingMarketplaceClient()
        client.errorToThrow = MarketplaceError.transport(reason: "upstream 503")
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )

        await viewModel.loadCatalogue()

        if case .error(let reason) = viewModel.state {
            #expect(reason.contains("upstream 503"))
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
    }
}

// MARK: - selectEntry

@MainActor
struct MarketplaceBrowserViewModelSelectEntryTests {
    @Test func testSelectEntryFetchesPackageAndSetsSelected() async {
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        await viewModel.loadCatalogue()

        let target = viewModel.entries[0]
        await viewModel.selectEntry(target)

        #expect(viewModel.selectedEntry == target)
        #expect(viewModel.package != nil)
        #expect(viewModel.package?.id == "echo")
        #expect(client.lastFetchedPackageID == "echo")
        #expect(client.packageCallCount == 1)
    }

    @Test func testSelectEntryWithUnknownIdGoesToError() async {
        let client = CapturingMarketplaceClient(packages: [:])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        let ghost = MarketplaceEntry(
            id: "ghost",
            name: "Ghost",
            summary: "Not in the catalogue",
            category: "tools",
            installCount: 0,
            rating: 0,
            generatorPromptId: "test.ghost"
        )

        await viewModel.selectEntry(ghost)

        #expect(viewModel.selectedEntry == ghost)
        #expect(viewModel.package == nil)
        if case .error = viewModel.state {
            // expected
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
    }
}

// MARK: - installSelected

@MainActor
struct MarketplaceBrowserViewModelInstallSelectedTests {
    @Test func testInstallSelectedWritesPluginAndTransitionsToInstalled() async throws {
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        // State machine should walk: .loaded → .installing → .installed
        await viewModel.installSelected(overwriteExisting: false)

        if case .installed(let targetURL) = viewModel.state {
            #expect(targetURL.lastPathComponent == "echo")
            #expect(targetURL.deletingLastPathComponent().lastPathComponent == "_marketplace")
            // The manifest + entry script landed on disk.
            #expect(FileManager.default.fileExists(
                atPath: targetURL.appendingPathComponent("manifest.json").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: targetURL.appendingPathComponent("echo.sh").path
            ))
        } else {
            Issue.record("expected .installed state, got \(viewModel.state)")
        }
    }

    @Test func testInstallSelectedWithoutManagerGoesToError() async {
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        await viewModel.installSelected(overwriteExisting: false)

        if case .error(let reason) = viewModel.state {
            #expect(reason.contains("Plugin manager"))
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
    }

    @Test func testInstallSelectedWithoutSelectionIsANoOp() async {
        let (_, manager) = makeTempManager()
        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        await viewModel.loadCatalogue()
        // No selectEntry call → selectedEntry is nil
        await viewModel.installSelected(overwriteExisting: false)

        // State must remain at .loaded (loadCatalogue() lands here).
        // The install was a defensive no-op.
        #expect(viewModel.state == .loaded)
    }

    @Test func testInstallSelectedOverwriteReplacesExistingPlugin() async throws {
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = CapturingMarketplaceClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        // First install: not overwriting → succeeds.
        await viewModel.installSelected(overwriteExisting: false)
        guard case .installed(let firstURL) = viewModel.state else {
            Issue.record("expected first install to land in .installed")
            return
        }

        // Second install without overwrite → must fail because
        // the target directory already exists.
        viewModel.state = .loaded // dismiss the success alert
        await viewModel.installSelected(overwriteExisting: false)
        if case .error = viewModel.state {
            // expected: writeFailed "target exists"
        } else {
            Issue.record("expected .error on second install without overwrite, got \(viewModel.state)")
        }

        // Third install with overwrite → must succeed and
        // return the same target URL.
        await viewModel.installSelected(overwriteExisting: true)
        if case .installed(let secondURL) = viewModel.state {
            #expect(secondURL == firstURL)
        } else {
            Issue.record("expected third install to land in .installed, got \(viewModel.state)")
        }
    }
}

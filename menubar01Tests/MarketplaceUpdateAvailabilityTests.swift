// MarketplaceUpdateAvailabilityTests.swift
// menubar01 — PluginMarketplace (M5 update-detection follow-up)
//
// Swift Testing coverage for
// `MarketplaceBrowserViewModel.updateAvailability(for:)` — the
// pure helper the Installed tab uses to decide which badge
// (if any) to render against each marketplace install.
//
// The contract under test:
//
//   1. Catalogue row is newer than the on-disk manifest →
//      `.available(catalogueVersion:)` so the sidebar
//      shows the green "v1.0.0 → v1.2.3" pill.
//   2. Catalogue row version matches the on-disk manifest
//      → `.upToDate` (no badge).
//   3. Local manifest is newer than the catalogue row →
//      `.aheadOfCatalogue(catalogueVersion:)` (the
//      "Local is newer" hint).
//   4. Manifest omits `version` or the string is
//      unparseable → `.unknown` regardless of the
//      catalogue row.
//   5. Catalogue has no matching entry for the snapshot →
//      `.unknown` (the user is in the "I removed the
//      catalogue row but kept the install" state — we
//      would rather suppress the badge than lie about
//      a missing row).
//
// Each test sets up a temp plugin directory, writes a
// `manifest.json` for a marketplace install, and asks the
// view model to recompute the availability. The catalogue
// is constructed inline so the test stays focused on the
// `updateAvailability(for:)` contract — the
// `MarketplaceBrowserViewModelTests` suite already covers
// the catalogue-load / install / uninstall flows.
//
// Target: 5 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test doubles

/// Test-only `MarketplaceClient` that returns a single
/// `MarketplaceEntry` with the caller-chosen `version` and
/// `id`. Mirrors the `CapturingMarketplaceClient` in
/// `MarketplaceBrowserViewModelTests` but is intentionally
/// lighter — only `fetchCatalogue()` is exercised by the
/// update-availability tests.
private final class AvailabilityCapturingClient: MarketplaceClient, @unchecked Sendable {
    let catalogue: [MarketplaceEntry]

    init(catalogue: [MarketplaceEntry]) {
        self.catalogue = catalogue
    }

    func fetchCatalogue() async throws -> [MarketplaceEntry] {
        return catalogue
    }

    func fetchPackage(id: String) async throws -> MarketplacePackage {
        // The update-availability tests never fetch a
        // package — they construct the on-disk install
        // by hand and ask the VM to compare. Return a
        // notFound to surface any accidental call site.
        throw MarketplaceError.notFound(id: id)
    }
}

// MARK: - Helpers

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at a per-test temp dir. Mirrors the helper
/// used in `MarketplaceBrowserViewModelTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.update-availability.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-upd-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Write a marketplace install's `manifest.json` to
/// `<tempDir>/_marketplace/<folder>/manifest.json`. Mirrors
/// the layout `installMarketplacePlugin(plan:overwriteExisting:)`
/// produces. The caller chooses `folder` (default
/// `"battery-watch"`) and the raw manifest JSON body.
@discardableResult
private func stageMarketplaceInstall(
    in tempDir: URL,
    folder: String = "battery-watch",
    manifestJSON: String
) throws -> URL {
    let marketplaceRoot = tempDir
        .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
    let installDir = marketplaceRoot.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
    let manifestURL = installDir.appendingPathComponent(pluginManifestFileName)
    try manifestJSON.write(to: manifestURL, atomically: true, encoding: .utf8)
    return installDir
}

/// Build a `MarketplaceEntry` with the canonical
/// `battery-watch` shape, optionally overriding the
/// catalogue's `version`. The `id` matches the
/// `stageMarketplaceInstall(in:folder:)` default so a
/// direct `id` lookup succeeds.
private func makeEntry(
    id: String = "battery-watch",
    name: String = "Battery Watch",
    version: String
) -> MarketplaceEntry {
    MarketplaceEntry(
        id: id,
        name: name,
        summary: "Live battery percentage and charging state.",
        category: "system",
        version: version,
        installCount: 97,
        rating: 4.2,
        generatorPromptId: "demo.battery.v1"
    )
}

// MARK: - Tests

@MainActor
struct MarketplaceUpdateAvailabilityTests {

    // 7

    @Test func testUpdateAvailability_catalogueNewer_returnsAvailable() {
        // Manifest on disk is 1.0.0; catalogue row is
        // 1.2.3. The badge should be
        // `.available(catalogueVersion: 1.2.3)`.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let folder = "battery-watch"
        let manifestJSON = "{\n  \"name\": \"Battery Watch\",\n  \"version\": \"1.0.0\"\n}\n"
        let installURL = try! stageMarketplaceInstall(
            in: tempDir,
            folder: folder,
            manifestJSON: manifestJSON
        )

        let client = AvailabilityCapturingClient(
            catalogue: [makeEntry(version: "1.2.3")]
        )
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        viewModel.entries = client.catalogue
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        // Sanity: the snapshot's id is the on-disk URL
        // path, not the catalogue `id` — the lookup
        // path uses `entriesByFolder(for:)`, which
        // matches on the folder name (`battery-watch`).
        #expect(snapshot.url.lastPathComponent == folder)
        #expect(snapshot.manifestVersion == MarketplaceVersion(major: 1, minor: 0, patch: 0))
        let availability = viewModel.updateAvailability(for: snapshot)
        if case .available(let catalogueVersion) = availability {
            #expect(catalogueVersion == MarketplaceVersion(major: 1, minor: 2, patch: 3))
        } else {
            Issue.record("expected .available, got \(availability)")
        }
        // Silence the unused warning for the snapshot
        // installURL in release builds (it's a debug
        // aid that confirms the stage succeeded).
        _ = installURL
    }

    // 8

    @Test func testUpdateAvailability_sameVersion_returnsUpToDate() {
        // Manifest on disk is 1.2.3; catalogue row is
        // 1.2.3. The badge should be suppressed
        // (`.upToDate`).
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manifestJSON = "{\n  \"name\": \"Battery Watch\",\n  \"version\": \"1.2.3\"\n}\n"
        _ = try! stageMarketplaceInstall(
            in: tempDir,
            folder: "battery-watch",
            manifestJSON: manifestJSON
        )

        let client = AvailabilityCapturingClient(
            catalogue: [makeEntry(version: "1.2.3")]
        )
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        viewModel.entries = client.catalogue
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        let availability = viewModel.updateAvailability(for: snapshot)
        #expect(availability == .upToDate)
    }

    // 9

    @Test func testUpdateAvailability_localNewer_returnsAheadOfCatalogue() {
        // Manifest on disk is 2.0.0; catalogue row is
        // 1.2.3. The badge should be the
        // "Local is newer" hint
        // (`.aheadOfCatalogue(catalogueVersion:)`).
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manifestJSON = "{\n  \"name\": \"Battery Watch\",\n  \"version\": \"2.0.0\"\n}\n"
        _ = try! stageMarketplaceInstall(
            in: tempDir,
            folder: "battery-watch",
            manifestJSON: manifestJSON
        )

        let client = AvailabilityCapturingClient(
            catalogue: [makeEntry(version: "1.2.3")]
        )
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        viewModel.entries = client.catalogue
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        let availability = viewModel.updateAvailability(for: snapshot)
        if case .aheadOfCatalogue(let catalogueVersion) = availability {
            #expect(catalogueVersion == MarketplaceVersion(major: 1, minor: 2, patch: 3))
        } else {
            Issue.record("expected .aheadOfCatalogue, got \(availability)")
        }
    }

    // 10

    @Test func testUpdateAvailability_unknownManifest_returnsUnknown() {
        // Manifest omits `version`. The badge is
        // suppressed (`.unknown`).
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manifestJSON = "{\n  \"name\": \"Battery Watch\"\n}\n"
        _ = try! stageMarketplaceInstall(
            in: tempDir,
            folder: "battery-watch",
            manifestJSON: manifestJSON
        )

        let client = AvailabilityCapturingClient(
            catalogue: [makeEntry(version: "1.2.3")]
        )
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        viewModel.entries = client.catalogue
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        #expect(snapshot.manifestVersion == nil)
        #expect(viewModel.updateAvailability(for: snapshot) == .unknown)
    }

    // 11

    @Test func testUpdateAvailability_unknownCatalogueEntry_returnsUnknown() {
        // Manifest on disk matches the on-disk folder
        // name, but the catalogue has no row for it
        // (the entry was retired). The badge is
        // suppressed (`.unknown`).
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manifestJSON = "{\n  \"name\": \"Battery Watch\",\n  \"version\": \"1.0.0\"\n}\n"
        _ = try! stageMarketplaceInstall(
            in: tempDir,
            folder: "battery-watch",
            manifestJSON: manifestJSON
        )

        // Catalogue has a different plugin entirely.
        let client = AvailabilityCapturingClient(
            catalogue: [makeEntry(id: "todays-date", name: "Today's Date", version: "1.0.0")]
        )
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        viewModel.entries = client.catalogue
        viewModel.refreshInstalledPlugins()

        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]
        #expect(snapshot.manifestVersion == MarketplaceVersion(major: 1, minor: 0, patch: 0))
        #expect(viewModel.updateAvailability(for: snapshot) == .unknown)
    }
}

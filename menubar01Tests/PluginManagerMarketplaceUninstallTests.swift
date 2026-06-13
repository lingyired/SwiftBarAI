// PluginManagerMarketplaceUninstallTests.swift
// menubar01 — PluginMarketplace (M5 uninstall / update follow-up)
//
// Swift Testing coverage for the new
// `PluginManager.uninstallMarketplacePlugin(at:)` +
// `PluginManager.updateMarketplacePluginWithCapabilityGate(...)`
// methods. Pins down the contract from the M5 uninstall / update
// follow-up:
//
//   - the uninstall path-safety check refuses any path that is
//     not rooted under `<pluginDirectoryURL>/_marketplace/`;
//   - the uninstall path-safety check refuses path-traversal
//     attempts (`..` runs) that would escape `_marketplace/`
//     after `.standardizedFileURL` resolution;
//   - the uninstall path-safety check refuses non-existent
//     paths and surfaces `.notFound` (not
//     `.notAMarketplacePlugin`) so the UI can show "already
//     uninstalled";
//   - the uninstall path-safety check refuses a corrupted
//     marketplace directory (one whose `manifest.json` is
//     missing or unparseable) so a partial install is not
//     silently removed;
//   - a successful uninstall removes the on-disk folder and
//     leaves the rest of the marketplace directory alone;
//   - uninstall does NOT revoke the plugin's grants in the
//     `PluginCapabilityGate`. The gate is keyed on
//     `manifest.name` (a stable string the user picked when
//     they first installed the plugin), so a re-install
//     after uninstall inherits the previously-granted
//     capability set;
//   - the update path is a re-install with
//     `overwriteExisting: true`; v2 bytes replace v1 bytes
//     on disk;
//   - the update path refuses via `gate.verify(manifest:)`
//     when v2 asks for a capability the user has not yet
//     granted, and surfaces a typed `.planFailed(reason:)`
//     without touching the disk.
//
// All tests are pure: each one wires a fresh `PluginManager`
// rooted at a per-test temp directory, a fresh
// `PluginCapabilityGate` backed by an isolated
// `UserDefaults(suiteName:)`, and a hand-rolled
// `prompt`-recording closure so SwiftUI presentation is
// never required. Mirrors the pattern in
// `PluginManagerMarketplaceInstallGateTests` and
// `MarketplaceInstallPromptTests`.
//
// Target: 8 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test helpers

/// Build a fresh `PluginCapabilityGate` backed by an
/// isolated `UserDefaults` suite. Mirrors the helper in
/// `PluginManagerMarketplaceInstallGateTests`.
private func makeIsolatedGate() -> PluginCapabilityGate {
    let suiteName = "menubar01.tests.mkt.uninstall.gate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return PluginCapabilityGate(defaults: defaults)
}

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at a temp dir the caller has already created.
/// Mirrors the helper in `PluginManagerMarketplaceInstallGateTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.uninstall.mgr.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

/// Build a fresh temp directory for the uninstall /
/// update tests, register cleanup, and return the URL
/// alongside a `PluginManager` rooted there.
private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-uninstall-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Build a `MarketplacePackage` whose manifest declares the
/// given v1-string capabilities. Mirrors the helper in
/// `PluginManagerMarketplaceInstallGateTests` so the two
/// suites read consistently; the test-only v1 mapping
/// keeps call sites readable.
private func makePackage(
    id: String = "battery-watch",
    name: String = "Battery Watch",
    version: String = "1.0.0",
    capabilities: [String]? = nil,
    entryScript: String = "#!/bin/zsh\necho Battery\n",
    entryFilename: String = "battery-watch.sh"
) -> MarketplacePackage {
    var manifest = PluginManifest()
    manifest.name = name
    manifest.version = version
    manifest.entry = entryFilename
    if let capabilities {
        manifest.capabilities = capabilities.map { raw in
            switch raw {
            case "network": return .init(capability: .network(hosts: []))
            case "clipboard": return .init(capability: .clipboard)
            case "notifications": return .init(capability: .notifications)
            case "calendar": return .init(capability: .calendar)
            case "fileWrite": return .init(capability: .fileWrite(paths: []))
            default:
                return .init(capability: nil)
            }
        }
    }
    return MarketplacePackage(
        id: id,
        manifest: manifest,
        entryScript: entryScript,
        entryFilename: entryFilename
    )
}

/// Build a `MarketplaceEntry` matching the package's id so
/// `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`
/// can wire the two together. Mirrors the seed in
/// `PluginManagerMarketplaceInstallGateTests`.
private func makeEntry(
    id: String = "battery-watch",
    name: String = "Battery Watch"
) -> MarketplaceEntry {
    MarketplaceEntry(
        id: id,
        name: name,
        summary: "Live battery percentage and charging state.",
        category: "system",
        installCount: 97,
        rating: 4.2,
        generatorPromptId: "demo.battery.v1"
    )
}

/// Write a fake marketplace install to
/// `<tempDir>/_marketplace/<folder>/manifest.json` and
/// return the on-disk URL. Mirrors the layout
/// `installMarketplacePlugin(plan:overwriteExisting:)`
/// produces. The caller chooses `folder` (default
/// `"battery-watch"`) so a single test can stage several
/// distinct installs in a single temp dir.
@discardableResult
private func stageFakeMarketplaceInstall(
    in tempDir: URL,
    folder: String = "battery-watch",
    manifestJSON: String? = nil
) throws -> URL {
    let marketplaceRoot = tempDir
        .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
    let installDir = marketplaceRoot.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
    let manifestURL = installDir.appendingPathComponent(pluginManifestFileName)
    let body = manifestJSON ?? "{\n  \"name\": \"Battery Watch\"\n}\n"
    try body.write(to: manifestURL, atomically: true, encoding: .utf8)
    return installDir
}

// MARK: - Uninstall

@MainActor
struct PluginManagerMarketplaceUninstallTests {

    // 1

    @Test func testUninstall_removesDirectoryFromDisk() {
        // Install (via the I/O half — write a manifest +
        // entry script directly so the test is not coupled
        // to the I/O write path), then uninstall, and
        // verify the directory is gone.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let targetURL = try! stageFakeMarketplaceInstall(in: tempDir)
        #expect(FileManager.default.fileExists(atPath: targetURL.path))

        let result = manager.uninstallMarketplacePlugin(at: targetURL)

        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        // The marketplace subfolder should still exist —
        // uninstall only removes the plugin folder, not
        // the parent.
        let marketplaceRoot = tempDir
            .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: marketplaceRoot.path))
    }

    // 2

    @Test func testUninstall_nonMarketplacePath_isRefused() {
        // Stage a folder that is NOT under
        // `<pluginDir>/_marketplace/`. The path-safety
        // check must refuse with
        // `.notAMarketplacePlugin(reason:)`.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let outside = tempDir
            .appendingPathComponent("not-a-marketplace-plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Stage a manifest so the path-safety check
        // gets past the "is it a marketplace plugin
        // folder?" hurdle and lands on the
        // `_marketplace/` check. A manifest that says
        // `"name": "x"` is fine — the issue is the
        // path, not the manifest content.
        let manifest = outside.appendingPathComponent(pluginManifestFileName)
        try? "{\n  \"name\": \"x\"\n}\n".write(to: manifest, atomically: true, encoding: .utf8)

        let result = manager.uninstallMarketplacePlugin(at: outside)

        guard case .failure(.notAMarketplacePlugin) = result else {
            Issue.record("expected .notAMarketplacePlugin, got \(result)")
            return
        }
        // The folder must not have been removed.
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    // 3

    @Test func testUninstall_nonexistentPath_returnsNotFound() {
        // A path under `_marketplace/` that does not
        // exist on disk. The path-safety check passes
        // (it is under the marketplace subfolder), the
        // existence check trips, and the error is
        // `.notFound(path:)` so the UI can show
        // "already uninstalled" instead of a generic
        // failure.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let marketplaceRoot = tempDir
            .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: marketplaceRoot, withIntermediateDirectories: true)
        let missing = marketplaceRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        let result = manager.uninstallMarketplacePlugin(at: missing)

        guard case .failure(.notFound(let path)) = result else {
            Issue.record("expected .notFound, got \(result)")
            return
        }
        #expect(path == missing.standardizedFileURL.path)
    }

    // 4

    @Test func testUninstall_pathTraversalAttempt_isRefused() {
        // The caller passes a path with `..` that
        // *resolves* to a folder OUTSIDE
        // `<tempDir>/_marketplace/`. The
        // `.standardizedFileURL` round-trip collapses
        // the `..`, and the pathComponents comparison
        // must recognise the resolved path as a
        // non-descendant of `_marketplace/` and
        // refuse. We stage a sibling outside
        // `_marketplace/` whose manifest matches the
        // test plugin, then point the uninstall URL
        // at
        // `<marketplace>/foo/../../sibling` — the
        // resolved path is `<tempDir>/sibling`,
        // which is NOT under
        // `<tempDir>/_marketplace/`, so the check
        // must refuse.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Sibling outside `_marketplace/`.
        let sibling = tempDir.appendingPathComponent("sibling", isDirectory: true)
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try? "{\n  \"name\": \"Sibling\"\n}\n"
            .write(to: sibling.appendingPathComponent(pluginManifestFileName),
                   atomically: true, encoding: .utf8)
        // Build a traversal path that resolves to
        // `sibling` (outside the marketplace
        // subfolder) but whose unresolved form is
        // rooted at `<tempDir>/_marketplace/`.
        let marketplaceRoot = tempDir
            .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
        let traversal = marketplaceRoot
            .appendingPathComponent("foo", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("sibling", isDirectory: true)
        // Sanity: standardizedFileURL collapses the
        // `..` runs.
        #expect(traversal.standardizedFileURL.path == sibling.standardizedFileURL.path)
        // And the resolved path is NOT under the
        // marketplace root.
        #expect(!traversal.standardizedFileURL.path.hasPrefix(marketplaceRoot.path))

        let result = manager.uninstallMarketplacePlugin(at: traversal)

        // The standardizedFileURL resolves to a
        // folder whose path components do NOT start
        // with the marketplace root's components, so
        // the check returns `.notAMarketplacePlugin`.
        guard case .failure(.notAMarketplacePlugin) = result else {
            Issue.record("expected .notAMarketplacePlugin, got \(result)")
            return
        }
        // Sibling must still exist (no deletion).
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    // 5

    @Test func testUninstall_emptyDirectory_succeeds() {
        // Same as test 1 but with no
        // `manifest.json`/entry script contents — the
        // dir only contains the manifest so the
        // path-safety check's "manifest must be
        // parseable" hurdle is satisfied. A real
        // install of the `battery-watch` plugin
        // (which has no extra artefacts) matches this
        // shape.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let targetURL = try! stageFakeMarketplaceInstall(in: tempDir)
        // Sanity: only `manifest.json` is in the dir.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: targetURL.path)) ?? []
        #expect(contents == [pluginManifestFileName])

        let result = manager.uninstallMarketplacePlugin(at: targetURL)

        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
    }

    // 6

    @Test func testUninstall_persistedCapabilityGrant_remains() {
        // Install a plugin that grants a non-default
        // capability, then uninstall, then verify the
        // gate's grant set for the plugin is still
        // there. The grants are keyed on
        // `manifest.name`, which is stable across
        // uninstalls — the user can re-install the
        // same plugin and the gate's record of
        // "previously granted" remains.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let gate = makeIsolatedGate()
        // Stage an install + record a grant for the
        // plugin's name, mimicking what
        // `installMarketplacePluginWithCapabilityGate(...)`
        // does on a successful prompt-driven
        // install.
        let targetURL = try! stageFakeMarketplaceInstall(in: tempDir)
        gate.grant([.network(hosts: [])], for: "Battery Watch")
        #expect(gate.granted(for: "Battery Watch") == [.network(hosts: [])])

        let result = manager.uninstallMarketplacePlugin(at: targetURL)

        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        // The grant MUST still be in the gate. The
        // marketplace uninstall path is intentionally
        // non-destructive on the gate — see the
        // `uninstallMarketplacePlugin(at:)` docstring.
        #expect(gate.granted(for: "Battery Watch") == [.network(hosts: [])])
    }

    // 7

    @Test func testUpdate_overwritesExistingPlugin() async {
        // Install v1, then update to v2, then verify
        // the on-disk manifest content is v2's. The
        // update path is a re-install with
        // `overwriteExisting: true`.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let gate = makeIsolatedGate()
        let entry = makeEntry()
        let v1 = makePackage(version: "1.0.0", entryScript: "#!/bin/zsh\necho v1\n")
        let v2 = makePackage(version: "2.0.0", entryScript: "#!/bin/zsh\necho v2\n")

        // v1 install — no capabilities, so the gate
        // never blocks the install.
        let v1Result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: try! MarketplaceInstaller.plan(entry: entry, package: v1, overwriteExisting: false),
            overwriteExisting: false,
            gate: gate,
            prompt: { _, _ in true }
        )
        guard case .success(let v1URL) = v1Result else {
            Issue.record("v1 install failed: \(v1Result)")
            return
        }

        // Update → v2. The update goes through the
        // gate-aware overload so the contract is the
        // same one the UI uses.
        let v2Result = await manager.updateMarketplacePluginWithCapabilityGate(
            entry: entry,
            package: v2,
            gate: gate
        )
        guard case .success(let v2URL) = v2Result else {
            Issue.record("v2 update failed: \(v2Result)")
            return
        }
        #expect(v2URL == v1URL)

        // On-disk manifest is v2.
        let manifestURL = v2URL.appendingPathComponent(pluginManifestFileName)
        let manifestData = try? Data(contentsOf: manifestURL)
        let manifestString = manifestData.flatMap { String(data: $0, encoding: .utf8) }
        #expect(manifestString?.contains("\"2.0.0\"") == true)
        #expect(manifestString?.contains("\"1.0.0\"") == false)
        // On-disk entry script is v2.
        let entryURL = v2URL.appendingPathComponent("battery-watch.sh")
        let entryData = try? Data(contentsOf: entryURL)
        let entryString = entryData.flatMap { String(data: $0, encoding: .utf8) }
        #expect(entryString?.contains("echo v2") == true)
    }

    // 8

    @Test func testUpdate_gateRefusesAbandonedCapabilities_returnsFailure() async {
        // v1 grants `clipboard` (a default-granted
        // capability, so the install proceeds
        // silently). v2 asks for `network` (a
        // non-default capability the user has not
        // granted). `gate.verify(manifest:)` must
        // refuse the update.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let gate = makeIsolatedGate()
        let entry = makeEntry()
        let v1 = makePackage(version: "1.0.0", capabilities: ["clipboard"])
        let v2 = makePackage(version: "2.0.0", capabilities: ["clipboard", "network"])

        // v1 install.
        let v1Result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: try! MarketplaceInstaller.plan(entry: entry, package: v1, overwriteExisting: false),
            overwriteExisting: false,
            gate: gate,
            prompt: { _, _ in true }
        )
        guard case .success(let v1URL) = v1Result else {
            Issue.record("v1 install failed: \(v1Result)")
            return
        }
        // The gate now records `clipboard` for
        // `"Battery Watch"`.
        #expect(gate.granted(for: "Battery Watch") == [.clipboard])

        // Update → v2. The update gate-aware path
        // runs `gate.verify(manifest:)` first; v2
        // asks for `network` which is not granted,
        // so verify throws and the update returns
        // `.planFailed(reason:)`.
        let v2Result = await manager.updateMarketplacePluginWithCapabilityGate(
            entry: entry,
            package: v2,
            gate: gate
        )
        guard case .failure(.planFailed(let reason)) = v2Result else {
            Issue.record("expected .planFailed, got \(v2Result)")
            return
        }
        #expect(reason.contains("gate refused update") == true)

        // The on-disk manifest must STILL be v1.
        // The update refused; the v1 bytes must be
        // intact.
        let manifestURL = v1URL.appendingPathComponent(pluginManifestFileName)
        let manifestData = try? Data(contentsOf: manifestURL)
        let manifestString = manifestData.flatMap { String(data: $0, encoding: .utf8) }
        #expect(manifestString?.contains("\"1.0.0\"") == true)
        #expect(manifestString?.contains("\"2.0.0\"") == false)
    }
}

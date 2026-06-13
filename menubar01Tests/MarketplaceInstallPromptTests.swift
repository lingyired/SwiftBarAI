// MarketplaceInstallPromptTests.swift
// menubar01 — PluginMarketplace (M5 install-prompt)
//
// Swift Testing coverage for the M5 marketplace install-prompt
// integration. Pins down the contract the new
// `MarketplaceInstallPromptSheet` consumes from
// `MarketplaceBrowserViewModel`:
//
// - `installPromptCapabilities` mirrors
//   `package.manifest.resolvedCapabilities` and is `[]` when
//   no package is loaded.
// - `installPromptIsPreApproved` is `true` when every
//   declared capability is already in the gate's grant set,
//   `false` when at least one is missing.
// - `requestInstallPrompt(overwriteExisting:)` returns a
//   `MarketplaceInstallPromptContext` that bundles the
//   plugin name, the resolved capabilities, the
//   pre-approval flag, the package, and the overwrite flag
//   (or `nil` when no package is loaded).
// - The grant side of the install-prompt flow lands in
//   `pluginCapabilityGate.granted(for:)` for the plugin name
//   after a successful run.
//
// The sheet itself (`MarketplaceInstallPromptSheet`) drives
// the flow by calling `gate.grant(_:for:)` and then
// `viewModel._installSelectedAfterGrants(...)`; the test
// suite exercises those hooks directly so SwiftUI presentation
// is not required to assert on the contract — the actual
// SwiftUI sheet is covered by the M2+
// `AIGeneratorInstallPromptSheet` precedent which also does
// not have a SwiftUI-level test.
//
// All tests are pure: the VM is driven through a hand-rolled
// `CapturingMarketplaceClient` and a per-test
// `UserDefaults(suiteName:)`-backed `PluginCapabilityGate`, so
// the suite never touches `UserDefaults.standard` or
// `PluginManager.shared`.
//
// Target: 7+ new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test doubles

/// A test-only `MarketplaceClient` that records the most
/// recent calls and returns canned values. Mirrors the helper
/// in `MarketplaceBrowserViewModelTests` so the two suites
/// read consistently; lives in this file to keep the
/// install-prompt suite hermetic.
private final class InstallPromptCapturingClient: MarketplaceClient, @unchecked Sendable {
    /// Catalogue to return from `fetchCatalogue()`. Tests
    /// set this to a one-entry seed so the suite stays
    /// focused on the install-prompt contract.
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
        self.catalogue = catalogue ?? [
            MarketplaceEntry(
                id: "battery-watch",
                name: "Battery Watch",
                summary: "Live battery percentage and charging state.",
                category: "system",
                installCount: 97,
                rating: 4.2,
                generatorPromptId: "demo.battery.v1"
            )
        ]
        self.packages = packages ?? [:]
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

/// Build a fresh `PluginCapabilityGate` backed by an
/// isolated `UserDefaults` suite. The suite name is
/// randomised so parallel test runs do not stomp each
/// other. Mirrors the helper in
/// `AIGeneratorInstallPromptTests`.
private func makeIsolatedGate() -> PluginCapabilityGate {
    let suiteName = "menubar01.tests.mkt.installPrompt.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return PluginCapabilityGate(defaults: defaults)
}

/// Build a `MarketplacePackage` whose manifest declares the
/// given capability set. Used by the prompt-data tests so
/// we can drive `installPromptCapabilities` without
/// involving the real marketplace client. The shorthand
/// `[String]?` keeps the existing call sites readable — the
/// helper maps each v1 string to its modern descriptor
/// (empty associated values). Unknown strings are passed
/// through as `nil` descriptors to mirror the on-disk
/// decoder's lenient behaviour.
private func makePackage(
    id: String = "battery-watch",
    name: String = "Battery Watch",
    capabilities: [String]? = nil
) -> MarketplacePackage {
    var manifest = PluginManifest()
    manifest.name = name
    manifest.version = "1.0.0"
    manifest.entry = "battery-watch.sh"
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
        entryScript: "#!/bin/zsh\necho Battery\n",
        entryFilename: "battery-watch.sh"
    )
}

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at a temp dir the caller has already created.
/// Mirrors the helper in
/// `MarketplaceBrowserViewModelTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.installPrompt.mgr.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

/// Build a fresh temp directory for the marketplace
/// install tests, registers a deinit-time cleanup, and
/// returns the URL alongside a `PluginManager` rooted
/// there.
private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-ip-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

// MARK: - installPromptCapabilities

@MainActor
struct MarketplaceInstallPromptCapabilitiesTests {
    @Test func testInstallPromptCapabilities_readsPackageManifestCapabilities() async {
        // Pre-condition: a package whose manifest declares
        // both `network` and `clipboard`.
        let package = makePackage(capabilities: ["network", "clipboard"])
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        #expect(viewModel.installPromptCapabilities == [.network(hosts: []), .clipboard])
    }

    @Test func testInstallPromptCapabilities_emptyWhenNoPackage() {
        // No `loadCatalogue` / `selectEntry` calls → no
        // `package`. The computed property should return
        // `[]` rather than crashing.
        let client = InstallPromptCapturingClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        #expect(viewModel.installPromptCapabilities.isEmpty)
    }

    @Test func testInstallPromptCapabilities_dropsUnknownStrings() async {
        // `resolvedCapabilities` drops unknown strings with
        // an `os_log` warning; the install-prompt sheet's
        // computed property should mirror the dropped list,
        // not the raw manifest text.
        let package = makePackage(capabilities: ["network", "future-foo", "clipboard"])
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        #expect(viewModel.installPromptCapabilities == [.network(hosts: []), .clipboard])
    }
}

// MARK: - installPromptIsPreApproved

@MainActor
struct MarketplaceInstallPromptPreApprovalTests {
    @Test func testInstallPromptIsPreApproved_trueWhenAllGranted() async {
        let package = makePackage(name: "Battery Watch", capabilities: ["network"])
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        let gate = makeIsolatedGate()
        gate.grant([.network(hosts: [])], for: "Battery Watch")
        viewModel.pluginCapabilityGate = gate

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        #expect(viewModel.installPromptIsPreApproved == true)
    }

    @Test func testInstallPromptIsPreApproved_falseWhenAnyMissing() async {
        // Grant only `clipboard`; the package needs both
        // `network` and `clipboard`, so pre-flight must
        // return `false`.
        let package = makePackage(
            name: "Battery Watch",
            capabilities: ["network", "clipboard"]
        )
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        let gate = makeIsolatedGate()
        gate.grant([.clipboard], for: "Battery Watch")
        viewModel.pluginCapabilityGate = gate

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        #expect(viewModel.installPromptIsPreApproved == false)
    }

    @Test func testInstallPromptIsPreApproved_trueWhenNoCapabilitiesDeclared() async {
        // A package with no declared capabilities should
        // always pre-approve — the install helper does not
        // need to present the prompt.
        let package = makePackage(name: "Empty", capabilities: nil)
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        #expect(viewModel.installPromptCapabilities.isEmpty)
        #expect(viewModel.installPromptIsPreApproved == true)
    }
}

// MARK: - requestInstallPrompt / runInstall

@MainActor
struct MarketplaceInstallPromptRequestTests {
    @Test func testRequestInstallPrompt_returnsContextWithPackageAndCapabilities() async {
        let package = makePackage(
            name: "Battery Watch",
            capabilities: ["network", "clipboard"]
        )
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        let context = viewModel.requestInstallPrompt(overwriteExisting: false)
        #expect(context != nil)
        #expect(context?.pluginName == "Battery Watch")
        #expect(context?.capabilities == [.network(hosts: []), .clipboard])
        #expect(context?.isPreApproved == false)
        #expect(context?.package.id == "battery-watch")
        #expect(context?.overwriteExisting == false)
    }

    @Test func testRequestInstallPrompt_returnsNilWhenNoPackage() {
        // No `loadCatalogue` / `selectEntry` calls → no
        // `package` → the context must be `nil` so the
        // parent sheet knows not to present the prompt.
        let client = InstallPromptCapturingClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        #expect(viewModel.requestInstallPrompt(overwriteExisting: false) == nil)
    }

    @Test func testRunInstall_grantsEnabledCapabilitiesForPluginName() async throws {
        // End-to-end: build a context, grant the
        // capabilities through the gate (mimicking the
        // prompt sheet's `runInstall` body), then call
        // `_installSelectedAfterGrants(...)` and verify the
        // gate has the grants after a successful install.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = makePackage(
            name: "Battery Watch",
            capabilities: ["network", "clipboard"]
        )
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        let gate = makeIsolatedGate()
        viewModel.pluginCapabilityGate = gate

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        // Mimic the prompt sheet's grant + install flow.
        let enabled: Set<PluginCapability> = [.network(hosts: []), .clipboard]
        gate.grant(enabled, for: "Battery Watch")
        await viewModel._installSelectedAfterGrants(overwriteExisting: false)

        // The install must have succeeded.
        guard case .installed(let targetURL) = viewModel.state else {
            Issue.record("expected .installed state, got \(viewModel.state)")
            return
        }
        #expect(targetURL.lastPathComponent == "battery-watch")
        #expect(FileManager.default.fileExists(
            atPath: targetURL.appendingPathComponent("manifest.json").path
        ))

        // And the gate must have the grants we enabled.
        #expect(gate.granted(for: "Battery Watch") == enabled)
    }

    @Test func testRunInstall_skipsInstallIfPackageMissing() async {
        // No `loadCatalogue` / `selectEntry` calls → no
        // `package` → `_installSelectedAfterGrants(...)`
        // is a defensive no-op and the state stays at
        // `.idle`.
        let (_, manager) = makeTempManager()
        let client = InstallPromptCapturingClient()
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: manager
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        await viewModel.loadCatalogue()
        // No selectEntry call → selectedEntry is nil →
        // _installSelectedAfterGrants is a no-op.
        await viewModel._installSelectedAfterGrants(overwriteExisting: false)

        #expect(viewModel.state == .loaded)
    }

    @Test func testRunInstall_setsErrorStateOnInstallFailure() async {
        // No `pluginManager` → the install primitive
        // should land in `.error(reason)` with the
        // "Plugin manager is unavailable" message.
        let package = makePackage(name: "Battery Watch", capabilities: ["network"])
        let client = InstallPromptCapturingClient(packages: ["battery-watch": package])
        let viewModel = MarketplaceBrowserViewModel(
            client: client,
            pluginManager: nil
        )
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        await viewModel.loadCatalogue()
        await viewModel.selectEntry(viewModel.entries[0])

        await viewModel._installSelectedAfterGrants(overwriteExisting: false)

        if case .error(let reason) = viewModel.state {
            #expect(reason.contains("Plugin manager"))
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
    }
}

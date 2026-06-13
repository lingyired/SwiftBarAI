// PluginManagerMarketplaceInstallGateTests.swift
// menubar01 — PluginMarketplace (M5 install-gate follow-up)
//
// Swift Testing coverage for the new
// `PluginManager.installMarketplacePluginWithCapabilityGate(...)`
// overload. Pins down the contract from the M5 install-gate
// follow-up:
//
//   - the manifest-derived `resolvedCapabilities` is walked
//     in declaration order, and each capability is routed to
//     "skip" (already granted), "auto-grant" (granted by
//     default), or "prompt" (ungranted + not granted by
//     default) buckets;
//   - auto-grant is silent — the prompt closure is **not**
//     invoked when every ungranted capability is granted by
//     default;
//   - prompt grant persists in the gate and the install
//     proceeds to write `manifest.json` + the entry script;
//   - prompt decline returns
//     `InstallMarketplacePluginError.capabilityDeclined(...)`
//     and writes nothing to disk;
//   - a second install of the same plugin does not re-prompt
//     (the gate already records the grant);
//   - `InstallMarketplacePluginError` keeps its `Equatable`
//     conformance after the new case lands.
//
// All tests are pure: each one wires a fresh
// `PluginManager` rooted at a per-test temp directory, a
// fresh `PluginCapabilityGate` backed by an isolated
// `UserDefaults(suiteName:)`, and a hand-rolled
// `prompt`-recording closure so SwiftUI presentation is
// never required. Mirrors the pattern in
// `MarketplaceInstallPromptTests` and
// `MarketplaceBrowserViewModelTests`.
//
// Target: 8 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test helpers

/// Build a fresh `PluginCapabilityGate` backed by an
/// isolated `UserDefaults` suite. The suite name is
/// randomised so parallel test runs do not stomp each
/// other. Mirrors the helper in
/// `MarketplaceInstallPromptTests`.
private func makeIsolatedGate() -> PluginCapabilityGate {
    let suiteName = "menubar01.tests.mkt.gate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return PluginCapabilityGate(defaults: defaults)
}

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at `pluginDirectory`. Mirrors the helper in
/// `MarketplaceInstallPromptTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.gate.mgr.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

/// Build a fresh temp directory for the install-gate
/// tests, registers a deinit-time cleanup, and returns the
/// URL alongside a `PluginManager` rooted there.
private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-gate-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Build a `MarketplacePackage` whose manifest declares the
/// given v1-string capabilities (so the test can drive
/// `resolvedCapabilities` through the wire format the user
/// would author). The shorthand `[String]?` keeps the call
/// sites readable; the helper maps each v1 string to its
/// modern descriptor (empty associated values).
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

/// Build a `MarketplaceEntry` matching the package's id so
/// `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`
/// can wire the two together. Mirrors the seed in
/// `InstallPromptCapturingClient`.
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

/// `CapabilityPromptHandler` recorder: tracks every call
/// (the plugin id, the capability set the prompt was asked
/// about) and returns the canned answer the test sets via
/// `nextResult`. The recorded call history is the only
/// signal the install-gate overload gives the test that the
/// prompt sheet was shown — the overload never sees the
/// sheet itself.
@MainActor
private final class PromptRecorder {
    struct Call: Equatable {
        let pluginID: String
        let capabilities: [PluginCapability]
    }
    private(set) var calls: [Call] = []
    /// Result the next prompt invocation will return.
    /// Subsequent invocations also return this value
    /// unless the test updates it.
    var nextResult: Bool = true

    func handler() -> CapabilityPromptHandler {
        // Capture `self` weakly so the test can drop the
        // recorder (and assert the handler is never called)
        // without leaking a retain cycle. The install
        // method does not store the handler past the
        // `await` so the cycle is short-lived in practice,
        // but `weak` is the right default.
        let result = nextResult
        return { [weak self] pluginID, capabilities in
            self?.calls.append(Call(pluginID: pluginID, capabilities: capabilities))
            return result
        }
    }
}

// MARK: - Tests

@MainActor
struct PluginManagerMarketplaceInstallGateTests {

    @Test func testInstall_withNoCapabilities_proceedsAndSucceeds() async {
        // Manifest declares no capabilities → the gate
        // should be untouched and the install should
        // proceed straight to the I/O half. Verifies the
        // "no-capability" short-circuit: the prompt closure
        // is never called.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = true

        let package = makePackage(capabilities: nil)
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: false
        )
        #expect(plan.manifest != nil)
        #expect(plan.manifest?.resolvedCapabilities.isEmpty == true)

        let result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: false,
            gate: gate,
            prompt: recorder.handler()
        )

        guard case .success(let targetURL) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(targetURL.lastPathComponent == "battery-watch")
        #expect(FileManager.default.fileExists(
            atPath: targetURL.appendingPathComponent("manifest.json").path
        ))
        // The prompt must not have been called when the
        // manifest declares no capabilities.
        #expect(recorder.calls.isEmpty)
        // The gate must remain empty.
        #expect(gate.granted(for: "Battery Watch").isEmpty)
    }

    @Test func testInstall_withDefaultGrantedCapabilities_autoGrantsAndSucceeds() async {
        // `clipboard` is `isGrantedByDefault == true` →
        // the install should auto-grant it silently and
        // proceed without ever calling the prompt. The
        // gate must record the auto-grant so a future
        // uninstall / re-install flow does not re-prompt.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = true

        let package = makePackage(capabilities: ["clipboard"])
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: false
        )

        let result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: false,
            gate: gate,
            prompt: recorder.handler()
        )

        guard case .success(let targetURL) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: targetURL.appendingPathComponent("manifest.json").path
        ))
        // The prompt must not have been called — the
        // single capability is granted by default.
        #expect(recorder.calls.isEmpty)
        // The gate must have the auto-grant.
        #expect(gate.granted(for: "Battery Watch") == [.clipboard])
    }

    @Test func testInstall_withNonDefaultCapability_callsPromptAndSucceedsOnGrant() async {
        // `network` is `isGrantedByDefault == false` →
        // the install must surface it to the prompt. The
        // test returns `true` (grant) → the install
        // proceeds and the gate records the grant.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = true

        let package = makePackage(capabilities: ["network"])
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: false
        )

        let result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: false,
            gate: gate,
            prompt: recorder.handler()
        )

        guard case .success(let targetURL) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: targetURL.appendingPathComponent("manifest.json").path
        ))
        // The prompt must have been called exactly once
        // with the single non-default capability.
        #expect(recorder.calls == [
            PromptRecorder.Call(pluginID: "Battery Watch", capabilities: [.network(hosts: [])])
        ])
        // The gate must have the grant.
        #expect(gate.granted(for: "Battery Watch") == [.network(hosts: [])])
    }

    @Test func testInstall_withNonDefaultCapability_callsPromptAndAbortsOnDecline() async {
        // Same manifest as the grant test, but the prompt
        // returns `false` (decline). The install must
        // abort with `.capabilityDeclined(...)` and the
        // gate must remain empty.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = false

        let package = makePackage(capabilities: ["network"])
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: false
        )

        let result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: false,
            gate: gate,
            prompt: recorder.handler()
        )

        guard case .failure(let error) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        guard case .capabilityDeclined(let pluginID, let capabilities) = error else {
            Issue.record("expected .capabilityDeclined, got \(error)")
            return
        }
        #expect(pluginID == "Battery Watch")
        #expect(capabilities == [.network(hosts: [])])
        // The prompt must have been called exactly once.
        #expect(recorder.calls.count == 1)
        // The gate must NOT have the grant — the user
        // explicitly declined, so the install aborted
        // before the gate was updated.
        #expect(gate.granted(for: "Battery Watch").isEmpty)
    }

    @Test func testInstall_promptDecline_doesNotWriteToDisk() async {
        // Stronger guarantee on the decline path: the
        // marketplace target subdirectory must not exist
        // on disk. Mirrors the "if you decline, abort with
        // a typed error (do not write to disk)" contract.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = false

        let package = makePackage(capabilities: ["network", "notifications"])
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: false
        )

        let result = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: false,
            gate: gate,
            prompt: recorder.handler()
        )

        guard case .failure(.capabilityDeclined) = result else {
            Issue.record("expected .failure(.capabilityDeclined), got \(result)")
            return
        }
        // The plugin folder for the marketplace install
        // lives at `directory/_marketplace/battery-watch`
        // (mirroring the existing
        // `installMarketplacePlugin(...)` layout).
        let targetDirectory = directory
            .appendingPathComponent("_marketplace", isDirectory: true)
            .appendingPathComponent("battery-watch", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: targetDirectory.path))
        // The `manifest.json` must not exist anywhere
        // under the temp dir (defensive: catches a future
        // refactor that accidentally writes before
        // prompting).
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? []
        let leaked = contents.filter { $0.contains("manifest.json") }
        #expect(leaked.isEmpty)
    }

    @Test func testInstall_promptGrant_persistsGrantInGate() async {
        // Explicitly verify the post-install gate state
        // for a multi-capability manifest: every
        // non-default capability the user grants through
        // the prompt must show up in
        // `gate.granted(for: pluginID)`.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = true

        let package = makePackage(
            capabilities: ["network", "notifications", "calendar"]
        )
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: false
        )

        _ = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: false,
            gate: gate,
            prompt: recorder.handler()
        )

        #expect(gate.granted(for: "Battery Watch") == [
            .network(hosts: []),
            .notifications,
            .calendar
        ])
        // The prompt was called exactly once with all
        // three capabilities in declaration order.
        #expect(recorder.calls == [
            PromptRecorder.Call(
                pluginID: "Battery Watch",
                capabilities: [.network(hosts: []), .notifications, .calendar]
            )
        ])
    }

    @Test func testInstall_promptGrantThenReinstall_doesNotPromptAgain() async {
        // Re-installing a previously-granted plugin must
        // skip the prompt. The gate's
        // `isGranted(capability, for:)` already returns
        // `true` for every previously-granted capability,
        // so the prompt closure should not be called a
        // second time. Verifies the "the user is not
        // re-prompted for capabilities they already
        // accepted" contract.
        let (directory, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = makeIsolatedGate()
        let recorder = PromptRecorder()
        recorder.nextResult = true

        let package = makePackage(capabilities: ["network", "notifications"])
        let plan = try! MarketplaceInstaller.plan(
            entry: makeEntry(),
            package: package,
            overwriteExisting: true
        )

        // First install: prompts the user, they grant.
        let first = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: true,
            gate: gate,
            prompt: recorder.handler()
        )
        guard case .success = first else {
            Issue.record("first install should succeed, got \(first)")
            return
        }
        #expect(recorder.calls.count == 1)
        #expect(gate.granted(for: "Battery Watch") == [.network(hosts: []), .notifications])

        // Second install: the gate already has the
        // grants, so the prompt closure must NOT be
        // called a second time.
        let second = await manager.installMarketplacePluginWithCapabilityGate(
            plan: plan,
            overwriteExisting: true,
            gate: gate,
            prompt: recorder.handler()
        )
        guard case .success = second else {
            Issue.record("second install should succeed, got \(second)")
            return
        }
        #expect(recorder.calls.count == 1)
    }

    @Test func testInstall_errorEquatable_capabilityDeclinedMatchesExactSet() async {
        // The M5 install-gate follow-up adds a new
        // `capabilityDeclined(pluginID:capabilities:)` case
        // to `InstallMarketplacePluginError`. The error
        // must keep its `Equatable` conformance so the
        // view model can pattern-match on the failure
        // case in the success / error banner. This test
        // exercises that conformance on the new case.
        let a = InstallMarketplacePluginError.capabilityDeclined(
            pluginID: "Battery Watch",
            capabilities: [.network(hosts: ["x"]), .notifications]
        )
        let b = InstallMarketplacePluginError.capabilityDeclined(
            pluginID: "Battery Watch",
            capabilities: [.network(hosts: ["x"]), .notifications]
        )
        let c = InstallMarketplacePluginError.capabilityDeclined(
            pluginID: "Battery Watch",
            capabilities: [.notifications, .network(hosts: ["x"])]
        )
        let d = InstallMarketplacePluginError.capabilityDeclined(
            pluginID: "Battery Watch",
            capabilities: [.network(hosts: ["y"])]
        )
        let e = InstallMarketplacePluginError.capabilityDeclined(
            pluginID: "Other",
            capabilities: [.network(hosts: ["x"]), .notifications]
        )
        // Same fields → equal.
        #expect(a == b)
        // Order matters in `==` on `[PluginCapability]`
        // (Array Equatable is order-sensitive) — this
        // is intentional: the prompt sheet renders
        // capabilities in declaration order and the user
        // can tell "you granted [network, notifications]"
        // from "you granted [notifications, network]".
        #expect(a != c)
        // Different associated values → not equal.
        #expect(a != d)
        #expect(a != e)
    }
}

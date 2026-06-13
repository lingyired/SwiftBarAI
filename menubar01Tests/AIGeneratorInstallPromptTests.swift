// AIGeneratorInstallPromptTests.swift
// menubar01 — AI Plugin Generator (M2 install-prompt)
//
// Swift Testing coverage for the M2 install-prompt sheet integration
// on `AIGeneratorViewModel`. All tests are pure: the view model is
// driven through `MockAIPluginGenerator` and a per-test
// `UserDefaults(suiteName:)`-backed `PluginCapabilityGate`, so the
// suite never touches `UserDefaults.standard` or
// `PluginManager.shared`.
//
// The view-model contract these tests pin down:
//
// - `installPromptCapabilities` mirrors
//   `latestPlugin.manifest.resolvedCapabilities` and is `[]` when
//   there is no `latestPlugin`.
// - `installPromptIsPreApproved` is `true` when every declared
//   capability is already in the gate's grant set, `false` when
//   at least one is missing.
// - `didCompleteInstall(at:)` flips `didRequestSave` and stores
//   the destination URL on `installedPluginURL`.
// - `didFailInstall(reason:)` clears both, so a Cancel does not
//   show a misleading "Saved" hint.
//
// The sheet itself (`AIGeneratorInstallPromptSheet`) is exercised
// end-to-end by the existing `PluginManagerInstallGeneratedPluginTests`
// suite — those tests already cover the install path the sheet
// delegates to.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// A test-only generator that records the most recent call and
/// returns the configured plugin. Mirrors the helper in
/// `AIGeneratorViewModelTests` so the two suites read
/// consistently.
private final class InstallPromptMockGenerator: AIPluginGenerator {
    let response: GeneratedPlugin?
    let errorToThrow: Error?
    private(set) var lastRequest: String?
    private(set) var lastContext: AIGeneratorContext?

    init(response: GeneratedPlugin? = nil, errorToThrow: Error? = nil) {
        self.response = response
        self.errorToThrow = errorToThrow
    }

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        lastRequest = request
        lastContext = context
        if let errorToThrow { throw errorToThrow }
        guard let response else {
            throw AIGeneratorError.providerFailure(reason: "test: no response configured")
        }
        return response
    }
}

/// Build a fresh `PluginCapabilityGate` backed by an isolated
/// `UserDefaults` suite. The suite name is randomised so parallel
/// test runs do not stomp each other.
private func makeIsolatedGate() -> PluginCapabilityGate {
    let suiteName = "menubar01.tests.installPrompt.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return PluginCapabilityGate(defaults: defaults)
}

/// Build a `GeneratedPlugin` whose manifest declares the given
/// capability set. Used by the pre-flight tests so we can drive
/// `installPromptCapabilities` without involving the real
/// generator. The shorthand `[String]?` keeps the existing
/// test call sites readable — the helper maps each v1 string
/// to its modern descriptor (empty associated values). Unknown
/// strings are passed through as `nil` descriptors to mirror
/// the on-disk decoder's lenient behaviour.
private func makePlugin(
    name: String = "TestPlugin",
    capabilities: [String]? = nil
) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = name
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = "test.sh"
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
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho test\n",
        explanation: "test explanation",
        promptId: "p-\(UUID().uuidString)",
        promptVersion: "v-test"
    )
}

// MARK: - installPromptCapabilities

@MainActor
struct AIGeneratorInstallPromptCapabilitiesTests {
    @Test func testInstallPromptCapabilities_readsLatestPluginManifestCapabilities() async {
        let plugin = makePlugin(name: "Weather", capabilities: ["network"])
        let generator = InstallPromptMockGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        viewModel.request = "show weather"
        await viewModel.generate()

        #expect(viewModel.installPromptCapabilities == [.network(hosts: [])])
    }

    @Test func testInstallPromptCapabilities_emptyWhenNoLatestPlugin() {
        let generator = InstallPromptMockGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        // No generate() call → no latestPlugin.
        #expect(viewModel.installPromptCapabilities.isEmpty)
    }

    @Test func testInstallPromptCapabilities_dropsUnknownStrings() async {
        // `resolvedCapabilities` drops unknown strings with an
        // `os_log` warning; the install-prompt sheet's computed
        // property should mirror the dropped list, not the raw
        // manifest text.
        let plugin = makePlugin(capabilities: ["network", "future-foo", "clipboard"])
        let generator = InstallPromptMockGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        viewModel.request = "show weather"
        await viewModel.generate()

        #expect(viewModel.installPromptCapabilities == [.network(hosts: []), .clipboard])
    }
}

// MARK: - installPromptIsPreApproved

@MainActor
struct AIGeneratorInstallPromptPreApprovalTests {
    @Test func testInstallPromptIsPreApproved_trueWhenAllGranted() async {
        let plugin = makePlugin(name: "Weather", capabilities: ["network"])
        let generator = InstallPromptMockGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)
        let gate = makeIsolatedGate()
        gate.grant([.network(hosts: [])], for: "Weather")
        viewModel.pluginCapabilityGate = gate

        viewModel.request = "show weather"
        await viewModel.generate()

        #expect(viewModel.installPromptIsPreApproved == true)
    }

    @Test func testInstallPromptIsPreApproved_falseWhenAnyMissing() async {
        // Grant only `clipboard`; the plugin needs both
        // `network` and `clipboard`, so pre-flight must return
        // `false`.
        let plugin = makePlugin(
            name: "Weather",
            capabilities: ["network", "clipboard"]
        )
        let generator = InstallPromptMockGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)
        let gate = makeIsolatedGate()
        gate.grant([.clipboard], for: "Weather")
        viewModel.pluginCapabilityGate = gate

        viewModel.request = "show weather"
        await viewModel.generate()

        #expect(viewModel.installPromptIsPreApproved == false)
    }

    @Test func testInstallPromptIsPreApproved_trueWhenNoCapabilitiesDeclared() async {
        // A plugin with no declared capabilities should always
        // pre-approve — the install helper does not need to
        // present the prompt.
        let plugin = makePlugin(name: "Empty", capabilities: nil)
        let generator = InstallPromptMockGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        viewModel.request = "show nothing"
        await viewModel.generate()

        #expect(viewModel.installPromptCapabilities.isEmpty)
        #expect(viewModel.installPromptIsPreApproved == true)
    }
}

// MARK: - didCompleteInstall / didFailInstall

@MainActor
struct AIGeneratorInstallCompletionTests {
    @Test func testDidCompleteInstall_setsDidRequestSaveAndInstalledURL() {
        let generator = InstallPromptMockGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        // Pre-condition: flag is false and the URL is nil.
        #expect(viewModel.didRequestSave == false)
        #expect(viewModel.installedPluginURL == nil)

        let url = URL(fileURLWithPath: "/tmp/test-plugin")
        viewModel.didCompleteInstall(at: url)

        // Post-condition: flag flips to true and the URL is
        // stored so the parent sheet can render a success
        // banner with the on-disk path.
        #expect(viewModel.didRequestSave == true)
        #expect(viewModel.installedPluginURL == url)
    }

    @Test func testDidFailInstall_clearsInstalledURLAndDidRequestSave() {
        let generator = InstallPromptMockGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)
        viewModel.pluginCapabilityGate = makeIsolatedGate()

        // Simulate the user completing a previous install, then
        // cancelling the next one. Both pieces of state must
        // roll back so the parent sheet's "Installed!" banner
        // does not linger.
        viewModel.didCompleteInstall(at: URL(fileURLWithPath: "/tmp/old"))
        #expect(viewModel.didRequestSave == true)
        #expect(viewModel.installedPluginURL != nil)

        viewModel.didFailInstall(reason: "cancelled")

        #expect(viewModel.didRequestSave == false)
        #expect(viewModel.installedPluginURL == nil)
    }
}

// AIGeneratorViewModelTests.swift
// menubar01 — AI Plugin Generator (M2)
//
// Swift Testing coverage for `AIGeneratorViewModel`. All tests
// run purely on the main actor (the VM is `@MainActor`) and use a
// hand-rolled `MockAIPluginGenerator` to drive the state machine
// without going through the real `MockAIPluginGenerator` factory —
// the test asserts on the VM's *contract* (state transitions,
// request→round-trip, error surface, save stub) rather than on the
// concrete payload of any particular generator.

import Foundation
import Testing

@testable import menubar01

/// A test-only generator that records the `(request, context)` pair
/// for the most recent call and lets each test choose what to
/// return. Mirrors the spirit of M1's `MockAIPluginGenerator` but
/// without the SHA256 `promptId` contract — the VM does not depend
/// on a specific `promptId` shape, only on the round-trip.
private final class CapturingMockAIPluginGenerator: AIPluginGenerator {
    /// Value to return from `generate(...)`. `nil` means "throw
    /// `errorToThrow` instead". Tests set this and `errorToThrow`
    /// in the `init` to drive the VM through specific paths.
    let response: GeneratedPlugin?
    let errorToThrow: Error?
    /// Records the inputs the VM handed to the protocol.
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
        if let errorToThrow {
            throw errorToThrow
        }
        guard let response else {
            throw AIGeneratorError.providerFailure(reason: "test: no response configured")
        }
        return response
    }
}

/// Builds a `GeneratedPlugin` the VM tests can compare against.
/// Lives next to the test type so the test reads as a spec, not as
/// a fixture-loading exercise.
private func makeFixturePlugin(promptId: String) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = "TestPlugin"
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = "test.sh"
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho test\n",
        explanation: "test explanation",
        promptId: promptId,
        promptVersion: "v-test"
    )
}

@MainActor
struct AIGeneratorViewModelTests {

    @Test func testInitialStateIsIdleWithEmptyRequest() {
        let generator = CapturingMockAIPluginGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)

        #expect(viewModel.request.isEmpty)
        #expect(viewModel.state == .idle)
        #expect(viewModel.latestPlugin == nil)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.canGenerate == false)
        #expect(viewModel.manifestJSON == nil)
    }

    @Test func testCanGenerateRequiresNonEmptyRequest() {
        let generator = CapturingMockAIPluginGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "   "
        #expect(viewModel.canGenerate == false)

        viewModel.request = "show weather"
        #expect(viewModel.canGenerate == true)

        // Force into loading state and verify canGenerate disables
        // itself so the user can't fire a second round-trip while
        // the first is in flight.
        viewModel.state = .loading
        #expect(viewModel.canGenerate == false)
    }

    @Test func testGenerateTransitionsToSuccessAndStoresPlugin() async {
        let plugin = makeFixturePlugin(promptId: "abc123")
        let generator = CapturingMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "show weather in Beijing"
        await viewModel.generate()

        #expect(generator.lastRequest == "show weather in Beijing")
        #expect(generator.lastContext == viewModel.context)
        #expect(viewModel.latestPlugin != nil)
        #expect(viewModel.latestPlugin?.promptId == "abc123")
        #expect(viewModel.state == .success(plugin))
        #expect(viewModel.isLoading == false)
        #expect(viewModel.manifestJSON != nil)
    }

    @Test func testGenerateTransitionsToFailureOnProviderError() async {
        let generator = CapturingMockAIPluginGenerator(
            errorToThrow: AIGeneratorError.providerFailure(reason: "upstream down")
        )
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "show weather"
        await viewModel.generate()

        #expect(viewModel.latestPlugin == nil)
        if case .failure(let reason) = viewModel.state {
            #expect(reason.contains("upstream down"))
        } else {
            Issue.record("expected .failure(...) state, got \(viewModel.state)")
        }
    }

    @Test func testGenerateResetsDidRequestSaveFlag() async {
        let plugin = makeFixturePlugin(promptId: "p1")
        let generator = CapturingMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        // Set the flag directly to simulate "user clicked Save" — the
        // real `requestSaveToPluginFolder()` now performs disk I/O via
        // `PluginManager.shared`, so we don't want the test to depend
        // on whether the host test bundle has a plugin directory
        // configured. The flag's flip-on-save behaviour is covered by
        // `PluginManagerInstallGeneratedPluginTests`.
        viewModel.request = "first"
        await viewModel.generate()
        viewModel.didRequestSave = true
        #expect(viewModel.didRequestSave == true)

        // Second round-trip should reset the flag so the user can
        // save the new result.
        viewModel.request = "second"
        await viewModel.generate()
        #expect(viewModel.didRequestSave == false)
    }

    @Test func testGenerateSkipsEmptyRequests() async {
        let generator = CapturingMockAIPluginGenerator(
            response: makeFixturePlugin(promptId: "p1")
        )
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "   \n  "
        await viewModel.generate()

        // Generator must not be called and the VM must stay in
        // its initial state.
        #expect(generator.lastRequest == nil)
        #expect(viewModel.state == .idle)
    }

    @Test func testRequestSaveToPluginFolderIsNoOpWithoutLatestPlugin() {
        let generator = CapturingMockAIPluginGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)

        #expect(viewModel.didRequestSave == false)
        viewModel.requestSaveToPluginFolder()
        // No `latestPlugin` is set, so the save is a no-op and
        // the flag stays false. The full install path is
        // exercised by `PluginManagerInstallGeneratedPluginTests`.
        #expect(viewModel.didRequestSave == false)
    }

    @Test func testResetClearsStateAndLatestPlugin() async {
        let plugin = makeFixturePlugin(promptId: "p1")
        let generator = CapturingMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "first"
        await viewModel.generate()
        viewModel.requestSaveToPluginFolder()

        viewModel.reset()
        #expect(viewModel.state == .idle)
        #expect(viewModel.latestPlugin == nil)
        #expect(viewModel.didRequestSave == false)
    }

    @Test func testManifestJSONRoundTripsGeneratorOutput() async {
        let plugin = makeFixturePlugin(promptId: "p1")
        let generator = CapturingMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "anything"
        await viewModel.generate()

        guard let json = viewModel.manifestJSON else {
            Issue.record("manifestJSON was nil after a successful generate()")
            return
        }
        #expect(json.contains("TestPlugin"))
        #expect(json.contains("test.sh"))
    }
}

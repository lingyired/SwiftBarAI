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

        // Set the flag directly to simulate "the install-prompt
        // sheet's completion handler called
        // `viewModel.didCompleteInstall(at:)`" — the real
        // completion path lives in the sheet, so we don't want
        // the test to depend on whether the host test bundle
        // has a plugin directory configured. The flag's
        // flip-on-save behaviour is covered by
        // `AIGeneratorInstallPromptTests` and by
        // `PluginManagerInstallGeneratedPluginTests`.
        viewModel.request = "first"
        await viewModel.generate()
        viewModel.didCompleteInstall(at: URL(fileURLWithPath: "/tmp/anywhere"))
        #expect(viewModel.didRequestSave == true)

        // Second round-trip should reset the flag so the user
        // can save the new result.
        viewModel.request = "second"
        await viewModel.generate()
        #expect(viewModel.didRequestSave == false)
        #expect(viewModel.installedPluginURL == nil)
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
        // the flag stays false. The contract changed in the
        // M2-install-prompt follow-up: the view model no longer
        // performs the install itself — the
        // `AIGeneratorInstallPromptSheet` is the active
        // participant. The full install path is exercised by
        // `PluginManagerInstallGeneratedPluginTests`, and the
        // completion-driven state transitions are covered by
        // `AIGeneratorInstallPromptTests`.
        #expect(viewModel.didRequestSave == false)
    }

    @Test func testResetClearsStateAndLatestPlugin() async {
        let plugin = makeFixturePlugin(promptId: "p1")
        let generator = CapturingMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        viewModel.request = "first"
        await viewModel.generate()
        viewModel.didCompleteInstall(at: URL(fileURLWithPath: "/tmp/anywhere"))

        viewModel.reset()
        #expect(viewModel.state == .idle)
        #expect(viewModel.latestPlugin == nil)
        #expect(viewModel.didRequestSave == false)
        #expect(viewModel.installedPluginURL == nil)
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

// MARK: - menuTreeJSON population (M5 history follow-up)

@MainActor
struct AIGeneratorViewModelMenuTreeJSONTests {

    /// `CapturingMockAIPluginGenerator` that returns a plugin
    /// whose `entryScript` is the supplied string. Each test
    /// sets the script it wants to exercise so the menu-tree
    /// assertion is independent of the generator's payload.
    private final class ScriptedGenerator: AIPluginGenerator {
        let entryScript: String
        init(entryScript: String) { self.entryScript = entryScript }
        func generate(request: String, context: AIGeneratorContext) async throws -> GeneratedPlugin {
            var manifest = PluginManifest()
            manifest.name = "Scripted"
            manifest.version = "1.0.0"
            manifest.type = .Executable
            manifest.entry = "scripted.sh"
            return GeneratedPlugin(
                manifest: manifest,
                entryScript: entryScript,
                explanation: "scripted",
                promptId: "scripted-\(abs(entryScript.hashValue))",
                promptVersion: "v-scripted"
            )
        }
    }

    /// Test-only history store that captures the recorded entry
    /// so the menu-tree test can assert on it without booting
    /// the file-system store. Mirrors the M5 `TestHistoryStore`
    /// pattern.
    private final class CapturingHistoryStore: AIGeneratorHistoryStore {
        var rootDirectory: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
        private(set) var recordedEntries: [AIGeneratorHistoryEntry] = []
        func record(_ entry: AIGeneratorHistoryEntry) throws {
            recordedEntries.append(entry)
        }
        func listAll() throws -> [AIGeneratorHistoryEntry] { recordedEntries }
        func delete(promptId: String) throws {
            recordedEntries.removeAll { $0.promptId == promptId }
        }
        func deleteAll() throws { recordedEntries.removeAll() }
    }

    @Test func testGenerate_populatesMenuTreeJSONForParseableScript() async {
        let script = """
        #!/bin/zsh
        # generated by the menubar01 AI
        echo "Hello"
        echo "Status: OK | href=https://example.com/status"
        ---
        echo "Submenu"
        --echo "Child 1"
        """
        let generator = ScriptedGenerator(entryScript: script)
        let store = CapturingHistoryStore()
        let viewModel = AIGeneratorViewModel(
            generator: generator,
            historyStore: store
        )

        viewModel.request = "any"
        await viewModel.generate()

        #expect(store.recordedEntries.count == 1)
        let entry = try? #require(store.recordedEntries.first)
        let menuData = try? #require(entry?.menuTreeJSON)
        #expect(menuData != nil)
        // JSON should be decodable back into the expected array
        // shape so a future render pass can build a SwiftUI view
        // out of the bytes.
        let decoder = JSONDecoder()
        let nodes = try? decoder.decode([AIGeneratorMenuNode].self, from: menuData ?? Data())
        let parsed = try? #require(nodes)
        #expect((parsed?.count ?? 0) >= 1)
        // The first parsed node should reflect the first non-comment
        // line (`echo "Hello"` → title "Hello", no href).
        #expect(parsed?.first?.title == "Hello")
    }

    @Test func testGenerate_menuTreeJSONContainsHrefFromParameters() async {
        let script = #"echo "Link | href=https://example.com""#
        let generator = ScriptedGenerator(entryScript: script)
        let store = CapturingHistoryStore()
        let viewModel = AIGeneratorViewModel(
            generator: generator,
            historyStore: store
        )

        viewModel.request = "any"
        await viewModel.generate()

        let entry = try? #require(store.recordedEntries.first)
        let menuData = try? #require(entry?.menuTreeJSON)
        let decoder = JSONDecoder()
        let nodes = try? decoder.decode([AIGeneratorMenuNode].self, from: menuData ?? Data())
        let parsed = try? #require(nodes)
        #expect(parsed?.count == 1)
        #expect(parsed?.first?.title == "Link")
        #expect(parsed?.first?.href == "https://example.com")
    }

    @Test func testGenerate_menuTreeJSONIsNilForUnparseableScript() async {
        // Only a shebang and comments — `parseEntryScript(_:)`
        // should return `nil`, the view model's `encodeMenuTree`
        // helper should return `nil`, and the recorded entry's
        // `menuTreeJSON` should be `nil`.
        let script = "#!/bin/zsh\n# just a comment\n# nothing else\n"
        let generator = ScriptedGenerator(entryScript: script)
        let store = CapturingHistoryStore()
        let viewModel = AIGeneratorViewModel(
            generator: generator,
            historyStore: store
        )

        viewModel.request = "any"
        await viewModel.generate()

        let entry = try? #require(store.recordedEntries.first)
        #expect(entry?.menuTreeJSON == nil)
    }
}

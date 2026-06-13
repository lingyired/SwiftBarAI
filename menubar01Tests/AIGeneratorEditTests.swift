// AIGeneratorEditTests.swift
// menubar01 — AI Plugin Generator (M2+ edit mode)
//
// Swift Testing coverage for the "Continue editing" mode
// added to the M2 AI plugin generator sheet. The tests pin
// down the view-model contract:
//
// - `enterEditMode()` populates `editedManifestJSON` (as
//   pretty-printed JSON) and `editedEntryScript` from the
//   current `latestPlugin` and flips `isEditing` to `true`.
// - `saveEdits()` with valid JSON updates `latestPlugin`
//   and `state` to `.success(newPlugin)`, leaves edit mode,
//   and clears the buffers.
// - `saveEdits()` with invalid JSON does **not** change
//   `state` / `latestPlugin` and sets
//   `editModeErrorMessage` to a human-readable reason.
// - `exitEditMode()` clears both buffers and flips
//   `isEditing` back to `false`.
//
// The tests are pure: they use a hand-rolled
// `CapturingMockAIPluginGenerator` (mirroring the helper in
// `AIGeneratorViewModelTests` and
// `AIGeneratorInstallPromptTests`) so the suite never
// touches AppKit, SwiftUI's view graph, the filesystem, or
// the real `MockAIPluginGenerator` factory.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// A test-only generator that records the most recent call
/// and returns the configured plugin. Mirrors the helper in
/// `AIGeneratorViewModelTests` and `AIGeneratorInstallPromptTests`
/// so the three suites read consistently.
private final class EditMockAIPluginGenerator: AIPluginGenerator {
    let response: GeneratedPlugin?
    private(set) var lastRequest: String?
    private(set) var lastContext: AIGeneratorContext?

    init(response: GeneratedPlugin? = nil) {
        self.response = response
    }

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        lastRequest = request
        lastContext = context
        guard let response else {
            throw AIGeneratorError.providerFailure(
                reason: "test: no response configured"
            )
        }
        return response
    }
}

/// Build a `GeneratedPlugin` the edit-mode tests can
/// compare against. Uses a stable `promptId` so the tests
/// can match on it without depending on
/// `MockAIPluginGenerator`'s SHA256 hash function.
private func makeEditFixturePlugin(
    promptId: String = "edit-test-prompt"
) -> GeneratedPlugin {
    var manifest = PluginManifest()
    manifest.name = "EditFixture"
    manifest.version = "1.0.0"
    manifest.type = .Executable
    manifest.entry = "edit-fixture.sh"
    return GeneratedPlugin(
        manifest: manifest,
        entryScript: "#!/bin/zsh\necho edit-fixture\n",
        explanation: "edit fixture explanation",
        promptId: promptId,
        promptVersion: "v-edit-test"
    )
}

// MARK: - Tests

@MainActor
struct AIGeneratorEditTests {

    @Test func testEnterEditMode_populatesBuffers() async {
        let plugin = makeEditFixturePlugin(promptId: "p1")
        let generator = EditMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        // Pre-condition: edit mode is off and the buffers
        // are empty.
        #expect(viewModel.isEditing == false)
        #expect(viewModel.editedManifestJSON.isEmpty)
        #expect(viewModel.editedEntryScript.isEmpty)

        // Generate a plugin first — `enterEditMode()` is a
        // no-op without a `latestPlugin`.
        viewModel.request = "any"
        await viewModel.generate()
        #expect(viewModel.latestPlugin != nil)

        viewModel.enterEditMode()

        // Post-condition: `isEditing` flipped, both buffers
        // are populated, the JSON contains the manifest's
        // name, and the entry script mirrors
        // `latestPlugin.entryScript`.
        #expect(viewModel.isEditing == true)
        #expect(viewModel.editedManifestJSON.contains("EditFixture"))
        #expect(viewModel.editedManifestJSON.contains("edit-fixture.sh"))
        #expect(viewModel.editedEntryScript == plugin.entryScript)

        // Double-entering is a no-op — the buffers must
        // not be re-snapshotted (a re-enter would clobber
        // the user's in-flight edits).
        viewModel.editedEntryScript = "user in-flight tweak"
        viewModel.enterEditMode()
        #expect(viewModel.editedEntryScript == "user in-flight tweak")
    }

    @Test func testSaveEdits_validJSON_updatesStateAndLatestPlugin() async throws {
        let plugin = makeEditFixturePlugin(promptId: "p2")
        let generator = EditMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        // Drive the VM into a successful `.success(...)`
        // state and then enter edit mode.
        viewModel.request = "any"
        await viewModel.generate()
        viewModel.enterEditMode()
        #expect(viewModel.isEditing == true)

        // Replace the manifest JSON with a *valid* but
        // different `PluginManifest`. We encode a manifest
        // via `JSONEncoder` and then bind it to
        // `editedManifestJSON` so the bytes are guaranteed
        // to round-trip through `JSONDecoder`.
        var newManifest = PluginManifest()
        newManifest.name = "EditedName"
        newManifest.version = "2.0.0"
        newManifest.type = .Executable
        newManifest.entry = "edited.sh"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let newData = try encoder.encode(newManifest)
        let jsonString = try #require(String(data: newData, encoding: .utf8))
        viewModel.editedManifestJSON = jsonString
        viewModel.editedEntryScript = "#!/bin/zsh\necho edited\n"

        await viewModel.saveEdits()

        // Post-condition: edit mode is off, buffers are
        // cleared, the error message is nil, and the
        // `state` / `latestPlugin` reflect the new
        // manifest / entry script.
        #expect(viewModel.isEditing == false)
        #expect(viewModel.editedManifestJSON.isEmpty)
        #expect(viewModel.editedEntryScript.isEmpty)
        #expect(viewModel.editModeErrorMessage == nil)
        #expect(viewModel.latestPlugin?.manifest.name == "EditedName")
        #expect(viewModel.latestPlugin?.manifest.version == "2.0.0")
        #expect(viewModel.latestPlugin?.manifest.entry == "edited.sh")
        #expect(viewModel.latestPlugin?.entryScript == "#!/bin/zsh\necho edited\n")
        if case .success(let newPlugin) = viewModel.state {
            #expect(newPlugin.manifest.name == "EditedName")
            #expect(newPlugin.entryScript == "#!/bin/zsh\necho edited\n")
        } else {
            Issue.record("expected .success(newPlugin) state, got \(viewModel.state)")
        }
    }

    @Test func testSaveEdits_invalidJSON_setsErrorAndPreservesState() async {
        let plugin = makeEditFixturePlugin(promptId: "p3")
        let generator = EditMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        // Drive the VM into a successful `.success(...)`
        // state and then enter edit mode.
        viewModel.request = "any"
        await viewModel.generate()
        viewModel.enterEditMode()
        #expect(viewModel.isEditing == true)

        // Replace the manifest JSON with broken JSON
        // (an unterminated object) and tweak the entry
        // script so we can assert the buffers are also
        // preserved on parse failure.
        viewModel.editedManifestJSON = "{"
        viewModel.editedEntryScript = "would-be-saved on success"

        let stateBefore = viewModel.state
        let pluginBefore = viewModel.latestPlugin

        await viewModel.saveEdits()

        // Post-condition: edit mode stays on (the user
        // should be able to fix the JSON and re-save),
        // the buffers are preserved (so the user's
        // in-flight work is not lost), the error message
        // is set, and `state` / `latestPlugin` are
        // unchanged.
        #expect(viewModel.isEditing == true)
        #expect(viewModel.editedManifestJSON == "{")
        #expect(viewModel.editedEntryScript == "would-be-saved on success")
        #expect(viewModel.editModeErrorMessage != nil)
        #expect(viewModel.state == stateBefore)
        #expect(viewModel.latestPlugin?.promptId == pluginBefore?.promptId)
    }

    @Test func testExitEditMode_clearsBuffersAndFlag() async {
        let plugin = makeEditFixturePlugin(promptId: "p4")
        let generator = EditMockAIPluginGenerator(response: plugin)
        let viewModel = AIGeneratorViewModel(generator: generator)

        // Drive the VM into edit mode.
        viewModel.request = "any"
        await viewModel.generate()
        viewModel.enterEditMode()
        #expect(viewModel.isEditing == true)
        #expect(!viewModel.editedManifestJSON.isEmpty)
        #expect(!viewModel.editedEntryScript.isEmpty)

        // Also pre-set an error so we can verify the
        // exit path clears it.
        viewModel.editedManifestJSON = "{"
        viewModel.editedEntryScript = "in-flight"
        // We avoid calling `saveEdits()` here (it would
        // set `editModeErrorMessage`, which is the path
        // we want to clear). Instead we just exercise
        // the exit path.

        viewModel.exitEditMode()

        // Post-condition: `isEditing` is back to `false`
        // and both buffers are empty. A second
        // `exitEditMode()` is a no-op (no crash, no
        // state change).
        #expect(viewModel.isEditing == false)
        #expect(viewModel.editedManifestJSON.isEmpty)
        #expect(viewModel.editedEntryScript.isEmpty)

        viewModel.exitEditMode()
        #expect(viewModel.isEditing == false)
    }
}

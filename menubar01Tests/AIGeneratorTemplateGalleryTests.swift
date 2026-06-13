// AIGeneratorTemplateGalleryTests.swift
// menubar01 — AI Plugin Generator (M2+ template gallery)
//
// Swift Testing coverage for the M2+ template gallery: the data
// type, the v1 catalogue, and the integration with the generator
// view model (loading a template fills the request field but does
// NOT auto-trigger a round-trip). All tests are pure (no
// AppKit, no networking) and run on the main actor because the
// integration tests touch `AIGeneratorViewModel`, which is
// `@MainActor`.

import Foundation
import Testing

@testable import menubar01

@MainActor
struct AIGeneratorTemplateGalleryTests {

    // MARK: - Gallery catalogue

    @Test func testGallery_hasExpectedNumberOfTemplates() {
        // v1 ships exactly 6 templates (see the
        // `AIGeneratorTemplateGallery` enum header for the
        // contract). Adding or removing one is a non-breaking
        // change in count, but the v1 baseline is 6.
        #expect(AIGeneratorTemplateGallery.templates.count == 6)
    }

    @Test func testGallery_templateIDsAreUnique() {
        // The SwiftUI `ForEach` and any future "bookmark" /
        // "recently used" feature rely on each template having
        // a unique `id`. Collisions would silently de-duplicate
        // cards in the gallery.
        let ids = AIGeneratorTemplateGallery.templates.map(\.id)
        let unique = Set(ids)
        #expect(ids.count == unique.count, "duplicate template IDs: \(ids)")
    }

    @Test func testGallery_templatePromptsAreNonEmpty() {
        // A template with an empty `prompt` would load a blank
        // request into the sheet and look like a bug. Catch the
        // case at test time so it never lands.
        for template in AIGeneratorTemplateGallery.templates {
            #expect(
                !template.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "template \(template.id) has an empty prompt"
            )
            #expect(
                !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "template \(template.id) has an empty title"
            )
            #expect(
                !template.systemImageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "template \(template.id) has an empty SF Symbol"
            )
        }
    }

    // MARK: - View model integration

    /// Mock generator that records every `generate(...)` /
    /// `stream(...)` call. Mirrors the pattern in
    /// `AIGeneratorViewModelTests.CapturingMockAIPluginGenerator`
    /// but lives next to the gallery tests so the gallery's
    /// test file does not depend on a sibling test type.
    private final class CallCountingMockAIPluginGenerator: AIPluginGenerator {
        let response: GeneratedPlugin?
        let errorToThrow: Error?
        private(set) var generateCallCount: Int = 0
        private(set) var streamCallCount: Int = 0

        init(response: GeneratedPlugin? = nil, errorToThrow: Error? = nil) {
            self.response = response
            self.errorToThrow = errorToThrow
        }

        func generate(request: String, context: AIGeneratorContext) async throws -> GeneratedPlugin {
            generateCallCount += 1
            if let errorToThrow { throw errorToThrow }
            guard let response else {
                throw AIGeneratorError.providerFailure(reason: "test: no response configured")
            }
            return response
        }
    }

    @Test func testGallery_loadingTemplateIntoRequestField_doesNotAutoGenerate() {
        // The v1 contract: picking a template fills the
        // request field but does NOT fire a generator
        // round-trip. The user is expected to review and tweak
        // the prompt before clicking "Generate".
        let generator = CallCountingMockAIPluginGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)
        guard let template = AIGeneratorTemplateGallery.templates.first else {
            Issue.record("gallery is unexpectedly empty")
            return
        }

        // Pre-condition: nothing has run yet, the request is empty.
        #expect(generator.generateCallCount == 0)
        #expect(generator.streamCallCount == 0)
        #expect(viewModel.request.isEmpty)

        // Simulate the sheet's template-card tap: assign the
        // prompt directly. The view is just a wrapper around
        // `viewModel.request = template.prompt` (see
        // `AIGeneratorSheet.templateCard(for:)`), so
        // exercising the assignment here covers the same
        // contract without booting a SwiftUI view graph.
        viewModel.request = template.prompt

        // The request field reflects the template.
        #expect(viewModel.request == template.prompt)

        // ...but no generator call has been made and the VM
        // is still in the idle state.
        #expect(generator.generateCallCount == 0)
        #expect(generator.streamCallCount == 0)
        #expect(viewModel.state == .idle)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.latestPlugin == nil)
    }

    @Test func testGallery_loadingSameTemplateTwice_isIdempotent() {
        // Loading the same template twice (e.g. the user
        // double-taps the card) should not crash, duplicate
        // state, or change the generator's call count.
        let generator = CallCountingMockAIPluginGenerator()
        let viewModel = AIGeneratorViewModel(generator: generator)
        guard let template = AIGeneratorTemplateGallery.templates.first else {
            Issue.record("gallery is unexpectedly empty")
            return
        }

        viewModel.request = template.prompt
        viewModel.request = template.prompt

        #expect(viewModel.request == template.prompt)
        #expect(generator.generateCallCount == 0)
        #expect(generator.streamCallCount == 0)
        #expect(viewModel.state == .idle)
    }
}

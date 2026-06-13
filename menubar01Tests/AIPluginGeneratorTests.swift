// AIPluginGeneratorTests.swift
// menubar01 — AI Plugin Generator (M1)
//
// Swift Testing coverage for the M1 skeleton. All tests are pure
// (no filesystem, no AppKit, no async I/O) so they run in the
// `menubar01Tests` test target without needing the host application.

import CryptoKit
import Foundation
import Testing

@testable import menubar01

struct AIPluginGeneratorTests {

    @Test func testDefaultFactory_returnsNonNilGenerator() {
        let generator = AIPluginGeneratorFactory.makeDefault()
        #expect(generator is MockAIPluginGenerator)
        #expect(generator is AIPluginGenerator)
    }

    @Test func testMockGenerator_promptIdIsDeterministic() async throws {
        let generator = MockAIPluginGenerator()
        let context = AIGeneratorContext(model: "mock-7b-q4")

        let first = try await generator.generate(request: "show weather", context: context)
        let second = try await generator.generate(request: "show weather", context: context)
        #expect(first.promptId == second.promptId)

        let differentRequest = try await generator.generate(request: "show time", context: context)
        #expect(differentRequest.promptId != first.promptId)

        let differentModel = try await generator.generate(
            request: "show weather",
            context: AIGeneratorContext(model: "gpt-4o-mini")
        )
        #expect(differentModel.promptId != first.promptId)

        // Sanity check: the hash matches a fresh SHA256(request|model).
        var hasher = SHA256()
        let expected = hasher.chain(request: "show weather", model: "mock-7b-q4")
        #expect(first.promptId == expected)
    }

    @Test func testMockGenerator_generatedPluginHasRunnableManifest() async throws {
        let generator = MockAIPluginGenerator()
        let generated = try await generator.generate(
            request: "echo something",
            context: AIGeneratorContext.empty
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(generated.manifest)

        let decoder = JSONDecoder()
        let roundTripped = try decoder.decode(PluginManifest.self, from: manifestData)

        #expect(roundTripped.name == "Echo")
        #expect(roundTripped.entry?.isEmpty == false)
        #expect(roundTripped.entry == generated.manifest.entry)
    }

    @Test func testGeneratedPlugin_encodedAsBundle_writesTwoFiles() {
        var manifest = PluginManifest()
        manifest.name = "Echo"
        manifest.version = "1.0.0"
        manifest.type = .Executable
        manifest.entry = "echo.zsh"
        manifest.refreshInterval = 5
        manifest.runInBash = false

        let generated = GeneratedPlugin(
            manifest: manifest,
            entryScript: "#!/bin/zsh\necho hi\n",
            explanation: "n/a",
            promptId: "abc123",
            promptVersion: "v1.0-mock"
        )

        let bundle = generated.encodedAsBundle()
        #expect(!bundle.manifestData.isEmpty)
        #expect(bundle.entryFilename.hasSuffix(".sh") || bundle.entryFilename.hasSuffix(".zsh"))
        #expect(!bundle.entryData.isEmpty)
        #expect(String(data: bundle.entryData, encoding: .utf8)?.contains("echo hi") == true)
    }
}

// MARK: - Test Helpers

private extension SHA256 {
    /// Mirrors `MockAIPluginGenerator.promptId(for:model:)` for the
    /// determinism test. Centralised here so the test reads as a
    /// "spec for the expected hash" rather than re-implementing the
    /// hashing.
    mutating func chain(request: String, model: String) -> String {
        update(data: Data(request.utf8))
        update(data: Data("|".utf8))
        update(data: Data(model.utf8))
        return finalize().map { String(format: "%02x", $0) }.joined()
    }
}

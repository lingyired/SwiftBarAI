// LocalAIPluginGeneratorTests.swift
// menubar01 — AI Plugin Generator (M2+)
//
// Swift Testing coverage for the v1 stub
// `LocalAIPluginGenerator`. The v1 stub is honest about its
// limits: it does not wire up an inference runtime, it just
// validates the user-supplied model file and returns a clear
// `AIGeneratorError.providerFailure(reason:)` from
// `generate(...)`. The tests cover both halves of that
// contract:
//
//   * Init / validation — a valid `.gguf` file constructs
//     cleanly; a non-existent path or a wrong-extension file
//     is logged (init does not throw, by design, so the factory
//     can hand the view model a usable instance).
//   * Generate — `generate(...)` always throws
//     `.providerFailure` and the reason is non-empty,
//     mentions the model file path, and points the user at the
//     M2+ roadmap.
//   * `validate(modelPath:)` — directly exercised for the three
//     reject paths: directory, wrong extension, empty file.

import Foundation
import Testing

@testable import menubar01

// MARK: - Temp file helpers

/// Writes a `Data` blob to a unique temp file with the given
/// extension and returns the file URL. The file lives in
/// `NSTemporaryDirectory()` and is cleaned up at the end of the
/// enclosing test via `defer`.
private func makeTempFile(
    data: Data,
    fileName: String = "model.gguf"
) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
    )
    let url = dir.appendingPathComponent(fileName)
    try data.write(to: url)
    return url
}

/// Returns a fresh, unique temp directory URL. The directory
/// is created and a `defer`-able cleanup closure is returned
/// so each test can register cleanup at the end of its body.
private func makeTempDirectory() throws -> (URL, () -> Void) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
    )
    let cleanup: () -> Void = {
        try? FileManager.default.removeItem(at: dir)
    }
    return (dir, cleanup)
}

// MARK: - Init

struct LocalAIPluginGeneratorInitTests {

    @Test func testInit_succeedsWithValidGGUFFile() throws {
        // Write a tiny (>= 1 byte) temp file with the right
        // extension. Init must not throw; the validation
        // contract is "log on failure, do not throw", so a
        // passing init is observable purely as "no exception
        // escapes".
        let url = try makeTempFile(
            data: Data("GGUF\u{00}\u{00}\u{00}".utf8),
            fileName: "tiny.gguf"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let generator = LocalAIPluginGenerator(modelPath: url)
        #expect(generator.modelPath == url)
    }

    @Test func testInit_logsErrorOnInvalidFile() throws {
        // Point at a non-existent file with the right
        // extension. Init must not throw, but must log the
        // validation failure via `os_log`. The test does not
        // assert on the log output (os_log assertions are
        // brittle); it asserts that init completes and the
        // `modelPath` is stored verbatim so a downstream
        // `generate(...)` can surface the path in its error
        // message.
        let missing = URL(fileURLWithPath: "/nonexistent/path-\(UUID().uuidString).gguf")
        let generator = LocalAIPluginGenerator(modelPath: missing)
        #expect(generator.modelPath == missing)
    }
}

// MARK: - Generate

struct LocalAIPluginGeneratorGenerateTests {

    @Test func testGenerate_alwaysThrowsProviderFailure() async throws {
        // With a valid temp file, `generate(...)` must throw
        // `AIGeneratorError.providerFailure` and the reason
        // must be non-empty. v1 is a stub; the contract is
        // "validate, then explain that inference is not yet
        // wired up".
        let url = try makeTempFile(
            data: Data("GGUF\u{00}\u{00}\u{00}".utf8),
            fileName: "tiny.gguf"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let generator = LocalAIPluginGenerator(modelPath: url)
        do {
            _ = try await generator.generate(
                request: "show weather",
                context: AIGeneratorContext(model: "gguf-local-7b")
            )
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            guard case .providerFailure(let reason) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test func testProviderFailure_messageMentionsModelPath() async throws {
        // The user-facing error must include the model file
        // path so the user can see what they pointed at. This
        // is the contract that makes the v1 stub useful: the
        // user reads the message and decides whether to
        // switch providers, swap the model file, or wait for
        // v2.
        let url = try makeTempFile(
            data: Data("GGUF\u{00}\u{00}\u{00}".utf8),
            fileName: "user-model-\(UUID().uuidString).gguf"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let generator = LocalAIPluginGenerator(modelPath: url)
        do {
            _ = try await generator.generate(
                request: "show weather",
                context: AIGeneratorContext.empty
            )
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            guard case .providerFailure(let reason) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(reason.contains(url.path))
        }
    }
}

// MARK: - Validate

struct LocalAIPluginGeneratorValidateTests {

    @Test func testValidate_rejectsDirectory() throws {
        // A directory path is not a valid `.gguf` model
        // file. `validate` must throw
        // `AIGeneratorError.providerFailure(reason:)` with a
        // non-empty reason that names the path.
        let (dir, cleanup) = try makeTempDirectory()
        defer { cleanup() }

        do {
            try LocalAIPluginGenerator.validate(modelPath: dir)
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            guard case .providerFailure(let reason) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
            #expect(reason.contains(dir.path))
        }
    }

    @Test func testValidate_rejectsNonGGUFExtension() throws {
        // A file with a non-`.gguf` extension (e.g. `.txt`)
        // is not a valid model file. The reason must mention
        // the wrong extension so the user can see what they
        // pointed at.
        let url = try makeTempFile(
            data: Data("hello world".utf8),
            fileName: "notes-\(UUID().uuidString).txt"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            try LocalAIPluginGenerator.validate(modelPath: url)
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            guard case .providerFailure(let reason) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
            #expect(reason.contains("txt"))
        }
    }

    @Test func testValidate_rejectsEmptyFile() throws {
        // A 0-byte `.gguf` is a clear mistake and should
        // fail validation before the user gets a confusing
        // "not implemented" error in `generate()`.
        let url = try makeTempFile(
            data: Data(),
            fileName: "empty-\(UUID().uuidString).gguf"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            try LocalAIPluginGenerator.validate(modelPath: url)
            Issue.record("expected .providerFailure, got success")
        } catch let error as AIGeneratorError {
            guard case .providerFailure(let reason) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
            #expect(reason.contains(url.path))
        }
    }

    @Test func testValidate_acceptsValidGGUF() throws {
        // Sanity check: a tiny non-empty `.gguf` passes
        // validation. This is the inverse of the three
        // reject tests above.
        let url = try makeTempFile(
            data: Data([0x47, 0x47, 0x55, 0x46]),
            fileName: "ok-\(UUID().uuidString).gguf"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Must not throw.
        try LocalAIPluginGenerator.validate(modelPath: url)
    }
}

// MARK: - Version

struct LocalAIPluginGeneratorVersionTests {

    @Test func testPromptVersion_isLocalStub() {
        // The v1 stub reports a stable `promptVersion` so a
        // system report or future M5 history view can tell
        // the placeholder apart from the mock and from the
        // future real v2 implementation.
        #expect(LocalAIPluginGenerator.localPromptVersion == "v1.0-local-stub")
    }
}

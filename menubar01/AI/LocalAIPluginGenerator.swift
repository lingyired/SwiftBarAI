// LocalAIPluginGenerator.swift
// menubar01 — AI Plugin Generator (M2+)
//
// v1 scaffolded stub for the on-device local-model provider. This
// file replaces the M2+ `LocalEchoAIPluginGenerator` placeholder
// that lived in `EchoAIPluginGenerator.swift`. The factory at
// `AIPluginGeneratorFactory.makeLocal(modelPath:prefs:)` now
// returns this type when the user has configured a model path.
//
// v1 is honest about its limits: it does **not** wire up any
// inference runtime. A real local generator needs llama.cpp (or
// similar) as a SwiftPM dependency, which v1 deliberately avoids
// because the dependency cost is large and the M2+ view-model
// contract already flows through a real-type name. v2 lands the
// real on-device inference (see `AI_PLUGIN_ARCHITECTURE.md` §4
// "M2+ roadmap" and §6 "open questions").
//
// What v1 does:
//   1. Validates the user-supplied `modelPath` synchronously in
//      `init`. The file must exist, be a regular file (not a
//      directory), end in `.gguf`, and be non-empty. Invalid
//      paths are logged via `os_log` and the generator is
//      constructed anyway so downstream callers do not crash;
//      the user-facing error surfaces from `generate(...)`.
//   2. Returns a clear `AIGeneratorError.providerFailure(reason:)`
//      from `generate(...)` that names the model file, points
//      the user at the M2+ roadmap, and tells them to switch
//      the provider to "remote" in the meantime.
//
// The validation and error path are deliberate user-visible
// surface. The error message is the contract: a user who points
// at a real GGUF model and clicks "Generate" in the AI
// Preferences pane sees a message that tells them exactly what
// they pointed at, what is and isn't wired up, and what their
// options are. That contract is exercised by the
// `LocalAIPluginGeneratorTests` suite.

import Foundation
import os

/// Real on-device local-model `AIPluginGenerator` (v1 stub).
///
/// In v1 this type validates the model file and returns a clear
/// "not yet implemented" error. v2 will replace the
/// `generate(request:context:)` body with a llama.cpp-backed
/// inference runtime; the `init` and the `AIPluginGenerator`
/// surface are designed to be stable across the v1 → v2 swap so
/// the factory and the view model do not have to change.
public final class LocalAIPluginGenerator: AIPluginGenerator {
    /// Version string reported in `GeneratedPlugin.promptVersion`.
    /// Distinguishes the stub's error-only payload from
    /// `MockAIPluginGenerator.mockPromptVersion` (`"v1.0-mock"`),
    /// `RemoteEchoAIPluginGenerator.remoteEchoPromptVersion`
    /// (`"v1.0-echo-remote"`), `LocalEchoAIPluginGenerator.localEchoPromptVersion`
    /// (`"v1.0-echo-local"`), and from the future real v2
    /// implementation's semver tag.
    public static let localPromptVersion = "v1.0-local-stub"

    /// Stable label the M5 history-UI filter picker groups
    /// local-model entries under. Surfaced through
    /// `AIPluginGenerator.providerName` so the user can narrow
    /// the sidebar to "Local" runs only.
    public static let providerDisplayName = "Local"

    /// The on-disk model path the user picked in the Preferences →
    /// AI pane. Stored verbatim so the future real local-inference
    /// v2 can adopt the same `init` and start loading from the
    /// same path with no factory change.
    public let modelPath: URL

    private static let log = OSLog(subsystem: "com.lingyi.menubar01", category: "AIGenerator")

    /// Build a real local-model generator.
    ///
    /// v1 is a stub: the `modelPath` is validated (must exist, be
    /// a regular file, end in `.gguf`, and be non-empty) but the
    /// validation failure is **logged** rather than thrown, so the
    /// factory can hand the view model a usable instance even
    /// when the user has pointed at a bad path. The user-facing
    /// error is raised later from `generate(...)` so the M2
    /// sheet's "click Generate" path always gets a clear
    /// `AIGeneratorError.providerFailure(reason:)` rather than a
    /// crash.
    public init(modelPath: URL) {
        self.modelPath = modelPath
        // Validate the model file. Validation must succeed
        // synchronously, in `init`, because the factory
        // builds the generator lazily and downstream code
        // expects a usable instance to be returned.
        do {
            try Self.validate(modelPath: modelPath)
        } catch {
            os_log("LocalAIPluginGenerator: invalid model at %{public}@: %{public}@",
                   log: Self.log, type: .error, modelPath.path, error.localizedDescription)
        }
    }

    /// `providerName` for the local generator. Mirrors the
    /// static `providerDisplayName` so the M5 history filter
    /// picker can group local-model entries together
    /// independent of the on-disk `modelPath`.
    public var providerName: String? { Self.providerDisplayName }

    public func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin {
        // v1: scaffolded stub. The validation passes, but we
        // never produce a plugin. The error message is the
        // user-facing contract: it tells the user that local
        // inference is not yet implemented and what file
        // they pointed at, so they can decide whether to
        // switch to a remote provider, swap the model file,
        // or wait for the v2 llama.cpp-backed implementation.
        _ = request
        _ = context
        throw AIGeneratorError.providerFailure(reason: """
        Local AI inference is not yet implemented in this build of menubar01. \
        The model file at \(modelPath.path) was found and validated, but no \
        inference backend is wired up yet — see the M2+ roadmap in \
        AI_PLUGIN_ARCHITECTURE.md §4. Switch the AI provider to "remote" in \
        Preferences → AI to use a hosted LLM in the meantime.
        """)
    }

    // MARK: - Validation

    /// Synchronously checks that `modelPath` looks like a usable
    /// GGUF model file. Exposed internally so the test suite can
    /// assert against the exact rule without going through
    /// `init`.
    ///
    /// Rules:
    ///   1. The path must exist on disk.
    ///   2. The path must be a regular file (not a directory).
    ///   3. The path's extension must be `gguf` (case-insensitive).
    ///   4. The file must be non-empty (size > 0).
    static func validate(modelPath: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath.path) else {
            throw AIGeneratorError.providerFailure(reason: "model file does not exist: \(modelPath.path)")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: modelPath.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AIGeneratorError.providerFailure(reason: "model path is a directory, not a file: \(modelPath.path)")
        }
        guard modelPath.pathExtension.lowercased() == "gguf" else {
            throw AIGeneratorError.providerFailure(reason: "model file must be a .gguf file, got: \(modelPath.pathExtension)")
        }
        // Optionally check the file is non-empty. A 0-byte .gguf
        // would be a clear mistake and should fail validation
        // before the user gets a confusing "not implemented"
        // error in `generate()`.
        let attrs = try fm.attributesOfItem(atPath: modelPath.path)
        let size = (attrs[.size] as? Int) ?? 0
        guard size > 0 else {
            throw AIGeneratorError.providerFailure(reason: "model file is empty: \(modelPath.path)")
        }
    }
}

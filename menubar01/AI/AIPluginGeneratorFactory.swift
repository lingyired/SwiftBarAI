// AIPluginGeneratorFactory.swift
// menubar01 — AI Plugin Generator (M1)
//
// Integration surface the Plugin Repository window will call in M2.
// All three factory methods currently return `MockAIPluginGenerator`
// — the local and remote paths are deliberate stubs, not unfinished
// work. M2 will wire `makeLocal` and `makeRemote` to real providers
// driven by the new `AIProvider` preference key.

import Foundation

/// Builds `AIPluginGenerator` instances for the rest of the app.
///
/// M1 ships a single implementation, `MockAIPluginGenerator`, behind
/// all three factory methods. This keeps the Plugin Repository
/// window's call sites stable while the real provider code lands in
/// M2+ — see `AI_PLUGIN_ARCHITECTURE.md` §6 for the milestone
/// breakdown.
public enum AIPluginGeneratorFactory {

    /// The default generator. For v1 this is the mock.
    public static func makeDefault() -> AIPluginGenerator {
        MockAIPluginGenerator()
    }

    /// Build a generator backed by an on-device model at `modelPath`.
    ///
    /// - Important: Local models are stubbed in v1; see M2. This
    ///   method deliberately returns the mock so call sites and
    ///   preferences UI can be wired up before the real model loader
    ///   lands.
    public static func makeLocal(modelPath: URL) -> AIPluginGenerator {
        _ = modelPath // intentionally unused in v1
        return MockAIPluginGenerator()
    }

    /// Build a generator that calls a remote model provider.
    ///
    /// - Important: Remote providers are stubbed in v1; see M2. This
    ///   method deliberately returns the mock so call sites and
    ///   preferences UI can be wired up before the real HTTP client
    ///   (and the network capability prompt) land.
    public static func makeRemote(
        endpoint: URL,
        apiKey: String
    ) -> AIPluginGenerator {
        _ = endpoint   // intentionally unused in v1
        _ = apiKey     // intentionally unused in v1
        return MockAIPluginGenerator()
    }
}

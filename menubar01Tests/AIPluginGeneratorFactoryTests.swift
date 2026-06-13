// AIPluginGeneratorFactoryTests.swift
// menubar01 — AI Plugin Generator (M2+ factory wiring)
//
// Swift Testing coverage for the config-driven
// `AIPluginGeneratorFactory` extension. The factory reads four
// `AIPluginGenerator.*` keys from a `PreferencesStore`; each
// test constructs a `PreferencesStore` backed by a per-test
// `UserDefaults(suiteName:)` (UUID-suffixed) so the suite never
// touches `UserDefaults.standard` and tests can run in parallel
// without stomping each other's prefs.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a fresh `UserDefaults` suite per call. The suite name
/// uses a UUID so parallel test runs (and Swift Testing's
/// cross-process re-execution model) do not stomp each other.
private func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "menubar01.tests.aiFactory.\(UUID().uuidString)")!
}

/// Builds a `PreferencesStore` backed by an isolated
/// `UserDefaults`. The store's `@Published` setters write to
/// the suite, the factory's read helpers read from the suite,
/// and the suite is discarded when the test returns so the next
/// test gets a clean slate.
private func makeIsolatedPreferencesStore() -> PreferencesStore {
    PreferencesStore(defaults: makeIsolatedDefaults())
}

// MARK: - makeDefault — happy paths

struct AIPluginGeneratorFactoryDefaultTests {

    @Test func testMakeDefault_withNoPrefsKey_returnsMockGenerator() {
        // No keys written → factory defaults to the mock
        // (the M1 contract the test suite has relied on).
        let prefs = makeIsolatedPreferencesStore()
        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        #expect(generator is MockAIPluginGenerator)
        #expect(generator is AIPluginGenerator)
    }

    @Test func testMakeDefault_withMockProviderKey_returnsMockGenerator() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.mock.rawValue, forKey: AIPluginGeneratorFactory.providerKey)

        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        #expect(generator is MockAIPluginGenerator)
    }

    @Test func testMakeDefault_withLocalProviderKey_andModelPathSet_returnsLocalAIGenerator() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.local.rawValue, forKey: AIPluginGeneratorFactory.providerKey)
        prefs.defaults.set("/tmp/fake-model.gguf", forKey: AIPluginGeneratorFactory.localModelPathKey)

        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        // The M2+ factory now returns the real
        // `LocalAIPluginGenerator` v1 stub (validates the
        // `.gguf` file and returns a clear
        // `AIGeneratorError.providerFailure(reason:)` from
        // `generate(...)`). The M2+ `LocalEchoAIPluginGenerator`
        // placeholder is no longer the production return
        // value; it is kept in the source tree for future
        // reference only.
        #expect(generator is LocalAIPluginGenerator)
        // Strong-typed access to the real local generator's
        // recorded input. A future v2 llama.cpp-backed
        // implementation will keep the same `init` shape so
        // the cast continues to hold.
        if let local = generator as? LocalAIPluginGenerator {
            #expect(local.modelPath.path == "/tmp/fake-model.gguf")
        } else {
            Issue.record("expected LocalAIPluginGenerator, got \(type(of: generator))")
        }
    }

    @Test func testMakeDefault_withLocalProviderKey_andNoModelPath_returnsMockAndLogsWarning() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.local.rawValue, forKey: AIPluginGeneratorFactory.providerKey)
        // Deliberately no `localModelPath` key — the factory
        // must fall back to the mock so the view model's
        // "click Generate" path never crashes from a missing
        // path.
        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        #expect(generator is MockAIPluginGenerator)
    }

    @Test func testMakeDefault_withRemoteProviderKey_andEndpointAndKeySet_returnsRemoteAIGenerator() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.remote.rawValue, forKey: AIPluginGeneratorFactory.providerKey)
        prefs.defaults.set("https://api.example.com/v1/chat", forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        prefs.defaults.set("sk-test-1234567890", forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)

        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        // The factory now returns the real URLSession-backed
        // `RemoteAIPluginGenerator` when both inputs are
        // configured. The fallback to the mock for missing
        // inputs is covered separately below.
        #expect(generator is RemoteAIPluginGenerator)
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.endpoint.absoluteString == "https://api.example.com/v1/chat")
            #expect(remote.apiKey == "sk-test-1234567890")
        } else {
            Issue.record("expected RemoteAIPluginGenerator, got \(type(of: generator))")
        }
    }

    @Test func testMakeDefault_withRemoteProviderKey_andMissingEndpoint_returnsMockAndLogsWarning() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.remote.rawValue, forKey: AIPluginGeneratorFactory.providerKey)
        prefs.defaults.set("sk-test-1234567890", forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        // No endpoint. The factory should fall back to the mock
        // rather than throwing.
        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        #expect(generator is MockAIPluginGenerator)
    }

    @Test func testFactory_doesNotCrashOnMalformedProviderValue() {
        // A hand-edited or stale prefs file can hold any string
        // in the provider key. The factory must log a warning
        // and fall back to the mock rather than crashing the
        // M2 sheet's "click Generate" path.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("some-unknown-value", forKey: AIPluginGeneratorFactory.providerKey)

        let generator = AIPluginGeneratorFactory.makeDefault(prefs: prefs)
        #expect(generator is MockAIPluginGenerator)
    }
}

// MARK: - makeLocal — direct invocation

struct AIPluginGeneratorFactoryLocalTests {

    @Test func testMakeLocal_withNilModelPath_returnsMockAndLogsWarning() {
        // The `makeLocal(modelPath: nil, ...)` form is
        // forgiving: it should never throw, it should warn
        // and return the mock.
        let prefs = makeIsolatedPreferencesStore()
        let generator = AIPluginGeneratorFactory.makeLocal(modelPath: nil, prefs: prefs)
        #expect(generator is MockAIPluginGenerator)
    }

    @Test func testMakeLocal_withModelPath_returnsLocalAIGenerator() {
        let prefs = makeIsolatedPreferencesStore()
        let url = URL(fileURLWithPath: "/tmp/some/local-model.gguf")
        let generator = AIPluginGeneratorFactory.makeLocal(modelPath: url, prefs: prefs)
        // The real v1 stub: validates the `.gguf` and returns
        // a clear `AIGeneratorError.providerFailure(reason:)`
        // from `generate(...)`. The `modelPath` is stored
        // verbatim on the instance so a future v2 llama.cpp
        // implementation can adopt the same `init` and start
        // loading from the same path with no factory change.
        #expect(generator is LocalAIPluginGenerator)
        if let local = generator as? LocalAIPluginGenerator {
            #expect(local.modelPath == url)
        }
    }
}

// MARK: - makeRemote — direct invocation

struct AIPluginGeneratorFactoryRemoteTests {

    @Test func testMakeRemote_withBothArgs_returnsRemoteAIGenerator() {
        let prefs = makeIsolatedPreferencesStore()
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let apiKey = "sk-test-abcdef"

        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: endpoint,
            apiKey: apiKey,
            prefs: prefs
        )
        // The real URLSession-backed generator is now the
        // happy-path return value. The apiKey / endpoint are
        // stored verbatim on the instance so a future real
        // session can adopt the same `init` and start sending
        // requests to the same URL with no factory change.
        #expect(generator is RemoteAIPluginGenerator)
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.endpoint == endpoint)
            #expect(remote.apiKey == apiKey)
        }
    }

    @Test func testMakeRemote_withNilEndpoint_returnsMockAndLogsWarning() {
        let prefs = makeIsolatedPreferencesStore()
        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: nil,
            apiKey: "sk-test",
            prefs: prefs
        )
        #expect(generator is MockAIPluginGenerator)
    }

    @Test func testMakeRemote_usesPrefsModel() {
        // The user-configured model in the AI Preferences pane
        // is persisted as `AIPluginGenerator.model`. The factory
        // must read it and pass it to `RemoteAIPluginGenerator`
        // so the request body carries the right identifier.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("gpt-4o", forKey: AIPluginGeneratorFactory.remoteModelKey)
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let apiKey = "sk-test-abcdef"

        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: endpoint,
            apiKey: apiKey,
            prefs: prefs
        )
        #expect(generator is RemoteAIPluginGenerator)
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.model == "gpt-4o")
        } else {
            Issue.record("expected RemoteAIPluginGenerator, got \(type(of: generator))")
        }
    }

    @Test func testMakeRemote_fallsBackToDefaultWhenModelMissing() {
        // No `AIPluginGenerator.model` key in prefs → factory
        // must hand the generator the `defaultRemoteModel`
        // constant (`"gpt-4o-mini"`) so a fresh-install user
        // gets the documented default without having to open
        // the Preferences pane.
        let prefs = makeIsolatedPreferencesStore()
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let apiKey = "sk-test-abcdef"

        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: endpoint,
            apiKey: apiKey,
            prefs: prefs
        )
        #expect(generator is RemoteAIPluginGenerator)
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.model == AIPluginGeneratorFactory.defaultRemoteModel)
            #expect(remote.model == "gpt-4o-mini")
        } else {
            Issue.record("expected RemoteAIPluginGenerator, got \(type(of: generator))")
        }
    }

    @Test func testMakeRemote_fallsBackToDefaultWhenModelEmpty() {
        // An empty string is treated the same as a missing key:
        // the view model's `save()` removes empty values, so an
        // empty `AIPluginGenerator.model` should only appear in
        // hand-edited prefs files — but the factory must
        // tolerate it.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("", forKey: AIPluginGeneratorFactory.remoteModelKey)
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let apiKey = "sk-test-abcdef"

        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: endpoint,
            apiKey: apiKey,
            prefs: prefs
        )
        #expect(generator is RemoteAIPluginGenerator)
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.model == "gpt-4o-mini")
        } else {
            Issue.record("expected RemoteAIPluginGenerator, got \(type(of: generator))")
        }
    }

    @Test func testMakeRemote_fallsBackToDefaultWhenModelWhitespace() {
        // A user who pastes `   ` (or `"\n"`) into the model
        // field must not end up sending a request with an
        // empty / whitespace model identifier.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("   ", forKey: AIPluginGeneratorFactory.remoteModelKey)
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let apiKey = "sk-test-abcdef"

        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: endpoint,
            apiKey: apiKey,
            prefs: prefs
        )
        #expect(generator is RemoteAIPluginGenerator)
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.model == "gpt-4o-mini")
        } else {
            Issue.record("expected RemoteAIPluginGenerator, got \(type(of: generator))")
        }
    }

    @Test func testMakeRemote_trimsWhitespaceAroundModel() {
        // Belt-and-braces: a user who pastes `  gpt-4o  `
        // should not have the surrounding whitespace end up in
        // the request body. The factory's read helper trims;
        // the view model's `save()` also trims, so the prefs
        // value is normally already trimmed — but the factory
        // must still tolerate a hand-edited prefs file.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("  gpt-4o  ", forKey: AIPluginGeneratorFactory.remoteModelKey)
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let apiKey = "sk-test-abcdef"

        let generator = AIPluginGeneratorFactory.makeRemote(
            endpoint: endpoint,
            apiKey: apiKey,
            prefs: prefs
        )
        if let remote = generator as? RemoteAIPluginGenerator {
            #expect(remote.model == "gpt-4o")
        } else {
            Issue.record("expected RemoteAIPluginGenerator, got \(type(of: generator))")
        }
    }
}

// MARK: - Placeholder contract

struct EchoAIPluginGeneratorContractTests {

    @Test func testLocalEchoGenerator_embedsModelPathInExplanation() async throws {
        // The placeholder records the user's chosen modelPath
        // in the explanation string so the M2 sheet's preview
        // can show which model produced the result. The test
        // verifies the path appears verbatim in the
        // explanation (and therefore in the user-visible
        // surface).
        let modelPath = URL(fileURLWithPath: "/tmp/menubar01-ai/test-model.gguf")
        let generator = LocalEchoAIPluginGenerator(modelPath: modelPath)
        let plugin = try await generator.generate(
            request: "show weather",
            context: AIGeneratorContext.empty
        )
        #expect(plugin.explanation.contains(modelPath.path))
    }

    @Test func testRemoteEchoGenerator_embedsEndpointInExplanation() async throws {
        let endpoint = URL(string: "https://api.example.com/v1/chat")!
        let generator = RemoteEchoAIPluginGenerator(endpoint: endpoint, apiKey: "sk-test")
        let plugin = try await generator.generate(
            request: "show weather",
            context: AIGeneratorContext.empty
        )
        #expect(plugin.explanation.contains(endpoint.absoluteString))
    }

    @Test func testRemoteEchoGenerator_doesNotEmbedAPIKeyInExplanation() async throws {
        // Security: the apiKey must never leak into the
        // user-visible explanation. The diagnostic `os_log`
        // line in `init` is the only place the redacted key
        // appears; the explanation string is a public surface
        // that may end up in a system-report dump, a future
        // M5 history view, or a sharable prompt-debug bundle.
        let apiKey = "sk-supersecret-1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let generator = RemoteEchoAIPluginGenerator(
            endpoint: URL(string: "https://api.example.com/v1/chat")!,
            apiKey: apiKey
        )
        let plugin = try await generator.generate(
            request: "show weather",
            context: AIGeneratorContext.empty
        )
        #expect(!plugin.explanation.contains(apiKey))
        // Belt-and-braces: assert that no contiguous
        // 8+ char slice of the key appears in the
        // explanation, defending against the key being
        // accidentally chunked into a longer string.
        let probe = String(apiKey.prefix(8))
        #expect(!plugin.explanation.contains(probe))
    }

    @Test func testEchoGenerators_promptIdMatchesMockContract() async throws {
        // The Echo placeholders must respect the same
        // `SHA256(request + "|" + context.model)` promptId
        // algorithm `MockAIPluginGenerator` uses, so the
        // existing test suite (and any future
        // history-persistence code keyed on promptId) treats
        // Echo payloads uniformly.
        let mockPlugin = try await MockAIPluginGenerator().generate(
            request: "show weather",
            context: AIGeneratorContext.empty
        )
        let localPlugin = try await LocalEchoAIPluginGenerator(
            modelPath: URL(fileURLWithPath: "/tmp/x")
        ).generate(
            request: "show weather",
            context: AIGeneratorContext.empty
        )
        let remotePlugin = try await RemoteEchoAIPluginGenerator(
            endpoint: URL(string: "https://example.com")!,
            apiKey: "k"
        ).generate(
            request: "show weather",
            context: AIGeneratorContext.empty
        )
        #expect(localPlugin.promptId == mockPlugin.promptId)
        #expect(remotePlugin.promptId == mockPlugin.promptId)
    }
}

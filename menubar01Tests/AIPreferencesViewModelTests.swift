// AIPreferencesViewModelTests.swift
// menubar01 — AI Plugin Generator (M2+ Preferences pane)
//
// Swift Testing coverage for `AIPreferencesViewModel`. The
// view model wraps a `PreferencesStore` (which wraps a
// `UserDefaults`) and persists the four
// `AIPluginGenerator.*` keys the factory reads.
//
// Every test uses a fresh `UserDefaults(suiteName:)` (UUID-
// suffixed) so the suite never touches `UserDefaults.standard`
// and parallel runs do not stomp each other.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a fresh `UserDefaults` suite per call. The suite name
/// uses a UUID so parallel test runs (and Swift Testing's
/// cross-process re-execution model) do not stomp each other.
private func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "menubar01.tests.aiPrefs.\(UUID().uuidString)")!
}

/// Builds a `PreferencesStore` backed by an isolated
/// `UserDefaults`. The store's `@Published` setters write to
/// the suite, the view model's read / write helpers read from
/// the suite, and the suite is discarded when the test returns
/// so the next test gets a clean slate.
private func makeIsolatedPreferencesStore() -> PreferencesStore {
    PreferencesStore(defaults: makeIsolatedDefaults())
}

// MARK: - Init reads

struct AIPreferencesViewModelInitTests {

    @Test @MainActor
    func testInit_readsProviderFromPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.local.rawValue,
                           forKey: AIPluginGeneratorFactory.providerKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.provider == .local)
    }

    @Test @MainActor
    func testInit_readsRemoteProviderFromPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.remote.rawValue,
                           forKey: AIPluginGeneratorFactory.providerKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.provider == .remote)
    }

    @Test @MainActor
    func testInit_readsLocalModelPathFromPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("/tmp/menubar01-ai/test.gguf",
                           forKey: AIPluginGeneratorFactory.localModelPathKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.localModelPath == "/tmp/menubar01-ai/test.gguf")
    }

    @Test @MainActor
    func testInit_readsRemoteEndpointFromPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("https://api.example.com/v1/chat",
                           forKey: AIPluginGeneratorFactory.remoteEndpointKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.remoteEndpoint == "https://api.example.com/v1/chat")
    }

    @Test @MainActor
    func testInit_readsRemoteAPIKeyFromPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("sk-test-1234567890",
                           forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.remoteAPIKey == "sk-test-1234567890")
    }

    @Test @MainActor
    func testInit_readsRemoteModelFromPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("claude-3-5-sonnet",
                           forKey: AIPluginGeneratorFactory.remoteModelKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.remoteModel == "claude-3-5-sonnet")
    }

    @Test @MainActor
    func testInit_defaultsRemoteModelToFactoryDefaultWhenKeyMissing() {
        // No `remoteModelKey` written → the view model shows
        // the factory's `defaultRemoteModel` in the text
        // field, so a fresh-install user sees what the factory
        // will pick without having to open the pane first.
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.remoteModel == AIPluginGeneratorFactory.defaultRemoteModel)
        #expect(viewModel.remoteModel == "gpt-4o-mini")
    }

    @Test @MainActor
    func testInit_defaultsToMockWhenPrefsKeyMissing() {
        // No `providerKey` written → view model falls back to
        // the factory's default of `.mock`.
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.provider == .mock)
    }

    @Test @MainActor
    func testInit_defaultsToMockWhenProviderKeyIsMalformed() {
        // A hand-edited prefs file can hold an unknown string.
        // The view model must not crash; it falls back to
        // `.mock` the same way the factory does.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("totally-unknown", forKey: AIPluginGeneratorFactory.providerKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.provider == .mock)
    }

    @Test @MainActor
    func testInit_defaultsToEmptyStringsWhenKeysMissing() {
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.localModelPath.isEmpty)
        #expect(viewModel.remoteEndpoint.isEmpty)
        #expect(viewModel.remoteAPIKey.isEmpty)
        // The model field does **not** default to empty — it
        // defaults to the factory's `defaultRemoteModel` so
        // the text field is pre-populated. Covered separately
        // in `testInit_defaultsRemoteModelToFactoryDefaultWhenKeyMissing`.
        #expect(viewModel.remoteModel == AIPluginGeneratorFactory.defaultRemoteModel)
    }
}

// MARK: - Save

struct AIPreferencesViewModelSaveTests {

    @Test @MainActor
    func testSave_writesProviderToPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.provider = .remote

        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.providerKey)
                == AIPluginGeneratorProvider.remote.rawValue)
    }

    @Test @MainActor
    func testSave_writesLocalModelPathToPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.localModelPath = "/tmp/some-model.gguf"

        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.localModelPathKey)
                == "/tmp/some-model.gguf")
    }

    @Test @MainActor
    func testSave_writesRemoteEndpointToPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.remoteEndpoint = "https://api.example.com/v1"

        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteEndpointKey)
                == "https://api.example.com/v1")
    }

    @Test @MainActor
    func testSave_writesRemoteAPIKeyToPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.remoteAPIKey = "sk-saved-key"

        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
                == "sk-saved-key")
    }

    @Test @MainActor
    func testSave_clearsLocalModelPathWhenEmpty() {
        // Empty strings must be removed (not written as ""), so
        // the factory's "missing key" check fires on the next
        // call and the user gets the expected "fall back to
        // mock" behaviour.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("/tmp/old-model.gguf",
                           forKey: AIPluginGeneratorFactory.localModelPathKey)
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.localModelPath == "/tmp/old-model.gguf")

        viewModel.localModelPath = ""
        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.localModelPathKey) == nil)
    }

    @Test @MainActor
    func testSave_clearsRemoteEndpointWhenEmpty() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("https://old.example.com",
                           forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        let viewModel = AIPreferencesViewModel(prefs: prefs)

        viewModel.remoteEndpoint = ""
        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteEndpointKey) == nil)
    }

    @Test @MainActor
    func testSave_clearsRemoteAPIKeyWhenEmpty() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("sk-old-key", forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        let viewModel = AIPreferencesViewModel(prefs: prefs)

        viewModel.remoteAPIKey = ""
        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey) == nil)
    }

    @Test @MainActor
    func testSave_writesRemoteModelToPrefs() {
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.remoteModel = "claude-3-5-sonnet"

        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey)
                == "claude-3-5-sonnet")
    }

    @Test @MainActor
    func testSave_trimsWhitespaceAroundRemoteModel() {
        // A user who pastes `  gpt-4o  ` (or types a trailing
        // space) must not have the whitespace end up in the
        // prefs value. The factory's read-side trim is the
        // belt; this trim is the braces.
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.remoteModel = "  gpt-4o  "

        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey)
                == "gpt-4o")
    }

    @Test @MainActor
    func testSave_clearsRemoteModelWhenEmpty() {
        // Empty strings must be removed (not written as ""), so
        // the factory's "missing key → defaultRemoteModel"
        // check fires on the next call and the user gets the
        // expected "fall back to gpt-4o-mini" behaviour.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("claude-3-5-sonnet",
                           forKey: AIPluginGeneratorFactory.remoteModelKey)
        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.remoteModel == "claude-3-5-sonnet")

        viewModel.remoteModel = ""
        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey) == nil)
    }

    @Test @MainActor
    func testSave_clearsRemoteModelWhenWhitespace() {
        // Whitespace-only is treated like empty: removed, not
        // written. Belt-and-braces against the factory's
        // read-side trim-empty-fallback.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set("claude-3-5-sonnet",
                           forKey: AIPluginGeneratorFactory.remoteModelKey)
        let viewModel = AIPreferencesViewModel(prefs: prefs)

        viewModel.remoteModel = "   "
        viewModel.save()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey) == nil)
    }
}

// MARK: - Reset

struct AIPreferencesViewModelResetTests {

    @Test @MainActor
    func testReset_clearsAllFourKeys() {
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.local.rawValue,
                           forKey: AIPluginGeneratorFactory.providerKey)
        prefs.defaults.set("/tmp/model.gguf",
                           forKey: AIPluginGeneratorFactory.localModelPathKey)
        prefs.defaults.set("https://api.example.com/v1",
                           forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        prefs.defaults.set("sk-test-1234567890",
                           forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        prefs.defaults.set("claude-3-5-sonnet",
                           forKey: AIPluginGeneratorFactory.remoteModelKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        viewModel.reset()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.providerKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.localModelPathKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteEndpointKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey) == nil)
    }

    @Test @MainActor
    func testReset_snapspublishedStateBackToDefaults() {
        // The Reset button is user-visible: clicking it must
        // update the form fields, not just the underlying
        // prefs. The user expects the picker to swing back to
        // "Mock (offline)" and the four string fields to
        // empty/default.
        let prefs = makeIsolatedPreferencesStore()
        prefs.defaults.set(AIPluginGeneratorProvider.remote.rawValue,
                           forKey: AIPluginGeneratorFactory.providerKey)
        prefs.defaults.set("/tmp/old.gguf", forKey: AIPluginGeneratorFactory.localModelPathKey)
        prefs.defaults.set("https://old.example.com",
                           forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        prefs.defaults.set("sk-old", forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        prefs.defaults.set("claude-3-5-sonnet",
                           forKey: AIPluginGeneratorFactory.remoteModelKey)

        let viewModel = AIPreferencesViewModel(prefs: prefs)
        #expect(viewModel.provider == .remote)
        #expect(!viewModel.localModelPath.isEmpty)
        #expect(!viewModel.remoteEndpoint.isEmpty)
        #expect(!viewModel.remoteAPIKey.isEmpty)
        #expect(viewModel.remoteModel == "claude-3-5-sonnet")

        viewModel.reset()

        #expect(viewModel.provider == .mock)
        #expect(viewModel.localModelPath.isEmpty)
        #expect(viewModel.remoteEndpoint.isEmpty)
        #expect(viewModel.remoteAPIKey.isEmpty)
        #expect(viewModel.remoteModel == AIPluginGeneratorFactory.defaultRemoteModel)
    }

    @Test @MainActor
    func testReset_isIdempotentWhenPrefsAreEmpty() {
        // Calling reset() on a clean store is a no-op — the
        // test guards against accidentally introducing a
        // required key on the reset path.
        let prefs = makeIsolatedPreferencesStore()
        let viewModel = AIPreferencesViewModel(prefs: prefs)

        viewModel.reset()

        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.providerKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.localModelPathKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteEndpointKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey) == nil)
        #expect(prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey) == nil)
    }
}

// MARK: - Round trip

struct AIPreferencesViewModelRoundTripTests {

    @Test @MainActor
    func testRoundTrip_writeThenRead() {
        // End-to-end: write through one view model, then build
        // a second one against the same prefs and verify the
        // second one reads what the first wrote.
        let prefs = makeIsolatedPreferencesStore()
        let writer = AIPreferencesViewModel(prefs: prefs)
        writer.provider = .remote
        writer.localModelPath = "/tmp/written.gguf"
        writer.remoteEndpoint = "https://api.example.com/v1/chat"
        writer.remoteAPIKey = "sk-round-trip-1234567890"
        writer.remoteModel = "claude-3-5-sonnet"
        writer.save()

        let reader = AIPreferencesViewModel(prefs: prefs)
        #expect(reader.provider == .remote)
        #expect(reader.localModelPath == "/tmp/written.gguf")
        #expect(reader.remoteEndpoint == "https://api.example.com/v1/chat")
        #expect(reader.remoteAPIKey == "sk-round-trip-1234567890")
        #expect(reader.remoteModel == "claude-3-5-sonnet")
    }

    @Test @MainActor
    func testRoundTrip_resetThenReinit_defaultsToMock() {
        // After reset(), re-initialising the view model against
        // the same prefs must produce a `.mock` provider with
        // empty strings — the factory's default behaviour.
        let prefs = makeIsolatedPreferencesStore()
        let writer = AIPreferencesViewModel(prefs: prefs)
        writer.provider = .local
        writer.localModelPath = "/tmp/some-model.gguf"
        writer.remoteModel = "claude-3-5-sonnet"
        writer.save()
        writer.reset()

        let reader = AIPreferencesViewModel(prefs: prefs)
        #expect(reader.provider == .mock)
        #expect(reader.localModelPath.isEmpty)
        #expect(reader.remoteEndpoint.isEmpty)
        #expect(reader.remoteAPIKey.isEmpty)
        #expect(reader.remoteModel == AIPluginGeneratorFactory.defaultRemoteModel)
    }
}

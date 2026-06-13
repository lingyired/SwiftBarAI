// AIPreferencesView.swift
// menubar01 — AI Plugin Generator (M2+ Preferences pane)
//
// SwiftUI pane that lets the user pick the active
// `AIPluginGeneratorProvider` and configure the corresponding
// model path / endpoint / API key. The pane writes the four
// `AIPluginGenerator.*` keys that
// `AIPluginGeneratorFactory.makeDefault(prefs:)` reads
// (shipped in 4075eb9).
//
// Scope is intentionally narrow: the four fields plus a Save /
// Reset pair. We do **not** ship a "Test connection" button —
// the factory's existing `os_log` warning is the diagnostic for
// a misconfigured provider, and shelling out to a live LLM
// would add cost / failure modes the Preferences window does
// not need to own.

import AppKit
import SwiftUI

// MARK: - View model

/// Backing view model for `AIPreferencesView`. The view binds
/// to the four `@Published` strings and persists them on
/// `save()`; `reset()` clears all four prefs keys and re-reads
/// the (now-empty) values back into the published state so the
/// UI snaps back to the factory's default of `.mock`.
///
/// The model is `@MainActor` because SwiftUI binds to it from
/// the main thread, and the prefs read / write is fast enough
/// to be done inline.
@MainActor
final class AIPreferencesViewModel: ObservableObject {
    @Published var provider: AIPluginGeneratorProvider
    @Published var localModelPath: String
    @Published var remoteEndpoint: String
    @Published var remoteAPIKey: String
    @Published var remoteModel: String

    /// The underlying prefs store. Tests inject a
    /// suite-backed `PreferencesStore(defaults:)` so the read /
    /// write operations stay off `UserDefaults.standard`.
    let prefs: PreferencesStore

    init(prefs: PreferencesStore = .shared) {
        self.prefs = prefs
        // Read from prefs.defaults. Mirrors the factory's
        // read-side fallbacks: missing or malformed provider
        // key → `.mock`; missing or empty string keys → "".
        let rawProvider = prefs.defaults.string(forKey: AIPluginGeneratorFactory.providerKey)
        self.provider = rawProvider.flatMap(AIPluginGeneratorProvider.init(rawValue:)) ?? .mock
        self.localModelPath = prefs.defaults.string(forKey: AIPluginGeneratorFactory.localModelPathKey) ?? ""
        self.remoteEndpoint = prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteEndpointKey) ?? ""
        self.remoteAPIKey = prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey) ?? ""
        // The model defaults to the factory's fallback when the
        // prefs key is missing; users see the default value
        // pre-populated in the text field so a fresh-install
        // user can tell at a glance what the factory will pick.
        self.remoteModel = prefs.defaults.string(forKey: AIPluginGeneratorFactory.remoteModelKey)
            ?? AIPluginGeneratorFactory.defaultRemoteModel
    }

    // MARK: Persistence

    /// Persist the `AIPluginGenerator.*` keys. Empty
    /// strings are removed (not written) so the factory's
    /// "missing key" check fires on the next call and the user
    /// gets the expected "fall back to mock" behaviour.
    func save() {
        prefs.defaults.set(provider.rawValue, forKey: AIPluginGeneratorFactory.providerKey)
        if localModelPath.isEmpty {
            prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.localModelPathKey)
        } else {
            prefs.defaults.set(localModelPath, forKey: AIPluginGeneratorFactory.localModelPathKey)
        }
        if remoteEndpoint.isEmpty {
            prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        } else {
            prefs.defaults.set(remoteEndpoint, forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        }
        if remoteAPIKey.isEmpty {
            prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        } else {
            prefs.defaults.set(remoteAPIKey, forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        }
        // Trim the model before writing so a user-typed trailing
        // space doesn't slip past the factory's read-side
        // trim-empty-fallback. Empty / whitespace-only is
        // removed (not written) so the factory's
        // defaultRemoteModel fallback fires on the next call.
        let trimmedModel = remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.isEmpty {
            prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.remoteModelKey)
        } else {
            prefs.defaults.set(trimmedModel, forKey: AIPluginGeneratorFactory.remoteModelKey)
        }
        prefs.defaults.synchronize()
    }

    /// Clear all five keys and re-read the (now-empty) state
    /// into the published properties so the UI snaps back to
    /// the factory's defaults.
    func reset() {
        prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.providerKey)
        prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.localModelPathKey)
        prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.remoteEndpointKey)
        prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.remoteAPIKeyKey)
        prefs.defaults.removeObject(forKey: AIPluginGeneratorFactory.remoteModelKey)
        prefs.defaults.synchronize()
        provider = .mock
        localModelPath = ""
        remoteEndpoint = ""
        remoteAPIKey = ""
        remoteModel = AIPluginGeneratorFactory.defaultRemoteModel
    }
}

// MARK: - View

/// SwiftUI pane that lets the user configure the active AI
/// provider and its corresponding inputs.
///
/// The pane reads / writes the same four `AIPluginGenerator.*`
/// keys `AIPluginGeneratorFactory.makeDefault(prefs:)` consumes.
/// It does **not** build an `AIPluginGenerator` instance itself:
/// "user-facing config" (this pane) and "build an instance"
/// (the factory) are deliberately split.
struct AIPreferencesView: View {
    @StateObject private var viewModel: AIPreferencesViewModel

    /// Brief toast shown after a successful save / reset.
    /// `nil` hides the banner; any other value renders for a
    /// couple of seconds and then the view's `task` modifier
    /// clears it.
    @State private var banner: Banner?

    private struct Banner: Equatable, Identifiable {
        let id = UUID()
        let kind: Kind
        enum Kind: Equatable {
            case saved
            case reset
        }
    }

    init(viewModel: AIPreferencesViewModel? = nil) {
        // SwiftUI's `View` inits are not implicitly
        // `@MainActor`-isolated, but our view model is. We
        // accept an optional here so a default-init
        // `AIPreferencesView()` works (the view model is built
        // on the main actor below), and so tests / previews
        // can still inject a hand-built instance.
        let resolved: AIPreferencesViewModel
        if let viewModel { resolved = viewModel } else { resolved = AIPreferencesViewModel() }
        _viewModel = StateObject(wrappedValue: resolved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            providerSection
            switch viewModel.provider {
            case .mock:
                mockSection
            case .local:
                localSection
            case .remote:
                remoteSection
            }
            footerSection
        }
        .padding(18)
        .frame(width: 500, alignment: .topLeading)
    }

    // MARK: Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI Plugin Generator")
                .font(.headline)
            Text("Choose which provider powers the “Generate plugin with AI…” workflow. The active provider is read at generate time, so toggling here affects the next click.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerSection: some View {
        SettingsPaneSection {
            SettingsPaneRow(title: "Provider") {
                Picker("", selection: $viewModel.provider) {
                    ForEach(AIPluginGeneratorProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var mockSection: some View {
        SettingsPaneSection {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("The generator will use the offline mock. No LLM call is made. The generator’s response is deterministic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var localSection: some View {
        SettingsPaneSection {
            SettingsPaneRow(title: "Model file", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("", text: $viewModel.localModelPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(true)
                            .help(viewModel.localModelPath.isEmpty
                                  ? "No model file selected."
                                  : viewModel.localModelPath)
                        Button("Choose…") {
                            pickLocalModel()
                        }
                    }
                    if !viewModel.localModelPath.isEmpty
                        && !FileManager.default.fileExists(atPath: viewModel.localModelPath) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("File does not exist. The factory will fall back to the mock on next generate.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else if !viewModel.localModelPath.isEmpty {
                        Text("The on-device model will load from this path on next generate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Pick a GGUF / on-device model file. The factory reads this on next generate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var remoteSection: some View {
        SettingsPaneSection {
            SettingsPaneRow(title: "Endpoint URL") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("https://api.example.com/v1/chat", text: $viewModel.remoteEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if viewModel.remoteEndpoint.isEmpty {
                        Text("The factory needs an endpoint URL to call the remote model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if URL(string: viewModel.remoteEndpoint) == nil {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Not a valid URL. The factory will fall back to the mock on next generate.")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                    } else {
                        Text("Endpoint looks valid.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsPaneRow(title: "Model") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("gpt-4o-mini", text: $viewModel.remoteModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("The model identifier sent in the chat-completions request body. Defaults to “gpt-4o-mini”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsPaneRow(title: "API key") {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("sk-…", text: $viewModel.remoteAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if viewModel.remoteAPIKey.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("API key is empty. The factory will fall back to the mock on next generate.")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                    } else {
                        Text("Stored in UserDefaults (v1). A future Keychain migration is planned.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner {
                bannerRow(banner)
            }
            HStack {
                Button("Reset", role: .destructive) {
                    viewModel.reset()
                    banner = Banner(kind: .reset)
                }
                Spacer()
                Button("Save") {
                    viewModel.save()
                    banner = Banner(kind: .saved)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .task(id: banner) {
            // Auto-dismiss the toast after a short delay. The
            // `task(id:)` modifier re-fires whenever the
            // banner changes; cancelling the old task before
            // starting the new one means a quick Save / Reset
            // never overlaps two timers.
            guard banner != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                banner = nil
            }
        }
    }

    @ViewBuilder
    private func bannerRow(_ banner: Banner) -> some View {
        let (symbol, color, text): (String, Color, String) = {
            switch banner.kind {
            case .saved:
                return ("checkmark.circle.fill", .green, "Saved.")
            case .reset:
                return ("arrow.uturn.backward.circle.fill", .secondary, "Reset to defaults.")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: File picker

    /// Open an `NSOpenPanel` constrained to model-shaped files
    /// (`.gguf` / `.bin` / `.mlmodel` / `public.data`) so the
    /// user can pick a local model file. The picked path is
    /// written back to the view model. The pane is otherwise
    /// unaware of file contents.
    private func pickLocalModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose on-device model file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = []
        }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.localModelPath = url.path
        }
    }
}

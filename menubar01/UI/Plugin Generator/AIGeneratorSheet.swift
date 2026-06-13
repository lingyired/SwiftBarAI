// AIGeneratorSheet.swift
// menubar01 — AI Plugin Generator (M2)
//
// SwiftUI sheet that lets the user type a natural-language plugin
// request and preview the generator's output. The actual "live
// preview" — running the generated script in a sandbox — is out of
// scope for M2 (it's M3 capability-gate territory). M2 just renders
// the manifest JSON, the entry script body, the model's
// explanation, and the `promptId` as text so the user can accept
// or reject the result.
//
// Driven by `AIGeneratorViewModel`. The view never holds generator
// state of its own — every state transition goes through the VM.
//
// M2 install-prompt: clicking "Save to Plugin Folder" now opens a
// second modal sheet (`AIGeneratorInstallPromptSheet`) that lists
// the plugin's declared capabilities, lets the user grant / deny
// each, and on Install calls `PluginCapabilityGate.grant(_:for:)`
// for every enabled capability before handing the plugin to
// `PluginManager.installGeneratedPlugin(_:)`.

import SwiftUI

/// Modal sheet that hosts the AI plugin generator workflow.
///
/// v1 (M2) surface:
/// - A multi-line `TextEditor` for the request.
/// - A "Generate" button that calls `viewModel.generate()`.
/// - When `.success(...)`: the manifest JSON, the entry script,
///   the explanation, the `promptId`, and a "Re-generate" / "Save
///   to Plugin Folder" / "Cancel" trio.
/// - When `.failure(reason)`: a red error banner with a
///   "Re-generate" retry button.
@MainActor
struct AIGeneratorSheet: View {
    @StateObject private var viewModel: AIGeneratorViewModel

    /// Backing state for the install-prompt sub-sheet. The
    /// `AIGeneratorInstallPromptSheet` is presented as a SwiftUI
    /// `.sheet(...)` modal so it stacks cleanly on top of this
    /// sheet and dismisses independently.
    @State private var showingInstallPrompt: Bool = false

    /// Designated initializer. Tests pass a hand-built view model
    /// that wraps a `MockAIPluginGenerator`; the production call
    /// site (`PluginGeneratorMenuCommand.presentSheet`) constructs
    /// the default `AIGeneratorViewModel` explicitly on the main
    /// actor. We do **not** use a default-value parameter here
    /// because a default of `AIGeneratorViewModel()` would force
    /// the call site to invoke a `@MainActor` initializer from a
    /// nonisolated context.
    init(viewModel: AIGeneratorViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    templateGallery
                    requestEditor
                    errorBanner
                    installSuccessBanner
                    streamingPreviewSection
                    if let plugin = viewModel.latestPlugin {
                        resultSection(for: plugin)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isStreaming)
        .animation(.easeInOut(duration: 0.2), value: viewModel.streamingPreview)
        .sheet(isPresented: $showingInstallPrompt) {
            AIGeneratorInstallPromptSheet(viewModel: viewModel) { result in
                // The sub-sheet's completion handler is the only
                // path back into view-model state. We toggle the
                // presentation binding first so the SwiftUI sheet
                // dismisses, then update the view model.
                showingInstallPrompt = false
                switch result {
                case .success(let url):
                    viewModel.didCompleteInstall(at: url)
                case .failure(let error):
                    switch error {
                    case .noLatestPlugin:
                        viewModel.didFailInstall(reason: "cancelled")
                    case .installFailed(let reason):
                        viewModel.didFailInstall(reason: reason)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Generate plugin with AI…")
                    .font(.title3.weight(.semibold))
                Text("Describe what the plugin should show. The generator returns a manifest, a script, and a short explanation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    /// M2+ template gallery: a horizontal-scrolling row of pre-made
    /// prompts the user can one-click load into the request field.
    /// Sits **above** the request `TextEditor` so it is visible
    /// from the empty state (before the user has typed anything)
    /// and remains tappable when the field is already populated
    /// — tapping a template REPLACES the current text (v1
    /// contract; the user can undo with the standard Cmd-Z).
    private var templateGallery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Start from a template")
                    .font(.headline)
                Spacer()
                Text("\(AIGeneratorTemplateGallery.templates.count) ready to try")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(AIGeneratorTemplateGallery.templates) { template in
                        templateCard(for: template)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// One card in the template gallery. Tapping the card fills
    /// `viewModel.request` with the template's prompt. The
    /// `withAnimation` block gives a brief scale + haptic so the
    /// user gets confirmation the tap registered without the
    /// sheet auto-generating.
    private func templateCard(for template: AIGeneratorTemplate) -> some View {
        Button {
            // Fill, then animate. We do NOT call
            // `viewModel.generate()` / `generateStreaming()`
            // here — the user is expected to review and tweak
            // the prompt before clicking "Generate". This is
            // the v1 contract documented in
            // `AIGeneratorTemplate`.
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.request = template.prompt
            }
            // Light haptic to confirm the tap. We use the
            // generic `.alignment` style so we do not assume
            // the user's accessibility / Reduce Motion
            // preferences; NSHapticFeedbackManager handles
            // the "respect system settings" part for us.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: template.systemImageName)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text(template.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(template.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(width: 200, height: 120, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Request")
                .font(.headline)
            TextEditor(text: $viewModel.request)
                .font(.body.monospaced())
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            HStack {
                Text("Tip: be specific. e.g. “show today's weather in Beijing, refresh every 30 minutes”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if case .failure(let reason) = viewModel.state {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generator failed")
                        .font(.subheadline.weight(.semibold))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var installSuccessBanner: some View {
        if viewModel.didRequestSave, let url = viewModel.installedPluginURL {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed!")
                        .font(.subheadline.weight(.semibold))
                    Text(url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Live "model is thinking" preview shown only while
    /// `viewModel.isStreaming` is `true` and the overall state
    /// is `.loading`. Renders the accumulated
    /// `streamingPreview` in a monospaced, scrollable view so
    /// the user can watch the response arrive token-by-token
    /// from the M2+ `RemoteAIPluginGenerator`. Falls through
    /// to nothing on `.idle`, `.success(_)`, `.failure(_)`,
    /// and during the non-streaming fallback path (the M2+
    /// view model still flips `isStreaming` to `true` while
    /// the fallback `generate()` runs, but `streamingPreview`
    /// stays `""` so the section is empty — no visual
    /// regression vs. today).
    @ViewBuilder
    private var streamingPreviewSection: some View {
        if viewModel.isStreaming {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Streaming response…")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                ScrollView(.vertical, showsIndicators: true) {
                    Text(viewModel.streamingPreview.isEmpty ? " " : viewModel.streamingPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func resultSection(for plugin: GeneratedPlugin) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            explanationSection(for: plugin)
            promptIdSection(for: plugin)
            manifestSection
            entryScriptSection(for: plugin)
        }
    }

    private func explanationSection(for plugin: GeneratedPlugin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Explanation")
                .font(.headline)
            Text(plugin.explanation)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func promptIdSection(for plugin: GeneratedPlugin) -> some View {
        HStack(spacing: 6) {
            Text("promptId:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(plugin.promptId)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
            Text("promptVersion: \(plugin.promptVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("manifest.json")
                .font(.headline)
            if let json = viewModel.manifestJSON {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("(manifest is not yet encodable)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryScriptSection(for plugin: GeneratedPlugin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Entry script")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(plugin.entryScript)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Generating…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                // M2's sheet is hosted in a standalone `NSWindow`
                // (not a SwiftUI `.sheet`), so there is no
                // `\.dismiss` environment to call. Close the
                // key window instead. The
                // `PluginGeneratorMenuCommand` keeps the
                // window controller alive for the next click.
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.cancelAction)
            if viewModel.latestPlugin != nil {
                Button("Re-generate") {
                    // Always go through `generateStreaming()` —
                    // the view model auto-detects whether the
                    // active generator supports streaming and
                    // falls back to `generate()` for the
                    // Mock / Echo / Local stub generators. See
                    // `AIGeneratorViewModel.generateStreaming()`.
                    Task { await viewModel.generateStreaming() }
                }
                .disabled(!viewModel.canGenerate)
                Button("Save to Plugin Folder") {
                    // M2 install-prompt: opening the prompt sheet
                    // here, not in the view model. The sub-sheet
                    // reads `viewModel.latestPlugin` /
                    // `viewModel.installPromptCapabilities` and
                    // calls back through the `.sheet` completion
                    // handler with the result. The view model
                    // itself is a no-op for the install — the
                    // sheet is the active participant.
                    showingInstallPrompt = true
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Generate") {
                    // Always go through `generateStreaming()` —
                    // see the matching comment on the
                    // "Re-generate" branch above for the
                    // auto-detect rationale.
                    Task { await viewModel.generateStreaming() }
                }
                .disabled(!viewModel.canGenerate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

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
//
// M2+ "Save as Template": clicking the new "Save as Template"
// button in the footer opens `AIGeneratorSaveTemplateSheet`, which
// captures a title, an SF Symbol, and a read-only preview of the
// current request. On Save the parent sheet writes the new
// `AIGeneratorTemplate` to disk through
// `AIGeneratorTemplateStore.shared.addTemplate(_:)` and reloads
// the gallery so the new card appears immediately. The 6 built-in
// templates stay read-only; user-saved templates get a small
// `person.crop.circle` badge and a long-press / context menu
// "Delete template" action.

import AppKit
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
///
/// v2 (M2+): adds a horizontal "Start from a template" gallery
/// (built-in + user-saved) and a "Save as Template" footer
/// button so the user can persist the current request as a
/// reusable template card.
@MainActor
struct AIGeneratorSheet: View {
    @StateObject private var viewModel: AIGeneratorViewModel

    /// Backing state for the install-prompt sub-sheet. The
    /// `AIGeneratorInstallPromptSheet` is presented as a SwiftUI
    /// `.sheet(...)` modal so it stacks cleanly on top of this
    /// sheet and dismisses independently.
    @State private var showingInstallPrompt: Bool = false

    /// Backing state for the "Save as Template" sub-sheet.
    /// Presented from the footer's "Save as Template" button;
    /// dismissed from the sub-sheet's completion handler. The
    /// `AIGeneratorSaveTemplateSheet` is read-only on the
    /// request text and writes the assembled
    /// `AIGeneratorTemplate` back through `onComplete` so the
    /// parent sheet owns the disk write and the gallery
    /// refresh.
    @State private var showingSaveTemplateSheet: Bool = false

    /// One-shot alert surfaced by the "Export…" footer button
    /// after an `AIGeneratorExporter.exportPlugin(_:)` call.
    /// `nil` means no alert is shown; a non-nil value is
    /// rendered as a modal `NSAlert` on the main run loop
    /// (the sheet's host window is a plain `NSWindow`, so an
    /// `NSAlert` is the right tool — it stacks on top of the
    /// key window and the user can dismiss with Return /
    /// Escape). Reset back to `nil` after the alert returns.
    @State private var exportAlert: ExportAlert?

    /// User-saved templates loaded from
    /// `AIGeneratorTemplateStore.shared` at sheet-open time
    /// and refreshed after every save / delete. Merged with
    /// the 6 built-ins by
    /// `AIGeneratorTemplateGallery.allTemplates(including:)`
    /// to produce the gallery's renderable array. Stored
    /// here (instead of computed on demand) so the SwiftUI
    /// `ForEach` sees a stable `id` set across re-renders
    /// and a delete can animate the card out without a
    /// full gallery rebuild.
    @State private var userTemplates: [AIGeneratorTemplate] = []

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
        .onAppear(perform: reloadUserTemplates)
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
        .sheet(isPresented: $showingSaveTemplateSheet) {
            AIGeneratorSaveTemplateSheet(currentRequest: viewModel.request) { result in
                // Toggle the binding first so SwiftUI dismisses
                // the sub-sheet, then either persist the new
                // template (which triggers a gallery reload) or
                // no-op on Cancel. The sheet owns the
                // `currentRequest` snapshot — by the time the
                // completion fires the parent may have continued
                // typing, but the saved copy stays faithful to
                // what the user actually saw in the sub-sheet.
                showingSaveTemplateSheet = false
                switch result {
                case .success(let template):
                    saveUserTemplate(template)
                case .failure:
                    // Cancel is a no-op; .emptyTitle and
                    // .emptyRequest are guarded by the sheet's
                    // disabled state and never reach here.
                    break
                }
            }
        }
        // Post-export alert. `runExport()` writes a non-nil
        // `exportAlert` after each `AIGeneratorExporter`
        // call; the `.onChange` modifier shows the alert and
        // resets the binding back to `nil` so the next
        // export can re-arm the alert. We use `.onChange`
        // (rather than rendering the alert inside the body)
        // because `NSAlert.runModal()` is a blocking call —
        // it would freeze the SwiftUI render loop if called
        // directly from the view body. The single-parameter
        // closure form is the macOS 12+ API; the two-
        // parameter `(oldValue, newValue) in` variant is
        // gated to macOS 14+ and the project deploys back
        // to macOS 12.
        .onChange(of: exportAlert) { newValue in
            guard let alert = newValue else { return }
            let nsAlert = NSAlert()
            nsAlert.messageText = alert.title
            nsAlert.informativeText = alert.message
            nsAlert.alertStyle = alert.style == .informational ? .informational : .warning
            nsAlert.addButton(withTitle: "OK")
            nsAlert.runModal()
            // Reset after the alert returns so the next
            // export can re-arm it. A bare `exportAlert =
            // nil` would not fire the `.onChange` (SwiftUI
            // sees a no-op transition), so we mutate the
            // binding via the captured copy.
            exportAlert = nil
        }
    }

    // MARK: - User-template helpers

    /// Reload the user-saved templates from
    /// `AIGeneratorTemplateStore.shared`. Called from
    /// `.onAppear` so a sheet opened in a long-lived app
    /// session picks up templates the user saved in a prior
    /// sheet instance, and after every save / delete so the
    /// gallery stays in sync with disk.
    private func reloadUserTemplates() {
        userTemplates = AIGeneratorTemplateStore.shared.loadUserTemplates()
    }

    /// Persist `template` through the shared store and refresh
    /// the in-memory gallery. Errors are swallowed (logged
    /// inside the store) so a write failure does not crash
    /// the sheet — the user can retry by clicking "Save as
    /// Template" again.
    private func saveUserTemplate(_ template: AIGeneratorTemplate) {
        do {
            try AIGeneratorTemplateStore.shared.addTemplate(template)
            reloadUserTemplates()
        } catch {
            // The store's `addTemplate(_:)` already logs the
            // underlying error; we keep the gallery as-is so
            // the user is not surprised by a partial state.
        }
    }

    /// Delete a user-saved template by `id` and refresh the
    /// in-memory gallery. Built-in templates have ids that
    /// do **not** start with `user-`; the gallery's
    /// `templateCard(for:)` only surfaces the context menu
    /// for user templates, so we do not need a second
    /// guard here.
    private func deleteUserTemplate(id: String) {
        do {
            try AIGeneratorTemplateStore.shared.removeTemplate(id: id)
            reloadUserTemplates()
        } catch {
            // See `saveUserTemplate(_:)` for the rationale.
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
    ///
    /// M2+ extension: the rendered list is
    /// `AIGeneratorTemplateGallery.allTemplates(including: userTemplates)`,
    /// so user-saved templates appear next to the 6 built-ins.
    /// User templates get a small `person.crop.circle` badge and
    /// a long-press / right-click "Delete template" context menu;
    /// built-in templates stay read-only.
    private var templateGallery: some View {
        let allTemplates = AIGeneratorTemplateGallery.allTemplates(
            including: userTemplates
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Start from a template")
                    .font(.headline)
                Spacer()
                Text("\(allTemplates.count) ready to try")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(allTemplates) { template in
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
    ///
    /// M2+ extension: user-saved templates (id starts with
    /// `user-`) get a small `person.crop.circle` SF Symbol in the
    /// top-right corner so the user can tell them apart from the
    /// built-ins at a glance, and a long-press / right-click
    /// context menu offering "Delete template". Built-in templates
    /// get neither — the v1 contract says the catalogue is
    /// read-only.
    private func templateCard(for template: AIGeneratorTemplate) -> some View {
        let isUser = template.id.hasPrefix(
            AIGeneratorSaveTemplateSheet.userIDPrefixSafe
        )
        return Button {
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
                ZStack(alignment: .topTrailing) {
                    Image(systemName: template.systemImageName)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isUser {
                        // Small badge in the top-right corner.
                        // Uses `caption2` so it does not visually
                        // compete with the template's primary
                        // SF Symbol; tinted with the secondary
                        // colour so it reads as metadata, not
                        // a primary affordance.
                        Image(systemName: "person.crop.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .contextMenu {
            // Context menu is empty for built-in templates —
            // SwiftUI still renders an empty `contextMenu` for
            // them, so the right-click affordance stays
            // consistent, but the v1 contract for built-ins
            // (read-only, append-only) is preserved.
            if isUser {
                Button("Delete template", role: .destructive) {
                    deleteUserTemplate(id: template.id)
                }
            }
        }
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
            regenerateHeader(for: plugin)
            explanationSection(for: plugin)
            promptIdSection(for: plugin)
            editModeErrorBanner
            if viewModel.isEditing {
                editSection
            } else {
                manifestSection
                entryScriptSection(for: plugin)
            }
        }
    }

    /// M2+ success-view header. Renders the "Re-generate"
    /// button next to a "Generated" label so the user has a
    /// single, always-visible affordance to ask the LLM for a
    /// variation of the current result. The button shows a
    /// small `ProgressView` in place of the label's icon
    /// while `viewModel.isRegenerating == true` and is disabled
    /// during the round-trip so a double-click does not fire
    /// two parallel LLM calls. The button is also disabled
    /// while the request field is empty (mirrors
    /// `canRegenerate`) so the user can never burn a round-trip
    /// on a blank prompt.
    private func regenerateHeader(for plugin: GeneratedPlugin) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Generated")
                .font(.headline)
            Spacer()
            // M2+ "Continue editing" affordance. Sits next to
            // the "Re-generate" button so the user can either
            // ask the LLM for a fresh take (re-generate) or
            // tweak the current output themselves (continue
            // editing). Toggling this opens two monospaced
            // `TextEditor` views in place of the read-only
            // manifest / entry-script panels; cancelling
            // discards the in-flight edits and restores the
            // originals. The button is hidden while the
            // sheet is in edit mode so the user does not
            // double-click and re-snapshot their
            // half-finished edits.
            if !viewModel.isEditing {
                Button {
                    viewModel.enterEditMode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("Continue editing")
                    }
                }
                .help("Tweak the manifest and entry script in place before saving.")
            }
            Button {
                // Fire-and-forget task: the closure runs on
                // the main actor (the button is in a SwiftUI
                // view body), and the `Task` re-enters the
                // view model's `@MainActor` `regenerateWithVariation()`.
                // The button does not need to await the result
                // — `isRegenerating` and the new `latestPlugin`
                // drive the UI.
                Task { await viewModel.regenerateWithVariation() }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isRegenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Re-generate")
                }
            }
            .disabled(!canRegenerate)
            .help("Ask the AI for a variation of this result (uses a higher temperature).")
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

    /// M2+ "Continue editing" panel. Renders two monospaced
    /// `TextEditor` views side by side — manifest JSON on the
    /// left, entry script on the right — plus a Save / Cancel
    /// row underneath. Replaces the read-only manifest /
    /// entry-script sections while `viewModel.isEditing` is
    /// `true` (see `resultSection(for:)`). The two editors
    /// are laid out side-by-side on viewports wide enough to
    /// fit both at ~300 pt each and stack vertically
    /// otherwise (a `GeometryReader` picks the layout so the
    /// panel stays usable when the sheet is shrunk).
    ///
    /// Save calls `viewModel.saveEdits()`; Cancel calls
    /// `viewModel.exitEditMode()`. After a successful save
    /// the read-only panels re-render with the new manifest
    /// / script; the "Save to Plugin Folder" and "Export…"
    /// footer buttons keep working because they read
    /// `viewModel.latestPlugin`, which `saveEdits()` updated
    /// in place.
    private var editSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Editing manifest + entry script")
                    .font(.headline)
                Spacer()
                Text("Save replaces the in-memory plugin; cancel discards edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // `GeometryReader` picks the layout based on
            // the available width. The horizontal
            // `HStack` is used on wide viewports (≥ 700 pt)
            // so the user sees both editors at once; the
            // vertical `VStack` is the fallback for narrow
            // viewports. The threshold matches the
            // `minWidth: 560` / `idealWidth: 640` defaults
            // on the sheet — anything above ~700 pt leaves
            // enough room for two ~300 pt editors.
            GeometryReader { proxy in
                if proxy.size.width >= 700 {
                    HStack(alignment: .top, spacing: 8) {
                        manifestEditor
                        entryScriptEditor
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        manifestEditor
                        entryScriptEditor
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.exitEditMode()
                }
                Button {
                    // Fire-and-forget task: the closure runs
                    // on the main actor (the button is in a
                    // SwiftUI view body), and the `Task`
                    // re-enters the view model's `@MainActor`
                    // `saveEdits()`. The button does not need
                    // to await the result — `isEditing` and
                    // `editModeErrorMessage` drive the UI.
                    Task { await viewModel.saveEdits() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("Save edits")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Left-hand editor in `editSection` — the manifest
    /// JSON. Binds the editor straight to
    /// `viewModel.editedManifestJSON` so every keystroke is
    /// captured by the view model. Renders in monospaced
    /// text with a 1-pt secondary border so the editing
    /// surface matches the read-only panel's chrome.
    private var manifestEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("manifest.json")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $viewModel.editedManifestJSON)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
    }

    /// Right-hand editor in `editSection` — the entry
    /// script body. Binds to
    /// `viewModel.editedEntryScript`. Same chrome as
    /// `manifestEditor`.
    private var entryScriptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Entry script")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $viewModel.editedEntryScript)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
    }

    /// Red banner that surfaces the most recent
    /// `saveEdits()` parse error. Renders only while
    /// `viewModel.isEditing` is `true` **and** a non-nil
    /// `viewModel.editModeErrorMessage` exists; otherwise
    /// the @ViewBuilder returns an empty `EmptyView` so the
    /// success view's vertical rhythm is unchanged.
    @ViewBuilder
    private var editModeErrorBanner: some View {
        if viewModel.isEditing, let message = viewModel.editModeErrorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Could not save edits")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
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
            // M2+ "Save as Template" affordance. Lives in the
            // footer (next to the primary Generate / Re-generate
            // / Save-to-Plugin-Folder buttons) so it is visible
            // regardless of which view-mode the sheet is in.
            // Disabled when the request field is empty (we never
            // want to save a blank prompt) and during a
            // generator round-trip (so the user does not save
            // an in-flight partial prompt).
            Button("Save as Template") {
                // The sub-sheet snapshots `viewModel.request`
                // at construction time; opening it does not
                // freeze the parent's text editor.
                showingSaveTemplateSheet = true
            }
            .disabled(!canSaveAsTemplate)
            // M2+ "Improve" affordance. Sits next to "Save as
            // Template" because both are secondary actions —
            // they mutate / persist the request, they do not
            // fire a generator round-trip themselves. Calls
            // `viewModel.improveRequest()`, which is gated by
            // `isImproving` so a double-click does not fire two
            // LLM round-trips. The button shows a small spinner
            // while the helper is mid-flight and is disabled
            // when the request is empty (so the user can never
            // burn a round-trip on a blank prompt).
            Button {
                Task { await viewModel.improveRequest() }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isImproving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text("Improve")
                }
            }
            .disabled(!canImprove)
            .help("Ask the active AI to rewrite your request as a more specific instruction.")
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
                // M2+ "Export…" affordance. Lives in the
                // footer between "Re-generate" and "Save to
                // Plugin Folder" so it is visible on the
                // success view (the button only renders when
                // `viewModel.latestPlugin != nil`) and never
                // collides with the empty-state "Generate"
                // button. The actual export logic — save
                // panel, staging temp dir, `/usr/bin/zip`,
                // cleanup — lives in `AIGeneratorExporter` so
                // the test bundle can exercise the zip
                // pipeline without driving an `NSAlert` /
                // `NSSavePanel`.
                Button("Export…") {
                    runExport()
                }
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

    /// `true` when the "Save as Template" button should be
    /// enabled. Mirrors the `canGenerate` rule (non-empty
    /// request, not currently loading) so the user sees the
    /// same affordance state for both "save" and "generate".
    /// Centralised here so the SwiftUI `.disabled` modifier
    /// does not have to repeat the rule.
    private var canSaveAsTemplate: Bool {
        !viewModel.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isLoading
    }

    /// `true` when the "Improve" footer button should be
    /// enabled. Mirrors `canSaveAsTemplate` (non-empty request,
    /// not currently loading) plus a guard against
    /// `isImproving` so a second click during a round-trip is
    /// a no-op rather than a parallel LLM call. Centralised
    /// here so the SwiftUI `.disabled` modifier does not have
    /// to repeat the rule.
    private var canImprove: Bool {
        !viewModel.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isLoading
            && !viewModel.isImproving
    }

    /// `true` when the success-view "Re-generate" button
    /// should be enabled. Mirrors `canImprove` (non-empty
    /// request, not currently loading, not already
    /// regenerating) so a double-click during a round-trip is
    /// a no-op rather than a parallel LLM call. Centralised
    /// here so the SwiftUI `.disabled` modifier does not
    /// have to repeat the rule.
    private var canRegenerate: Bool {
        !viewModel.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isLoading
            && !viewModel.isRegenerating
    }

    /// Drive the "Export…" footer button. Captures the
    /// current `viewModel.latestPlugin` (the footer's button
    /// only renders when one exists, so this is always
    /// non-nil here) and delegates to
    /// `AIGeneratorExporter.exportPlugin(_:)`, which shows the
    /// `NSSavePanel`, runs the zip, and surfaces the result
    /// via a modal `NSAlert`. The result is stored back into
    /// `exportAlert` so the SwiftUI body renders the alert on
    /// the next redraw.
    private func runExport() {
        guard let plugin = viewModel.latestPlugin else { return }
        switch AIGeneratorExporter.exportPlugin(plugin) {
        case .success(let destination):
            // The exporter already calls
            // `NSWorkspace.shared.activateFileViewerSelecting(...)`
            // on success so Finder pops up with the new zip
            // highlighted. The alert copy mirrors the
            // GeneratorHistorySheet's "Exported" alert so the
            // two flows feel consistent.
            exportAlert = ExportAlert(
                title: "Exported",
                message: "Exported to \(destination.lastPathComponent). Finder has been opened to the file.",
                style: .informational
            )
        case .cancelled:
            // User dismissed the save panel — no alert.
            break
        case .writeFailed(let reason),
             .zipFailed(let reason),
             .launchFailed(let reason):
            exportAlert = ExportAlert(
                title: "Export failed",
                message: reason,
                style: .warning
            )
        }
    }
}

// MARK: - Export alert

/// Backing model for the post-export `NSAlert`. Lives at file
/// scope (rather than inside the `View`) so it can be
/// `Equatable` and the SwiftUI `onChange(of:)` modifier can
/// fire the alert exactly once per non-nil transition. The
/// `style` is split out because the `NSAlert` initialiser
/// wants an `NSAlert.Style`, not a custom enum, and the SwiftUI
/// view body has no direct handle on AppKit types.
struct ExportAlert: Equatable {
    enum Style: Equatable {
        case informational
        case warning
    }
    let title: String
    let message: String
    let style: Style
}

// AIGeneratorSaveTemplateSheet.swift
// menubar01 — AI Plugin Generator (M2+ user-saved template flow)
//
// Sub-sheet presented by `AIGeneratorSheet` when the user clicks
// "Save as Template" next to the Generate button. The sheet has
// three fields — `title` (text), `icon` (text, defaulting to
// `doc.text`), and `prompt` (read-only, pre-filled from the
// parent's `viewModel.request`) — and a Save / Cancel button
// pair. On Save, the parent writes the result through
// `AIGeneratorTemplateStore.shared.addTemplate(_:)` and reloads
// the gallery so the new card appears immediately.
//
// The sheet intentionally does **not** own view-model state —
// the `onComplete` callback is the only way it talks to the
// parent sheet, which then decides whether to write the template
// to disk and refresh the gallery. The generated `id` is
// `user-<uuid8>` so the v1 contract for the 6 built-in
// template ids stays untouched (the merge logic in
// `AIGeneratorTemplateGallery.allTemplates(including:)` is the
// single collision-resolution point).

import SwiftUI

/// Modal sub-sheet that captures the user's edits and asks the
/// parent to persist a new `AIGeneratorTemplate` to disk.
///
/// Presented by `AIGeneratorSheet` from a `.sheet(...)` modal
/// when the user clicks the "Save as Template" footer button.
/// The sheet reads `currentRequest` (the verbatim text from
/// the parent's request `TextEditor`) and writes the assembled
/// `AIGeneratorTemplate` back to the parent via the
/// `onComplete` callback. The parent owns the disk write and
/// the gallery refresh — the sheet itself is a pure form.
@MainActor
struct AIGeneratorSaveTemplateSheet: View {

    /// Verbatim request text the user typed in the parent
    /// sheet. Captured at construction time so the sheet
    /// shows a stable preview even if the parent's request
    /// field changes while the sub-sheet is open. The sheet
    /// treats this as **read-only** — letting the user edit
    /// both the request and the saved copy in two places at
    /// once would be confusing.
    let currentRequest: String

    /// Completion handler invoked exactly once — on Save or
    /// Cancel. The parent sheet writes the template to disk
    /// on `.success(_)` and refreshes its gallery, and
    /// dismisses the sub-sheet on either path.
    let onComplete: (Result<AIGeneratorTemplate, SaveTemplateError>) -> Void

    /// Backing state for the "Title" text field. Defaults to
    /// an empty string so the user has to actively type a
    /// title; the Save button is disabled until the trimmed
    /// title is non-empty.
    @State private var title: String = ""

    /// Backing state for the "Icon" text field. Defaults to
    /// `doc.text` per the v1 contract — the user can change
    /// it to any SF Symbol available in macOS 12+ if they
    /// want a more specific icon (e.g. `cloud.sun` for a
    /// weather-themed prompt).
    @State private var iconName: String = "doc.text"

    /// Set to `true` after a failed save so the sheet can
    /// show a red error banner with the underlying message.
    @State private var saveError: String?

    /// Errors surfaced by the save-template sheet. Cases are
    /// deliberately small: Cancel collapses to `.cancelled`
    /// (the parent treats it as a no-op) and Save failures
    /// bubble up the underlying reason so the parent can
    /// decide how to surface them.
    enum SaveTemplateError: Error, Equatable {
        /// The user clicked Cancel.
        case cancelled
        /// The user clicked Save with an empty title.
        case emptyTitle
        /// The user clicked Save with an empty request.
        case emptyRequest
        /// The `AIGeneratorTemplateStore.addTemplate(_:)`
        /// call threw. The associated `String` is the
        /// underlying `Error.localizedDescription`.
        case storeFailed(reason: String)
    }

    /// Stable identifier prefix for user-saved templates.
    /// The merge logic in
    /// `AIGeneratorTemplateGallery.allTemplates(including:)`
    /// relies on this prefix to avoid colliding with the 6
    /// built-in ids; the suffix is 8 hex chars from a
    /// freshly-allocated `UUID()` so two saves in the same
    /// millisecond still get distinct ids.
    private static let userIDPrefix = "user-"

    /// Public, side-effect-free accessor for the user-id
    /// prefix. `AIGeneratorSheet.templateCard(for:)` uses
    /// this to detect user-saved templates (vs. the 6
    /// built-ins) so the badge / context-menu affordance
    /// only shows for templates the user owns. The
    /// `Safe` suffix is a hint that this property is a
    /// pure constant — it does not allocate a UUID and
    /// has no AppKit / SwiftUI dependencies.
    static let userIDPrefixSafe: String = userIDPrefix

    /// Computes a fresh `user-<uuid8>` identifier. Pulled out
    /// so the test suite (and the Save button action) reach
    /// the same code path.
    static func makeUserTemplateID() -> String {
        let suffix = UUID().uuidString.prefix(8)
        return "\(userIDPrefix)\(suffix)"
    }

    /// `true` when both the title and the request are
    /// non-empty after trimming whitespace. The Save button
    /// mirrors this so the user cannot click through to a
    /// broken save.
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !currentRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Template")
                .font(.headline)
            Text("Save the current request as a reusable template. It will appear in the gallery next to the built-in templates.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. Crypto price for BTC", text: $title)
                    .textFieldStyle(.roundedBorder)

                Text("Icon")
                    .font(.subheadline.weight(.semibold))
                TextField("SF Symbol name, e.g. doc.text", text: $iconName)
                    .textFieldStyle(.roundedBorder)

                Text("Prompt (read-only)")
                    .font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(currentRequest)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onComplete(.failure(.cancelled))
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let template = AIGeneratorTemplate(
                        id: Self.makeUserTemplateID(),
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        description: "Saved from your request",
                        prompt: currentRequest,
                        systemImageName: iconName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "doc.text"
                            : iconName.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onComplete(.success(template))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}

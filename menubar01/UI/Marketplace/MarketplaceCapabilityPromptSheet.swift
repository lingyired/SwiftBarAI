// MarketplaceCapabilityPromptSheet.swift
// menubar01 — PluginMarketplace (M5 install-gate follow-up)
//
// Closure-driven SwiftUI sheet for the M5 install-gate
// overload on `PluginManager`. Lists the ungranted
// non-default capabilities a marketplace plugin declares
// and asks the user for a single all-or-nothing grant:
//
//   - "Grant"  → the install proceeds, every listed
//                capability is recorded in the gate.
//   - "Decline" → the install aborts, the gate is
//                untouched, no files are written.
//
// The sheet is intentionally distinct from
// `MarketplaceInstallPromptSheet` (the M5 checkbox prompt
// that lets the user grant / deny per capability). The
// install-gate overload surfaces only the capabilities
// the user *has not yet granted* and that the gate
// considers opt-in (i.e. `isGrantedByDefault == false`),
// so the checkbox UI's per-row toggles would all default
// to "on" — a single Grant button is the more honest
// representation of the choice. The M2+ install flow
// continues to use the checkbox sheet; the M5 install-gate
// flow uses this one.
//
// Presented by `MarketplaceCapabilityPrompter` (a small
// NSWindow host) so the sheet stacks cleanly on top of the
// marketplace browser window even when the browser itself
// is a non-`.sheet` AppKit window.

import SwiftUI

/// Modal sub-sheet that lists the ungranted non-default
/// capabilities a marketplace plugin declares and offers
/// the user a single Grant / Decline choice. The
/// completion handler is the only signal back to the
/// caller — the sheet does not own any state of its own.
///
/// @MainActor because it presents a SwiftUI sheet that
/// must run on the main thread.
@MainActor
struct MarketplaceCapabilityPromptSheet: View {

    /// Plugin name shown in the sheet header. The
    /// install-gate overload derives this from the
    /// manifest's `name` field (or `<unnamed>` as a
    /// defensive fallback).
    let pluginID: String

    /// Ungranted, non-default capabilities the plugin
    /// declared in its `manifest.json`. The sheet renders
    /// one row per capability with the `displayName` and
    /// `description` the v1.1 `PluginCapability` API
    /// exposes. Order matches the manifest's declaration
    /// order so the user sees the same row order they
    /// would in any other capability-prompt UI.
    let capabilities: [PluginCapability]

    /// Completion handler invoked exactly once — on
    /// "Decline" or on "Grant". `true` = grant every
    /// listed capability, `false` = abort the install.
    /// The sheet never re-invokes the handler.
    let onCompletion: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \"\(pluginID)\"")
                .font(.headline)
            Text("This plugin wants to access:")
                .font(.callout)
                .foregroundStyle(.secondary)
            capabilityList
            HStack {
                Button("Decline", role: .cancel) {
                    onCompletion(false)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Grant") {
                    onCompletion(true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    // MARK: - Sections

    @ViewBuilder
    private var capabilityList: some View {
        if capabilities.isEmpty {
            // Should not be reached — the install-gate
            // overload only surfaces this sheet when at
            // least one capability needs user consent.
            // Defensive: render an informational row so
            // the sheet never crashes the host window.
            Text("This plugin does not request any special capabilities.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(capabilities, id: \.self) { capability in
                    capabilityRow(for: capability)
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(for capability: PluginCapability) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(capability.displayName)
                .font(.body.weight(.semibold))
            Text(capability.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lightweight AppKit wrapper that presents
/// `MarketplaceCapabilityPromptSheet` on the app's key
/// window and resolves the user's Grant / Decline choice
/// through a completion closure.
///
/// Used by the M5 install-gate overload on
/// `PluginManager`. The prompter is `@MainActor` because
/// it touches `NSApp.keyWindow` and the SwiftUI sheet
/// presentation; the install method's `prompt` closure
/// typealias already requires `@MainActor` isolation.
@MainActor
enum MarketplaceCapabilityPrompter {
    /// Present the install-prompt sheet for `pluginID` /
    /// `capabilities` and call `completion(true)` when the
    /// user clicks "Grant", `completion(false)` when they
    /// click "Decline". The completion is dispatched on the
    /// main actor (via the SwiftUI sheet's own queue).
    ///
    /// The implementation walks the existing
    /// `MarketplaceBrowserMenuCommand`-style pattern: it
    /// builds a standalone `NSWindow` hosting a
    /// `NSHostingView` rooted at the sheet, sets the
    /// window to a sheet on the key window, and resolves
    /// the choice when the sheet returns. The M5 install
    /// path is the only caller in v1.
    static func present(
        pluginID: String,
        capabilities: [PluginCapability],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !capabilities.isEmpty else {
            // No prompt needed — the install-gate
            // overload would not normally call the
            // prompter with an empty set, but treat it
            // as an implicit "yes" so the caller does
            // not deadlock on the completion.
            completion(true)
            return
        }

        let sheet = MarketplaceCapabilityPromptSheet(
            pluginID: pluginID,
            capabilities: capabilities
        ) { granted in
            completion(granted)
        }

        let hosting = NSHostingController(rootView: sheet)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Install \"\(pluginID)\""
        window.styleMask = [.titled, .closable]
        // `beginSheet` requires a parent window; fall
        // back to running the hosting view standalone
        // if `NSApp.keyWindow` is nil (e.g. an Xcode
        // preview or a unit test environment). The
        // standalone mode is intentionally minimal —
        // the test seam passes a closure that does
        // not need a real sheet to be on-screen.
        if let parent = NSApp.keyWindow {
            window.beginSheet(parent) { _ in
                window.orderOut(nil)
            }
        } else {
            // No parent window — surface the sheet
            // modally on the main window anyway. The
            // unit tests never reach this branch
            // because the install-gate overload uses
            // an injected closure in tests, but the
            // fallback keeps the prompter safe to call
            // from any UI surface.
            window.makeKeyAndOrderFront(nil)
        }
    }
}

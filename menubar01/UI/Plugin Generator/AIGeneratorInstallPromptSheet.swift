// AIGeneratorInstallPromptSheet.swift
// menubar01 — AI Plugin Generator (M2 install-prompt)
//
// Sub-sheet presented by `AIGeneratorSheet` when the user clicks
// "Save to Plugin Folder". The sheet surfaces every capability the
// current `latestPlugin.manifest` declares as a toggle (pre-checked
// when the user has already granted the capability on a previous
// round-trip). On "Install" the sheet grants every enabled
// capability via `PluginCapabilityGate.grant(_:for:)` and then
// hands the plugin to `PluginManager.installGeneratedPlugin(_:)`
// for the actual disk write. On "Cancel" the sheet completes
// with `.failure(.noLatestPlugin)` and the parent sheet rolls
// the view-model state back via `didFailInstall(reason:)`.
//
// The sheet intentionally does **not** own view-model state —
// the `onComplete` callback is the only way it talks to the
// parent sheet, which then calls `didCompleteInstall(at:)` /
// `didFailInstall(reason:)` on the view model. This keeps the
// install-prompt UI swappable (a future marketplace install flow
// can reuse the same `gate.grant(_:for:)` pattern) and makes
// the sheet trivially previewable.

import SwiftUI

/// Modal sub-sheet that lists the plugin's declared capabilities
/// and grants them via `PluginCapabilityGate.grant(_:for:)` before
/// installing the plugin to disk.
///
/// Presented by `AIGeneratorSheet` from a `.sheet(...)` modal when
/// the user clicks the "Save to Plugin Folder" footer button. The
/// sheet reads `viewModel.latestPlugin`, `viewModel.installPromptCapabilities`,
/// and `viewModel.pluginCapabilityGate` for the data and
/// `PluginManager.shared` for the actual install — it does **not**
/// mutate the view model itself; the `onComplete` callback is the
/// only path back into the parent's state.
@MainActor
struct AIGeneratorInstallPromptSheet: View {

    /// Shared view model. The sheet never owns this — it only
    /// reads from it and calls back through `onComplete`.
    @ObservedObject var viewModel: AIGeneratorViewModel

    /// Set of capabilities the user has **toggled on** in the
    /// sheet. Pre-populated from the gate in `onAppear` so an
    /// already-granted capability shows up pre-checked.
    @State private var enabledCapabilities: Set<PluginCapability> = []

    /// `true` while the install is in flight (the grant loop +
    /// `PluginManager.installGeneratedPlugin(...)` call). Disables
    /// both buttons so the user cannot double-click.
    @State private var isInstalling: Bool = false

    /// Last install failure message, surfaced in the sheet's red
    /// error banner. `nil` when the last attempt succeeded or no
    /// attempt has been made.
    @State private var installError: String?

    /// Destination URL the most recent successful install wrote
    /// into. Kept here (and forwarded via the completion handler)
    /// so the parent sheet can render a success hint that
    /// includes the on-disk path.
    @State private var installedURL: URL?

    /// Completion handler invoked exactly once — on Cancel, on
    /// Install success, or on Install failure. The parent sheet
    /// maps the result to a `didCompleteInstall(at:)` /
    /// `didFailInstall(reason:)` call on the view model.
    let onComplete: (Result<URL, InstallPromptError>) -> Void

    /// Errors surfaced by the install-prompt sheet. The cases
    /// are deliberately small: a Cancel collapses to
    /// `.noLatestPlugin` (the v1 contract uses the same path
    /// for Cancel and "the parent lost its plugin in flight",
    /// which the parent sheet can no-op).
    enum InstallPromptError: Error, Equatable {
        /// The user clicked Cancel, or the parent lost the
        /// `latestPlugin` while the sheet was visible.
        case noLatestPlugin
        /// The install helper returned a non-success result.
        /// The associated `String` is the underlying error
        /// description surfaced for the user.
        case installFailed(reason: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \"\(viewModel.latestPlugin?.manifest.name ?? "plugin")\"")
                .font(.headline)
            Text("This plugin requests the following capabilities. Enable each one you'd like to grant. The plugin will not be able to use a capability you leave off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            capabilityList
            if let error = installError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", role: .cancel) {
                    onComplete(.failure(.noLatestPlugin))
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)
                Spacer()
                Button(isInstalling ? "Installing…" : "Install") {
                    Task { await runInstall() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling || viewModel.latestPlugin == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear(perform: preCheckGrantedCapabilities)
    }

    // MARK: - Sections

    @ViewBuilder
    private var capabilityList: some View {
        if viewModel.installPromptCapabilities.isEmpty {
            Text("This plugin does not request any special capabilities.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.installPromptCapabilities, id: \.self) { capability in
                    capabilityRow(for: capability)
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(for capability: PluginCapability) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                capability.displayName,
                isOn: Binding(
                    get: { enabledCapabilities.contains(capability) },
                    set: { isOn in
                        if isOn {
                            enabledCapabilities.insert(capability)
                        } else {
                            enabledCapabilities.remove(capability)
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            Text(capability.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// On first appearance, pre-check every capability the gate has
    /// already granted for the current plugin name. The user can
    /// uncheck a row before clicking Install; this only sets the
    /// *default* state of the toggles.
    private func preCheckGrantedCapabilities() {
        guard let pluginName = viewModel.latestPlugin?.manifest.name else { return }
        let granted = viewModel.pluginCapabilityGate.granted(for: pluginName)
        for capability in viewModel.installPromptCapabilities
        where granted.contains(capability) {
            enabledCapabilities.insert(capability)
        }
    }

    /// Run the install: grant every enabled capability, then call
    /// `PluginManager.installGeneratedPlugin(_:)`. The completion
    /// callback is the only signal back to the parent sheet —
    /// this method does not touch the view model directly.
    private func runInstall() async {
        guard let plugin = viewModel.latestPlugin else {
            onComplete(.failure(.noLatestPlugin))
            return
        }
        isInstalling = true
        installError = nil

        // 1. Grant every enabled capability for this plugin name.
        //    The gate is idempotent, so re-running the install
        //    for an already-granted capability is a no-op.
        let pluginName = plugin.manifest.name ?? "unnamed"
        if !enabledCapabilities.isEmpty {
            viewModel.pluginCapabilityGate.grant(enabledCapabilities, for: pluginName)
        }

        // 2. Call the install helper. The grant is independent
        //    of the install — if the install fails the user can
        //    retry; the grants stay in place.
        switch PluginManager.shared.installGeneratedPlugin(plugin) {
        case .success(let url):
            installedURL = url
            isInstalling = false
            onComplete(.success(url))
        case .failure(let error):
            let reason = String(describing: error)
            installError = reason
            isInstalling = false
            onComplete(.failure(.installFailed(reason: reason)))
        }
    }
}

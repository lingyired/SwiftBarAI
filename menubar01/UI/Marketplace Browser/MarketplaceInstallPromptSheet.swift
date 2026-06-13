// MarketplaceInstallPromptSheet.swift
// menubar01 — PluginMarketplace (M5 install-prompt)
//
// Sub-sheet presented by `MarketplaceBrowserSheet` when the user
// clicks "Install" or "Install (overwrite)" on a catalogue entry.
// Mirrors `AIGeneratorInstallPromptSheet` line-for-line: it lists
// every capability the currently-loaded `MarketplacePackage`'s
// manifest declares, pre-checks the rows that the gate has
// already granted, and on Install grants every enabled capability
// via `PluginCapabilityGate.grant(_:for:)` and then calls
// `MarketplaceBrowserViewModel._installSelectedAfterGrants(...)`
// to do the actual install.
//
// The "shared pattern" between this sheet and the M2+ AI generator
// install-prompt sheet is intentional — the two flows are
// operationally identical from the user's perspective (an external
// plugin requests N capabilities, the user ticks the ones to grant,
// the install proceeds). See
// `docs/M5-marketplace-install-prompt.md` for the future
// "unified install-prompt" follow-up that would collapse the two
// sheets into one shared view.

import SwiftUI

/// Modal sub-sheet that lists the currently-selected marketplace
/// package's declared capabilities, lets the user grant / deny
/// each, and on Install grants every enabled capability via
/// `PluginCapabilityGate.grant(_:for:)` before calling
/// `MarketplaceBrowserViewModel._installSelectedAfterGrants(...)`
/// to land the plugin on disk.
///
/// Presented by `MarketplaceBrowserSheet` from a `.sheet(...)`
/// modal. The sheet reads its input from the
/// `MarketplaceInstallPromptContext` value type the parent sheet
/// builds via
/// `MarketplaceBrowserViewModel.requestInstallPrompt(overwriteExisting:)`
/// — it does not reach into the view model for the per-install
/// data, only for the actual install primitive and the gate.
@MainActor
struct MarketplaceInstallPromptSheet: View {

    /// Snapshot of the data this sheet needs. Built by the
    /// parent sheet at presentation time so the sheet cannot
    /// accidentally read stale state if the user clicks
    /// around between the prompt being shown and the Install
    /// button being pressed.
    let context: MarketplaceInstallPromptContext

    /// Shared view model. The sheet only uses it for the
    /// `pluginCapabilityGate` (to pre-check already-granted
    /// capabilities) and the `_installSelectedAfterGrants(...)`
    /// install primitive. It does **not** mutate the VM
    /// directly — the `onComplete` callback is the only path
    /// back to the parent.
    @ObservedObject var viewModel: MarketplaceBrowserViewModel

    /// Set of capabilities the user has **toggled on** in the
    /// sheet. Pre-populated from the gate in `onAppear` so an
    /// already-granted capability shows up pre-checked.
    @State private var enabledCapabilities: Set<PluginCapability> = []

    /// `true` while the install is in flight (the grant loop +
    /// `_installSelectedAfterGrants(...)` call). Disables both
    /// buttons so the user cannot double-click.
    @State private var isInstalling: Bool = false

    /// Last install failure message, surfaced in the sheet's red
    /// error banner. `nil` when the last attempt succeeded or no
    /// attempt has been made.
    @State private var installError: String?

    /// Completion handler invoked exactly once — on Cancel, on
    /// Install success, or on Install failure. The parent sheet
    /// maps the result to a state update.
    let onComplete: (Result<URL, InstallPromptError>) -> Void

    /// Errors surfaced by the install-prompt sheet. The cases
    /// are deliberately small and mirror the M2+ install-prompt
    /// sheet's enum so the two flows are interchangeable.
    enum InstallPromptError: Error, Equatable {
        /// The user clicked Cancel, or the parent lost its
        /// package while the sheet was visible.
        case noSelectedPackage
        /// The install primitive returned a non-success result.
        /// The associated `String` is the underlying error
        /// description surfaced for the user.
        case installFailed(reason: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \"\(context.pluginName)\"")
                .font(.headline)
            Text("This marketplace plugin requests the following capabilities. Enable each one you'd like to grant. The plugin will not be able to use a capability you leave off.")
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
                    onComplete(.failure(.noSelectedPackage))
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)
                Spacer()
                Button(isInstalling ? "Installing…" : "Install") {
                    Task { await runInstall() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear(perform: preCheckGrantedCapabilities)
    }

    // MARK: - Sections

    @ViewBuilder
    private var capabilityList: some View {
        if context.capabilities.isEmpty {
            Text("This plugin does not request any special capabilities.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(context.capabilities, id: \.self) { capability in
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

    /// On first appearance, pre-check every capability the gate
    /// has already granted for the current plugin name. The user
    /// can uncheck a row before clicking Install; this only sets
    /// the *default* state of the toggles.
    private func preCheckGrantedCapabilities() {
        let granted = viewModel.pluginCapabilityGate.granted(for: context.pluginName)
        for capability in context.capabilities
        where granted.contains(capability) {
            enabledCapabilities.insert(capability)
        }
    }

    /// Run the install: grant every enabled capability, then call
    /// `_installSelectedAfterGrants(...)`. The completion
    /// callback is the only signal back to the parent sheet —
    /// this method does not touch the view model directly.
    private func runInstall() async {
        isInstalling = true
        installError = nil

        // 1. Grant every enabled capability for this plugin
        //    name. The gate is idempotent, so re-running the
        //    install for an already-granted capability is a
        //    no-op.
        if !enabledCapabilities.isEmpty {
            viewModel.pluginCapabilityGate.grant(
                enabledCapabilities,
                for: context.pluginName
            )
        }

        // 2. Run the actual install primitive. The grant is
        //    independent of the install — if the install fails
        //    the user can retry; the grants stay in place.
        await viewModel._installSelectedAfterGrants(
            overwriteExisting: context.overwriteExisting
        )
        switch viewModel.state {
        case .installed(let url):
            isInstalling = false
            onComplete(.success(url))
        case .error(let reason):
            installError = reason
            isInstalling = false
            onComplete(.failure(.installFailed(reason: reason)))
        default:
            // Should not happen — `_installSelectedAfterGrants`
            // always lands in `.installed(...)` or `.error(...)`
            // when there is a selected entry. We surface it as
            // an error rather than silently leaving the sheet
            // open so the user sees feedback.
            installError = "Install did not complete."
            isInstalling = false
            onComplete(.failure(.installFailed(reason: "Install did not complete.")))
        }
    }
}

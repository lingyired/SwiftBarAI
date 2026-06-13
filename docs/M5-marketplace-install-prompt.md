# M5 Marketplace Install Prompt

Status: M5 follow-up (parallel to M5 follow-ups; depends on M3 capability gate and M2+ install-prompt sheet). The marketplace browser's "Install" / "Install (overwrite)" footer buttons used to call `PluginManager.installMarketplacePlugin(plan:overwriteExisting:)` directly — silently granting every declared capability. This design note covers the new install-prompt sub-sheet that closes that gap.

## The flow

1. The user opens the marketplace browser (`MarketplaceBrowserSheet`) and clicks on a catalogue entry on the left. The VM fetches the entry's `MarketplacePackage` and the right pane shows the manifest + entry script + the **Install** / **Install (overwrite)** buttons.

2. The user clicks **Install**. The parent sheet calls
   ```swift
   viewModel.requestInstallPrompt(overwriteExisting: false)
   ```
   which builds a `MarketplaceInstallPromptContext` value type bundling the plugin name, the resolved capabilities (`package.manifest.resolvedCapabilities`), the pre-approval flag, the package, and the overwrite flag. The parent sheet then sets `showingInstallPrompt = true` and SwiftUI presents `MarketplaceInstallPromptSheet` as a modal.

3. The prompt sheet's `onAppear` pre-checks every capability the `PluginCapabilityGate` has already granted for the plugin name (so a repeat-install of a previously-approved plugin shows the toggles already on).

4. The user toggles capabilities on / off and clicks **Install**. The prompt sheet's `runInstall` does:
   ```swift
   viewModel.pluginCapabilityGate.grant(enabledCapabilities, for: context.pluginName)
   await viewModel._installSelectedAfterGrants(overwriteExisting: context.overwriteExisting)
   ```
   The completion callback is the only path back to the parent sheet; the parent maps the result to state transitions and the existing success alert / error banner.

5. On Cancel, the prompt sheet completes with `.failure(.noSelectedPackage)` and the parent rolls the VM state back to `.loaded` so a stale `.error(reason)` from a previous attempt does not linger.

## Why a value type for the context?

`MarketplaceInstallPromptContext` is a struct (not a class, not a binding into the VM) so the prompt sheet cannot accidentally read stale state if the user clicks around between the prompt being shown and the Install button being pressed. The parent sheet rebuilds the context on every Install click via `requestInstallPrompt(overwriteExisting:)`. `Equatable` is hand-rolled because `MarketplacePackage` is intentionally not `Equatable` (its embedded `PluginManifest` is not); the context compares by `package.id` only.

## The gate integration

The new VM-level dependencies are:

- `pluginCapabilityGate: PluginCapabilityGate` — the dependency-injection seam, defaults to `PluginManager.shared.pluginCapabilityGate`, overridable for tests via the `internal(set)` setter. Mirrors `AIGeneratorViewModel.pluginCapabilityGate`.
- `installPromptCapabilities: [PluginCapability]` — computed property that reads `package?.manifest.resolvedCapabilities ?? []`. Returns `[]` when no package is loaded.
- `installPromptIsPreApproved: Bool` — `true` when every declared capability is already in the gate's grant set. Used by tests and available to the parent sheet for future UX (e.g. an "already approved" badge).
- `requestInstallPrompt(overwriteExisting:) -> MarketplaceInstallPromptContext?` — returns the context (or `nil` when no package is loaded).
- `_installSelectedAfterGrants(overwriteExisting:)` — the actual install primitive, renamed from `installSelected(...)` so the contract is clear: the sheet drives the flow, the VM does the install. The old public `installSelected(...)` is kept as a thin forwarder for backward compatibility with `MarketplaceBrowserViewModelTests`.

The grant loop in the prompt sheet is idempotent (the gate itself is idempotent), so re-running the install for an already-granted capability is a no-op.

## Shared pattern with the M2+ install-prompt sheet

The two flows are operationally identical from the user's perspective:

|                              | M2+ AI generator (4075eb9) | M5 marketplace (this commit) |
| ---------------------------- | -------------------------- | ---------------------------- |
| Data source                  | `GeneratedPlugin.manifest` | `MarketplacePackage.manifest` |
| Capability read              | `manifest.resolvedCapabilities` | `package.manifest.resolvedCapabilities` |
| Gate DI                      | `AIGeneratorViewModel.pluginCapabilityGate` | `MarketplaceBrowserViewModel.pluginCapabilityGate` |
| Pre-check on appear          | `gate.granted(for: pluginName)` | `gate.granted(for: context.pluginName)` |
| Grant + install              | `gate.grant(enabled, for: pluginName); PluginManager.shared.installGeneratedPlugin(plugin)` | `gate.grant(enabled, for: context.pluginName); viewModel._installSelectedAfterGrants(overwriteExisting: context.overwriteExisting)` |
| Errors surfaced to UI        | `InstallPromptError` enum (`noLatestPlugin`, `installFailed(reason:)`) | `InstallPromptError` enum (`noSelectedPackage`, `installFailed(reason:)`) |
| Result on parent             | `didCompleteInstall(at:)` / `didFailInstall(reason:)` | the VM's existing state machine (`.installed(URL)` / `.error(reason)`) drives the success alert / error banner |

The differences are mechanical: the AI generator has no package concept (the `GeneratedPlugin` is the unit of install), so its prompt sheet is built around `latestPlugin`; the marketplace has a `MarketplacePackage` plus an `overwriteExisting` flag, so its context bundles both. The two enums are deliberately close to each other so a future refactor can collapse them into a single `InstallPromptError` if the sheets are unified.

## Tests

`menubar01Tests/MarketplaceInstallPromptTests.swift` adds 10 Swift Testing tests across three suites, using a per-test `UserDefaults(suiteName:)`-backed `PluginCapabilityGate` and a per-test temp-dir-backed `PluginManager`. Coverage:

- `installPromptCapabilities` reads the manifest, is empty when no package, drops unknown strings.
- `installPromptIsPreApproved` is `true` when all granted, `false` when any missing, `true` when no capabilities declared.
- `requestInstallPrompt(...)` returns the right context, returns `nil` when no package.
- `_installSelectedAfterGrants(...)` grants enabled capabilities (gate verification), skips when no package, sets `.error` state on install failure (no manager).

Full suite: **274 tests passed, 0 failed** (was 264 before this milestone; +10 net new tests, exceeding the +7 target).

## Future work: a unified install-prompt sheet

The two prompt sheets are nearly identical. A future refactor could:

1. Extract the shared body into a `CapabilityInstallPromptSheet<Context>` generic view that takes the resolved capabilities, the plugin name, the gate, and a closure for the actual install primitive.
2. Replace both `AIGeneratorInstallPromptSheet` and `MarketplaceInstallPromptSheet` with thin call sites that pass the right context.
3. Collapse the two `InstallPromptError` enums into a single shared type.

That refactor would not change any user-visible behaviour, just deduplicate the SwiftUI code. It is out of scope for this commit — the immediate goal is to close the M3 §3 violation, and shipping the M5 prompt sheet as a near-clone of the M2+ sheet is the smallest change that does that. The two sheets' file headers both note the future unification.

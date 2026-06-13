# 2026-06-13: M5 Marketplace Install Prompt

- **Type:** feat
- **Scope:** `menubar01/UI/Marketplace Browser/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** e033493
- **Status:** done

## Summary

The M5 marketplace browser's "Install" / "Install (overwrite)" footer buttons now open a new `MarketplaceInstallPromptSheet` sub-sheet that lists the currently-selected package's declared capabilities, lets the user grant / deny each, and on Install calls `PluginCapabilityGate.grant(_:for:)` for every enabled capability and then runs `PluginManager.installMarketplacePlugin(plan:overwriteExisting:)` via the renamed `MarketplaceBrowserViewModel._installSelectedAfterGrants(...)` primitive. Mirrors the M2+ AI generator install-prompt sheet (commit 4075eb9) line-for-line.

## Motivation

The M3 capability gate record (commit 9755129) explicitly lists the M2+ install-prompt sheet as the "M2 (the install-prompt sheet that calls `gate.grant(_:for:)`) and the marketplace install path" as the two consumer paths. The M2+ path landed in commit 4075eb9; the marketplace path was left as a gap that this commit closes. Without this change, marketplace-installed plugins silently bypass the gate, which is a §3 violation of the M3 architecture doc (a plugin's `manifest.capabilities` is supposed to be gated at load time, but the marketplace install path was granting every declared capability by default).

## Changes

- `menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
  - New `pluginCapabilityGate: PluginCapabilityGate` DI property (defaults to `PluginManager.shared.pluginCapabilityGate`, mirrors `AIGeneratorViewModel.pluginCapabilityGate`).
  - New `installPromptCapabilities: [PluginCapability]` computed property — mirrors `package?.manifest.resolvedCapabilities ?? []`.
  - New `installPromptIsPreApproved: Bool` computed property — `true` when every declared capability is already in the gate's grant set.
  - New `MarketplaceInstallPromptContext` value type — bundles `pluginName`, `capabilities`, `isPreApproved`, `package`, and `overwriteExisting` for the prompt sheet to consume without reaching into the VM mid-flow.
  - New `func requestInstallPrompt(overwriteExisting: Bool) -> MarketplaceInstallPromptContext?` — builds the context (or `nil` when no package is loaded).
  - Renamed the existing `func installSelected(overwriteExisting:)` to `func _installSelectedAfterGrants(overwriteExisting:)` (the actual install primitive called by the prompt sheet after granting); the public `installSelected(...)` is kept as a thin forwarder so the existing `MarketplaceBrowserViewModelTests` assertions and any future programmatic caller continue to compile without modification.
- `menubar01/UI/Marketplace Browser/MarketplaceInstallPromptSheet.swift` (new)
  - SwiftUI `@MainActor` view that mirrors `AIGeneratorInstallPromptSheet`. Pre-checks already-granted capabilities on `onAppear`, on Install grants every enabled capability via `viewModel.pluginCapabilityGate.grant(_:for:)` and then calls `viewModel._installSelectedAfterGrants(overwriteExisting:)`. The completion handler is the only path back to the parent sheet.
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
  - New `@State private var showingInstallPrompt: Bool` presentation binding for the sub-sheet.
  - New `@State private var pendingPromptContext: MarketplaceInstallPromptContext?` cached context.
  - The "Install" / "Install (overwrite)" footer buttons now call a new `presentInstallPrompt(overwriteExisting:)` helper instead of `viewModel.installSelected(...)` directly; the helper builds a fresh context and toggles `showingInstallPrompt = true`.
  - The new `.sheet(isPresented:)` modifier presents the prompt sheet, which calls back through the `.sheet` completion handler.
- `menubar01Tests/MarketplaceInstallPromptTests.swift` (new)
  - 10 new Swift Testing tests across three suites:
    - `MarketplaceInstallPromptCapabilitiesTests` (3) — `installPromptCapabilities` reads the manifest, is empty when no package, drops unknown strings.
    - `MarketplaceInstallPromptPreApprovalTests` (3) — `installPromptIsPreApproved` is `true` when all granted, `false` when any missing, `true` when no capabilities declared.
    - `MarketplaceInstallPromptRequestTests` (4) — `requestInstallPrompt(...)` returns the right context, returns `nil` when no package, `_installSelectedAfterGrants(...)` grants enabled capabilities, skips when no package, sets `.error` state on install failure.
  - All tests use a per-test `UserDefaults(suiteName:)`-backed `PluginCapabilityGate` and a per-test temp-dir-backed `PluginManager`; the suite never touches `UserDefaults.standard` or `PluginManager.shared`.
- `menubar01.xcodeproj/project.pbxproj`
  - Registered `MarketplaceInstallPromptSheet.swift` in the main target via the `pbxproj` Python library with `force=True`.
  - The new test file auto-discovers via `PBXFileSystemSynchronizedRootGroup` (no pbxproj edit needed for tests).

## Impact

- Backward compatibility: the existing `MarketplaceBrowserViewModel.installSelected(overwriteExisting:)` is preserved as a thin forwarder to `_installSelectedAfterGrants(overwriteExisting:)`, so all existing test assertions and any future programmatic caller continue to compile without modification. The `MarketplaceBrowserMenuCommand.presentSheet(...)` call site is unchanged.
- New API surface: a single public type, `MarketplaceInstallPromptContext`, plus three new methods / computed properties on `MarketplaceBrowserViewModel` (`installPromptCapabilities`, `installPromptIsPreApproved`, `requestInstallPrompt(overwriteExisting:)`). The renamed install primitive `_installSelectedAfterGrants(overwriteExisting:)` is the new authoritative entry point.
- User-visible behaviour: installing a marketplace plugin now shows a second modal sheet listing the plugin's declared capabilities. A user who installs a "battery-watch" plugin can see "this plugin wants to read .network" and decide whether to grant it. The Install button is now disabled by default; the user must explicitly click "Install" in the prompt sheet to confirm. A plugin that declares no capabilities shows an informational "This plugin does not request any special capabilities." hint and the Install button proceeds without any toggle row.
- The marketplace `Run Install` path now respects the M3 capability gate exactly the way the M2+ AI generator install path does.

## Testing

- 10 new tests added in `MarketplaceInstallPromptTests.swift`. All 10 pass.
- Full suite: **274 tests passed, 0 failed** (was 264 before this milestone; +10 net new tests, matching the +7 target in the task brief with extra coverage in the pre-approval and request-prompt spaces).
- xcodebuild: `** TEST SUCCEEDED **`.
- Build command used:
  ```
  xcodebuild -project menubar01.xcodeproj -scheme menubar01 -destination 'platform=macOS' -configuration Debug test
  ```

## Related

- M3 capability gate (9755129) — `PluginCapabilityGate` with `grant(_:for:)`, `granted(for:)`, `verify(...)`.
- M2 install flow (2beeccc) — `PluginManager.installGeneratedPlugin(_:)` for the AI generator's install path.
- M2+ install-prompt sheet (4075eb9) — the existing `AIGeneratorInstallPromptSheet` pattern this commit mirrors.
- M5 marketplace browser (351b460) — `MarketplaceBrowserSheet` and `MarketplaceBrowserViewModel`. This commit wires the install path of that browser to the gate.
- M5 marketplace client (b84a075) — `MarketplacePackage` and `MarketplaceInstaller` (manifest already exposed as `PluginManifest`, so the gate can read `capabilities` via `resolvedCapabilities`).
- `changes/2026-06-13-m3-capability-gate.md`, `changes/2026-06-13-m2-install-prompt-sheet.md`, `changes/2026-06-13-m5-marketplace-browser.md`, `changes/2026-06-13-m4-plugin-marketplace.md`.
- `docs/M5-marketplace-install-prompt.md` (new) — the design note this commit adds alongside the code change.

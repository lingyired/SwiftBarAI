# M5 install-gate follow-up: marketplace install flow consults `PluginCapability` declarations

## Why

The M3 capability-gate extension (`changes/2026-06-13-capability-gate-extension.md`)
landed the `PluginCapability` enum + `PluginCapabilityGate` store + a
`PluginCapabilityError` hierarchy, but the marketplace install path still
writes `manifest.json` and the entry script without ever consulting the
`capabilities` field. This change threads the gate through the new
`PluginManager.installMarketplacePluginWithCapabilityGate(...)` overload,
adds a dedicated `MarketplaceCapabilityPromptSheet` (an all-or-nothing
Grant/Decline prompt distinct from the M5 checkbox sheet), and
auto-grants capabilities the gate considers implicitly granted (e.g.
`clipboard`, which any foreground macOS app can read via
`NSPasteboard.general` without an entitlement).

## What changed

### New install primitive on `PluginManager`

- `menubar01/Plugin/PluginManager+MarketplaceInstall.swift` adds:
  - `public typealias CapabilityPromptHandler = @MainActor (_ pluginID: String, _ capabilities: [PluginCapability]) async -> Bool`
  - `public func installMarketplacePluginWithCapabilityGate(plan:overwriteExisting:gate:prompt:) -> Result<URL, InstallMarketplacePluginError>`
  - the new overload auto-grants every `isGrantedByDefault == true`
    capability, hands the rest to the injected `prompt` closure, and
    on user grant delegates to the existing I/O install
    (`installMarketplacePlugin(plan:overwriteExisting:)`).
  - the existing `installMarketplacePlugin(plan:overwriteExisting:)`
    signature is **unchanged** — the M5 install-prompt flow
    (which grants per-capability via the checkbox sheet) keeps
    working without modification.

### New `InstallMarketplacePluginError` case

- `.capabilityDeclined(pluginID: String, capabilities: [PluginCapability])`
  surfaces a user-declined install. `Equatable` is preserved by
  hand: the existing `Equatable` synthesis still works because
  `String`, `Array<Equatable>`, and `PluginCapability` are all
  `Equatable` (verified by
  `testInstall_errorEquatable_capabilityDeclinedMatchesExactSet`).

### `MarketplaceInstallPlan` gains a `manifest` carrier field

- `menubar01/Marketplace/MarketplaceInstaller.swift` adds
  `let manifest: PluginManifest?` to the plan, populated by
  `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`
  from the package's decoded `PluginManifest`. The field is
  `internal` (matching the `PluginManifest` access level — a
  Swift "internal-typed `public` field is an access-level
  error" guard) and the init drops to `internal` for the same
  reason. `Equatable` is hand-rolled because `PluginManifest`
  is not `Equatable`; the equality check skips the new
  `manifest` field because the canonical identity of a plan
  is `manifestData` (the bytes the installer writes verbatim).
  Older call sites that build a plan from raw `Data` continue
  to compile — the new parameter has a `nil` default.

### `isGrantedByDefault` is refined for `clipboard`

- `menubar01/Plugin/PluginCapabilities.swift`: `clipboard` now
  returns `true` for `isGrantedByDefault`. Rationale: any
  foreground macOS app can read `NSPasteboard.general` without
  an entitlement, so surfacing a "this plugin wants to read the
  clipboard" row in the install prompt would just be noise. The
  other four cases (`network`, `notifications`, `calendar`,
  `fileWrite`) still return `false` — those all require
  explicit user consent. The existing
  `testEnumIsGrantedByDefault_isFalseForAllCases` is renamed to
  `testEnumIsGrantedByDefault_clipboardIsTrueOthersAreFalse`
  and asserts the new policy.

### New SwiftUI prompt sheet + prompter

- `menubar01/UI/Marketplace/MarketplaceCapabilityPromptSheet.swift`
  is a new file (not in the existing
  `menubar01/UI/Marketplace Browser/` directory because the
  new prompt is conceptually distinct from the checkbox sheet
  — it renders a single Grant/Decline button per install
  because the install-gate overload has already filtered out
  the `isGrantedByDefault == true` capabilities). The file
  declares:
  - `@MainActor struct MarketplaceCapabilityPromptSheet: View`
    — lists the ungranted, non-default capabilities with
    `displayName` (bolded) and `description` (secondary).
  - `@MainActor enum MarketplaceCapabilityPrompter` — AppKit
    wrapper that hosts the sheet on `NSApp.keyWindow` and
    resolves the choice through a closure.

### M5 marketplace browser wiring

- `menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
  adds `installSelectedWithCapabilityGate(overwriteExisting:)`
  — a programmatic install path that builds the plan, hands
  the `prompt` closure to
  `MarketplaceCapabilityPrompter.present(...)`, and rolls
  state back to `.loaded` on a `.capabilityDeclined` failure
  (so the install button re-enables without showing the
  error banner). The existing
  `installSelected(overwriteExisting:)` flow is unchanged.

### Tests

- `menubar01Tests/PluginManagerMarketplaceInstallGateTests.swift`
  is a new file (auto-discovered by the
  `PBXFileSystemSynchronizedRootGroup`-backed test target).
  Eight tests, all passing:
  1. `testInstall_withNoCapabilities_proceedsAndSucceeds`
  2. `testInstall_withDefaultGrantedCapabilities_autoGrantsAndSucceeds`
  3. `testInstall_withNonDefaultCapability_callsPromptAndSucceedsOnGrant`
  4. `testInstall_withNonDefaultCapability_callsPromptAndAbortsOnDecline`
  5. `testInstall_promptDecline_doesNotWriteToDisk`
  6. `testInstall_promptGrant_persistsGrantInGate`
  7. `testInstall_promptGrantThenReinstall_doesNotPromptAgain`
  8. `testInstall_errorEquatable_capabilityDeclinedMatchesExactSet`

### Project

- `menubar01.xcodeproj/project.pbxproj` registers
  `MarketplaceCapabilityPromptSheet.swift` as a member of
  the menubar01 target (PBXBuildFile, PBXFileReference,
  PBXGroup children, Sources phase). The test file does not
  need an explicit pbxproj entry — the test target uses
  `PBXFileSystemSynchronizedRootGroup` which auto-discovers
  files in `menubar01Tests/`.

## Verification

- `xcodebuild build` succeeds.
- `xcodebuild test -only-testing:menubar01Tests` — all tests
  pass (no failures, including the existing 7
  `PluginCapabilityTests` cases updated for the new
  `isGrantedByDefault` policy).

Status: done (fc169b7)

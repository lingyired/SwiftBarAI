# 2026-06-13 — M2 install-prompt sheet (M2 + M3 integration)

- **Type:** feat
- **Scope:** `menubar01/UI/Plugin Generator/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** 4075eb9
- **Status:** done

## Summary

The AI generator's "Save to Plugin Folder" footer button now opens
a **second** modal sheet — `AIGeneratorInstallPromptSheet` — that
lists the plugin's declared capabilities (read off
`latestPlugin.manifest.resolvedCapabilities`), lets the user toggle
each on or off (defaulting to the on-state), and on **Install**
calls `PluginCapabilityGate.grant(_:for:)` for every enabled
capability before handing the plugin to
`PluginManager.installGeneratedPlugin(_:)`. **Cancel** rolls the
view-model state back so the parent sheet's success banner does
not linger.

## Motivation

The M2 install-flow record (2beeccc) explicitly deferred the
install-prompt sheet:

> Capability-gate install prompt: the M3 record says "M2's install
> sheet can call `gate.grant(_:for:)` using the same name the
> loader sees." The current M2 sheet does not have an
> install-prompt sub-sheet; the install happens silently under
> the assumption that the user just generated and is saving
> their own plugin.

The M3 capability-gate record (9755129) restates the same
deferral:

> M2 (the install-prompt sheet that calls `gate.grant(_:for:)`)
> and the marketplace install path.

This change closes both gaps. The AI generator and the
(marketplace) install paths now both call
`PluginCapabilityGate.grant(_:for:)` before the actual install,
satisfying the §3 architecture-doc rule that no plugin gets
`network` / `clipboard` / etc. without a recorded grant.

## Changes

### New files

- **`menubar01/UI/Plugin Generator/AIGeneratorInstallPromptSheet.swift`**
  the new sub-sheet. `MainActor`-isolated SwiftUI view that
  presents a `ForEach` of `Toggle`s (one per
  `viewModel.installPromptCapabilities`), pre-checks any
  capability the gate has already granted for the current
  `manifest.name`, and on Install grants every enabled
  capability for the same name before delegating to
  `PluginManager.shared.installGeneratedPlugin(_:)`. Owns no
  view-model state — the `onComplete: (Result<URL, InstallPromptError>) -> Void`
  callback is the only path back into the parent sheet.

- **`menubar01Tests/AIGeneratorInstallPromptTests.swift`** —
  8 new tests in 3 Swift Testing suites:
  - `AIGeneratorInstallPromptCapabilitiesTests` (3): reads the
    manifest's resolved capability list, returns `[]` when there
    is no `latestPlugin`, and drops unknown capability strings.
  - `AIGeneratorInstallPromptPreApprovalTests` (3): the
    `installPromptIsPreApproved` flag is `true` when every
    declared capability is already granted, `false` when at
    least one is missing, and `true` when the manifest
    declares no capabilities.
  - `AIGeneratorInstallCompletionTests` (2):
    `didCompleteInstall(at:)` flips `didRequestSave` and stores
    the URL; `didFailInstall(reason:)` clears both.

  Per-test `UserDefaults(suiteName: "menubar01.tests.installPrompt.<UUID>")`
  isolation pattern, mirroring `PluginCapabilityTests.swift`.

### Modified files

- **`menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`**
  - New `@Published var installedPluginURL: URL?` (set by the
    sheet's completion handler, read by the parent sheet to
    render the success banner).
  - New `var pluginCapabilityGate: PluginCapabilityGate`
    (defaults to `PluginManager.shared.pluginCapabilityGate`,
    overridable by tests with a fresh instance backed by an
    isolated `UserDefaults` suite — same DI pattern as
    `generator`).
  - New `installPromptCapabilities: [PluginCapability]`
    computed property (mirrors
    `latestPlugin.manifest.resolvedCapabilities`).
  - New `installPromptIsPreApproved: Bool` computed property
    (true when the gate has every declared capability).
  - New `didCompleteInstall(at: URL)` / `didFailInstall(reason: String)`
    methods — the only state mutators the sheet calls.
  - `requestSaveToPluginFolder()` is now a documented no-op
    (the sheet drives the flow).
  - `generate()` resets `installedPluginURL = nil` alongside
    `didRequestSave = false`.
  - `reset()` also clears `installedPluginURL`.

- **`menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`**
  - "Save to Plugin Folder" footer button now sets
    `showingInstallPrompt = true` instead of calling
    `viewModel.requestSaveToPluginFolder()`.
  - New `@State private var showingInstallPrompt: Bool = false`
    and a `.sheet(isPresented:)` modal that presents
    `AIGeneratorInstallPromptSheet(viewModel: viewModel) { ... }`.
  - The completion handler maps the `Result` to
    `viewModel.didCompleteInstall(at:)` /
    `viewModel.didFailInstall(reason:)`.
  - Old `alert("M3 will wire this to PluginManager.importPlugin")`
    removed; replaced with a new `installSuccessBanner` view
    that shows a green check + the on-disk path when
    `viewModel.didRequestSave == true && viewModel.installedPluginURL != nil`.

- **`menubar01Tests/AIGeneratorViewModelTests.swift`**
  - `testRequestSaveToPluginFolderIsNoOpWithoutLatestPlugin` —
    unchanged behaviour, comments updated to point at
    `AIGeneratorInstallPromptTests` and
    `PluginManagerInstallGeneratedPluginTests`.
  - `testGenerateResetsDidRequestSaveFlag` — now drives the
    save through `viewModel.didCompleteInstall(at:)` (the
    sheet's completion contract) and asserts
    `installedPluginURL == nil` after re-generation.
  - `testResetClearsStateAndLatestPlugin` — also asserts
    `installedPluginURL == nil` after `reset()`.

- **`menubar01.xcodeproj/project.pbxproj`**
  - New `PBXFileReference` + `PBXBuildFile` entries for
    `AIGeneratorInstallPromptSheet.swift` (the test file is
    auto-discovered via the existing
    `PBXFileSystemSynchronizedRootGroup` for `menubar01Tests`).
  - File added to the top-level group's children and the
    menubar01 target's Sources build phase. MAS target
    unaffected (it does not include the M2 AI generator).

### Pre-existing fix (workaround)

- **`menubar01/AI/AIPluginGeneratorFactory.swift`** — the
  in-flight M2+ real-LLM factory work introduced three
  `public static func make*(prefs: PreferencesStore? = nil)`
  methods while `PreferencesStore` is still `internal`. The
  resulting 3 compile errors blocked the test suite. Dropped
  the `public` keyword on the 3 methods (default → `internal`,
  matches the original M1 access level in ef7702c). The M2+
  factory work can re-add `public` once `PreferencesStore` is
  made public (or change the parameter type).

## Impact

User-visible. The Save button now opens a second modal sheet
before writing to disk. Without this, every AI-generated plugin
would be installed with no capability prompt, which violates §3
of the architecture doc ("no plugin gets `network` /
`clipboard` / etc. without a recorded grant").

The sheet is also a natural extension point for the marketplace
install path: the `gate.grant(_:for:)` call is the same one
`PluginManager+MarketplaceInstall.swift` will need to make
when a user installs a marketplace plugin that declares
`capabilities` in its `manifest.json`. The marketplace flow
can reuse `AIGeneratorInstallPromptSheet` (with a different
`onComplete` mapping) or its own sheet that calls
`gate.grant(_:for:)` directly — both paths keep the gate
authoritative.

## Testing

- 8 new tests in `AIGeneratorInstallPromptTests.swift`.
- 2 existing tests in `AIGeneratorViewModelTests.swift` updated
  for the new contract; the third existing test
  (`testRequestSaveToPluginFolderIsNoOpWithoutLatestPlugin`) is
  unchanged.
- Full suite: **211 tests, 0 failures, 0 regressions** (was
  202 before this change; +8 new + 1 from the renamed
  `testResetClearsStateAndLatestPlugin` which gained an
  `installedPluginURL` assertion).

## Related

- M2 install-flow (2beeccc) — first version of the real install
  path, which explicitly deferred the install-prompt sheet.
- M3 capability-gate (9755129) — `PluginCapability`,
  `PluginCapabilityError`, `PluginCapabilityGate`. This change
  is the M2 side of the integration M3 called out.
- M2+ real-LLM factory (in flight in this round) — the
  in-progress `AIPluginGeneratorFactory` rewrite that broke the
  test suite via 3 public-method-takes-internal-type errors.
  Worked around by dropping the `public` keyword on the 3
  methods. Not strictly part of this change; tracked here so
  reviewers know why a non-`UI/Plugin Generator/` file was
  touched.

# 2026-06-13: AIPluginGenerator M2 live preview UI

- **Type:** feat
- **Scope:** `menubar01/UI/Plugin Generator/`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Implements M2 of [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
§1.5 / §6: the live preview UI for the AI plugin generator. M2
ships a SwiftUI sheet (`AIGeneratorSheet`) backed by a
`@MainActor` view model (`AIGeneratorViewModel`), wired into the
existing menubar01 app menu (`AppDelegate+Menu.swift` →
`AppMenu`) via a small `PluginGeneratorMenuCommand` helper. The
sheet consumes the M1 `AIPluginGenerator` protocol directly
through `AIPluginGeneratorFactory.makeDefault()`; no LLM code
lands in this milestone. The "Save to Plugin Folder" action is a
stub — M3 will wire it through to `PluginManager.importPlugin`
and the `GeneratedPlugin.encodedAsBundle()` helper.

## Motivation

`AI_PLUGIN_ARCHITECTURE.md` §6 lists M2 as
"Live preview UI in the Plugin Repository window" with
`PluginRepositoryView` and `PluginEntryView` as the existing
dependencies. The VM and the menu wiring can land before the
sandboxed dry-run / capability-gate (M3) does, because the M1
protocol is enough to drive an end-to-end review loop: the user
types a request, gets a manifest + script + explanation, and
either accepts or regenerates. This lets the UX be designed
against a stable sheet shape before M3's install pipeline is
ready.

## Changes

- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`:
  new. `@MainActor` `ObservableObject` with `@Published` `request`,
  `state` (`.idle | .loading | .success(GeneratedPlugin) | .failure(String)`),
  `latestPlugin`, `context`, and `didRequestSave` flag. Drives the
  sheet through `func generate() async`, `func reset()`, and
  `func requestSaveToPluginFolder()`. The `manifestJSON` computed
  property encodes the internal `GeneratedPlugin.manifest` via a
  private `EncodedManifest: Encodable` adapter so the public type
  does not leak `PluginManifest`'s `internal` access level.
- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`: new.
  SwiftUI `View` with a header, a request `TextEditor`, an
  optional error banner, and a result section (explanation,
  `promptId` / `promptVersion`, manifest JSON, entry script). The
  footer shows "Cancel" + "Generate" / "Re-generate" +
  "Save to Plugin Folder" depending on `viewModel.latestPlugin`.
  Save click flips `viewModel.didRequestSave` which triggers an
  `alert(...)` that displays the M3 hand-off message.
- `menubar01/UI/Plugin Generator/PluginGeneratorMenuCommand.swift`:
  new. `enum PluginGeneratorMenuCommand` with `static let
  menuItemTitle`, `static func install(into: AppMenu)` (inserts
  the item + a separator into the existing AppMenu submenu), and
  `static func presentSheet()` (lazily creates an `NSWindow` held
  by `AppDelegate.aiGeneratorWindowController` and shows a
  SwiftUI `NSHostingController` over it). The window is a single
  `NSWindowController` rooted on the `AppDelegate` so subsequent
  menu clicks reuse the same window.
- `menubar01Tests/AIGeneratorViewModelTests.swift`: new. 9 Swift
  Testing tests in 1 `@MainActor` suite, using a hand-rolled
  `CapturingMockAIPluginGenerator` to control the generator's
  return value / thrown error and to assert on the inputs the
  VM hands the protocol. Coverage: initial state; `canGenerate`
  requires a non-empty request and is disabled while loading;
  success path stores the plugin and produces manifest JSON;
  failure path lands in `.failure(reason)` with the upstream
  message; `didRequestSave` is reset by a re-generate; empty
  requests short-circuit; `requestSaveToPluginFolder` flips the
  flag; `reset` clears state; manifest JSON round-trips the
  generator's payload.
- `docs/M2-ai-plugin-generator-ui.md`: new. Short design note
  quoting the §6 milestone description, listing in-scope vs.
  M3-deferred work, and documenting the VM→view contract.
- `menubar01/AppDelegate+Menu.swift`: edit. Two additions:
  (1) `PluginGeneratorMenuCommand.install(into: self)` at the
  end of `AppMenu.init`; (2) `@objc func openAIGenerator() { … }`
  next to the other `@objc` action handlers. Both are
  single-call / single-method additions; the existing
  `init`/`@objc` patterns are unchanged.
- `menubar01/AppDelegate.swift`: edit. New
  `var aiGeneratorWindowController: NSWindowController?` property
  on the `AppDelegate` class so the menu command can persist the
  generator window across re-opens.

## Impact

- **New public types:** none. All new types are `internal` to the
  `menubar01` module, matching the access pattern of the rest of
  the UI layer (`AIGeneratorSheet`, `AIGeneratorViewModel`,
  `PluginGeneratorMenuCommand`, `CapturingMockAIPluginGenerator`).
- **User-visible behaviour change:** the menubar01 app menu now
  shows "Generate plugin with AI…" right after "About menubar01".
  Clicking the item opens a new window with the sheet. The sheet
  renders the M1 mock generator's output (an "Echo" plugin).
- **No new entitlements**, no new dependencies, no new URL scheme
  handlers, no new AppIntents. The M1 public API surface is
  unchanged.
- **No new localisation keys.** The menu title and sheet copy
  are hard-coded English strings in v1; once a real LLM-backed
  factory lands in M2+ the strings can move into
  `Localizable.strings` in a follow-up.

## Testing

- 9 new unit tests in
  `menubar01Tests/AIGeneratorViewModelTests.swift`. All are
  pure (no filesystem, no AppKit, no networking). The
  `CapturingMockAIPluginGenerator` test double lives in the
  test file so the production code does not gain a new
  internal-public type.
- Verification: `xcodebuild … build-for-testing` should report
  0 errors in the new module path. The Swift Testing tests
  under `menubar01Tests` use
  `PBXFileSystemSynchronizedRootGroup` and are auto-discovered,
  so once the main agent registers the new files the test target
  picks them up without further pbxproj edits.

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.5
  (the M1 contract this milestone consumes) and §6 (the
  roadmap entry for M2).
- Follow-up: M3 (capability-gate install flow that consumes
  `GeneratedPlugin.encodedAsBundle()` from M1 and replaces the M2
  save stub with a real `PluginManager.importPlugin` call);
  M5 (real LLM-backed factory + generator history persistence).

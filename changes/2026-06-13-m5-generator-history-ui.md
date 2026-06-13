# M5 — Generator History UI

- **Type:** feat
- **Scope:**
  `menubar01/UI/Generator History/`,
  `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`,
  `menubar01/AppDelegate+Menu.swift`,
  `menubar01/AppDelegate.swift`,
  `menubar01/AI/AIGeneratorHistoryStore.swift`,
  `menubar01/UI/Preferences/AdvancedPreferencesView.swift`,
  `menubar01.xcodeproj/project.pbxproj`,
  `menubar01Tests/GeneratorHistoryViewModelTests.swift`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Wire the M5 data layer (`f2a1cf4` — `AIGeneratorHistoryEntry`,
`AIGeneratorHistoryStore`, `FileSystemAIGeneratorHistoryStore`,
`AIGeneratorHistoryStoreFactory`) to a SwiftUI browser sheet and a
"Wipe All Generator History" Preferences → Advanced button. The M2
view model now records every successful `generate()` result so the
user can audit, re-generate, or downgrade a generated plugin
later.

## Motivation

The M5 record (f2a1cf4) ends with:

> "Follow-up: M2 (UI in the Plugin Repository window that calls
> `record(_:)` after every successful run) and a future 'Wipe all
> generator history' item in Preferences → Advanced that wires
> `deleteAll()` into the UI."

This change closes both follow-ups: the M2 view model now calls
`historyStore.record(...)` on every successful run, the new
`GeneratorHistorySheet` is the user-facing browser, and the new
Advanced-preferences button surfaces the destructive
`deleteAll()` to users who never open the sheet.

## Changes

### New source files (menubar01 main target)

- `menubar01/UI/Generator History/GeneratorHistoryViewModel.swift` —
  `@MainActor` view model with a 5-state machine
  (`.idle` / `.loading` / `.loaded` / `.deleting` / `.error(String)`),
  `selectedPromptId: String?` (avoids forcing the non-`Hashable`
  `GeneratedPlugin` to conform), and `reload()`,
  `deleteSelected()`, `deleteAll()`, `reset()` methods.
- `menubar01/UI/Generator History/GeneratorHistorySheet.swift` —
  SwiftUI sheet with a sidebar `List` of past runs, a detail pane
  showing the manifest JSON + entry script, and a footer with
  Close / Re-generate / Delete / Delete All actions. macOS 12
  compatible (`NavigationView`, not `NavigationStack`).
- `menubar01/UI/Generator History/GeneratorHistoryMenuCommand.swift` —
  `enum` mirroring the M2 / M5 marketplace pattern. Inserts the
  "Generator History…" item next to the existing M2 / M5
  marketplace items, and lazily creates a hosting `NSWindow` so
  the menu → window plumbing matches the existing flows.

### New test file (menubar01Tests target)

- `menubar01Tests/GeneratorHistoryViewModelTests.swift` — 10
  Swift-Testing tests covering `reload()`, `deleteSelected()`,
  `deleteAll()`, `reset()`, and the `AIGeneratorViewModel`
  integration. Uses a `TestHistoryStore` (in-memory, configurable
  to throw on each method) and the per-test temp-dir pattern
  from `AIGeneratorHistoryStoreTests`.

### Edited files

- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift` —
  added `historyStore: AIGeneratorHistoryStore` to the view
  model, updated the init to default to
  `AIGeneratorHistoryStoreFactory.makeDefault()`, and added a
  record-after-success hook in `generate()`. Failures are logged
  via `os_log` and swallowed so a failed write never blocks the
  user from seeing the generated plugin.
- `menubar01/AppDelegate+Menu.swift` — calls
  `GeneratorHistoryMenuCommand.install(into: self)` at the end of
  `AppMenu.init` and adds `@objc func openGeneratorHistory()`
  next to `openAIGenerator` / `openMarketplaceBrowser`.
- `menubar01/AppDelegate.swift` — adds
  `var generatorHistoryWindowController: NSWindowController?`
  next to the existing `marketplaceBrowserWindowController`.
- `menubar01/UI/Preferences/AdvancedPreferencesView.swift` — adds
  an "AI Generator History" section with a "Wipe All Generator
  History" destructive button. The button confirms via
  `NSAlert`, then calls
  `AIGeneratorHistoryStoreFactory.makeDefault().deleteAll()` and
  surfaces a "Wiped N entries." / "Wipe failed: …" toast.
- `menubar01/UI/Plugin Generator/PluginGeneratorMenuCommand.swift` —
  `presentSheet(...)` now takes an optional `appDelegate:`
  argument so the history sheet's "Re-generate" button can reuse
  the same window-controller / `AIGeneratorViewModel` lifecycle.
- `menubar01/AI/AIGeneratorHistoryStore.swift` — adds a
  `public var reason: String` accessor on
  `AIGeneratorHistoryError` so the view model can show the
  underlying reason verbatim (the error type does not conform to
  `LocalizedError`, so `error.localizedDescription` returns the
  default NSError description).
- `menubar01.xcodeproj/project.pbxproj` — registers the 3 new
  main-target sources. The new test file auto-discovers via
  `PBXFileSystemSynchronizedRootGroup`.

## Impact

- **User-visible.** A new "Generator History…" menu item in the
  menubar01 app menu, and a new "Wipe All Generator History"
  button in Preferences → Advanced. Every successful `generate()`
  call now persists a `response.json` (and `request.txt`) to
  `~/Library/Application Support/menubar01/AIGenerator/<promptId>/`.
- **Internal.** A new `AIGeneratorViewModel` constructor argument
  (`historyStore`) — production call sites use the default; tests
  inject a fresh `FileSystemAIGeneratorHistoryStore` rooted at a
  temp dir. `AIGeneratorHistoryError` gained a `reason` accessor
  (non-breaking).

## Testing

10 new tests in
`menubar01Tests/GeneratorHistoryViewModelTests.swift` (Swift
Testing):

- `testReload_populatesEntriesFromStore`
- `testReload_setsStateToLoaded`
- `testReload_setsStateToErrorOnStoreFailure`
- `testDeleteSelected_removesEntryAndReloads`
- `testDeleteSelected_isNoOpWhenNothingSelected`
- `testDeleteSelected_setsStateToErrorOnStoreFailure`
- `testDeleteAll_clearsEntriesAndReloads`
- `testDeleteAll_setsStateToErrorOnStoreFailure`
- `testReset_clearsState`
- `testHistoryStore_integrationWithAIGeneratorViewModel`

Full suite: 235 tests, 0 failing.

## Follow-ups (deferred to a future M5+ round)

- **Re-generate wiring.** v1's "Re-generate" footer button closes
  the history window and re-opens the M2 sheet; the M2 sheet does
  not yet accept a pre-filled request, so the user has to copy /
  paste from the detail pane. Tracked as a separate change.
- **`menuTreeJSON` population.** The record-after-generate hook
  passes `menuTreeJSON: nil`. The generator's sandboxed dry-run
  will populate this in M5+ so the sheet can render a preview of
  the menu the generator emitted.
- **Audit-log export.** A future "Export history as JSON" button
  in the sheet's footer would let users send the audit trail to
  support.

## Related

- M5 data layer (f2a1cf4) —
  `AIGeneratorHistoryEntry`, `AIGeneratorHistoryStore`,
  `FileSystemAIGeneratorHistoryStore`,
  `AIGeneratorHistoryStoreFactory`.
- M2 sheet (8f11372) — `AIGeneratorViewModel` /
  `AIGeneratorSheet` / `PluginGeneratorMenuCommand`.
- Install flow (2beeccc) — `PluginManager+MarketplaceInstall`.
- Install-prompt sheet (in flight this round) —
  `AIGeneratorInstallPromptSheet` / `AIGeneratorViewModel` install
  lifecycle.

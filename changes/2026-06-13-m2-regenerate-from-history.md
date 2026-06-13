# 2026-06-13: M5 history "Re-generate" closes the history sheet before opening M2

- **Type:** feat
- **Scope:**
  `menubar01/UI/Generator History/GeneratorHistoryMenuCommand.swift`,
  `menubar01Tests/GeneratorHistoryMenuCommandTests.swift`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Closes the final M5+ follow-up gap on the "Re-generate" history
flow: clicking the footer button in the M5 history sheet now
**closes the history window** before opening the M2 sheet
(pre-populated with the original request), so the user no longer
ends up with two stacked sheets on top of the menu bar item. The
underlying wiring — the M5 `onRegenerate` closure forwarding
`entry.request` to `PluginGeneratorMenuCommand.presentSheet(prefillRequest:)`
— was already in place after `e033493`; this change is a one-line
behavioural fix at the closure call site plus a new Swift Testing
suite that pins the wiring.

## Motivation

`changes/2026-06-13-m5-history-followups.md` (commit `e033493`)
landed the `onRegenerate` → `PluginGeneratorMenuCommand.presentSheet(prefillRequest:)`
wiring, but the M5 history window stayed open. With both windows
visible the user saw:

```
┌──────────────────────────────────────────────┐
│ Generator History  (stays open)              │
│   selected entry: "show weather in Beijing"  │
│   [ Re-generate ]                            │
└──────────────────────────────────────────────┘
            ↓ (on top of the history sheet)
┌──────────────────────────────────────────────┐
│ Generate plugin with AI…  (M2)               │
│   request: "show weather in Beijing"         │
└──────────────────────────────────────────────┘
```

The M2 sheet is the only one the user wants in the foreground
during re-generation; the history sheet serves no purpose once
the user has decided to re-run. Closing the history window
before opening the M2 sheet also matches the existing
"open a window" pattern across the rest of the app: each menu
command owns its own `NSWindowController` and shows one window
at a time, so two sheets visible at once is a UX surprise.

## Changes

### Edited files

- `menubar01/UI/Generator History/GeneratorHistoryMenuCommand.swift`:
  the `onRegenerate` closure body — installed on
  `GeneratorHistorySheet` by `presentSheet(appDelegate:)` — now
  closes `windowController.window?` before calling
  `PluginGeneratorMenuCommand.presentSheet(appDelegate:prefillRequest:)`.
  The two `AppDelegate`-rooted window controllers are independent,
  so the close is local to the M5 history window. The M2 sheet's
  hosting controller is rebuilt (when `prefillRequest != nil`)
  and shown afterwards, mirroring the existing
  `presentSheet(prefillRequest:)` semantics from
  `PluginGeneratorMenuCommand.swift`.

### New test file (menubar01Tests target)

- `menubar01Tests/GeneratorHistoryMenuCommandTests.swift` —
  5 new Swift-Testing tests:
  - `testOnRegenerate_isCapturedByInit` — pins that the
    `GeneratorHistorySheet.init` stores the `onRegenerate`
    closure on the public `var`, so the "Re-generate" button
    reaches it.
  - `testOnRegenerate_invocationForwardsSelectedEntryRequest` —
    pins the contract that the closure receives the
    `viewModel.selectedEntry` (not `entries.first`,
    not `entries.last`) when the user clicks the button.
  - `testOnRegenerate_invocationTracksLatestSelectedEntry` —
    pins that successive selections re-target the same
    closure instance, so the same `onRegenerate` callback
    works for the entire lifetime of the sheet.
  - `testOnRegenerate_nilCallbackDoesNotCrash` — pins the
    "missing closure is tolerated" branch the button relies
    on (`onRegenerate?(entry)` is an optional-chain call).
  - `testRegenerateFromHistory_forwardsEntryRequestAsPrefill`
    — pins the actual payload the menu command's closure
    body forwards to `PluginGeneratorMenuCommand.presentSheet(prefillRequest:)`:
    `entry.request` reaches the captured closure verbatim.

  All five are pure Swift Testing tests; the AppKit-bound
  `NSWindow` close is not exercised from the test bundle
  because the existing test infrastructure has no SwiftUI
  view-testing scaffolding. The closure-capture round-trip
  is the same code path the button would exercise, so the
  tests act as a sanity check on the wiring without
  involving AppKit.

### Not changed

- `PluginGeneratorMenuCommand.presentSheet(appDelegate:prefillRequest:)`
  is **already** `internal` (not `private`), so the history
  command can call it without a visibility change.
- `GeneratorHistorySheet.onRegenerate` is unchanged: the
  `if let entry = viewModel.selectedEntry { onRegenerate?(entry) }`
  button action is the source of truth, and the new tests
  assert against that exact code path.
- The M2 "Save to Plugin Folder" flow and the M5 "Export…"
  flow are not touched.

## Impact

- **User-visible.** Clicking the M5 history sheet's
  "Re-generate" button now hides the history window before
  the M2 sheet appears, so the user sees a single
  generator sheet (pre-populated with the original
  request) instead of two stacked sheets. Closing the
  history window is non-destructive — the on-disk history
  is untouched, and the user can re-open the window via
  "Generator History…" in the app menu to pick a
  different entry.
- **Internal.** No new API surface. The
  `onRegenerate: ((AIGeneratorHistoryEntry) -> Void)?`
  signature, the `PluginGeneratorMenuCommand.presentSheet(prefillRequest:)`
  overload, and the `AppDelegate`-rooted window controllers
  are all unchanged.

## Testing

5 new tests in
`menubar01Tests/GeneratorHistoryMenuCommandTests.swift` (Swift
Testing):

- `testOnRegenerate_isCapturedByInit`
- `testOnRegenerate_invocationForwardsSelectedEntryRequest`
- `testOnRegenerate_invocationTracksLatestSelectedEntry`
- `testOnRegenerate_nilCallbackDoesNotCrash`
- `testRegenerateFromHistory_forwardsEntryRequestAsPrefill`

Full suite: 331 tests, 0 failing (was 326 before this
change; +5 from the new file).

## Related

- M5 history follow-ups (`e033493`) — landed the
  `onRegenerate` → `PluginGeneratorMenuCommand.presentSheet(prefillRequest:)`
  wiring and the new M2 `prefillRequest:` overload.
- M5 history UI (`4075eb9`) — the
  `GeneratorHistorySheet` and its `onRegenerate` callback.
- M2 sheet (`8f11372`) — `AIGeneratorViewModel` /
  `AIGeneratorSheet` / `PluginGeneratorMenuCommand`.
- `changes/2026-06-13-m5-history-followups.md` — the prior
  M5 follow-up record that closed the
  "re-generate / menuTreeJSON / audit-log export" trio.

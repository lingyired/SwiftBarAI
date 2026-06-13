# AIGenerator history UI — filter by provider/host and delete-single

**Date:** 2026-06-13
**Status:** pending
**Commit:** _fill in after commit_

## Summary
- Generator History sheet now has a filter picker (All / by provider / by endpoint host)
  with options derived from the entries actually present.
- The history list supports deleting a single entry (swipe or context menu) and
  has a "Delete All" button with a confirmation alert.
- The store already exposed `delete(promptId:)` and `deleteAll()`; this change wires
  the UI to them and adds a small `HistoryFilter` enum on the view model.
- Tests: 5 new tests covering filter behaviour and deletion.

## Impact
- The history view is the only entry point for these operations, so the blast
  radius is local to `menubar01/UI/Generator History/` and the
  `AIGeneratorHistoryStore` facade.
- No on-disk schema change.

## Notes
- `providerName` is a new field on `AIGeneratorHistoryEntry` and a new
  default-`nil` property on the `AIPluginGenerator` protocol. Each v1
  generator (`Mock`, `Local`, `LocalEcho`, `Remote`, `RemoteEcho`)
  overrides `providerName` to a stable label (`"Mock"` / `"Local"` /
  `"Remote"`) so the filter picker can group their entries
  without storing the name at record time.
- `providerName` is `nil` for older entries written before this
  change; the store decodes the missing `providerName` key as
  `nil` and the filter surfaces those entries under
  `"Unknown"`.
- The filter is in-memory only and resets to `.all` whenever
  `viewModel.reset()` is called (e.g. on sheet re-presentation).
- Per-row delete uses a context menu (right-click on the sidebar
  list). `.swipeActions` is unreliable on macOS sidebars, and
  context-menu mirrors the Finder / Mail pattern.
- The "Delete All" button in the top-of-sheet header is new; the
  existing footer "Delete All" stays so users don't lose reach
  when the sidebar is scrolled to the bottom.

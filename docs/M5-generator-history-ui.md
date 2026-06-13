# M5 — Generator History UI

> Status: in-progress
> Source-of-truth: `changes/2026-06-13-m5-generator-history-ui.md`
> Layer: M5 history UI (sheet + record-after-generate hook +
> Wipe-All button)

This note describes the user-facing shape of the M5 history UI
and the two design decisions that aren't obvious from the code:
how the sheet handles a non-`Hashable` selection, and how the
"record after every successful run" hook is wired so it never
blocks the user from seeing the generator's output.

## 1. The sheet shape

`GeneratorHistorySheet` is a macOS-12-compatible SwiftUI sheet
(`NavigationView`, not `NavigationStack`) presented from the
`GeneratorHistoryMenuCommand.presentSheet(...)` AppKit hosting
window. The sheet is a 4-quadrant layout:

```
┌──────────────────────────────────────────────┐
│ Header: "Generator History" + subtitle       │
├─────────────────┬────────────────────────────┤
│ Sidebar List    │ Detail pane                │
│ (entries,       │ (selected entry metadata,  │
│  newest first)  │  manifest JSON, entry      │
│                 │  script, raw request)      │
├─────────────────┴────────────────────────────┤
│ State banner / ProgressView / error          │
├──────────────────────────────────────────────┤
│ Footer: Close / Re-generate / Delete /       │
│         Delete All                           │
└──────────────────────────────────────────────┘
```

- The sidebar is a `List(selection: $viewModel.selectedPromptId)`
  bound to a `String?` (see §2 below). Each row shows
  `promptId` (monospaced, truncated middle), the request
  (truncated to 60 chars), and `createdAt` (abbreviated date +
  short time).
- The detail pane shows `promptId`, `createdAt` (full date +
  standard time), `model`, the `request`, the
  `GeneratedPlugin.manifest` (pretty-printed JSON), and the
  `entryScript` body (monospaced, scrollable). A small
  `EncodedManifest` adapter at the bottom of the file reaches
  `GeneratedPlugin.manifest` (which is `internal`) without
  re-exposing the type's access level.
- The state banner shows a `ProgressView` while
  `viewModel.state == .deleting` and a red error banner with a
  "Dismiss" button on `.error(reason)`.
- The footer has Close (`NSApp.keyWindow?.close()`), Re-generate
  (re-opens the M2 sheet — see §3), Delete (single-entry, with
  a confirmation dialog), and Delete All (with a confirmation
  dialog).

## 2. The "selection" plumbing

SwiftUI's `List(selection:)` requires `Hashable`. The
`AIGeneratorHistoryEntry` record carries a `GeneratedPlugin`
whose `manifest` is `PluginManifest`, neither of which is
`Hashable`. Forcing the whole chain to be `Hashable` purely to
satisfy SwiftUI would leak a presentation-only requirement
into the data layer.

The view model side-steps this by tracking the selection as a
`String?` (`selectedPromptId`) and exposing the resolved entry
through a computed property:

```swift
@Published var selectedPromptId: String?

var selectedEntry: AIGeneratorHistoryEntry? {
    guard let selectedPromptId else { return nil }
    return entries.first { $0.promptId == selectedPromptId }
}
```

The sheet binds the picker to `selectedPromptId`, and reads
`viewModel.selectedEntry` for the detail pane. The result: the
data layer stays protocol-minimal, the view model is
straightforward to test, and there is no `Hashable` /
`Equatable` chain to keep in sync.

## 3. The "record after every successful run" hook

`AIGeneratorViewModel` now takes a `historyStore` argument
(defaulting to `AIGeneratorHistoryStoreFactory.makeDefault()`)
and records the result of every successful `generate()`:

```swift
do {
    let plugin = try await generator.generate(...)
    latestPlugin = plugin
    state = .success(plugin)
    do {
        try historyStore.record(AIGeneratorHistoryEntry(
            promptId: plugin.promptId,
            createdAt: Date(),
            request: trimmed,
            model: context.model,
            plugin: plugin,
            menuTreeJSON: nil  // M5+; dry-run will populate.
        ))
    } catch {
        os_log("AIGenerator: failed to record history entry: %{public}@",
               log: Self.log, type: .error, error.localizedDescription)
        // Non-fatal: the user still sees the generated plugin.
    }
} catch { ... }
```

The history store is a "best effort" audit trail, not a hard
dependency. If the disk is full, or the user has revoked our
file-system permission, the generator sheet still shows the
generated plugin and offers the user the Install button.

The catch block in the view model uses a private
`errorReason(from:)` helper that pattern-matches on
`AIGeneratorHistoryError` to surface the wrapped `reason`
verbatim (the error type does not conform to
`LocalizedError`, so `error.localizedDescription` returns the
default NSError description).

## 4. The destructive "Delete All" confirmation flow

Both destructive actions (Delete, Delete All) gate on a
SwiftUI `.confirmationDialog` so the user has to deliberately
click the red button:

```swift
.confirmationDialog(
    "Delete every entry?",
    isPresented: $showingDeleteAllConfirmation,
    titleVisibility: .visible
) {
    Button("Delete All", role: .destructive) {
        Task { await viewModel.deleteAll() }
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("Wipes every recorded AI generator run from disk. This cannot be undone.")
}
```

`viewModel.deleteAll()` then calls
`store.deleteAll()` and reloads; failures land in
`viewModel.state = .error(...)` which the sheet's state banner
renders.

The same flow is reachable from Preferences → Advanced. The
"AI Generator History" section's "Wipe All Generator History"
button prompts the user with an `NSAlert` (so the user can
cancel with the keyboard), then calls
`AIGeneratorHistoryStoreFactory.makeDefault().deleteAll()` and
surfaces a "Wiped N entries." / "Wipe failed: …" toast inline.

## 5. Follow-ups (deferred)

- **Re-generate wiring.** v1's "Re-generate" button closes the
  history window and re-opens the M2 sheet; the M2 sheet does
  not yet accept a pre-filled `request`. The plumbing
  (`PluginGeneratorMenuCommand.presentSheet(appDelegate:)`) was
  generalised to take an explicit app delegate so a future
  change can plumb the pre-filled request through. The
  detail-pane copy is a workaround for the missing
  plumbing — the user can copy / paste from there.
- **`menuTreeJSON` population.** The record hook passes
  `menuTreeJSON: nil`; the generator's sandboxed dry-run will
  populate this in a future round. The sheet's detail pane
  already has a slot for the menu preview; a follow-up can
  render it without changing the data layer.
- **Audit-log export.** A future "Export history as JSON"
  button in the sheet's footer would let users send the audit
  trail to support.

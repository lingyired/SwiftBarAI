# 2026-06-13: M2+ "Continue editing" mode for the AI plugin generator success view

- **Type:** feat
- **Scope:** `menubar01/UI/Plugin Generator/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Adds a "Continue editing" toggle to the M2 AI plugin generator
sheet's success view. When the user clicks it, the read-only
manifest / entry-script panels are replaced by two monospaced
`TextEditor` views — manifest JSON on the left, entry script
on the right — so the user can tweak the generator's output
in place. A new `AIGeneratorViewModel.saveEdits()` method
parses the edited manifest, builds a fresh `GeneratedPlugin`,
and replaces `latestPlugin` in place; `exitEditMode()` rolls
back the in-flight edits and restores the read-only view.
The existing "Save to Plugin Folder" and "Export…" footer
buttons keep working after an edit because they read from
`latestPlugin`, which the save path updates in place.

## Motivation

M2's success view shows the AI's output as read-only text
panels. In practice users want to nudge the result — change
the manifest's `refreshInterval`, swap a `bash=` parameter
key, tighten the `entry` filename — before saving. Today
they have to either re-generate (a full LLM round-trip that
often returns a different plugin entirely) or hand-edit the
JSON in a separate editor after the install. The new
"Continue editing" mode gives them a fast, in-sheet path
that does not touch the LLM: edit, save, install, export —
all in one flow.

The user can still re-generate (the existing
"Re-generate" / `regenerateWithVariation()` button is
preserved), so the two paths are complementary: re-generate
asks the LLM for a *variation*, continue-editing tweaks the
*current* output. The Edit button is hidden while edit mode
is active so a stray double-click does not re-snapshot the
user's half-finished edits.

## Changes

### Edited files

- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`:
  edit. New `@Published private(set) var isEditing: Bool`
  flag (next to `isImproving` / `isStreaming` /
  `isRegenerating`), a `@Published private(set) var
  editModeErrorMessage: String?` error surface, and two
  mutable buffers `@Published var editedManifestJSON:
  String` / `@Published var editedEntryScript: String`.
  New methods:

  - `enterEditMode()` — snapshots the current
    `latestPlugin.manifest` as pretty-printed JSON into
    `editedManifestJSON` and copies `entryScript` into
    `editedEntryScript`, then flips `isEditing` to `true`.
    No-op when `latestPlugin` is `nil` (the edit mode only
    makes sense after a successful generation) or when
    `isEditing` is already `true` (so a stray double-click
    does not clobber the user's in-progress edits).
  - `exitEditMode()` — clears both buffers, flips
    `isEditing` back to `false`, and logs the cancellation
    through `os_log` at `.info`. No-op when `isEditing` is
    already `false`.
  - `saveEdits() async` — parses `editedManifestJSON`
    back into a `PluginManifest` via `JSONDecoder`. On
    parse failure sets `editModeErrorMessage` to a
    human-readable reason (`"Invalid manifest JSON: …"`)
    and logs through `os_log` at `.error`; the `state` /
    `latestPlugin` are left unchanged so the user keeps
    their previous read-only result. On success builds a
    new `GeneratedPlugin` (preserving `explanation`,
    `promptId`, `promptVersion` from the previous
    `latestPlugin`), replaces `latestPlugin`, transitions
    `state` to `.success(newPlugin)`, leaves edit mode,
    clears the buffers, records a fresh
    `AIGeneratorHistoryEntry` via the existing
    `recordHistory(...)` helper, and logs at `.info`.

  `reset()` was extended to clear the new editing state
  (`isEditing`, both buffers, and `editModeErrorMessage`)
  so a sheet that gets reset mid-edit does not leak the
  half-finished state.

- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`:
  edit. New "Continue editing" button in the success-view
  header (`regenerateHeader(for:)`), next to the existing
  "Re-generate" button and hidden while `isEditing` is
  `true` so a stray double-click does not re-snapshot the
  in-flight edits. The new `editSection` view (with
  `manifestEditor` and `entryScriptEditor` sub-views)
  replaces the read-only `manifestSection` and
  `entryScriptSection` while `isEditing` is `true`. The
  two editors are laid out side-by-side via `ViewThatFits`
  so they stack vertically on narrow viewports (sheet
  shrunk below ~700 pt) and stay side-by-side on wide
  ones. A new `editModeErrorBanner` renders a red banner
  with the most recent parse error above the editors when
  `editModeErrorMessage` is non-nil. The Save / Cancel
  row in `editSection` calls `viewModel.saveEdits()` and
  `viewModel.exitEditMode()` respectively. The existing
  "Save to Plugin Folder" and "Export…" footer buttons are
  unchanged — they read from `latestPlugin`, which
  `saveEdits()` updates in place, so editing + install /
  export remains a single, fluid flow.

### New test file (menubar01Tests target)

- `menubar01Tests/AIGeneratorEditTests.swift` — 4 new
  Swift Testing tests in 1 suite, all `@MainActor` and
  pure (no AppKit, no SwiftUI view graph, no filesystem):

  1. `testEnterEditMode_populatesBuffers` — after a
     successful `generate()` call, `enterEditMode()` flips
     `isEditing` to `true` and the two buffers mirror
     the current `latestPlugin.manifest` (as JSON) and
     `latestPlugin.entryScript`.
  2. `testSaveEdits_validJSON_updatesStateAndLatestPlugin`
     — after editing the manifest JSON in place to a
     valid (but different) `PluginManifest` and tweaking
     `editedEntryScript`, `saveEdits()` replaces
     `latestPlugin`, transitions `state` to
     `.success(newPlugin)`, leaves edit mode, and clears
     the buffers. The post-save `latestPlugin.manifest`
     matches the new JSON and `entryScript` matches the
     new buffer.
  3. `testSaveEdits_invalidJSON_setsErrorAndPreservesState`
     — with `editedManifestJSON` set to broken JSON
     (`"{"`), `saveEdits()` does **not** transition
     `state` (it stays in the previous `.success(plugin)`),
     does **not** replace `latestPlugin`, and sets
     `editModeErrorMessage` to a non-nil string.
  4. `testExitEditMode_clearsBuffersAndFlag` — after
     entering edit mode, `exitEditMode()` flips
     `isEditing` back to `false` and clears both buffers
     to `""`.

  The new test file is auto-discovered by the
  `menubar01Tests` `PBXFileSystemSynchronizedRootGroup`
  and needs no pbxproj registration.

## Impact

- **New internal API surface:** the new
  `AIGeneratorViewModel.isEditing`,
  `editedManifestJSON`, `editedEntryScript`,
  `editModeErrorMessage` `@Published` properties and the
  new `enterEditMode()` / `exitEditMode()` /
  `saveEdits()` methods on `AIGeneratorViewModel`. None
  of these are `public`; they are consumed only by
  `AIGeneratorSheet` and the new test file.
- **User-visible behaviour change:** the M2 generator
  sheet's success view now renders a "Continue editing"
  button next to "Re-generate". Clicking it swaps the
  read-only manifest / entry-script panels for two
  monospaced `TextEditor` views. Save applies the edits
  in place and dismisses the editor; cancel discards the
  in-flight edits and restores the originals. A failed
  save surfaces a red error banner above the editors
  describing the parse error, and the read-only result
  stays available as a fallback.
- **No new entitlements**, no new dependencies, no new
  URL scheme handlers, no new AppIntents.
- **No new localisation keys.** The button label
  "Continue editing", the Save / Cancel labels, the
  "Editing manifest + entry script" header, and the
  "Save replaces the in-memory plugin; cancel discards
  edits." hint are hard-coded English strings, consistent
  with the rest of the M2 sheet copy. They can move into
  `Localizable.strings` in a follow-up alongside the rest
  of the M2 sheet.
- **No new SF Symbol assets.** The Edit button uses
  `pencil` (a system-provided SF Symbol available in
  macOS 12+). The Save button uses `checkmark.circle`.
  The error banner reuses `exclamationmark.triangle.fill`
  (already used by the generator-failure banner).

## Testing

4 new unit tests in
`menubar01Tests/AIGeneratorEditTests.swift` (Swift
Testing):

- `testEnterEditMode_populatesBuffers`
- `testSaveEdits_validJSON_updatesStateAndLatestPlugin`
- `testSaveEdits_invalidJSON_setsErrorAndPreservesState`
- `testExitEditMode_clearsBuffersAndFlag`

The new tests are pure (no AppKit, no SwiftUI view graph,
no filesystem, no real networking). They are `@MainActor`
and use a hand-rolled `CapturingMockAIPluginGenerator`
that mirrors the helper used by
`AIGeneratorViewModelTests` and
`AIGeneratorInstallPromptTests`.

## Related

- [`2026-06-13-ai-regenerate-with-variation.md`](2026-06-13-ai-regenerate-with-variation.md)
  — the M2+ "Re-generate" button. The new "Continue
  editing" button is the complementary "tweak the current
  output" affordance: re-generate asks the LLM for a
  *variation* of the previous result, continue-editing
  tweaks the *current* output without involving the LLM.
- [`2026-06-13-ai-plugin-export.md`](2026-06-13-ai-plugin-export.md)
  — the M2+ "Export…" footer button. The edit-mode save
  updates `latestPlugin` in place, so the "Export…"
  button exports the post-edit plugin without any extra
  wiring.
- [`2026-06-13-ai-improve-prompt.md`](2026-06-13-ai-improve-prompt.md)
  — the M2+ "Improve" footer button (rewrites the
  request, not the response). The new "Continue editing"
  button is the response-side equivalent: the user keeps
  the request and edits the response directly.

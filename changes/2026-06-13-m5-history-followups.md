# M5 — Generator History follow-ups

- **Type:** feat
- **Scope:**
  `menubar01/UI/Generator History/`,
  `menubar01/UI/Plugin Generator/`,
  `menubar01/AI/`,
  `menubar01Tests/AIGeneratorViewModelTests.swift`,
  `menubar01Tests/GeneratorHistoryExporterTests.swift`,
  `menubar01.xcodeproj/project.pbxproj`
- **Author(s):** Trae AI
- **Commit(s):** e033493
- **Status:** done

## Summary

Land the three M5 follow-ups the original `2026-06-13-m5-generator-history-ui.md`
record listed as deferred:

1. **Re-generate wiring.** The history sheet's "Re-generate" button
   now opens the M2 sheet with `viewModel.request` pre-populated
   from the selected entry's `request` column — no more
   copy / paste from the detail pane.
2. **`menuTreeJSON` population.** Every successful
   `AIGeneratorViewModel.generate()` call now records a non-nil
   `menuTreeJSON` (pretty-printed JSON `[AIGeneratorMenuNode]`
   array) when the entry script is parseable. The history sheet
   can later decode the bytes back into a tree for rendering.
3. **Audit-log export.** A new "Export…" button in the sheet's
   footer bundles the selected entry's on-disk audit log
   (`request.txt` + `response.json` + the optional `menu.json`)
   into a `.zip` via `/usr/bin/zip`, via an `NSSavePanel`
   destination prompt.

## Motivation

`changes/2026-06-13-m5-generator-history-ui.md` (commit 4075eb9)
ends with three explicit "Follow-ups (deferred to a future M5+
round)" bullets: re-generate wiring, `menuTreeJSON` population,
and audit-log export. This change closes all three at once so the
user-visible story ("audit / re-generate / share") is complete
without a fourth round-trip to the history sheet.

## Changes

### New source files (menubar01 main target)

- `menubar01/AI/AIGeneratorMenuNode.swift` — new
  `public struct AIGeneratorMenuNode: Codable, Equatable, Sendable`
  with three fields (`title: String`, `href: String?`,
  `children: [AIGeneratorMenuNode]`) and a `static func
  parseEntryScript(_:) -> [AIGeneratorMenuNode]?` synthetic
  parser that walks the script line-by-line, strips shell
  `echo "..."` wrappers, extracts an optional `href=…`
  parameter, and returns `nil` for unparseable input (empty
  scripts, comments only, etc.).
- `menubar01/UI/Generator History/GeneratorHistoryExporter.swift`
  — new helper that runs the actual `/usr/bin/zip` invocation
  and returns a typed `GeneratorHistoryExportResult` enum
  (`.success(destination:)` / `.cancelled` /
  `.missingDirectory(reason:)` / `.zipFailed(reason:)` /
  `.launchFailed(reason:)`). Lives in its own file (rather than
  in the SwiftUI sheet) so the view stays a pure renderer and
  the export logic is unit-testable from the test bundle
  without booting an `NSHostingController` / `NSSavePanel`.

### New test file (menubar01Tests target)

- `menubar01Tests/GeneratorHistoryExporterTests.swift` — 5 new
  Swift-Testing tests:
  - `testRootDirectory_returnsConstructionPath`
  - `testRootDirectory_defaultForProtocol`
  - `testExport_writesNonEmptyZipAndExitsZero`
  - `testExport_zipContainsRequestAndResponseFiles`
  - `testExport_runZipFailsWhenSourceDirectoryIsMissing`

  Uses the per-test temp-dir pattern from
  `AIGeneratorHistoryStoreTests` and a per-test `TempStore`
  helper that owns the lifecycle of one
  `FileSystemAIGeneratorHistoryStore` rooted at a temp path.

### Edited files

- `menubar01/UI/Plugin Generator/PluginGeneratorMenuCommand.swift`
  — adds a `prefillRequest: String? = nil` parameter to the
  existing `presentSheet(appDelegate:)` overload. When non-nil,
  the window controller's hosting controller is rebuilt with a
  fresh `AIGeneratorViewModel` whose `request` is the supplied
  string, so the user lands in a sheet that already has their
  pre-filled text in the `TextEditor`.
- `menubar01/UI/Generator History/GeneratorHistoryMenuCommand.swift`
  — the `onRegenerate` closure now passes
  `prefillRequest: entry.request` to
  `PluginGeneratorMenuCommand.presentSheet(...)`, replacing
  the v1 comment that told the user to copy / paste from the
  detail pane.
- `menubar01/UI/Generator History/GeneratorHistorySheet.swift`
  — adds the "Export…" button to the footer (next to "Delete
  All" / "Delete" / "Re-generate" / "Close"). The button calls
  `GeneratorHistoryExporter.exportEntry(_:store:)`, which
  drives the `NSSavePanel` and the actual zip. The sheet's
  `exportEntry(_:)` private helper routes the typed result
  enum through a single `showAlert(title:message:)` UI.
- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift` —
  the `record-after-generate` hook in `generate()` now passes a
  non-nil `menuTreeJSON` to `historyStore.record(...)`. The
  hook is fed by a new `static func encodeMenuTree(from:) -> Data?`
  helper that calls
  `AIGeneratorMenuNode.parseEntryScript(...)` and pretty-prints
  the resulting `[AIGeneratorMenuNode]` as JSON. When the
  script is empty or only contains comments, the helper
  returns `nil` and the recorded entry's `menuTreeJSON` stays
  at its default `nil` value (matching the M5 v1 contract).
- `menubar01/AI/AIGeneratorHistoryStore.swift` — adds a
  `public var rootDirectory: URL { get }` accessor to the
  `AIGeneratorHistoryStore` protocol and a default
  protocol-extension implementation that falls through to
  `AIGeneratorHistoryStoreFactory.makeDefault().rootDirectory`.
  `FileSystemAIGeneratorHistoryStore` overrides it with the
  path it was actually constructed with. The previous
  `private let rootDirectory` is renamed to `_rootDirectory`
  so the public accessor can re-expose it without collision.
- `menubar01.xcodeproj/project.pbxproj` — registers the two
  new main-target sources (`AIGeneratorMenuNode.swift` and
  `GeneratorHistoryExporter.swift`). The new test file
  auto-discovers via `PBXFileSystemSynchronizedRootGroup`.

### Re-generate wiring summary

```
GeneratorHistorySheet "Re-generate" button
    └─ onRegenerate(entry)                                  (sheet)
         └─ PluginGeneratorMenuCommand.presentSheet(
                 appDelegate: appDelegate,
                 prefillRequest: entry.request              (NEW)
             )
              └─ viewModel.request = prefillRequest ?? ""   (NEW)
               └─ rebuild NSHostingController with the prefilled VM
```

The prefill is a 1-line code change at the closure in
`GeneratorHistoryMenuCommand.swift`. The new optional
parameter on `presentSheet(...)` is the only API addition.

## Impact

- **User-visible.**
  - The history sheet's "Re-generate" button now opens the M2
    sheet pre-populated with the original request, so the user
    does not have to copy / paste.
  - Every successful `generate()` now records a non-nil
    `menuTreeJSON` for parseable scripts. The history sheet
    can later surface a "Render menu preview" detail pane by
    decoding the bytes — the encoding contract is the
    `[AIGeneratorMenuNode]` JSON array documented above.
  - A new "Export…" button bundles the selected entry's
    on-disk audit log into a `.zip` for sharing with support.
- **Internal.** Two new public API surfaces on the
  `menubar01` module:
  - `public struct AIGeneratorMenuNode: Codable, Equatable, Sendable`
    (and its `static func parseEntryScript(_:)`).
  - `AIGeneratorHistoryStore.rootDirectory: URL { get }`
    (protocol-level accessor with a default extension
    fallback).
  Plus an `internal enum GeneratorHistoryExporter` and
  `internal enum GeneratorHistoryExportResult` consumed by
  both the SwiftUI sheet and the test bundle. None of these
  break the existing `AIGeneratorViewModel` / history-store
  API surface.

### `menuTreeJSON` encoding contract

The bytes written to `AIGeneratorHistoryEntry.menuTreeJSON`
are the `JSONEncoder`-serialized form of `[AIGeneratorMenuNode]`,
with the following settings:

- `outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`

Field semantics (mirrors the public subset of `MenuItemNode`):

- `title: String` — user-facing title, sourced from the line
  text of the entry script after stripping the surrounding
  `echo "..."` shell wrapper and the `key=value` parameter
  block.
- `href: String?` — optional `href=` parameter from the line,
  when the entry script produced a link-style menu item. `nil`
  for plain text items.
- `children: [AIGeneratorMenuNode]` — nested submenu children.
  v1 always emits an empty `children` array; a future round
  can populate it once a real sandboxed dry-run of the entry
  script is in place.

When the entry script is empty or only contains blank lines /
comments, the recording hook leaves `menuTreeJSON` at its
default `nil` value (matching the M5 v1 contract).

### Export flow

```
User clicks "Export…" in the history sheet's footer
  ↓
GeneratorHistorySheet.exportEntry(entry)
  ↓
GeneratorHistoryExporter.exportEntry(entry, store: viewModel.store)
  ↓
NSSavePanel.runModal()                                       (UI modal)
  ↓
GeneratorHistoryExporter.runZip(sourceDirectory:, destination:)
  ↓
/usr/bin/zip -r <destination> .                             (Process)
  ↓
GeneratorHistoryExportResult enum
  ↓
NSAlert "Exported" / "Export failed"                        (UI)
```

The `sourceDirectory` is
`store.rootDirectory.appendingPathComponent(entry.promptId)`.
The store writes `request.txt`, `response.json`, and (when
populated) `menu.json` to that directory; zipping `.` from
that cwd is enough to bundle the whole audit log. The
`/usr/bin/zip` binary ships with macOS 12+; no SwiftPM
dependency is needed.

## Testing

8 new tests across 2 files:

- `menubar01Tests/AIGeneratorViewModelTests.swift` →
  `AIGeneratorViewModelMenuTreeJSONTests` (3 tests):
  - `testGenerate_populatesMenuTreeJSONForParseableScript`
  - `testGenerate_menuTreeJSONContainsHrefFromParameters`
  - `testGenerate_menuTreeJSONIsNilForUnparseableScript`
- `menubar01Tests/GeneratorHistoryExporterTests.swift` (5 tests):
  - `testRootDirectory_returnsConstructionPath`
  - `testRootDirectory_defaultForProtocol`
  - `testExport_writesNonEmptyZipAndExitsZero`
  - `testExport_zipContainsRequestAndResponseFiles`
  - `testExport_runZipFailsWhenSourceDirectoryIsMissing`

Full suite: 264 tests, 0 failing.

## Related

- M5 history UI (4075eb9) —
  `GeneratorHistorySheet`, `GeneratorHistoryViewModel`,
  `GeneratorHistoryMenuCommand`,
  `AIGeneratorViewModel.record-after-generate` hook.
- M5 data layer (f2a1cf4) —
  `AIGeneratorHistoryEntry.menuTreeJSON` field,
  `AIGeneratorHistoryStore` protocol, `FileSystemAIGeneratorHistoryStore`.
- M2 sheet (8f11372) — `AIGeneratorViewModel` /
  `AIGeneratorSheet` / `PluginGeneratorMenuCommand`.
- `docs/M5-generator-history-ui.md` — updated with a small
  "Follow-up items landed" section linking to this record.

# 2026-06-13: "Export…" button saves the generated plugin as a zip

- **Type:** feat
- **Scope:**
  `menubar01/UI/Plugin Generator/AIGeneratorExporter.swift`,
  `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`,
  `menubar01Tests/AIGeneratorExporterTests.swift`,
  `menubar01.xcodeproj/project.pbxproj`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

The M2 AI generator sheet's success view now exposes an
"Export…" button next to "Save to Plugin Folder". Clicking
it presents an `NSSavePanel`, stages the generated plugin
(manifest.json + entry script) in a per-call temp directory,
runs `/usr/bin/zip -r <destination> .` from the staging dir,
reveals the resulting zip in Finder, and surfaces a single
success / failure `NSAlert`. The zip contains the two files
at the archive root, so the user can unzip it directly into
a plugin folder of their choosing and the files land at the
plugin folder's top level — exactly the layout that
`PluginManager.installGeneratedPlugin(_:)` writes today.

## Motivation

Today, the only way to keep a generated plugin outside the
app's own `_generated/` staging tree is to install it
through the install-prompt sheet, which writes to
`<plugin-dir>/_generated/<promptId>/`. Power users who want
to share a generated plugin with a friend, commit it to a
git repo, or push it through the Plugin Marketplace flow
have no way to get the raw `(manifest.json, entry script)`
pair out of menubar01. The "Export…" button closes that
loop and matches the export pattern already established by
`GeneratorHistoryExporter.exportEntry(_:store:)` (M5
history).

The chosen layout — files at the zip root, not inside a
`<plugin-name>/` subfolder — matches the v1 install layout
produced by `PluginManager.installGeneratedPlugin(_:)` and
means the export is a true round-trip: unzip into an empty
folder, point the user's Plugin Folder at it, and the
plugin loads. A nested layout would force the user to
unwrap an extra level on the receiving end and could
collide with names that already exist on disk.

## Changes

### `menubar01/UI/Plugin Generator/AIGeneratorExporter.swift`

- New file. Houses the v1 export pipeline so the SwiftUI
  sheet stays a pure renderer and the test bundle can
  exercise the zip path without driving an `NSSavePanel`.
- Public `enum AIGeneratorExportResult` (cases:
  `.success(destination:)`, `.cancelled`, `.writeFailed(reason:)`,
  `.zipFailed(reason:)`, `.launchFailed(reason:)`).
  Modelled as an `enum` (mirroring
  `GeneratorHistoryExportResult`) so the SwiftUI sheet can
  route the result to a single alert without duplicating
  error-string plumbing.
- `public static func writeToTempDir(_ plugin: GeneratedPlugin) throws -> URL`:
  creates a per-call UUID-suffixed temp directory under
  `FileManager.default.temporaryDirectory`, writes
  `manifest.json` (encoded with `JSONEncoder`) and the
  entry script at the staging dir's root using
  `plugin.manifest.entry ?? "plugin.sh"` as the script
  filename. The caller is responsible for cleaning up the
  temp dir; the production path defers the cleanup, the
  test path defers it from its own `defer` block. The
  contract matches the v1 install format that
  `PluginManager.installGeneratedPlugin(_:)` writes
  (`manifest.json` + `<entry>` at the folder root), so a
  successful export unzips into a valid plugin folder.
- `public static func exportPlugin(_ plugin: GeneratedPlugin) -> AIGeneratorExportResult`:
  the UI entry point, marked `@MainActor` (the only AppKit
  call is `NSSavePanel.runModal()`). Shows the
  `NSSavePanel` with a default filename of
  `<pluginName>.zip`, stages the plugin in a temp dir,
  runs the zip, and defers cleanup of the temp dir to
  guarantee it lands in the trash even when the zip fails
  mid-flight. A `.cancelled` save-panel dismissal is
  short-circuited before any temp dir is created.
- `public static func runZip(sourceDirectory:destination:)`:
  runs `/usr/bin/zip -r <destination> .` from
  `sourceDirectory` (which becomes the archive's root
  after the `zip -r .` invocation, so `manifest.json` and
  the entry script land at the zip's top level). Exposed
  publicly so the test bundle can drive the same code
  path the UI does, but with a known destination file
  rather than a user-driven `NSSavePanel`. Calls a private
  `revealInFinder(_:)` helper on the success branch (same
  pattern as
  `GeneratorHistoryExporter.runZip(...)` after the M5
  follow-up).
- `static func entryFilename(for: GeneratedPlugin) -> String`:
  mirrors the entry-filename fallback in
  `GeneratedPlugin.encodedAsBundle()` — `plugin.manifest.entry`
  when non-empty, otherwise `"plugin.sh"`. Centralised so
  the staging temp dir's entry filename and the install
  path's entry filename stay byte-identical.
- Private `enum AIGeneratorExportError` with a single
  `.entryEncodingFailed` case. Exists so
  `writeToTempDir(_:)`'s `throws` contract is total; in
  practice `GeneratedPlugin.entryScript` is always a
  `String` so the `String.data(using: .utf8)` conversion
  cannot fail.

### `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`

- New `import AppKit` (was just `import SwiftUI`) so the
  post-export alert can construct an `NSAlert`.
- New `@State private var exportAlert: ExportAlert?`
  backing the post-export alert. `nil` means no alert is
  shown; a non-nil value is rendered as a modal `NSAlert`
  on the main run loop by the new
  `.onChange(of: exportAlert)` modifier.
- New `Button("Export…")` in the success-view footer
  (between "Re-generate" and "Save to Plugin Folder").
  Only rendered when `viewModel.latestPlugin != nil` so it
  never collides with the empty-state "Generate" button.
  Click handler delegates to the new `runExport()` helper.
- New private `runExport()` helper that captures the
  current `viewModel.latestPlugin` and delegates to
  `AIGeneratorExporter.exportPlugin(_:)`. The four result
  cases route to a single `exportAlert` state — `.success`
  populates an `ExportAlert(title: "Exported", ...,
  style: .informational)`, the three failure cases
  populate an `ExportAlert(title: "Export failed", ...,
  style: .warning)`, and `.cancelled` is a silent no-op.
- New `.onChange(of: exportAlert)` modifier on the body
  that constructs an `NSAlert` and shows it modally. The
  modifier resets `exportAlert` back to `nil` after the
  alert returns so the next export can re-arm the alert.
  We use `.onChange` (rather than rendering the alert in
  the view body) because `NSAlert.runModal()` is a
  blocking call — calling it directly from the body would
  freeze the SwiftUI render loop.
- New `struct ExportAlert: Equatable` at file scope, with
  an inner `enum Style` (`.informational` / `.warning`).
  Lives outside the `View` so the `.onChange` modifier can
  fire exactly once per non-nil transition (the
  `Equatable` conformance is what makes the modifier
  fire on real changes, including the `nil → ExportAlert`
  one).

### `menubar01Tests/AIGeneratorExporterTests.swift`

- New file. 5 Swift-Testing tests in 2 suites, all
  hermetic (per-test temp dir + `defer` cleanup) and
  parallel-safe (UUID-suffixed staging paths):
  1. `testWriteToTempDir_createsManifest` — staging dir
     exists, `manifest.json` is at the staging dir's
     root, and the dir name carries the expected
     `menubar01-export-` prefix.
  2. `testWriteToTempDir_createsEntryScript` — entry
     script lands at the staging dir's root under the
     manifest-declared filename; the on-disk body
     contains the test's `entryScript` payload.
  3. `testWriteToTempDir_entryScriptIsExecutable` —
     POSIX permissions on the entry script have at least
     one execute bit set (matches the `chmod +x` step
     `PluginManager.installGeneratedPlugin(_:)` performs
     on install).
  4. `testWriteToTempDir_emptyManifestName_usesFallback`
     — a `nil` `manifest.name` round-trips through the
     encoder without crashing; the entry script still
     lands at the manifest-declared filename. (The name
     fallback's downstream effect is the save panel
     default filename in `exportPlugin(_:)`; the test
     asserts on the encoder's behaviour because that is
     the testable surface.)
  5. `testExportPlugin_zipSucceeds_writesValidZip` — full
     flow without an `NSSavePanel`: stage via
     `writeToTempDir(_:)`, zip via `runZip(...)` to a
     known temp file, then probe the archive with
     `GeneratorHistoryExporter.listContents(ofZipAt:)` to
     confirm both `manifest.json` and the entry script
     are at the zip's root (no subfolder).
- The test bundle re-uses
  `GeneratorHistoryExporter.listContents(ofZipAt:)` to
  scrape the archive's table of contents. The helper is
  public-and-static, so the test bundle can reach it
  without adding a new test seam.

### `menubar01.xcodeproj/project.pbxproj`

- New `AIGeneratorExporter.swift` registered as a member
  of the project root group (mirrors the pattern used by
  `AIGeneratorSaveTemplateSheet.swift`, which lives in the
  same directory):
  - One `PBXFileReference` entry pointing at
    `menubar01/UI/Plugin Generator/AIGeneratorExporter.swift`.
  - Two `PBXBuildFile` entries — one per target
    (`menubar01` and `menubar01 MAS`), each pointing at
    the shared file reference. The IDs are unique to
    this change (24-hex characters, do not collide with
    any existing entry).
  - New file added to the project root group's
    `children` list, immediately after
    `AIGeneratorSaveTemplateSheet.swift`.
  - New `… in Sources` entry added to both `Sources`
    build phases (the `menubar01` non-MAS phase and the
    `menubar01 MAS` phase).
- The new `AIGeneratorExporterTests.swift` is
  auto-discovered by the `menubar01Tests`
  `PBXFileSystemSynchronizedRootGroup` and needs no
  pbxproj registration, matching the convention used by
  every other test file in the target.
- pbxproj verified well-formed via `plutil -lint`:
  `menubar01.xcodeproj/project.pbxproj: OK`.

## Impact

- **User-visible.** The M2 generator sheet's success
  view now renders an "Export…" button between
  "Re-generate" and "Save to Plugin Folder". Clicking it
  opens an `NSSavePanel` (default filename
  `<plugin-name>.zip`), writes a zip containing
  `manifest.json` + the entry script at the archive
  root, and reveals it in Finder via
  `NSWorkspace.shared.activateFileViewerSelecting(...)`.
  A success alert is shown on the main run loop
  ("Exported to <name>.zip. Finder has been opened to the
  file."). A failure alert is shown for any of the three
  error cases (`writeFailed`, `zipFailed`,
  `launchFailed`). A save-panel Cancel is a silent
  no-op.
- **Internal.** New public types `AIGeneratorExporter`
  (`enum`), `AIGeneratorExportResult` (`enum`), and
  `AIGeneratorExportError` (`enum`). New public methods
  on `AIGeneratorExporter`: `writeToTempDir(_:)`,
  `exportPlugin(_:)`, `runZip(sourceDirectory:destination:)`.
  The new `ExportAlert` value type on
  `AIGeneratorSheet.swift` is file-scope (not public)
  and only consumed by the sheet itself.
- **No new entitlements**, no new dependencies, no new
  URL scheme handlers, no new AppIntents.
- **No new localisation keys.** The alert copy
  ("Exported", "Export failed", "Exported to … Finder
  has been opened to the file.") mirrors the
  `GeneratorHistorySheet` success / failure alerts so
  the two export flows feel consistent. The "Export…"
  button label is the same as the M5 history sheet's
  export button.

## Testing

- 5 new unit tests in
  `menubar01Tests/AIGeneratorExporterTests.swift`. All
  are pure (no AppKit modals, no SwiftUI view graph)
  and run on a background queue because the suite does
  not touch `@MainActor` types directly — the
  `exportPlugin(_:)` entry point is `@MainActor`, but
  the tests cover the lower-level `writeToTempDir(_:)`
  and `runZip(...)` helpers.
- Verification: `xcodebuild … test` should report 0
  failures in the new file. The `menubar01Tests` target
  uses `PBXFileSystemSynchronizedRootGroup` so the new
  test file is auto-discovered without further pbxproj
  edits.
- No new view-test infra was introduced (the task spec
  did not call for SwiftUI rendering tests; the existing
  pattern in this project skips view-graph tests for
  sub-sheets). The alert plumbing is exercised by the
  manual user flow that prompted this change.

## Related

- [`2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md)
  — the M2 sheet that hosts the new "Export…" button.
- [`2026-06-13-m2-install-flow.md`](2026-06-13-m2-install-flow.md)
  — the `PluginManager.installGeneratedPlugin(_:)`
  layout this export mirrors.
- [`2026-06-13-history-export-reveal-in-finder.md`](2026-06-13-history-export-reveal-in-finder.md)
  — the M5 history sheet's "Export…" button + the
  `revealInFinder(_:)` helper this change re-uses.
- `AI_PLUGIN_ARCHITECTURE.md` §4 — design intent for
  the user-shareable plugin flow.

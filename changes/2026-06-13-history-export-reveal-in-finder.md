# Generator history export — reveal in Finder on success

- **Type:** feat
- **Scope:**
  `menubar01/UI/Generator History/GeneratorHistoryExporter.swift`,
  `menubar01/UI/Generator History/GeneratorHistorySheet.swift`,
  `menubar01Tests/GeneratorHistoryExporterTests.swift`
- **Author(s):** Trae AI
- **Commit(s):** _fill in after commit_
- **Status:** pending

## Summary

- `GeneratorHistoryExporter.runZip(...)` now calls
  `NSWorkspace.shared.activateFileViewerSelecting([destination])` on the
  main thread when the zip write succeeds, so Finder pops up with
  the new file highlighted.
- The history sheet's success alert is updated to mention the
  reveal.

## Impact

- macOS only. No code or test changes outside the exporter and the
  sheet's success banner.

## Motivation

The M5 history sheet's "Export…" button (introduced in
[`2026-06-13-m5-history-followups.md`](2026-06-13-m5-history-followups.md))
bundles the selected entry's on-disk audit log into a `.zip`
via `/usr/bin/zip`, and the user picks the destination through
an `NSSavePanel`. After the export, the user has to dig the file
out of wherever the panel put it. This change closes the loop
by activating Finder with the new zip pre-selected.

The reveal is a UX nicety, not a correctness requirement: the
zip is already on disk, and a failure to launch Finder (e.g.
`activateFileViewerSelecting` is a no-op) does not surface to
the caller. The `GeneratorHistoryExportResult` enum is
unchanged.

## Changes

### `menubar01/UI/Generator History/GeneratorHistoryExporter.swift`

- `runZip(sourceDirectory:destination:entry:)` gains a single new
  line on the success branch: a call to the new private
  `revealInFinder(_:)` helper, placed immediately before
  `return .success(destination: destination)` so a failed zip
  write still returns `.zipFailed(reason:)` /
  `.launchFailed(reason:)` without ever popping Finder.
- New private `static func revealInFinder(_ url: URL)` that:
  - Logs the reveal attempt at `.info` level via `os_log` using
    the existing `OSLog(subsystem: "com.lingyi.menubar01",
    category: "GeneratorHistory")` handle.
  - Dispatches `NSWorkspace.shared.activateFileViewerSelecting([url])`
    onto the main queue (`DispatchQueue.main.async`). The
    `NSWorkspace` call is documented to be safe from any
    thread, but the project keeps UI work on the main thread
    for consistency, and the `GeneratorHistoryExporter` type
    is not `@MainActor`-isolated.
- No new imports: `AppKit` and `os` are already imported.
- No new public API.

### `menubar01/UI/Generator History/GeneratorHistorySheet.swift`

- The `.success(destination:)` branch of the sheet's
  `exportEntry(_:)` helper now surfaces a slightly different
  message: `"Exported to <lastPathComponent>. Finder has been
  opened to the file."` instead of the v1
  `"Saved to <full path>"`.
- The alert still has a single "OK" dismiss button (no
  "Reveal in Finder" button existed to remove). The alert
  style remains `.informational` for the success case.
- A short comment above the success branch documents the new
  behaviour so a future reader does not "fix" the message
  back to the v1 form.

### `menubar01Tests/GeneratorHistoryExporterTests.swift`

- New `testRunZip_succeeds_doesNotThrow` test: sanity
  counterpart to the existing
  `testExport_writesNonEmptyZipAndExitsZero`, asserting that
  the happy-path source + destination round-trip returns
  `.success(destination:)`. This is the code path the new
  reveal call lives on, so a regression that broke the
  success branch would also break the UX follow-up.
- The test's docstring documents the deliberate omission of
  a `NSWorkspace.shared.activateFileViewerSelecting` assertion:
  `NSWorkspace` has no test seam (system singleton, no
  injection point in `GeneratorHistoryExporter`), and adding
  a protocol abstraction for a single one-liner would be
  over-engineering. The visible behaviour (Finder pops up)
  is a UX nicety, not a correctness requirement.

## Test count delta

- Before this change: 326 tests, 0 failing (baseline from
  [`2026-06-13-history-exporter-manifest.md`](2026-06-13-history-exporter-manifest.md)).
- After: 327 tests, 0 failing — +1 new test in
  `GeneratorHistoryExporterTests`.

## Related

- [`2026-06-13-m5-history-followups.md`](2026-06-13-m5-history-followups.md)
  — introduced `GeneratorHistoryExporter` and the "Export…"
  button that this UX polish closes the loop on.
- [`2026-06-13-history-exporter-manifest.md`](2026-06-13-history-exporter-manifest.md)
  — previous change to the same file, added the
  `MANIFEST.json` zip-root.
- `AI_PLUGIN_ARCHITECTURE.md` §4 — design intent for the
  per-entry audit log + the support-bundle flow.

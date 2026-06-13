# 2026-06-13: Marketplace Installed tab exposes a "View source" button

- **Type:** feat
- **Scope:** menubar01/UI/Marketplace Browser
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Add a per-row "View source" button to the marketplace browser's
Installed sidebar tab. The button opens the on-disk `manifest.json`
for the plugin in the user's default JSON editor (Xcode, TextEdit,
VS Code, etc.) via `NSWorkspace.shared.open(_:)`, so a user can
inspect a marketplace install's metadata without leaving the
browser sheet.

## Motivation

The M5 marketplace browser (`2026-06-13-m5-marketplace-browser.md`)
and its uninstall / update / toggle follow-ups surface
`name`, `version`, `lastUpdated`, and an "Update available" pill
in the Installed sidebar, plus a manifest JSON pane in the
detail column. But there is no shortcut to *open* the
on-disk `manifest.json` in the user's editor — a user who
wants to peek at (or copy fields from) the manifest has to
flip to Finder, navigate into the plugin folder, and
double-click the file. This change makes that one click.

## Changes

- `menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
  - Adds `import AppKit` (for `NSWorkspace`).
  - Adds `var viewSourceOpener: (URL) -> Void = { url in
    _ = NSWorkspace.shared.open(url) }`. The default
    delegates to `NSWorkspace.shared.open(_:)` so the
    system honours the user's default-app binding for
    `.json` files. The `var` (not `let`) follows the
    same injection pattern as `pluginCapabilityGate` so
    tests can swap the closure and intercept the call
    without the xctest host actually launching a JSON
    editor.
  - Adds `func viewSource(snapshot: InstalledPluginSnapshot)`
    that computes the on-disk manifest URL as
    `snapshot.url.appendingPathComponent(pluginManifestFileName)`,
    logs the path via `os_log` at `.info` level on
    `Log.plugin`, and delegates to `viewSourceOpener`.
    The method does not touch the
    `MarketplaceBrowserState` machine — viewing source
    is a regular in-app action that does not need a
    banner (mirroring the design of
    `toggleEnabled(for:)`).
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
  - Adds a small icon-only `Button` (`Image(systemName:
    "doc.text")`, `.borderless` style, `.mini` control
    size) to the bottom row of `installedRow(for:)`,
    placed between the trailing `Spacer` and the
    Enable / Disable `Toggle`. The button's `help`
    tooltip spells out the action
    ("View manifest.json for <name>"). The icon-only
    shape keeps the row compact and the toggle never
    gets pushed off the right edge on long folder
    names. Clicking the button calls
    `viewModel.viewSource(snapshot: snapshot)`.
- `menubar01Tests/MarketplaceBrowserViewSourceTests.swift`
  - New file with 3 Swift Testing tests:
    1. `testViewSource_invokesOpenerWithManifestURL`
       — stages a marketplace install, builds a real
       `InstalledPluginSnapshot` via
       `refreshInstalledPlugins()`, injects a
       recording opener, calls `viewSource(snapshot:)`,
       and asserts the opener was called exactly
       once with `installURL/manifest.json`.
    2. `testViewSource_injectedOpenerReplacesDefault`
       — calls `viewSource` twice with two
       different injected openers and verifies the
       second opener is the one called the second
       time (and saw the expected manifest URL).
    3. `testViewSource_doesNotMutateStateMachine` —
       captures a deep snapshot of `state`,
       `installedPlugins`, `entries`,
       `selectedEntry`, and `package`, calls
       `viewSource`, and asserts none of them
       change. The opener is verified to have
       been called.
  - The test file uses a per-test temp directory +
    per-test `UserDefaults(suiteName:)` (mirroring
    the `MarketplaceBrowserToggleEnabledTests`
    pattern) and a small `@MainActor`-bound
    `ViewSourceOpenerRecorder` helper class so the
    closures can mutate a counter without tripping
    Swift 6 strict-concurrency warnings around
    captured `var`s.

## Impact

- **User-visible behavior:** the Installed tab in the
  marketplace browser now shows a small "doc.text" icon
  button on every installed-plugin row. Clicking it
  opens the on-disk `manifest.json` in the user's
  default JSON editor. Disabled when no plugin is
  selected (no row to click).
- **New API surface:** `MarketplaceBrowserViewModel.viewSource(snapshot:)`
  and the internal `viewSourceOpener` dependency
  (mirroring the `pluginCapabilityGate` injection
  pattern).
- **No state-machine changes** — viewing source does
  not transition `MarketplaceBrowserState` and does
  not show a banner.

## Testing

`xcodebuild test -only-testing:menubar01Tests/MarketplaceBrowserViewSourceTests`
— all 3 new tests pass cleanly. The full suite
(`xcodebuild test -only-testing:menubar01Tests`) runs
the new 3 tests in addition to the existing ~424
tests; the 3 follow-up tests are isolated per-test
via `UserDefaults(suiteName:)` and the injected
opener closure, so they do not touch any
pre-existing flakiness surface.

## Related

- Builds on the M5 marketplace browser surface
  (`2026-06-13-m5-marketplace-browser.md`) and the
  Installed tab follow-ups
  (`2026-06-13-marketplace-uninstall-and-update.md`,
  `2026-06-13-marketplace-installed-toggle.md`,
  `2026-06-13-marketplace-update-detection.md`).
- Mirrors the editor-open pattern in
  `menubar01/UI/Preferences/PluginDetailsView.swift:143`
  and `menubar01/MenuBar/MenuBarItem.swift:1870`
  (both call `NSWorkspace.shared.open(_:)` directly).

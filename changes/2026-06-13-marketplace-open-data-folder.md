# 2026-06-13: Marketplace Installed tab exposes an "Open data folder" button

- **Type:** feat
- **Scope:** menubar01/UI/Marketplace Browser
- **Author(s):** Trae AI
- **Commit(s):** 38b976d
- **Status:** done

> **Status: done** — the original "partial" status was
> caused by a pre-existing signal-abrt cascade in the
> `menubar01Tests` parallel test runner. The cascade is
> resolved in
> [`2026-06-14-fix-integration-test-flake.md`](2026-06-14-fix-integration-test-flake.md)
> (commit `8c6594b`): the 3 new tests pass in isolation
> and the full suite now passes 5/5 consecutive runs.
> The signal-abrt crashes were the same pre-existing
> `xctest` host issue documented in
> [`2026-06-13-marketplace-open-data-folder-test-flake.md`](2026-06-13-marketplace-open-data-folder-test-flake.md),
> which is now closed.

## Summary

Add a per-row "Open data folder" button to the marketplace
browser's Installed sidebar tab. The button reveals the
on-disk per-plugin data directory in Finder (creating the
directory on demand if it does not exist yet) via
`NSWorkspace.shared.activateFileViewerSelecting(_:)`, so a
user can inspect (or wipe) a marketplace install's state,
cache, and `vars.json` without leaving the browser sheet.

## Motivation

The M5 marketplace browser (`2026-06-13-m5-marketplace-browser.md`)
and its Installed tab follow-ups surface `name`, `version`,
`lastUpdated`, an "Update available" pill, a manifest JSON
pane, plus a "View source" button (per
[`2026-06-13-marketplace-view-source.md`](2026-06-13-marketplace-view-source.md))
on the Installed sidebar. But there is no shortcut to
*open* the per-plugin data directory — the
`~/Library/Application Support/menubar01/Plugins/<plugin-id>/`
location the running plugin receives as
`$MENUBAR01_PLUGIN_DATA_PATH` (see
[`README-MANIFEST-PLUGINS.md`](../../README-MANIFEST-PLUGINS.md)
and the `MENUBAR01_PLUGIN_DATA_PATH` entry in
[`CLAUDE.md`](../../CLAUDE.md)). A user who wants to peek at
the data dir, drop in a `vars.json`, or wipe a corrupt
state file has to flip to Finder, navigate deep into
`~/Library/Application Support/menubar01/Plugins/`, and
hunt for the right symlink-resolved plugin folder. This
change makes that one click.

The directory is created on demand so a brand-new install
(the user has never run the plugin) still has a target for
Finder to highlight — the directory layout
(`AppShared.dataDirectory/<plugin-id>/`) is what the
running plugin will eventually create itself, so the
reveal target matches what would be on disk after the
first run.

## Changes

- `menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
  - Adds `var openDataFolderRevealer: ([URL]) -> Void =
    { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) }`.
    The default delegates to
    `NSWorkspace.shared.activateFileViewerSelecting(_:)`
    so Finder pops up with the per-plugin data directory
    pre-selected. The closure is `([URL]) -> Void`
    (matching the `NSWorkspace` signature) so a future
    "reveal both the plugin folder and the data folder
    side-by-side" follow-up can be added without breaking
    the injection seam. The `var` (not `let`) follows the
    same injection pattern as `viewSourceOpener` /
    `pluginCapabilityGate` so tests can swap the closure
    and intercept the call without the xctest host
    actually launching Finder.
  - Adds `func openDataFolder(snapshot: InstalledPluginSnapshot)`
    that:
    1. Resolves the per-plugin data directory URL via the
       new private `dataDirectoryURL(for:)` helper (the
       same `<AppShared.dataDirectory>/<symlink-resolved
       snapshot path>/` location the running plugin
       receives as `$MENUBAR01_PLUGIN_DATA_PATH`).
    2. Creates the directory with
       `FileManager.createDirectory(at:withIntermediateDirectories: true)`
       so Finder always has a target to highlight. A
       creation failure (permissions, read-only volume, …)
       is logged at `.error` level on `Log.plugin` and the
       reveal is skipped — the user is not shown a banner
       because opening a data folder is a regular in-app
       action (mirroring the design of
       `viewSource(snapshot:)` and `toggleEnabled(for:)`).
    3. Logs the resolved path at `.info` level on
       `Log.plugin` and delegates to
       `openDataFolderRevealer([dataURL])`.
    The method does not touch the
    `MarketplaceBrowserState` machine — opening a data
    folder is a regular in-app action that does not need
    a banner.
  - Adds `private func dataDirectoryURL(for:)` that
    returns
    `AppShared.dataDirectory?.appendingPathComponent(snapshot.url.resolvingSymlinksInPath().path, isDirectory: true)`.
    The symlink-resolved path matches the `id` that
    `FolderPlugin.init(manifestDirectory:manifest:)`
    writes, so the directory the user reveals is exactly
    the directory the running plugin writes to via
    `$MENUBAR01_PLUGIN_DATA_PATH`.
  - No new imports: `AppKit` and `os` are already
    imported.
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
  - Adds a small icon-only `Button`
    (`Image(systemName: "folder")`, `.borderless` style,
    `.mini` control size) to the bottom row of
    `installedRow(for:)`, placed immediately after the
    "View source" button. The button's `help` tooltip
    spells out the action
    ("Open data folder for <name>"). The icon-only
    shape matches the sibling "View source" button so the
    two actions cluster on the trailing edge of the row;
    the Enable / Disable `Toggle` stays on its own
    trailing line so a long folder name never pushes it
    off the right edge of the sidebar. Clicking the
    button calls
    `viewModel.openDataFolder(snapshot: snapshot)`.
- `menubar01Tests/MarketplaceBrowserOpenDataFolderTests.swift`
  - New file with 3 Swift Testing tests:
    1. `testOpenDataFolder_revealerSeesDataDirectoryAndCreatesIt` —
       stages a marketplace install, builds a real
       `InstalledPluginSnapshot` via
       `refreshInstalledPlugins()`, injects a recording
       revealer, calls `openDataFolder(snapshot:)`, and
       asserts the revealer was called exactly once with
       a single-element array pointing at the expected
       `<AppShared.dataDirectory>/<resolved snapshot path>/`
       URL. Also asserts the directory exists on disk
       after the call (the VM is responsible for `mkdir
       -p`) and that the path encodes the symlink-
       resolved install path (not the original temp-dir
       path) so the test is stable across macOS's
       `/private/var/...` symlink prefix.
    2. `testOpenDataFolder_injectedRevealerReplacesDefault` —
       calls `openDataFolder` twice with two different
       injected revealers and verifies the second
       revealer is the one called the second time (and
       saw the expected data directory URL). The first
       revealer must NOT be called again — swapping the
       seam is observable.
    3. `testOpenDataFolder_doesNotMutateStateMachine` —
       captures a deep snapshot of `state`,
       `installedPlugins`, `entries`, and
       `selectedEntry`, calls `openDataFolder`, and
       asserts none of them change. The revealer is
       verified to have been called.
  - The test file uses a per-test temp directory +
    per-test `UserDefaults(suiteName:)` (mirroring the
    `MarketplaceBrowserViewSourceTests` pattern) and a
    small `@MainActor`-bound
    `OpenDataFolderRevealerRecorder` helper class so the
    closures can mutate a counter without tripping
    Swift 6 strict-concurrency warnings around captured
    `var`s. The created data directories are cleaned up
    in `defer` so the test bundle's
    `~/Library/Application Support/<bundleName>/Plugins/`
    is not littered with test artefacts. Tests skip
    assertions gracefully if `AppShared.dataDirectory`
    cannot be resolved by the test bundle.

## Impact

- **User-visible behavior:** the Installed tab in the
  marketplace browser now shows a small "folder" icon
  button on every installed-plugin row, placed next to
  the "doc.text" "View source" button. Clicking it
  reveals the per-plugin data directory in Finder,
  creating the directory on demand. No effect when no
  plugin is selected.
- **New API surface:**
  `MarketplaceBrowserViewModel.openDataFolder(snapshot:)`,
  the private
  `MarketplaceBrowserViewModel.dataDirectoryURL(for:)`,
  and the internal `openDataFolderRevealer` dependency
  (mirroring the `viewSourceOpener` injection pattern).
- **Disk side effect:** calling
  `openDataFolder(snapshot:)` for a brand-new install
  whose data directory does not yet exist will create
  `<AppShared.dataDirectory>/<plugin-id>/` on disk. This
  is the same directory the running plugin will create on
  its first invocation, so the side effect is observable
  only in the timing of directory creation — the contents
  are still empty until the plugin writes to it.
- **No state-machine changes** — opening a data folder
  does not transition `MarketplaceBrowserState` and does
  not show a banner.

## Testing

`xcodebuild test -only-testing:menubar01Tests/MarketplaceBrowserOpenDataFolderTests`
— all 3 new tests pass cleanly. The full suite
(`xcodebuild test -only-testing:menubar01Tests`) runs
the new 3 tests in addition to the existing suite; the 3
follow-up tests are isolated per-test via
`UserDefaults(suiteName:)` and the injected revealer
closure, so they do not touch any pre-existing flakiness
surface.

## Related

- Builds on the M5 marketplace browser surface
  ([`2026-06-13-m5-marketplace-browser.md`](2026-06-13-m5-marketplace-browser.md))
  and the Installed tab follow-ups
  ([`2026-06-13-marketplace-uninstall-and-update.md`](2026-06-13-marketplace-uninstall-and-update.md),
  [`2026-06-13-marketplace-installed-toggle.md`](2026-06-13-marketplace-installed-toggle.md),
  [`2026-06-13-marketplace-update-detection.md`](2026-06-13-marketplace-update-detection.md),
  [`2026-06-13-marketplace-view-source.md`](2026-06-13-marketplace-view-source.md)).
- Mirrors the reveal-in-Finder pattern in
  `menubar01/UI/Plugin Generator/AIGeneratorExporter.swift:224`
  and
  `menubar01/UI/Generator History/GeneratorHistoryExporter.swift:180`
  (both call
  `NSWorkspace.shared.activateFileViewerSelecting([url])`
  via a private helper).
- The data directory layout the button reveals is
  documented in [`CLAUDE.md`](../../CLAUDE.md) under
  "Environment Variables" (`MENUBAR01_PLUGIN_DATA_PATH`)
  and implemented in
  `menubar01/Plugin/Plugin.swift:144` /
  `menubar01/AppShared.swift:292`.

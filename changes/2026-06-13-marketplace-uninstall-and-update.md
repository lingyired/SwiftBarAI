# 2026-06-13 — Marketplace uninstall & update

Status: done
Commit: <backfilled by `git commit` after tests pass>

## Summary

The M5 marketplace browser shipped in
[`2026-06-13-m5-marketplace-browser.md`](2026-06-13-m5-marketplace-browser.md)
with **install only**. This change adds the symmetric flow:

- **Uninstall** — a path-safety-gated `removeItem(at:)` for
  marketplace installs, with a typed error type and a
  confirmation alert in the browser sheet.
- **Update** — a re-install with `overwriteExisting: true` so
  the marketplace-installed plugin can be refreshed to a newer
  version (catalogue row → newer `MarketplacePackage`) without
  the user having to uninstall + reinstall by hand.

Both flows are routed through the existing M3 capability
gate. The uninstall path does **not** revoke grants (grants
are keyed on `manifest.name`, a stable string the user picked
when they first installed the plugin; re-installing the same
plugin must inherit the previous grant set). The update path
runs `gate.verify(manifest:)` up-front so an update that asks
for a new capability the user has not yet granted is refused
with a typed `.planFailed(reason:)` — the user has to install
the v2 separately and accept the new capabilities in the
prompt sheet.

## User-visible changes

- The marketplace browser sheet now has a segmented control
  with two tabs: **Catalogue** (the existing M5 install UI)
  and **Installed** (the new management UI).
- The **Installed** tab lists every folder under
  `<pluginDirectory>/_marketplace/`, with name, version, last
  modification date, and a one-tap **Uninstall** / **Update**
  row.
- Tapping **Uninstall** shows a confirmation alert ("Uninstall
  `<pluginName>`? This will delete the plugin folder. The
  plugin will no longer appear in your menu bar.") — the
  alert's destructive button delegates to the new
  `PluginManager.uninstallMarketplacePlugin(at:)`.
- Tapping **Update** calls
  `PluginManager.updateMarketplacePluginWithCapabilityGate(entry:package:gate:)`,
  which re-installs the plugin in place with
  `overwriteExisting: true` and a no-op `prompt` closure. A
  transient success banner ("Updated to latest version.")
  surfaces the on-disk URL on success; the error banner
  surfaces the gate's refusal reason on failure.
- The tab refreshes on view appearance and after every
  install / uninstall / update round-trip, so the sidebar
  stays in sync with the file system without a manual
  refresh button.

## API surface

### New on `PluginManager`

- `public func uninstallMarketplacePlugin(at pluginURL: URL) -> Result<Void, UninstallMarketplacePluginError>`
- `public func updateMarketplacePlugin(entry: MarketplaceEntry, package: MarketplacePackage) -> Result<URL, InstallMarketplacePluginError>`
- `public func updateMarketplacePluginWithCapabilityGate(entry: MarketplaceEntry, package: MarketplacePackage, gate: PluginCapabilityGate = PluginCapabilityGate()) async -> Result<URL, InstallMarketplacePluginError>`
- `public static func marketplacePluginURL(pluginDirectoryURL: URL?, entryFilename: String) -> URL?` — helper that computes the on-disk folder URL for a given entry filename, so the view model does not duplicate the sanitisation rules.

### New error enum

`UninstallMarketplacePluginError` with four cases:

- `.pluginDirectoryUnavailable` — no Plugin Folder is set.
- `.notAMarketplacePlugin(reason:)` — the path is not rooted
  under `<pluginDirectory>/_marketplace/`, the path's
  components do not match the marketplace root, the target
  is not a directory, or the target's `manifest.json` is
  missing / unparseable. A single `reason` string covers the
  four sub-cases so the UI can show it verbatim.
- `.notFound(path:)` — the path is under `_marketplace/` but
  the file does not exist. Surfaced as a distinct case so
  the UI can show "already uninstalled" instead of a generic
  failure.
- `.removeFailed(reason:)` — `FileManager.removeItem(at:)`
  failed. `reason` is the underlying error's
  `localizedDescription`.

## Path-safety design

`uninstallMarketplacePlugin(at:)` is the only place in the
codebase that deletes a marketplace-installed folder, so it
is the canonical "is this a marketplace install?" gate. The
check has three layers:

1. **Component-wise path comparison.** Both the target URL
   and `<pluginDirectoryURL>/_marketplace/` are passed
   through `.standardizedFileURL`, then compared via
   `pathComponents`. The `pathComponents` walk defeats the
   classic "prefix collision" attack: a sibling like
   `<pluginDir>/_marketplace-evil/...` cannot slip through
   because the first differing component fails the equality
   test.
2. **Existence + directory check.** A `.notFound` is
   returned before the manifest check so a concurrent
   deletion (or a stale `Installed` tab) does not produce a
   generic failure.
3. **Manifest sanity check.** A folder whose
   `manifest.json` is missing or unparseable is refused with
   `.notAMarketplacePlugin(reason:)` and the corruption is
   `os_log`'d at error level so the diagnostic dump surfaces
   it. The M5 install path always writes a valid
   `manifest.json`; a missing one means the directory is
   either a hostile replacement or a partially-completed
   install, and deleting it is a side effect the user did not
   ask for.

## Test coverage

8 new tests in
[`menubar01Tests/PluginManagerMarketplaceUninstallTests.swift`](../menubar01Tests/PluginManagerMarketplaceUninstallTests.swift):

1. `testUninstall_removesDirectoryFromDisk` — happy path.
2. `testUninstall_nonMarketplacePath_isRefused` — path
   outside `_marketplace/` is refused.
3. `testUninstall_nonexistentPath_returnsNotFound` —
   `.notFound` is the typed error, not a generic failure.
4. `testUninstall_pathTraversalAttempt_isRefused` — a path
   with `..` runs that resolves OUTSIDE `_marketplace/` is
   refused after `.standardizedFileURL` resolution.
5. `testUninstall_emptyDirectory_succeeds` — uninstall a
   real install (only `manifest.json` on disk).
6. `testUninstall_persistedCapabilityGrant_remains` —
   uninstall does not revoke grants (the gate is keyed on
   `manifest.name`, a stable string).
7. `testUpdate_overwritesExistingPlugin` — v1 install, v2
   update, on-disk bytes are v2.
8. `testUpdate_gateRefusesAbandonedCapabilities_returnsFailure`
   — v1 grants `clipboard`, v2 asks for `clipboard` +
   `network`; gate refuses update with `.planFailed(reason:)`
   and v1 bytes are intact.

## Files changed

- `menubar01/Plugin/PluginManager+MarketplaceInstall.swift`
  — added `uninstallMarketplacePlugin(at:)`,
  `updateMarketplacePlugin(entry:package:)`,
  `updateMarketplacePluginWithCapabilityGate(entry:package:gate:)`,
  `marketplacePluginURL(pluginDirectoryURL:entryFilename:)`,
  and the `UninstallMarketplacePluginError` enum.
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
  — added `uninstallSelected()`,
  `updateSelectedWithCapabilityGate()`,
  `refreshInstalledPlugins()`, `InstalledPluginSnapshot`, the
  `uninstalling` / `uninstalled` / `updating` / `updated`
  state cases, and a `humanReadable(_:)` overload for the
  uninstall error type.
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
  — added the `Catalogue` / `Installed` segmented control,
  the `Installed` sidebar with one row per marketplace
  install, the uninstall confirmation alert, the install /
  update / uninstall detail pane, and the success / error
  banners.
- `menubar01Tests/PluginManagerMarketplaceUninstallTests.swift`
  — 8 new tests.

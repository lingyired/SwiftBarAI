# M5 enable/disable follow-up: marketplace Installed tab exposes a per-row toggle

Status: done

## Why

The M5 marketplace browser's Installed tab lists every
marketplace plugin on disk and exposes Uninstall / Update
actions, but the only way to *temporarily* disable a plugin
short of uninstalling it is to open `menubar01 → Toggle
Plugins` and untick the global checkbox. That is
discoverable but indirect — a user looking at "Echo" in the
Installed tab has no in-place affordance to flip it off
without leaving the marketplace surface. This change adds
a SwiftUI `Toggle` to each Installed row that calls the
existing `PluginManager.enablePlugin(plugin:)` /
`disablePlugin(plugin:)` helpers, so disable and re-enable
is a single click and the menu bar item is added/removed
on the next `pluginsDidChange()` pass — same plumbing the
legacy "Toggle Plugins" menu uses.

## What changed

### `InstalledPluginSnapshot` gains `isEnabled`

`menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
adds `let isEnabled: Bool` to `InstalledPluginSnapshot`
and populates it in `refreshInstalledPlugins()` via a
membership check against
`pluginManager.prefs.disabledPlugins`. The check uses the
folder's symlink-resolved path — the same key the
`FolderPlugin.id` getter writes, so a toggle that flips
`prefs.disabledPlugins` and a subsequent
`refreshInstalledPlugins()` always agrees on the snapshot
state. Defaults to `true` when `pluginManager` is `nil`
(test seam) or when the folder is not in the disabled
set.

### `MarketplaceBrowserViewModel.toggleEnabled(for:)`

New method on the view model. Looks the snapshot's URL
up in `pluginManager.plugins` by the symlink-resolved
folder path (the same key `FolderPlugin.id` /
`PreferencesStore.disablePlugin(_:)` / `enablePlugin(_:)`
use), and routes through the existing
`PluginManager.enablePlugin(plugin:)` /
`disablePlugin(plugin:)` helpers. Both helpers mutate
`prefs.disabledPlugins`, fire the
`disabledPluginsPublisher`, and trigger
`pluginsDidChange()` on the next main-queue pass — so
the `NSStatusItem` is created/torn down without the view
model having to duplicate any of that logic. Defensive
no-ops when no `pluginManager` is wired or when no
loaded `Plugin` matches the snapshot's folder path
(e.g. the user just installed the plugin and the loader
has not yet picked it up; the next
`refreshInstalledPlugins()` re-emits the snapshot with
the new preference). Logs are emitted via `os_log` at
info level so the diagnostic dump can show the
toggle reason.

The method does **not** change
`MarketplaceBrowserState` — enable / disable is a
regular in-app action that does not need a banner. The
state machine still owns the install / uninstall /
update flow.

### Installed-tab UI: SwiftUI `Toggle` + dim

`menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
adds a per-row `Toggle` (`.switch` style, `.mini`
control size) to the `installedRow(for:)` view. Bound
to a `Binding<Bool>` whose `get:` reads
`snapshot.isEnabled` and whose `set:` calls
`viewModel.toggleEnabled(for: snapshot)`. The row's
container applies `.opacity(snapshot.isEnabled ? 1.0 : 0.55)`
so a disabled row is visually dimmed while the toggle
stays interactive (macOS toggles do not inherit the
opacity modifier). The toggle's tooltip is
"Disable <name> without uninstalling" / "Enable <name>"
so the user knows the action does **not** remove the
plugin from disk.

### Tests

`menubar01Tests/MarketplaceBrowserToggleEnabledTests.swift`
is a new file with 5 Swift Testing tests:

1. `testInstalledSnapshot_isEnabledByDefault` — A
   freshly-staged marketplace install surfaces
   `isEnabled == true` from `refreshInstalledPlugins()`.
2. `testInstalledSnapshot_disabledAfterPrefSet` — When
   the folder's resolved path is in
   `prefs.disabledPlugins`, the snapshot's
   `isEnabled` flips to `false`.
3. `testToggleEnabled_disablesLoadedPlugin` — Loads
   the marketplace install via
   `manager.loadPlugin(fileURL:)`, injects the plugin
   into `manager.plugins`, builds a snapshot, calls
   `toggleEnabled(for:)`, and verifies the pref set
   now contains the folder path and the snapshot's
   `isEnabled` is `false`.
4. `testToggleEnabled_enablesDisabledPlugin` —
   Symmetric: pre-disable the plugin in the pref,
   then call `toggleEnabled(for:)` and verify the
   pref no longer contains the folder path and the
   snapshot is `enabled == true`.
5. `testToggleEnabled_noMatchingPluginIsNoOp` — A
   snapshot whose URL matches no loaded `Plugin`
   (no install staged) is a no-op — the
   `disabledPlugins` set is not mutated.

Each test uses a per-test
`UserDefaults(suiteName:)` so the prefs store is
isolated from the rest of the suite. The tests do
**not** invoke `manager.loadPlugins()` — they inject
the loaded `FolderPlugin` directly into
`manager.plugins` to avoid the `DirectoryObserver` /
`NSStatusItem` setup `loadPlugins()` would require.

## Verification

`xcodebuild test -only-testing:menubar01Tests/MarketplaceBrowserToggleEnabledTests`
— all 5 new tests pass cleanly.

The full suite (`xcodebuild test -only-testing:menubar01Tests`)
runs the new 5 tests in addition to the existing
~419. The 5 follow-up tests do not touch any
pre-existing flakiness surface; the marketplace test
infrastructure is isolated per-test via
`UserDefaults(suiteName:)`.

Status: done

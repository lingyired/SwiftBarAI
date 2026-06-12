# 2026-06-12: Icon rendering + folder-plugin loading + toggle scaffolding

- **Type:** fix + feat + refactor
- **Scope:** `SwiftBar/Utility/NSImage.swift`, `SwiftBar/MenuBar/MenuBarItem.swift`, `SwiftBar/AppDelegate.swift`, `SwiftBar/Plugin/PluginManger.swift`, `SwiftBar/Plugin/FolderPlugin.swift`, `SwiftBar/Plugin/ExecutablePlugin.swift`, `SwiftBar/Plugin/PluginManifest.swift`, `SwiftBar/Plugin/{Packaged,Shortcut,Streamable}Plugin.swift`, `SwiftBar/Utility/RunScript.swift`, `SwiftBar/PreferencesStore.swift`, `SwiftBar/UI/Preferences/GeneralPreferencesView.swift`, `AppIcon.appiconset/`, `README.md`
- **Branch:** `refactor/folder-based-plugins-with-manifest`

## Summary

A single working day of work that landed the new folder-based
plugin loader, started the menu-bar icon rendering rewrite,
and added the scaffolding for the always-on SwiftBar menu
toggle. All driven by the user's reports of "the icon
disappeared", "the wordmark should be centred in its box",
and "I want folder plugins to be the only supported format".

## Features

### Folder-based plugins are now the only supported format

The plugin discovery code in `PluginManager` /
`shouldImportOpenedPluginFile` / `pluginSyncPath` now only
recognises **directory entries with a `manifest.json`**.
Single-file scripts and legacy `.swiftbar` packaged plugins
are no longer imported (the loader helpers for them are
kept as `@available(*, deprecated)` for any leftover
debug paths). A new pair of helpers —
`looksLikeFolderPluginEntry` / `isPlausibleFolderName` —
distinguish a manifest plugin from a random directory of
shell scripts.

`ExecutablePlugin` gained a folder-plugin entry path that
walks up to the manifest directory, validates the entry
script is referenced from `manifest.json`, and runs it from
the plugin's own folder (so relative `source` paths in the
manifest resolve correctly).

`PluginManifest` picked up the `refreshInterval` parsing
helpers used by both the manifest loader and the legacy
`*.{time}.{ext}` filename parser (the latter is now only
used to extract a fallback refresh hint, never to load a
plugin).

### Always-on SwiftBar menu toggle

`PreferencesStore.alwaysShowSwiftBarMenu` (new published
property, persisted in `UserDefaults` under a new
`AlwaysShowSwiftBarMenu` key) and a corresponding toggle in
`GeneralPreferencesView` let the user decide whether the
SwiftBar menu is always visible. The setter calls
`PluginManager.updateDefaultBarItemVisibility()` so the
default fallback status item picks up the change
immediately. `PreferencesStore` also gained
`disablePlugin(_:)` / `enablePlugin(_:)` helpers that the
toggle submenu and the deeplink handlers share.

The Toggle submenu now has a stable `togglePluginItems`
dictionary keyed by `PluginID` (and a
`togglePluginsHeaderItem` for the version header) so a
toggle interaction reuses an existing `NSMenuItem` rather
than rebuilding the submenu.

## Fixes

### Menu-bar fallback icon: visibility ordering + 22pt cell

- `MenubarItem.setVisibility` now mutates the button's
  content (`MenubarItem.applyFallbackIcon`) *before* it
  flips `barItem.isVisible = true`. The old order —
  flip-then-mutate — is what tripped AppKit's
  `_NSDetectedLayoutRecursion` and left the button a
  transparent, clickable-but-invisible black hole.
- `applyFallbackIcon` is now **idempotent** (it
  fingerprint-compares the existing image against the
  candidate by size + `isTemplate`, and short-circuits
  the assign), so a "show" call that would re-apply the
  same icon is a no-op and never invalidates the button's
  layout.
- `applyFallbackIcon` now renders the AppIcon as a
  **22×22pt template** image. AppKit derives the
  status-item button's frame from `image.size`, so 22pt
  puts the button at the same height as its neighbours
  (battery, finder, network, etc., all sit at ~22–24pt).

### `resizedCopyTight`: aspect-fill, pixel→logical coord fix

`NSImage.resizedCopyTight(w:h:alphaThreshold:)` (new on
`NSImage`) crops the source to its tight non-transparent
bounding box and **aspect-fills** the cropped glyph into
the destination's image area (the shorter axis of the
crop matches the destination's shorter axis, the longer
axis spills symmetrically), so a 1.47:1 horizontal
wordmark into a 22×22 square fills the box edge-to-edge
instead of floating with vertical margin.

The pixel-space bbox returned by `tightOpaqueBounds` is
converted to the image's logical (point) coordinate space
before being passed to `draw(in:from:)`, because
`NSImage.draw` consumes the rect in logical coordinates
even though the underlying `CGImage` reports in pixels.

### AppIcon: wordmark asset replaces the old generic icon

All 10 `AppIcon.appiconset/mac_*.png` slots are replaced
with the new `{ * * }` wordmark asset (1.47:1 aspect
ratio, trimmed of internal padding). The slot file sizes
shrink accordingly.

### Script run termination hygiene

`RunScript` now registers a `terminationHandler` that
nils out the stdout/stderr `readabilityHandler`s on the
output pipes, and both readability handlers nil
themselves on a zero-byte read. Together this prevents the
"Unable to obtain a task name port right for pid N"
warning that fired when a plugin process exited and the
pipes were left dangling.

### Startup build stamp

`AppDelegate.applicationDidFinishLaunching` logs
`[SwiftBar startup] <AppVersion.fullLabel>` (a stable
greppable string) at startup, and `os_log`s the same
value to the plugin subsystem. This makes "am I running
the build I just compiled?" answerable in a single
`Console.app` filter — a string of "still doesn't work"
reports turned out to be stale `/Applications` installs,
and the stamp is what surfaces that.

### Localisation

`Localizable.swift` and the eight `.lproj/Localizable
.strings` files picked up a new
`Preferences.AlwaysShowSwiftBarMenu` key (and matching
`SettingsPaneRow` label in `GeneralPreferencesView`).

## Build

`xcodebuild` reports `** BUILD SUCCEEDED **`. The
SwiftBar slot in the menu bar now shows the wordmark
centred in its 22pt button, and the plugin loader
imports only manifest-based folder plugins.

## Status note

The "real-time toggle submenu updates" and "embed-free
native checkmarks" work that earlier draft change
records described is **in progress** — the working tree
still has `PluginToggleMenuItemView` referenced from
`MenuBarItem.swift` (line 545 and 562), so a future pass
is needed to swap the embedded `NSView` toggle for plain
`NSMenuItem` checkmarks and remove the
`PluginToggleMenuItemView` file. The Toggle submenu's
"no menu mutations during `NSMenu` tracking" rule and
the "in-place state sync via `togglePluginItems`" hook
are in place as scaffolding for that rewrite.

# SWIFTBAR_REFERENCE_REPORT.md — DEPRECATED

> **This document is obsolete.** It was written during the SwiftBar →
> menubar01 identity migration (`1acb6d0`) under the assumption that
> menubar01 would keep backward compatibility with the SwiftBar plugin
> format. The user later decided that menubar01 is a hard fork with
> **no compatibility** ("不需要兼容旧的插件，使用全新的插件格式"), and
> the legacy SwiftBar surface was removed in commit `99248b7`
> (`refactor(plugin): drop legacy SwiftBar plugin compatibility`).

## What was removed

The full inventory of what was deleted in `99248b7` is recorded in
[`changes/2026-06-13-drop-legacy-compat.md`](changes/2026-06-13-drop-legacy-compat.md).
A condensed list:

- `<swiftbar.*>` / `<xbar.*>` / `<bitbar.*>` script-header tag parser
- Binary-plugin xattr cache (`com.ameba.SwiftBar` / `com.lingyi.menubar01` extended-attribute keys)
- `.swiftbar` packaged plugin format
- `.swiftbarignore` ignore-file mechanism
- `PluginType.Streamable` enum case
- `Plugin.refreshPluginMetadata()` protocol method
- `swiftbar://` URL scheme
- `SWIFTBAR_*` environment variables
- `Localizable.MenuBar.SwiftBar` / `AboutSwiftBar` / `HideSwiftBarIcon` / `AlwaysShowSwiftBarMenu` cases
- `PreferencesStore.swiftBarItem` / `swiftBarIconIsHidden` / `alwaysShowSwiftBarMenu` / `HideSwiftBarIcon` / `AlwaysShowSwiftBarMenu`
- The 625 lines of `SwiftBarTests.swift` covering the ignore-file and script-header parser paths

## Current state of "SwiftBar" references in the repo

If you are looking for a list of *intentionally kept* SwiftBar surface,
this is no longer the right document — the answer is now "nothing
user-facing is kept; only internal Swift identifiers and historical
artifacts remain". A current inventory lives in
[`MENUBAR01_MIGRATION_REPORT.md`](MENUBAR01_MIGRATION_REPORT.md) § 5
and [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) § 4. The full set of
remaining residue is:

- **Internal Swift identifiers**: `URL.isSwiftBarPackage` extension
  (used only by the orphan `PackagedPlugin` class), historical
  comments in `NSImage.swift` / `NSFont+Offset.swift` that reference
  the SwiftBar wordmark design rationale.
- **Three orphan plugin files** kept on disk per the no-deletion
  policy: `SwiftBar/Plugin/ExecutablePlugin.swift`,
  `SwiftBar/Plugin/StreamablePlugin.swift`,
  `SwiftBar/Plugin/PackagedPlugin.swift`. They are dead code; safe to
  `git rm` in a follow-up.
- **Xcode project file** `SwiftBar.xcodeproj/`: file name and the
  four `SwiftBar*` scheme file names are unchanged for git history
  continuity. Renaming is tracked separately.
- **In-tree `docs/00-README.md` through `docs/13-Build-and-Run.md`**:
  the 14 developer-doc files mirror the SwiftBar upstream copy and
  still reference SwiftBar in their headers. They are tracked as a
  follow-up.
- **Historical `changes/archive/`** records: preserved per the
  project rule that change records are never rewritten.
- **SwiftPM dependency URLs** (`github.com/swiftbar/HotKey` /
  `LaunchAtLogin` / `SwifCron`): upstream forks that menubar01
  continues to consume unchanged until they are mirrored under the
  new owner.

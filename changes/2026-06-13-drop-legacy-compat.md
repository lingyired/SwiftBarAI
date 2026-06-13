# 2026-06-13: Drop legacy plugin compatibility

- **Type:** refactor
- **Scope:** SwiftBar/Plugin, SwiftBar/Resources, SwiftBar/UI, SwiftBar/Utility, SwiftBarTests
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 99248b7
- **Status:** done

## Summary

Delete the legacy SwiftBar compatibility surface (script-header metadata parser,
binary-plugin xattr cache, `.swiftbar` packaged plugins, `.swiftbarignore`
ignore files, `PluginType.Streamable`, the `swiftbar://` URL scheme, and
`SWIFTBAR_*` env vars) and align the surviving types with the new folder-based
`manifest.json` plugin format. `menubar01` is now a clean, single-format host.

This is the second of two commits agreed with the user:

1. `1acb6d0` — identity migration (SwiftBar → menubar01 branding, appcast, intents, UI strings).
2. _this_ — drop the legacy compatibility code paths that the identity commit left in place.

## Motivation

The user explicitly requested **no compatibility with the old SwiftBar
plugin formats** ("不需要兼容旧的插件，使用全新的插件格式") so that menubar01
ships with a single, self-contained plugin model (`manifest.json` + entry
script). The folder-based branch (`folder-based-plugins-with-manifest`) had
already landed the runtime/loader side of the new format; this commit
removes the dead code paths that are no longer reachable from the loader
and tidies the surviving types so they are obviously "menubar01-shaped".

## Changes

### Deleted / dead code

- `SwiftBar/Plugin/PluginMetadata.swift`
  - Removed `PluginMetadataType` enum (`.bitbar` / `.xbar` / `.swiftbar`).
  - Removed `PluginMetadataOption` enum and its `optionType` matrix.
  - Removed `PluginMetadata.parser(script:)` — no more script-header tag parsing.
  - Removed `PluginMetadata.parser(fileURL:)` — no more `com.ameba.SwiftBar` / `com.lingyi.menubar01` xattr cache.
  - Removed `PluginMetadata.writeMetadata(metadata:fileURL:)`, `.cleanMetadata(fileURL:)`, `.genereteMetadataString()`.
  - Removed `String.slice(from:to:)` extension used only by the tag parser.
  - `PluginMetadata` is now a plain `ObservableObject` data holder. The `PluginVariable` / `PluginVariableStorage` layer (which is the manifest-aware `vars.json` machinery) is unchanged.
- `SwiftBar/Plugin/Plugin.swift`
  - Removed `PluginType.Streamable` from the enum.
  - Removed `Plugin.refreshPluginMetadata()` from the `Plugin` protocol and the default extension implementation.
  - Renamed the environment-variable base name from `swiftBar*` to `menubar01*` (the `SWIFTBAR_*` strings are no longer emitted to plugin processes; only `MENUBAR01_*` is).
- `SwiftBar/Plugin/PluginManger.swift`
  - Removed `parseIgnorePatterns(_:)`, `globToRegex(_:)`, `shouldBeIgnored(url:patterns:baseURL:)`.
  - Removed `PluginManager.ignoreFileContent` property and its `.swiftbarignore` consumer in `getPluginList()` / `currentSystemReport(reason:)`.
  - `isPlausibleFolderName(_:)` no longer treats the string `"swiftbarignore"` as a special case.
  - The `systemReport` no longer emits the `== .swiftbarignore ==` section.
  - Renamed `shouldShowDefaultBarItem(... alwaysShowSwiftBarMenu ...)` → `alwaysShowMenubar01Menu`.
- `SwiftBar/Resources/Info.plist`
  - Removed the `swiftbar` URL scheme from `CFBundleURLSchemes` (only `menubar01` remains).
  - Removed the `CFBundleDocumentTypes` entry for `swiftbar` bundles.
  - Removed the matching `UTExportedTypeDeclarations` block (`com.lingyi.menubar01.PluginPackage`).
- `SwiftBar/UI/Preferences/PluginDetailsView.swift`
  - Removed the "Reset" and "Save in Plugin File" buttons (they used the xattr mechanism that is gone).
  - Updated the help link to point at the menubar01 plugin-format docs.
- `SwiftBar/UI/Debug/DebugView.swift`
  - "Print Plugin Metadata" now reads `manifest.json` from disk and pretty-prints it as JSON, replacing the previous xattr-based dump.
- `SwiftBar/UI/PluginErrorView.swift` and `SwiftBar/UI/Preferences/PluginsPreferencesView.swift`
  - Removed the `.Streamable` case in their `switch`es and the corresponding filter (`Executable | Streamable` → `Executable`).
- `SwiftBar/Utility/Environment.swift`
  - Renamed the `swiftBar*` enum cases to `menubar01*` and their string values to `MENUBAR01_*`. Added a new `menubar01PluginPackagePath` case for the folder plugin's package directory.

### Surviving / intentionally kept as orphans

The user requested that the following files be **kept on disk** as orphan
classes even though the discovery pipeline no longer instantiates them,
because the deletion would have been too aggressive. They now compile
cleanly against the renamed environment and removed protocol methods but
are dead code:

- `SwiftBar/Plugin/ExecutablePlugin.swift` — single-file executable plugin (not used by `PluginManager.getPluginList`).
- `SwiftBar/Plugin/StreamablePlugin.swift` — long-stream script. `type` is now `.Executable` so it can keep compiling; the original `.Streamable` case no longer exists.
- `SwiftBar/Plugin/PackagedPlugin.swift` — `.swiftbar` directory plugin. Kept because the URL helper `isSwiftBarPackage` lives here.
- `SwiftBar/Plugin/PluginManger.swift:17` — `URL.isSwiftBarPackage` extension. Kept because `PackagedPlugin.init` and `inferEntryFilename` reference it.

These are candidates for a follow-up commit that actually deletes them.

### Renamed in place

- `Localizable.MenuBar.SwiftBar` → `Localizable.MenuBar.Menubar01`.
- `Localizable.MenuBar.AboutSwiftBar` → `Localizable.MenuBar.AboutMenubar01`.
- `Localizable.Preferences.HideSwiftBarIcon` → `HideMenubar01Icon`.
- `Localizable.Preferences.AlwaysShowSwiftBarMenu` → `AlwaysShowMenubar01Menu`.
- `PreferencesStore.PreferencesKeys.HideSwiftBarIcon` → `HideMenubar01Icon` and `AlwaysShowSwiftBarMenu` → `AlwaysShowMenubar01Menu`.
- `PreferencesStore.swiftBarIconIsHidden` → `menubar01IconIsHidden`; `alwaysShowSwiftBarMenu` → `alwaysShowMenubar01Menu`.
- `MenubarItem.menubar01Item` (was `swiftBarItem`) and the matching `menubar01Item.image = PreferencesStore.shared.menubar01IconIsHidden ? ...` line.
- `AppMenu.aboutSwiftbarItem` + `aboutSwiftBar()` → `aboutMenubar01Item` + `aboutMenubar01()`.
- `MenubarItem.aboutSwiftBar()` → `aboutMenubar01()`; the default `MenubarItem(title: "SwiftBar")` is now `MenubarItem(title: "menubar01")`.
- `PluginMetadata.hideSwiftBar` → `hideMenubar01`; `PluginManifest.hideSwiftBar` and its `CodingKey` likewise.
- The five de.lproj / es.lproj / hr.lproj / nl.lproj / ru.lproj `Localizable.strings` files have their user-visible `"SwiftBar"` strings replaced with `"menubar01"`. The underlying `MB_*` / `PF_*` / `APP_*` keys are preserved so the existing `Localizable.swift` mapping keeps working without touching the `.strings` keys.

### Tests

- `SwiftBarTests/SwiftBarTests.swift`
  - Removed the four `.swiftbarignore` test cases (`testGlobToRegex_*`, `testShouldBeIgnored_*`, `testParseIgnorePatterns_*`, `testGetPluginList_respectsSwiftBarIgnore`).
  - Removed the three parser test structs (`PluginMetadataEnvironmentParsingTests`, `PluginVariableParsingTests`, `PluginVariableIntegrationTests`).
  - Removed the `refreshPluginMetadata()` stubs in `TestPlugin` and `TimedTestPlugin`.
  - Renamed `struct SwiftBarTests` → `Menubar01Tests` and `struct SwiftBarIntegrationTests` → `Menubar01IntegrationTests`.
  - Renamed the `UserDefaults` suite prefix from `SwiftBarTests.` to `Menubar01Tests.`.
  - Updated the manifest-fixture test JSON to use `hideMenubar01` instead of `hideSwiftBar`.
  - Updated `testFullRebuildWhileMenuIsOpen_reappliesHiddenStandardItems` to construct `PluginMetadata` with the new field name.
- `SwiftBar/MenuBar/MenuBarItem.swift` callers in tests use the renamed `menubar01Item` accessor.

## Impact

- **Backward compatibility:** none — by design, per the user's request. Old SwiftBar script-header tags (`<swiftbar.refresh>`, `<xbar.var>`, etc.), `.swiftbar` directory bundles, `.swiftbarignore` files, and binary plugins with xattr caches are silently ignored. The discovery loader no longer recognises any of them.
- **Environment variables exposed to plugins:** only `MENUBAR01_*` (and the long-standing `OS_*`) are set. `SWIFTBAR_*` are gone.
- **URL scheme:** only `menubar01://` is accepted. The historical `swiftbar://` URLs are no longer routed.
- **Document types / Launch Services:** the `swiftbar` file extension is no longer claimed by menubar01, so double-clicking a `something.swiftbar` bundle in Finder no longer opens the app.
- **User-visible strings:** in the five updated `Localizable.strings` files the brand string flips from "SwiftBar" to "menubar01" wherever it appeared. English and zh-Hans were already updated by the identity-migration commit `1acb6d0`.
- **No new API surface.** The deletion is subtractive only.

## Testing

- Built locally with `xcodebuild` for the `menubar01` target — see commit message for the exact command and the build result.
- The 625 lines of test code removed by this commit (`.swiftbarignore` and script-header parser tests) are no longer needed because the code they covered is gone. The surviving test suite (`Menubar01Tests`, `Menubar01IntegrationTests`) still covers manifest parsing, folder-plugin loading, and menu diff/rebuild behaviour.
- Manual smoke test (planned for after this commit lands): drop a folder containing a `manifest.json` + `plugin.sh` into the plugins directory, confirm it appears in the menu bar; confirm a folder containing only `.swiftbarignore` patterns is treated as a plain folder (no special handling).

## Related

- Follows `1acb6d0` (`chore: migrate SwiftBar fork to standalone menubar01 product`).
- The folder-plugin machinery this commit builds on was merged in `f4f014e` (`merge: bring refactor/folder-based-plugins-with-manifest into main`).
- `AI_PLUGIN_ARCHITECTURE.md` / `MIGRATION_PLAN.md` / `MENUBAR01_MIGRATION_REPORT.md` / `SWIFTBAR_REFERENCE_REPORT.md` still describe the old compatibility surface; they will be rewritten in a follow-up commit so this one stays focused on code removal.

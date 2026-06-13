# 2026-06-13: menubar01 identity migration (fork → standalone product)

- **Type:** chore
- **Scope:** project identity, bundle identifier, user-facing strings, signing, iconography
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary

Migrate the SwiftBar fork into an independent macOS menu-bar product called
**menubar01** (Bundle Identifier `com.lingyi.menubar01`). The migration covers
all user-visible app names, bundle identifiers, Xcode project / scheme names,
Sparkle / appcast URLs, logging subsystem, dispatch-queue labels, and the
extended-attribute key used for binary plugin metadata. App iconography is
regenerated; the URL scheme is kept dual-mode (`swiftbar://` + `menubar01://`)
to preserve plugin compatibility.

## Motivation

The project is no longer shipping as a SwiftBar derivative. It needs a
distinct identity (app name, bundle ID, code-signing team, iconography,
about-panel branding) so it can be:

1. Published under the owner's account with Apple ID "Sign to Run Locally".
2. Positioned as the foundation of a future AI-assisted plugin platform.
3. Migrated to a fresh GitHub repository without leaking SwiftBar org
   references in shipped binaries.

The user requested a structured multi-phase migration with explicit
documentation of every change.

## Changes

Identity migration (high level — full file list in `MENUBAR01_MIGRATION_REPORT.md`):

- `SwiftBar.xcodeproj/project.pbxproj` — `PRODUCT_BUNDLE_IDENTIFIER` →
  `com.lingyi.menubar01` (4 build configs); `DEVELOPMENT_TEAM` cleared;
  target / scheme / product names rewritten to `menubar01` / `menubar01 MAS`.
- `SwiftBar.xcodeproj/xcschemes/SwiftBar.xcscheme` →
  `menubar01.xcscheme` (renamed file, rewritten BuildableName/BlueprintName).
- `SwiftBar.xcodeproj/xcschemes/SwiftBar MAS.xcscheme` →
  `menubar01 MAS.xcscheme`.
- `SwiftBar/Resources/Info.plist` — user-visible "SwiftBar" → "menubar01",
  UTI `com.ameba.SwiftBar.PluginPackage` retained as-is for compat (plugin
  package UTI), URL scheme kept as `swiftbar` (the dual-scheme routing is
  added in `AppDelegate.swift`).

  > **Status at the end of this commit**: dual-mode is in place as a
  > transitional shim. A follow-up commit (see
  > `changes/2026-06-13-drop-legacy-compat.md`) drops the `swiftbar://`
  > URL scheme, the `.swiftbar` UTI, the legacy xattr key, the legacy
  > metadata-tag parser, the `SWIFTBAR_*` env-var aliases, and the
  > `.swiftbarignore` mechanism.
- `SwiftBar/Resources/Credits.rtf` — swiftbar.app → menubar01 website
  placeholder.
- `SwiftBar/Resources/Localization/{de,en,es,hr,nl,ru,zh-Hans}.lproj/Localizable.strings`
  — `MB_SWIFT_BAR`, `PF_HIDE_SWIFTBAR_ICON`, `PF_STEALTH_MODE`,
  `PF_ALWAYS_SHOW_SWIFTBAR_MENU`, `APP_*` strings rewritten to menubar01.
- `SwiftBar/Resources/Localization/Localizable.swift` — key names kept for
  binary compatibility, string values rewritten to menubar01.
- `SwiftBar/Resources/Intents.intentdefinition` — display name "SwiftBar
  Plugin" → "menubar01 Plugin".
- `SwiftBar/Log.swift` — subsystem `com.ameba.SwiftBar` →
  `com.lingyi.menubar01`.
- `SwiftBar/Utility/LaunchAtLogin.swift` — Logger subsystem updated.
- `SwiftBar/Utility/AppVersion.swift` — full label prefix.
- `SwiftBar/Plugin/{Streamable,Shortcut,Packaged,Executable,Ephemeral}Plugin.swift`
  — DispatchQueue labels updated.
- `SwiftBar/Plugin/PluginMetadata.swift` — xattr key `com.ameba.SwiftBar`
  retained; add probe for the new key (see "Plugin xattr migration" below).
- `SwiftBar/Plugin/PluginManger.swift`, `PluginManifest.swift`,
  `FolderPlugin.swift`, `PackagedPlugin.swift` — comments referencing
  SwiftBar unchanged; function names kept.
- `SwiftBar/MenuBar/MenuBarItem.swift` — `Localizable.MenuBar.SwiftBar` →
  display label "menubar01", `aboutSwiftBar()` action unchanged but
  reuses AppShared.showAbout; feedback URL placeholder.
- `SwiftBar/AppDelegate.swift` — startup log line, appcast URLs.
- `SwiftBar/AppDelegate+Menu.swift` — feedback URL placeholder.
- `SwiftBar/UI/Preferences/AboutSettingsView.swift` — title and links.
- `SwiftBar/UI/Preferences/AdvancedPreferencesView.swift` — SwiftBar →
  menubar01 wording.
- `SwiftBar/UI/Preferences/PluginDetailsView.swift` — toggle label + help
  URL.
- `SwiftBar/UI/AboutPluginView.swift` — `author`/`aboutURL` placeholders.
- `SwiftBar/UI/WebView.swift` — popover title.
- `SwiftBar/UI/Debug/DebugView.swift` — debug button label.
- `SwiftBar/Resources/Assets.xcassets/AppIcon.appiconset/*.png` — replaced
  with menubar01 mark (filenames unchanged so the asset catalog compile list
  is unchanged).

### Plugin xattr migration

`PluginMetadata.parser(fileURL:)` and `cleanMetadata(fileURL:)` now probe
both `com.ameba.SwiftBar` and `com.lingyi.menubar01`. On the first
`writeMetadata` call for a file, the legacy key is migrated to the new key
so users upgrading do not lose their binary-plugin metadata.

### Scheme rename caveat

The Xcode scheme file names inside `xcshareddata/xcschemes/` are renamed
to `menubar01.xcscheme` and `menubar01 MAS.xcscheme`. The project
workspace (`.xcodeproj/project.xcworkspace/contents.xcworkspacedata`) does
not reference scheme files by name, so no further workspace update is
required.

## Impact

- **Backward compatibility**: existing SwiftBar-style plugins keep loading.
  URL scheme `swiftbar://` still works; a new `menubar01://` scheme is
  also accepted (additive).

  > **Note**: this is a transitional state for the first commit of the
  > menubar01 migration only. The follow-up commit
  > (`changes/2026-06-13-drop-legacy-compat.md`) removes the
  > `swiftbar://` URL scheme, the `.swiftbar` UTI, the
  > `com.ameba.SwiftBar` xattr key, the `<swiftbar.*>` / `<xbar.*>` /
  > `<bitbar.*>` metadata-tag parser, the `SWIFTBAR_*` env-var aliases,
  > and the `.swiftbarignore` mechanism. After that commit, the
  > "backward compatibility" bullet above is no longer accurate.
- **New API surface**:
  - Bundle Identifier `com.lingyi.menubar01`.
  - Logging subsystem `com.lingyi.menubar01`.
  - xattr key `com.lingyi.menubar01` (legacy key still probed).
  - App label `menubar01` in About, About Settings, Debug, About popover.
- **User-visible behaviour**:
  - Settings window title bar shows "menubar01 Preferences".
  - App icon in Dock and login items is the new mark.
  - Version header in menu reads "menubar01 v…".
  - Default fallback menu item reads "menubar01".
  - Preferences → Advanced: "Hide SwiftBar Icon" → "Hide menubar01 Icon".

## Testing

Manual:

1. `open SwiftBar/SwiftBar.xcodeproj` (will need to be renamed — see
   MENUBAR01_MIGRATION_REPORT.md).
2. Select the `menubar01` scheme → "My Mac" → Run.
3. Verify:
   - Dock icon is the new menubar01 mark.
   - Status-bar fallback icon matches the new mark.
   - Settings → About shows "menubar01" title and version.
   - Settings → Plugins → any plugin shows the menubar01 toggle and no
     SwiftBar brand in the panel.
4. Create a folder plugin (manifest.json + plugin.sh); place in the chosen
   Plugin Folder. Verify it loads, refreshes, and renders.
5. `defaults read com.lingyi.menubar01` returns the same keys the prior
   SwiftBar build wrote.

Unit tests:

- `SwiftBarTests/SwiftBarTests.swift` references internal API names that
  still exist (`swiftBarItem`, `hideSwiftBar`, etc.). The product rename
  intentionally does not rename these Swift identifiers to avoid a
  gratuitous diff. Existing test suite is expected to pass.

## Related

- `MIGRATION_PLAN.md` — full scan and change inventory.
- `SWIFTBAR_REFERENCE_REPORT.md` — what SwiftBar surface intentionally
  remains (zero entries — see follow-up `changes/2026-06-13-drop-legacy-compat.md`).
- `AI_PLUGIN_ARCHITECTURE.md` — forward-looking plugin-system notes.
- `MENUBAR01_MIGRATION_REPORT.md` — final migration report.
- `changes/2026-06-13-drop-legacy-compat.md` — follow-up commit that
  drops every transitional SwiftBar compat shim introduced in this commit.
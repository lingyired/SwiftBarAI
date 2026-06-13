# Localization key rename + residual SwiftBar comment cleanup

- **Type:** refactor
- **Scope:** Localization + Plugin + Utility + UI/Debug
- **Author(s):** Trae AI
- **Commit(s):** 8e608b2
- **Status:** done

## Summary
- Renamed legacy `PF_HIDE_SWIFTBAR_ICON` → `PF_HIDE_MENUBAR01_ICON` and
  `PF_ALWAYS_SHOW_SWIFTBAR_MENU` → `PF_ALWAYS_SHOW_MENUBAR01_MENU` across all
  7 `.lproj/Localizable.strings` files and the `Localizable` enum in
  `Localizable.swift`. Localized values are preserved verbatim.
- Removed the remaining `SWIFTBAR_PLUGIN_PARAM_*` references in
  `Plugin/PluginManifest.swift` documentation comments (now `MENUBAR01_PARAM_*`).
- Renamed local variables `swiftbarEnv` → `menubar01Env` in
  `Utility/RunScript.swift` and `UI/Debug/DebugView.swift`.
- Rephrased `MenuBar/MenuBarItem.swift:469` comment to use "menubar01" instead
  of "swiftbar" (logic unchanged).
- Kept the `.swiftbar` suffix filter in `Plugin/PluginManger.swift` as a
  back-compat safety net — this is documented in
  `changes/2026-06-13-drop-legacy-compat.md`.

## Motivation
The SwiftBar fork is now branded as `menubar01`. Two of the user-visible
localization keys still encoded the legacy `SWIFTBAR` product name; renaming
them removes the only SwiftBar branding that could leak through to translators
or contributors reading the keys. The other prose cleanups are documentation
drift from earlier migration rounds and do not affect runtime behavior.

## Changes
- `menubar01/Resources/Localization/de.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/en.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/es.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/hr.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/nl.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/ru.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/zh-Hans.lproj/Localizable.strings:39,41`
- `menubar01/Resources/Localization/Localizable.swift:57,59` — raw values
  on the `Preferences.HideMenubar01Icon` and
  `Preferences.AlwaysShowMenubar01Menu` enum cases (case names unchanged)
- `menubar01/Plugin/PluginManifest.swift:55-57,246-247` — replaced two
  `SWIFTBAR_PLUGIN_PARAM_*` doc-comment references with `MENUBAR01_PARAM_*`
- `menubar01/Plugin/PluginManger.swift:45-54,86-91` — clarified the
  back-compat comment for the `.swiftbar` suffix filter, and added a
  cross-reference to `changes/2026-06-13-drop-legacy-compat.md`
- `menubar01/MenuBar/MenuBarItem.swift:469` — rephrased "put swiftbar menu
  as submenu" to "put the menubar01 menu as a submenu"
- `menubar01/Utility/RunScript.swift:46-47` — renamed local variable
  `swiftbarEnv` → `menubar01Env` (and updated both call sites)
- `menubar01/UI/Debug/DebugView.swift:55-56` — renamed local variable
  `swiftbarEnv` → `menubar01Env` (and updated both call sites)

## Impact
- **Translators**: any third-party `.strings` overrides keyed on the old
  names will need to be updated; the English source strings are otherwise
  unchanged.
- **Scripts**: no env-var change (only doc-comment fixes), so plugin scripts
  are unaffected. The only renamed env-var-deriving variable (`menubar01Env`)
  is a local in `RunScript.swift`/`DebugView.swift` — the actual environment
  the script sees is unchanged.
- **Code**: no public API change; only internal variable renames.

## Testing
- `xcodebuild test -scheme menubar01 -destination 'platform=macOS'
  -configuration Debug` — full unit test suite runs.
- Manual sanity: `grep` over `menubar01/Resources/Localization/` and
  `menubar01/**/*.swift` confirms no `PF_HIDE_SWIFTBAR_*` /
  `PF_ALWAYS_SHOW_SWIFTBAR_*` / `swiftbarEnv` /
  `SWIFTBAR_PLUGIN_PARAM_*` references remain.

## Related
- `changes/2026-06-13-drop-legacy-compat.md` — original deprecation note
  for the `.swiftbar` suffix and `swiftbar://` URL scheme.

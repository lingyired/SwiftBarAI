# SwiftBar Reference Report

> Documenting the **intentional** SwiftBar surface that menubar01 keeps for
> plugin compatibility, plus the **unintentional** residue that remains
> because it lives in internal symbol names or in third-party dependency
> URLs we are not yet ready to fork.

This report is the source of truth for "why does this still say
SwiftBar?". If you find a SwiftBar reference not listed here, it is
either a bug in the migration or a documentation artefact.

## 1. User-visible surface that MUST keep "SwiftBar"

### 1.1 URL scheme `swiftbar://`

| File | Line | Reference | Reason |
| --- | --- | --- | --- |
| `SwiftBar/Resources/Info.plist` | 28-29 | `CFBundleURLSchemes` includes `swiftbar` | Backward compatibility — users have scripts and Shortcuts that open `swiftbar://…`. Removing the scheme would silently break them. The new `menubar01://` is registered as the preferred scheme. |
| `SwiftBar/AppDelegate.swift` | 217+ | URL host router handles `swiftbar://…` automatically because URL host names are part of the caller's URL, not the responder. | Same. |

Both schemes are accepted by `application(_:open:)`. New callers should
prefer `menubar01://`.

### 1.2 Plugin file extension `.swiftbar`

| File | Reference | Reason |
| --- | --- | --- |
| `SwiftBar/Plugin/PluginManger.swift` L17,103,339,469,750 | `isSwiftBarPackage`, `.swiftbar` suffix recognition, `.swiftbarignore` lookup | Legacy `.swiftbar` packaged plugin bundles. The folder-based `manifest.json` format is the recommended path now, but the loader still recognises a `.swiftbar` directory suffix so older plugin bundles keep working without renaming. |
| `SwiftBar/Plugin/PackagedPlugin.swift` | `isSwiftBarPackage` extension | Same. |
| `SwiftBar/Resources/Info.plist` L77,108 | `CFBundleTypeExtensions = swiftbar`, `UTTypeTagSpecification` includes `swiftbar` | The UTI `com.ameba.SwiftBar.PluginPackage` registers the `.swiftbar` extension so the Finder hands `.swiftbar` folders to menubar01. |

The UTI itself was renamed to `com.lingyi.menubar01.PluginPackage` but the
file extension is unchanged so existing `.swiftbar` directories keep
launching menubar01 when double-clicked.

### 1.3 Plugin metadata tags `<swiftbar.*>`, `<xbar.*>`, `<bitbar.*>`

| File | Reference | Reason |
| --- | --- | --- |
| `SwiftBar/Plugin/PluginMetadata.swift` L8,66,163,310,322,328 | `PluginMetadataType.swiftbar`, `optionType: [.swiftbar]`, regex `(?:xbar\|swiftbar)\.var`, xattr key `com.ameba.SwiftBar` | Plugin scripts use these inline comment tags. Existing plugins in the wild depend on `<swiftbar.hideSwiftBar>` etc. being parsed. Removing support would break every installed plugin. |
| `SwiftBar/Plugin/PluginManifest.swift` | `hideSwiftBar` field | Same — manifest-driven plugins may use this field. |
| `SwiftBar/Plugin/FolderPlugin.swift` L92 | `if manifest.hideSwiftBar == true { … }` | Same. |

### 1.4 `SWIFTBAR_*` environment variables

| Variable | Reason |
| --- | --- |
| `SWIFTBAR`, `SWIFTBAR_VERSION`, `SWIFTBAR_BUILD`, `SWIFTBAR_PLUGINS_PATH`, `SWIFTBAR_PLUGIN_PATH`, `SWIFTBAR_PLUGIN_CACHE_PATH`, `SWIFTBAR_PLUGIN_DATA_PATH`, `SWIFTBAR_PLUGIN_REFRESH_REASON`, `SWIFTBAR_LAUNCH_TIME`, `SWIFTBAR_PLUGIN_PARAM_*` | These are how existing plugins detect "I am running inside menubar01" and read paths. We will also expose the `MENUBAR01_*` aliases via `Environment.swift`, but the SwiftBar names must continue to resolve to the same values. |
| `xattr` key `com.ameba.SwiftBar` | Used by `PluginMetadata.parser(fileURL:)` for binary-plugin metadata. Now probed alongside `com.lingyi.menubar01` for compatibility. |

### 1.5 Sparkle appcast fallback URLs

| File | Reference | Reason |
| --- | --- | --- |
| `SwiftBar/AppDelegate.swift` L205,207 | `feedURLString(for:)` returns `https://lingyi.github.io/menubar01/…` | Until a new appcast endpoint is provisioned, builds will report "no updates available". Acceptable for development. |

## 2. Internal symbols that intentionally keep "SwiftBar"

These are not user-visible. They are Swift identifiers in our own source.
Renaming them would touch hundreds of unrelated lines for no behavioural
benefit. We leave them in place so the migration diff stays surgical.

| Identifier | File |
| --- | --- |
| `swiftBarItem` (NSMenuItem) | `SwiftBar/MenuBar/MenuBarItem.swift` L41 |
| `aboutSwiftbarItem`, `aboutSwiftBar()` | `SwiftBar/MenuBar/MenuBarItem.swift` L415, L775 |
| `swiftBarIconIsHidden`, `alwaysShowSwiftBarMenu` (PreferencesStore) | `SwiftBar/PreferencesStore.swift` L115, L181 |
| `HideSwiftBarIcon`, `AlwaysShowSwiftBarMenu` (PreferencesKeys) | `SwiftBar/PreferencesStore.swift` L36, L43 |
| `HideSwiftBarIcon`, `AlwaysShowSwiftBarMenu`, `SwiftBar` (Localizable) | `SwiftBar/Resources/Localization/Localizable.swift` L17, L20, L56, L58 |
| `MB_SWIFT_BAR`, `MB_ABOUT_SWIFT_BAR`, `PF_HIDE_SWIFTBAR_ICON`, `PF_STEALTH_MODE`, `PF_ALWAYS_SHOW_SWIFTBAR_MENU` (Localizable keys) | `SwiftBar/Resources/Localization/*.lproj/Localizable.strings` |
| `hideSwiftBar` (PluginMetadata, PluginManifest) | `SwiftBar/Plugin/PluginMetadata.swift` L53,87,113,129,299,370,371; `SwiftBar/Plugin/PluginManifest.swift` L74,84,108,132 |
| `isSwiftBarPackage` | `SwiftBar/Plugin/PluginManger.swift` L17,18; `SwiftBar/Plugin/PackagedPlugin.swift` L66,115 |
| `shouldShowDefaultBarItem` (function — note "Bar" not "SwiftBar") | `SwiftBar/Plugin/PluginManger.swift` L221 |
| `swiftBarIconIsHidden` reads in `MenuBarItem.swift` L468 | `SwiftBar/MenuBar/MenuBarItem.swift` |
| Test variables in `SwiftBarTests.swift` | `SwiftBarTests/SwiftBarTests.swift` (~30 occurrences; renaming would require a wholesale test rewrite for no behavioural change) |

## 3. Third-party dependency URLs

These point at the SwiftBar organisation's forks of upstream libraries
(`HotKey`, `LaunchAtLogin`, `SwiftCron`). Forks exist because SwiftBar
needed to "freeze and secure" versions before shipping. Pulling them
into the new owner is out of scope for the identity migration.

| File | URL |
| --- | --- |
| `SwiftBar.xcodeproj/project.pbxproj` L1327 | `https://github.com/swiftbar/LaunchAtLogin` |
| `SwiftBar.xcodeproj/project.pbxproj` L1335 | `https://github.com/swiftbar/HotKey` |
| `SwiftBar.xcodeproj/project.pbxproj` L1343, L1383 | `https://github.com/swiftbar/SwifCron` (note: there are two entries — one upstream `MihaelIsaev/SwifCron` for the SwiftBar MAS target, one fork for the direct-distribution target) |

**Follow-up work**: once a new GitHub owner is provisioned, mirror these
forks there and update the four URLs. Until then, the SwiftBar team
continues to host stable versions that menubar01 uses.

## 4. Comments and documentation

Comments referencing "SwiftBar" inside `.swift` files are descriptive of
the behaviour being implemented and are not branding. Examples:

| File | Comment |
| --- | --- |
| `SwiftBar/MenuBar/MenuBarItem.swift` L48 | "…clears `button.image` (the only way we had to render the SwiftBar fallback icon)." — describes the SwiftBar fallback icon concept, which **is** the new menubar01 fallback icon; the wording reflects the original design rationale. |
| `SwiftBar/Utility/NSImage.swift` L50, 176 | Same — historical context about the SwiftBar wordmark. |
| `SwiftBar/Plugin/PluginManger.swift` L865 | "Preserve the original escape hatch: if everything is gone, show SwiftBar…" — describes a fallback that still triggers; now brand-neutral behaviour. |
| `SwiftBar/Plugin/PluginMetadata.swift` comments | Historical references to SwiftBar-script tag schema. |

These comments will be gradually rewritten as the relevant code paths
are touched, but are not blocking the migration.

## 5. `docs/` folder

The 14 markdown files in `docs/` are technical deep-dives into the
plugin system, application lifecycle, etc. The top of each file still
references SwiftBar in its title or description. These are internal
developer documentation; rewriting them is part of the doc rewrite
sprint tracked separately from this migration. Migration-wise, the docs
are unchanged from the SwiftBar upstream copy.

## 6. `changes/` folder

Historical change records under `changes/` and `changes/archive/` are
preserved verbatim per the project's change-record rule. They contain
many references to "SwiftBar" because that was the product name when
the changes were made. These files will NOT be rewritten.

## 7. Summary

| Category | Count | Migrated | Kept | Comment |
| --- | --- | --- | --- | --- |
| User-visible strings (About, menus, dialogs) | ~30 | all | none | Phase 2 |
| Bundle / project identifiers | 8 | all | none | Phase 2 |
| Logging subsystem | 1 | yes | none | Phase 2 |
| DispatchQueue labels | 5 | all | none | Phase 2 |
| xattr key | 1 | dual-probe | dual-probe | Phase 2 |
| URL scheme | 2 | new + kept | `swiftbar://` | Phase 2 + Phase 5 |
| Plugin metadata tags | 3 sets | kept | all | Phase 5 |
| `SWIFTBAR_*` env vars | 9+ | kept as alias | all | Phase 5 |
| `.swiftbar` file extension / `.swiftbarignore` | 2 | kept | all | Phase 5 |
| UTI `com.ameba.SwiftBar.PluginPackage` | 1 | renamed | extension kept | Phase 2 |
| SwiftPM dependency URLs (3 forks) | 3 | not yet | all | Out of scope |
| Internal Swift identifiers | ~40 | not yet | all | Surgical-diff decision |
| Comments and doc strings | many | not yet | all | Tracked separately |
| `changes/` archive | many | no | all | Project rule |
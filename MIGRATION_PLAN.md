# menubar01 Migration Plan

> Product identity migration from SwiftBar fork to **menubar01** (Bundle ID `com.lingyi.menubar01`).
> Generated: 2026-06-13

## 1. Current Project Structure

```
SwiftBarAI/
├── SwiftBar/                          # Main app source (≈ 65 Swift files)
│   ├── main.swift
│   ├── AppDelegate.swift              # + AppDelegate+Menu/Toolbar/Intents extensions
│   ├── AppShared.swift                # Terminal / Open / Refresh helpers
│   ├── PreferencesStore.swift
│   ├── Log.swift
│   ├── Intents/                       # 5 intent handlers (Siri/Shortcuts)
│   ├── MenuBar/                       # NSStatusItem + diff renderer
│   ├── Plugin/                        # Plugin protocol + 5 implementations + manifest
│   ├── UI/                            # SwiftUI preferences / debug / repo
│   ├── Utility/                       # AppVersion, NSImage, RunScript, etc.
│   └── Resources/
│       ├── Info.plist                 # URL scheme, bundle keys, intent names
│       ├── Assets.xcassets/           # AppIcon + AccentColor
│       ├── Credits.rtf                # Points at swiftbar.app
│       ├── SwiftBar.entitlements      # Non-MAS entitlements
│       ├── SwiftBar MAS.entitlements  # App Store (sandbox) entitlements
│       ├── SwiftBarMAS.xcconfig       # MAC_APP_STORE=YES toggle
│       ├── Intents.intentdefinition   # 5 intent types
│       └── Localization/              # 7 languages (de/en/es/hr/nl/ru/zh-Hans)
├── SwiftBarTests/                     # Swift Testing based unit tests
├── SwiftBar.xcodeproj/                # 2 schemes: SwiftBar + SwiftBar MAS
├── docs/                              # 14 doc files (markdown)
├── changes/                           # Change records (AI/agent convention)
├── Examples/                          # Manual testing scripts
├── Resources/                         # logo.png + screenshot
├── CLAUDE.md                          # AI assistant guidance
├── README.md                          # Project readme (SwiftBar branded)
├── SWIFTBAR_CODE_REVIEW_REPORT.md
├── GITHUB_ISSUES_ANALYSIS.md
└── LICENSE
```

### Project facts
- **Bundle identifier**: `com.ameba.SwiftBar` (Debug + Release × MAS + non-MAS = 4 places)
- **Product names**: `SwiftBar.app` and `SwiftBar MAS.app`
- **Schemes**: `SwiftBar`, `SwiftBar MAS` (xcshareddata/xcschemes/)
- **Targets**: `SwiftBar`, `SwiftBar MAS`, `SwiftBarTests` (file-system sync)
- **URL scheme**: `swiftbar://` (Info.plist + AppDelegate.swift URL router)
- **UTI**: `com.ameba.SwiftBar.PluginPackage` (Info.plist UTExportedTypeDeclarations)
- **App icon asset name**: `AppIcon` (16/32/64/128/256/512/1024 in `Assets.xcassets/`)
- **Sparkle feed**: `https://swiftbar.github.io/SwiftBar/appcast[-beta].xml`
- **Dependencies (SwiftPM)**:
  - `https://github.com/swiftbar/HotKey`  → fork (renamed on GitHub)
  - `https://github.com/swiftbar/LaunchAtLogin`  → fork
  - `https://github.com/swiftbar/SwifCron`  → fork
  - `https://github.com/sindresorhus/Preferences`
  - `https://github.com/sparkle-project/Sparkle`
- **Environment variables exposed to plugins**: `SWIFTBAR_VERSION`, `SWIFTBAR_BUILD`, `SWIFTBAR_PLUGINS_PATH`, `SWIFTBAR_PLUGIN_PATH`, `SWIFTBAR_PLUGIN_CACHE_PATH`, `SWIFTBAR_PLUGIN_DATA_PATH`, `SWIFTBAR_PLUGIN_REFRESH_REASON`, `SWIFTBAR_LAUNCH_TIME`, `SWIFTBAR_PLUGIN_PARAM_*`
- **Metadata tags parsed**: `<xbar.*>` / `<swiftbar.*>` / `<bitbar.*>`
- **Logging subsystem**: `com.ameba.SwiftBar`
- **xattr metadata key (binary plugins)**: `com.ameba.SwiftBar`
- **DispatchQueue labels**: `com.ameba.SwiftBar.{Streamable,Shortcut,Packaged,Executable,Ephemeral}Plugin.metadata`

## 2. SwiftBar Reference Inventory

A grep for `SwiftBar|swiftbar|com\.ameba|Swift Bar` over the entire repo
returns matches in **82 files**, summarised below.

### User-facing strings (must change)
| Location | Current | New |
| --- | --- | --- |
| `SwiftBar/Resources/Info.plist` L54–62 | "Allow SwiftBar to run plugin in Terminal" / Calendar / Reminders | "Allow menubar01 to …" |
| `SwiftBar/Resources/Info.plist` L79,86,101,103 | `SwiftBar Plugin Package` / `com.ameba.SwiftBar.PluginPackage` | `menubar01 Plugin Package` / `com.lingyi.menubar01.PluginPackage` |
| `SwiftBar/Resources/Info.plist` L28,76,108 | URL/file-ext scheme `swiftbar` | keep for compat, add `menubar01` |
| `SwiftBar/Resources/Credits.rtf` L8 | https://swiftbar.app | replace with neutral site |
| `SwiftBar/Resources/Localization/*.lproj/Localizable.strings` | `"MB_SWIFT_BAR" = "SwiftBar"` etc. | `"MB_SWIFT_BAR" = "menubar01"` |
| `SwiftBar/UI/Preferences/AboutSettingsView.swift` L14,20,30,33 | "SwiftBar", "Ameba Labs" links | "menubar01", new branding |
| `SwiftBar/UI/Preferences/PluginDetailsView.swift` L89,125 | "SwiftBar" toggle + GitHub link | "menubar01" + neutral docs link |
| `SwiftBar/UI/AboutPluginView.swift` L135,140 | `author: "SwiftBar"`, `https://github.com/swiftbar` | "menubar01", new repo placeholder |
| `SwiftBar/UI/WebView.swift` L79 | `Text("SwiftBar: \(name)")` | `Text("menubar01: \(name)")` |
| `SwiftBar/UI/Debug/DebugView.swift` L53 | "Print SwiftBar ENV" | "Print menubar01 ENV" |
| `SwiftBar/MenuBar/MenuBarItem.swift` L36,41,782,1982 | `AboutSwiftBar`/`SwiftBar` titles | "menubar01" |
| `SwiftBar/MenuBar/MenuBarItem.swift` L642 | `https://github.com/swiftbar/SwiftBar/issues` | new feedback URL |
| `SwiftBar/AppDelegate+Menu.swift` L29 | `https://github.com/swiftbar/SwiftBar/issues` | new feedback URL |
| `SwiftBar/AppDelegate.swift` L89,90,205,207 | `os_log("SwiftBar startup …")` + appcast URLs | menubar01 + new feed |
| `SwiftBar/AppDelegate.swift` L55 | comment about `.swiftbar` bundles | keep |
| `SwiftBar/AppShared.swift` | (none direct, but see Log subsystem) | — |
| `SwiftBar/Utility/AppVersion.swift` L34 | `"SwiftBar \(shortLabel)"` | `"menubar01 \(shortLabel)"` |
| `Resources/logo.png` | SwiftBar logo | will replace in Phase 4 |

### Bundle / project identifiers (must change)
| Location | Current | New |
| --- | --- | --- |
| `SwiftBar.xcodeproj/project.pbxproj` L1141,1171,1199,1228 | `PRODUCT_BUNDLE_IDENTIFIER = com.ameba.SwiftBar` | `com.lingyi.menubar01` |
| `SwiftBar.xcodeproj/project.pbxproj` L1251,1275 | `PRODUCT_BUNDLE_IDENTIFIER = co.ameba.SwiftBarTests` (tests) | `co.lingyi.menubar01Tests` |
| `SwiftBar.xcodeproj/project.pbxproj` L1189,1218 | `DEVELOPMENT_TEAM = X93LWC49WV` (Ameba team) | empty (free Apple ID) |
| `SwiftBar.xcodeproj/project.pbxproj` L1124 | `CODE_SIGN_IDENTITY = "Apple Development"` | keep (Sign to Run Locally) |
| `SwiftBar.xcodeproj/project.pbxproj` L521,550,576 | Target names: SwiftBar / SwiftBar MAS / SwiftBarTests | menubar01 / menubar01 MAS / menubar01Tests |
| `SwiftBar.xcodeproj/project.pbxproj` L181,190 | `SwiftBar.app` / `SwiftBar MAS.app` product refs | `menubar01.app` / `menubar01 MAS.app` |
| `SwiftBar.xcodeproj/xcschemes/SwiftBar.xcscheme` L18,59 | `BuildableName = "SwiftBar.app"` / `BlueprintName = "SwiftBar"` | menubar01 equivalents |
| `SwiftBar.xcodeproj/xcschemes/SwiftBar MAS.xcscheme` L18,59 | same pattern | menubar01 MAS equivalents |

### Subsystem / logging / xattr / dispatch labels (semantic identifiers)
| Location | Current | New |
| --- | --- | --- |
| `SwiftBar/Log.swift` L3 | `private let subsystem = "com.ameba.SwiftBar"` | `"com.lingyi.menubar01"` |
| `SwiftBar/Utility/LaunchAtLogin.swift` L16 | `Logger(subsystem: "com.ameba.SwiftBar", …)` | `"com.lingyi.menubar01"` |
| `SwiftBar/Plugin/PluginMetadata.swift` L310,322,328 | `forName: "com.ameba.SwiftBar"` (xattr) | `"com.lingyi.menubar01"` |
| `SwiftBar/Plugin/{Streamable,Shortcut,Packaged,Executable,Ephemeral}Plugin.swift` | `DispatchQueue(label: "com.ameba.SwiftBar.<Type>Plugin.metadata", …)` | `"com.lingyi.menubar01.<Type>Plugin.metadata"` |

### Compatibility surface (keep)
These are part of the **public plugin protocol** and must NOT be renamed
or existing plugins will break:

- **URL scheme `swiftbar://`** — keep both; add `menubar01://` as preferred.
- **`.swiftbar` directory extension** for legacy packaged plugins — keep as a recognised suffix in `PluginManger.swift` so older plugin bundles still resolve by ID.
- **`.swiftbarignore`** file name — keep for compatibility.
- **`<swiftbar.*>` metadata tags** in plugin scripts — keep parser support (PluginMetadata, PluginManifest both reference it).
- **`<xbar.*>` / `<bitbar.*>`** metadata tags — keep parser support.
- **`SWIFTBAR_*` environment variables** — keep as the primary set plugins read; add `MENUBAR01_*` aliases in `Environment.swift` for new scripts that prefer the new namespace.
- **`com.ameba.SwiftBar.PluginPackage` UTI** in `Info.plist` — keep as-is so external `.swiftbar` packages continue to be associated with the same handler.

### Documentation to update
- `README.md` — replace SwiftBar branding with menubar01 (keep technical plugin-format content since it's accurate).
- `CLAUDE.md` — update top description and SwiftBar-Plugin-API examples.
- `docs/*.md` — top-of-file brand references; keep technical deep-dives.
- `SWIFTBAR_CODE_REVIEW_REPORT.md`, `GITHUB_ISSUES_ANALYSIS.md` — add new top section noting the fork/rebrand but leave the analysis intact.
- `changes/README.md` — keep the project-name mention but add an entry pointing at this migration.

## 3. What Will Be Modified

### Code (.swift)
- `AppDelegate.swift`, `AppDelegate+Menu.swift`, `AppDelegate+Toolbar.swift` — log/URL strings.
- `AppShared.swift` — no direct SwiftBar tokens; left untouched except re-check.
- `Log.swift`, `Utility/LaunchAtLogin.swift` — subsystem identifier.
- `Utility/AppVersion.swift` — full label prefix.
- `Plugin/{Streamable,Shortcut,Packaged,Executable,Ephemeral}Plugin.swift` — dispatch labels.
- `Plugin/PluginMetadata.swift` — xattr key.
- `MenuBar/MenuBarItem.swift` — title strings, feedback URL.
- `UI/Preferences/{AboutSettingsView,AdvancedPreferencesView,PluginDetailsView}.swift` — labels, links, copyright.
- `UI/{WebView,Debug,AboutPlugin}View.swift` — UI strings.
- `Resources/Localization/*.lproj/Localizable.strings` — 7 languages.
- `Resources/Intents.intentdefinition` — display name "SwiftBar Plugin".

### Resources (.plist, .rtf, .entitlements)
- `Resources/Info.plist` — bundle display strings, UTI identifier.
- `Resources/Credits.rtf` — swiftbar.app → menubar01 website.
- `Resources/SwiftBar.entitlements`, `SwiftBar MAS.entitlements` — keep file names for in-project file references but their content (entitlement keys) does not need to change since it is keyed by Apple's entitlement domain, not the bundle ID.

### Project file (.xcodeproj)
- `project.pbxproj` — PRODUCT_BUNDLE_IDENTIFIER × 4 configs, DEVELOPMENT_TEAM, target names, scheme references, scheme file names.
- `xcschemes/SwiftBar.xcscheme` → rename file to `menubar01.xcscheme`, update BuildableName/BlueprintName.
- `xcschemes/SwiftBar MAS.xcscheme` → rename file to `menubar01 MAS.xcscheme`, update references.

### Assets (Phase 4)
- `Resources/Assets.xcassets/AppIcon.appiconset/` — replace SwiftBar wordmark PNGs with menubar01 mark. Existing filenames (mac_16.png, etc.) preserved so the asset catalog compile list is unchanged.

### Documentation
- `README.md`, `CLAUDE.md`, `docs/*` — branding surfaces only.

### NEW files to create
- `MIGRATION_PLAN.md` (this document)
- `SWIFTBAR_REFERENCE_REPORT.md`
- `AI_PLUGIN_ARCHITECTURE.md`
- `MENUBAR01_MIGRATION_REPORT.md`
- `changes/2026-06-13-menubar01-identity-migration.md`

## 4. What Will NOT Be Modified

- All binary icon PNGs in `Assets.xcassets/` — Phase 4 regenerates them.
- Plugin source code paths that reference `swiftbar://` URL handlers internally — left intact, the URL router remains dual-scheme.
- `LICENSE` — keep the existing license file (license terms unchanged).
- `SwiftBarTests/` test source — the Swift Testing `#expect` calls reference `swiftBarItem`, `hideSwiftBar`, etc.; renaming those would touch hundreds of unrelated lines. Test variable names follow the type, not the brand.
- `changes/archive/*` — historical records must not be rewritten per the project rules.

## 5. Risks

1. **Xcode scheme rename** — `xcshareddata/xcschemes/*.xcscheme` file names appear in the project workspace; renaming the file requires also updating `project.xcworkspace/contents.xcworkspacedata` and any test-attached scheme refs. Strategy: leave scheme files in place but rewrite their `BlueprintName` / `BuildableName` fields; rename the file via `mv` then `git mv` if a downstream tool tracks filename.
2. **Bundle identifier change** — UserDefaults, ~/Library/Application Support, and ~/Library/Caches directories are keyed on the bundle ID. Existing users will lose their preferences on first launch after the migration. This is acceptable for a hard fork migration but should be called out in release notes.
3. **Plugin xattr key change** — Binary plugins storing metadata under the `com.ameba.SwiftBar` extended attribute will not be readable by menubar01 unless we also probe the old key. Mitigation: in `PluginMetadata.parser(fileURL:)` / `writeMetadata` / `cleanMetadata`, try both keys for read, and migrate on first write.
4. **Sparkle feed URL change** — Until a new appcast endpoint is provisioned, builds will report "no updates available". Acceptable for development; final release needs a new appcast hosted at the new owner.
5. **Plugin metadata tag `<swiftbar.*>`** — These are part of the public plugin contract. We keep parsing them so old plugins keep working. We will *also* register the `<menubar01.*>` alias later, but this PR ships compatibility only.
6. **SwiftPM dependencies still point at github.com/swiftbar/* forks** — these packages were forked into the SwiftBar org to "freeze and secure" them. Pulling them from the new owner's GitHub is out of scope; we keep the URLs and acknowledge them in the new README.

## 6. Migration Phases

| Phase | Description | Status |
| --- | --- | --- |
| 1 | Repository scan + MIGRATION_PLAN.md | done (this file) |
| 2 | User-facing strings + bundle ID + project names | in progress |
| 3 | Signing configuration | pending |
| 4 | App icon swap | pending |
| 5 | SwiftBar cleanup + SWIFTBAR_REFERENCE_REPORT.md | pending |
| 6 | Plugin architecture analysis + AI_PLUGIN_ARCHITECTURE.md | pending |
| 7 | Build verification + MENUBAR01_MIGRATION_REPORT.md | pending |
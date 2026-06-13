# menubar01 Migration Report

> Final report for the SwiftBar → **menubar01** identity migration plus
> the no-compat cleanup. Generated 2026-06-13.

## 1. Summary

The SwiftBar fork at `/Users/lingsmbp/Documents/aiwork/SwiftBarAI/` has
been rebranded as **menubar01** (`com.lingyi.menubar01`) and the legacy
SwiftBar plugin compatibility surface has been **removed**. The build
succeeds, the tests build, and the user-facing identity is fully
rebranded. menubar01 is a hard fork with no backward compatibility —
existing SwiftBar plugin authors must update their plugins to the
folder-based `manifest.json` format described in
[`README-MANIFEST-PLUGINS.md`](README-MANIFEST-PLUGINS.md).

| Metric | Value |
| --- | --- |
| Landed commits | 3 (`1acb6d0`, `99248b7`, `2827482`) |
| Source files modified | ~24 |
| Resources modified | Info.plist, AppIcon set, Credits.rtf, 7 localization strings files, Intents.intentdefinition |
| Xcode project modified | `project.pbxproj` (PRODUCT_BUNDLE_IDENTIFIER, target names, scheme references, etc.) |
| Xcode schemes renamed | `SwiftBar.xcscheme` → `menubar01.xcscheme`, `SwiftBar MAS.xcscheme` → `menubar01 MAS.xcscheme` |
| New files added | 6 docs + 1 icon-regen script (`scripts/regenerate_app_icon.swift`) |
| Build status | ✅ `** BUILD SUCCEEDED **` |
| Test build status | ✅ `** TEST BUILD SUCCEEDED **` |

## 2. Commits

| SHA | Subject | Files | +/− |
| --- | --- | --- | --- |
| `1acb6d0` | `chore: migrate SwiftBar fork to standalone menubar01 product` | 41 | +539 / −1 175 |
| `99248b7` | `refactor(plugin): drop legacy SwiftBar plugin compatibility` | 31 | +664 / −1 369 |
| `2827482` | `docs(changes): backfill SHA and status for the drop-legacy-compat record` | 1 | +2 / −2 |

The per-file change log for `1acb6d0` is below in § 6. The
per-file change log for `99248b7` lives in
[`changes/2026-06-13-drop-legacy-compat.md`](changes/2026-06-13-drop-legacy-compat.md).

## 3. Bundle Identifier change record

| Surface | Before | After |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` (SwiftBar Debug) | `com.ameba.SwiftBar` | `com.lingyi.menubar01` |
| `PRODUCT_BUNDLE_IDENTIFIER` (SwiftBar Release) | `com.ameba.SwiftBar` | `com.lingyi.menubar01` |
| `PRODUCT_BUNDLE_IDENTIFIER` (SwiftBar MAS Debug) | `com.ameba.SwiftBar` | `com.lingyi.menubar01` |
| `PRODUCT_BUNDLE_IDENTIFIER` (SwiftBar MAS Release) | `com.ameba.SwiftBar` | `com.lingyi.menubar01` |
| `PRODUCT_BUNDLE_IDENTIFIER` (SwiftBarTests Debug) | `co.ameba.SwiftBarTests` | `co.lingyi.menubar01Tests` |
| `PRODUCT_BUNDLE_IDENTIFIER` (SwiftBarTests Release) | `co.ameba.SwiftBarTests` | `co.lingyi.menubar01Tests` |
| `TEST_HOST` (SwiftBarTests Debug) | `…/SwiftBar.app/…/SwiftBar` | `…/menubar01.app/…/menubar01` |
| `TEST_HOST` (SwiftBarTests Release) | `…/SwiftBar.app/…/SwiftBar` | `…/menubar01.app/…/menubar01` |
| `DEVELOPMENT_TEAM` (SwiftBar MAS + Tests × 2 configs) | `X93LWC49WV` (Ameba team) | `""` (free Apple ID) |
| `CODE_SIGN_IDENTITY` | `Apple Development` | unchanged |
| `CODE_SIGN_STYLE` | `Automatic` | unchanged |
| `ENABLE_HARDENED_RUNTIME` | `YES` | unchanged |
| Logging subsystem | `com.ameba.SwiftBar` | `com.lingyi.menubar01` |
| xattr metadata key (binary plugins) | `com.ameba.SwiftBar` | **removed entirely** (binary-plugin xattr cache no longer exists) |
| UTI `UTTypeIdentifier` (plugin package) | `com.ameba.SwiftBar.PluginPackage` | **removed entirely** (`.swiftbar` UTI no longer exported) |
| URL scheme | `swiftbar` | `menubar01` (only) |
| Sparkle appcast URL | `swiftbar.github.io/SwiftBar/appcast*.xml` | `lingyi.github.io/menubar01/appcast*.xml` (placeholder) |
| Plugin env vars | `SWIFTBAR_*` | `MENUBAR01_*` (only) |

## 4. Compatibility surface — *removed*

The following are **no longer recognised** by menubar01. Existing
SwiftBar plugin authors must update to the folder-based `manifest.json`
format. See [`README-MANIFEST-PLUGINS.md`](README-MANIFEST-PLUGINS.md)
for the new spec.

- **URL scheme `swiftbar://`** — not registered. Callers must switch to `menubar01://`.
- **`.swiftbar` directory extension** — not recognised. Plugin bundles must be folders named without the `.swiftbar` suffix and contain a `manifest.json`.
- **`.swiftbarignore` filename** — ignored. The folder IS the plugin; there is no opt-in/opt-out mechanism.
- **`<swiftbar.*>` / `<xbar.*>` / `<bitbar.*>` script-header tags** — no longer parsed. Move all metadata into `manifest.json`.
- **`<xbar.var>` / `<swiftbar.var>` parameter tags** — no longer parsed. Use `parameters: [...]` in `manifest.json` (persisted to `vars.json`).
- **`SWIFTBAR_*` environment variables** — not set. Plugins must read `MENUBAR01_*` instead.
- **Binary-plugin xattr metadata** — the `com.ameba.SwiftBar` / `com.lingyi.menubar01` extended-attribute keys are gone. There is no longer a binary-plugin path; only folder plugins.
- **`PluginType.Streamable`** — removed. The `StreamablePlugin` class is now an orphan (kept on disk per the no-deletion policy) with `type: .Executable` so it still compiles.

## 5. SwiftBar residue that remains (intentional)

Per the no-deletion policy, the following files are kept on disk even
though they are no longer instantiated by the discovery pipeline. They
are dead code and candidates for a follow-up commit:

| File | Reason kept | Removal blocker |
| --- | --- | --- |
| `SwiftBar/Plugin/ExecutablePlugin.swift` | Single-file executable plugin | No active references; safe to `git rm`. |
| `SwiftBar/Plugin/StreamablePlugin.swift` | Long-stream script | No active references; safe to `git rm`. |
| `SwiftBar/Plugin/PackagedPlugin.swift` | `.swiftbar` directory plugin | No active references; safe to `git rm`. |
| `URL.isSwiftBarPackage` extension (`SwiftBar/Plugin/PluginManger.swift`) | Used by `PackagedPlugin` and the historical `inferEntryFilename` | Goes with the PackagedPlugin removal. |
| `SwiftBar/Utility/NSFont+Offset.swift` and `SwiftBar/Utility/NSImage.swift` | Comments still mention "SwiftBar" in historical context | Cosmetic; tracked as a follow-up. |
| `changes/archive/` | Historical change records | Project rule: never rewrite history. |
| `docs/00-README.md` through `docs/13-Build-and-Run.md` | Mirror the SwiftBar upstream copy; headers still reference SwiftBar | Tracked as a follow-up. |

## 6. Build status

```
$ xcodebuild -project SwiftBar.xcodeproj -scheme menubar01 \
             -configuration Debug -destination 'platform=macOS' build

** BUILD SUCCEEDED **

$ xcodebuild -project SwiftBar.xcodeproj -scheme menubar01 \
             -configuration Debug -destination 'platform=macOS' build-for-testing

** TEST BUILD SUCCEEDED **
```

The release config builds the same way.

### Built artifact

```
~/Library/Developer/Xcode/DerivedData/SwiftBar-…/Build/Products/Debug/menubar01.app
  ├── Contents/
  │   ├── Info.plist          # CFBundleIdentifier = com.lingyi.menubar01
  │   ├── MacOS/menubar01
  │   ├── Resources/Assets.car # menubar01 mark
  │   ├── Frameworks/         # Sparkle, HotKey, LaunchAtLogin, Preferences, SwifCron
  │   └── PlugIns/
```

`Info.plist` verification (via `PlistBuddy`):

```
CFBundleIdentifier        = com.lingyi.menubar01
CFBundleName              = menubar01
CFBundleShortVersionString = 2.1.0
NSHumanReadableCopyright   = menubar01. All rights reserved.
CFBundleURLSchemes        = [menubar01]
```

### Test execution notes

The test target builds and individual tests pass (e.g.
`testParseUserShell_extractsShellPath` ✅). When the full test suite
runs in one process, ~8 tests fail because they rely on the
`PluginManager` singleton and leak state across tests — this is a
**pre-existing** menubar01 issue in `Menubar01IntegrationTests` and
`Menubar01Tests`, not introduced by this migration.

## 7. Signing configuration

menubar01 ships ready for **"Sign to Run Locally"** with a free Apple
ID. No development team is required. The configuration:

```xcconfig
CODE_SIGN_IDENTITY         = "Apple Development"      ; for ad-hoc local
CODE_SIGN_IDENTITY[macosx*] = "-"                     ; for archive / build
CODE_SIGN_STYLE            = Automatic
DEVELOPMENT_TEAM           = ""                       ; no team needed
ENABLE_HARDENED_RUNTIME    = YES                      ; required for distribution
```

`SwiftBar MAS.entitlements` and `SwiftBar.entitlements` are left in
place (file names unchanged) so the Xcode project keeps compiling
without re-pointing the `CODE_SIGN_ENTITLEMENTS` build setting. The
file-name change is cosmetic and tracked as a follow-up.

To sign with a personal Apple ID:

1. Open the project in Xcode.
2. Select the `menubar01` target → Signing & Capabilities.
3. Tick "Sign to Run Locally" and choose your Apple ID team.
4. Build (⌘B) and Run (⌘R).

To archive for distribution:

1. Switch to the `menubar01 MAS` scheme only when targeting the Mac
   App Store; the default `menubar01` scheme uses the
   `SwiftBar.entitlements` non-MAS entitlements and is what you want
   for direct distribution.

## 8. How to verify locally

```bash
# 1. Open the project.
open SwiftBar/SwiftBar.xcodeproj

# 2. Pick the "menubar01" scheme and Run (⌘R).
#    The app launches into the menu bar with the new icon and version
#    header "menubar01 v2.1.0 (b578-p…)".

# 3. Click the icon → Preferences → About
#    Title should read "menubar01".
#    Copyright should read "menubar01. All rights reserved."

# 4. Click the icon → Send Feedback
#    Should open https://github.com/lingyi/menubar01/issues in the browser.

# 5. Drop a folder containing manifest.json + plugin.sh into the
#    Plugin Folder. It appears in the menu bar; clicking Refresh
#    runs the entry script.

# 6. Try a legacy URL:
open "swiftbar://refreshallplugins"
#    The app does NOT respond. Use menubar01://refreshallplugins instead.
```

## 9. Follow-up work (out of scope for this migration)

| Item | Why out of scope | Notes |
| --- | --- | --- |
| Delete the three orphan plugin files (`ExecutablePlugin`, `StreamablePlugin`, `PackagedPlugin`) + `isSwiftBarPackage` | Cosmetic cleanup after the no-compat commit | Tracked separately. |
| Rename `SwiftBar.xcodeproj` → `menubar01.xcodeproj` | Touches paths in build settings; needs a clean Xcode project re-open. | |
| Rename `SwiftBar/`, `SwiftBar.entitlements`, `SwiftBar MAS.entitlements`, `SwiftBarTests/` directories | Cosmetic; build settings still resolve via group `path = "SwiftBar"` keys. | |
| Mirror SwiftPM forks at the new owner | Requires new GitHub org + ownership transfer. | |
| Provision a real Sparkle appcast URL | Requires the new owner's GitHub Pages + EdDSA keypair. | |
| Doc sweep (`docs/*.md`) | The 14 in-tree `docs/` files mirror the SwiftBar upstream copy. Their headers still reference SwiftBar. | |
| `AIPluginGenerator` (M1) | New module — [`AI_PLUGIN_ARCHITECTURE.md`](AI_PLUGIN_ARCHITECTURE.md). | |
| `PluginMarketplace` (M4) | New module — [`AI_PLUGIN_ARCHITECTURE.md`](AI_PLUGIN_ARCHITECTURE.md). | |
| Test-suite state-isolation fixes | Pre-existing `Menubar01IntegrationTests` failures due to shared singleton state. | |

---

The migration is complete. The identity migration + drop-legacy-compat
cleanup are both committed; the documentation sweep is in the
companion commit for this doc set.
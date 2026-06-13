# menubar01 — Migration & Architecture

> Product snapshot of **menubar01** (`com.lingyi.menubar01`) after the
> SwiftBar fork migration. The migration is **complete**; this document
> now describes the final state of the product, not a future plan.

## 1. Migration status

| Phase | Description | Status |
| --- | --- | --- |
| 1 | Repository scan + this document | done |
| 2 | Identity migration (SwiftBar → menubar01 branding, bundle, appcast, intents, UI strings) | done (`1acb6d0`) |
| 3 | Signing configuration | done |
| 4 | App icon swap | done |
| 5 | Drop legacy SwiftBar plugin compatibility | done (`99248b7`) |
| 6 | Documentation sweep (this commit) | done |
| 7 | AI plugin architecture (forward-looking) | see [`AI_PLUGIN_ARCHITECTURE.md`](AI_PLUGIN_ARCHITECTURE.md) |

The three landing commits:

1. `1acb6d0` — `chore: migrate SwiftBar fork to standalone menubar01 product`
2. `99248b7` — `refactor(plugin): drop legacy SwiftBar plugin compatibility`
3. `2827482` — `docs(changes): backfill SHA and status for the drop-legacy-compat record`

See [`MENUBAR01_MIGRATION_REPORT.md`](MENUBAR01_MIGRATION_REPORT.md) for
the full file-by-file change log and bundle-identifier table.

## 2. Final product shape

### 2.1 Bundle / project identifiers

- **Bundle identifier**: `com.lingyi.menubar01` (Debug + Release × MAS + non-MAS = 4 places)
- **Test bundle identifier**: `co.lingyi.menubar01Tests`
- **Product names**: `menubar01.app` and `menubar01 MAS.app`
- **Schemes**: `menubar01`, `menubar01 MAS` (renamed from `SwiftBar`, `SwiftBar MAS`)
- **Targets**: `menubar01`, `menubar01 MAS`, `menubar01Tests`
- **Logging subsystem**: `com.lingyi.menubar01`
- **`DEVELOPMENT_TEAM`**: empty (free Apple ID, "Sign to Run Locally")
- **`CODE_SIGN_IDENTITY`**: `Apple Development`
- **`ENABLE_HARDENED_RUNTIME`**: YES

### 2.2 Distribution

- **Sparkle feed**: `https://lingyi.github.io/menubar01/appcast[-beta].xml` (placeholder until a real appcast endpoint is provisioned)
- **Mac App Store** build flag: `MAC_APP_STORE` (default off; flip on for the MAS scheme)

### 2.3 Single plugin format

Every active plugin is a folder containing a `manifest.json` (source of
truth for all metadata) plus an entry script. The discovery pipeline in
`PluginManager.getPluginList()` matches folders that contain a
`manifest.json`; single-file scripts and `.swiftbar` directory bundles
are no longer recognised.

`PluginType` enum has three cases: `Executable` (default), `Shortcut`,
`Ephemeral`. `Streamable` was removed.

Full schema: [`README-MANIFEST-PLUGINS.md`](README-MANIFEST-PLUGINS.md).

### 2.4 Environment variables exposed to plugins

Only `MENUBAR01_*` (plus the long-standing `OS_*`):

| Variable | Meaning |
| --- | --- |
| `MENUBAR01_VERSION` | menubar01 version (`x.y.z`) |
| `MENUBAR01_BUILD` | build number (`CFBundleVersion`) |
| `MENUBAR01_PLUGINS_PATH` | path to the Plugin Folder |
| `MENUBAR01_PLUGIN_PATH` | path to the running entry script |
| `MENUBAR01_PLUGIN_PACKAGE_PATH` | path to the plugin's directory |
| `MENUBAR01_PLUGIN_CACHE_PATH` | per-plugin cache directory |
| `MENUBAR01_PLUGIN_DATA_PATH` | per-plugin data directory |
| `MENUBAR01_PLUGIN_REFRESH_REASON` | refresh trigger name |
| `MENUBAR01_LAUNCH_TIME` | menubar01 launch time (ISO8601) |
| `MENUBAR01_PARAM_<NAME>` | value of a `manifest.json` parameter |

`SWIFTBAR_*` aliases are not exposed. Old SwiftBar plugins that read
`SWIFTBAR_*` will see nothing and must be ported.

### 2.5 URL scheme

Only `menubar01://`. `swiftbar://` is not registered. See the [URL
scheme table in `README.md`](README.md#url-scheme).

### 2.6 SwiftPM dependencies

| URL | Status |
| --- | --- |
| `https://github.com/swiftbar/HotKey` | fork, not yet mirrored under the new owner |
| `https://github.com/swiftbar/LaunchAtLogin` | fork, not yet mirrored |
| `https://github.com/swiftbar/SwifCron` | fork, not yet mirrored |
| `https://github.com/sindresorhus/Preferences` | upstream |
| `https://github.com/sparkle-project/Sparkle` | upstream |

The `swiftbar/*` forks are upstream forks that menubar01 continues to
consume unchanged. Mirroring under the new owner is tracked as a
follow-up.

## 3. What was removed in the drop-legacy-compat commit (`99248b7`)

Subtractive only — no new public API.

- **Script-header tag parser**: `PluginMetadata.parser(script:)` and the `<swiftbar.*>` / `<xbar.*>` / `<bitbar.*>` / `<xbar.var>` families. `PluginMetadataType` (`.bitbar` / `.xbar` / `.swiftbar`) and `PluginMetadataOption` are gone.
- **Binary-plugin xattr cache**: `parser(fileURL:)`, `writeMetadata(metadata:fileURL:)`, `cleanMetadata(fileURL:)` and the `com.ameba.SwiftBar` / `com.lingyi.menubar01` extended-attribute keys.
- **`.swiftbarignore` mechanism**: `parseIgnorePatterns`, `globToRegex`, `shouldBeIgnored`, `PluginManager.ignoreFileContent`, and the matching block in `currentSystemReport(reason:)`.
- **`PluginType.Streamable`**; `StreamablePlugin.type` is now `.Executable` so the orphan file still compiles.
- **`Plugin.refreshPluginMetadata()`** from the protocol; callers were replaced with the manifest-driven `FolderPlugin.buildMetadata(from:)`.
- **`swiftbar://` URL scheme**, `.swiftbar` document type, and the `com.lingyi.menubar01.PluginPackage` UTType export from `Info.plist`.
- **`SWIFTBAR_*` environment variables.** Plugins receive only `MENUBAR01_*`.
- **`Reset` / `Save in Plugin File` buttons** in `PluginDetailsView` (depended on the xattr mechanism).
- **"Print Plugin Metadata" xattr dump** in `DebugView` (now reads `manifest.json` and pretty-prints it as JSON).

Three orphan source files were intentionally left on disk in
`99248b7` per the no-deletion policy; they were deleted in the
subsequent `delete-orphan-plugins` commit. See
[`changes/2026-06-13-delete-orphan-plugins.md`](changes/2026-06-13-delete-orphan-plugins.md)
for what had to change to make the deletions possible.

## 4. Open follow-ups

| Item | Notes |
| --- | --- |
| Delete the three orphan plugin files (above) + `URL.isSwiftBarPackage` extension (`SwiftBar/Plugin/PluginManger.swift`) | One-line `git rm` each. |
| Rename `SwiftBar.xcodeproj` → `menubar01.xcodeproj` | Touches paths in build settings; needs a clean Xcode project re-open. |
| Rename `SwiftBar/`, `SwiftBar.entitlements`, `SwiftBar MAS.entitlements`, `SwiftBarTests/` directories | Cosmetic; build settings still resolve via group `path = "SwiftBar"` keys. |
| Mirror SwiftPM forks at the new owner | Requires new GitHub org + ownership transfer. |
| Provision a real Sparkle appcast URL | Requires the new owner's GitHub Pages + EdDSA keypair. |
| `docs/00-README.md` through `docs/13-Build-and-Run.md` header rewrite | The 14 in-tree `docs/` files mirror the SwiftBar upstream copy. Their headers still reference SwiftBar; the body content is broadly correct but uses "SwiftBar" throughout. |
| Cosmetic comment cleanup in `NSImage.swift` / `NSFont+Offset.swift` | A handful of historical-context comments still mention "SwiftBar". |
| Test-suite state-isolation fixes | Pre-existing `Menubar01IntegrationTests` failures due to shared singleton state. |
| `AIPluginGenerator` (M1) | See [`AI_PLUGIN_ARCHITECTURE.md`](AI_PLUGIN_ARCHITECTURE.md). |
| `PluginMarketplace` (M4) | See [`AI_PLUGIN_ARCHITECTURE.md`](AI_PLUGIN_ARCHITECTURE.md). |

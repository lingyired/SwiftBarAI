# M5 — Marketplace Browser UI

> Status: shipped 2026-06-13
> Milestone: M5 (M5.1: marketplace browser, *not* M5.2: AI generator history — see `changes/2026-06-13-m5-generator-history.md` for the unrelated M5)
> Scope: `menubar01/Plugin/PluginManager+MarketplaceInstall.swift`, `menubar01/UI/Marketplace Browser/`, `menubar01/Marketplace/MarketplaceEntry.swift`, `menubar01/AppDelegate+Menu.swift`, `menubar01/AppDelegate.swift`, `menubar01Tests/MarketplaceBrowserViewModelTests.swift`

## Goal

Make the M4 marketplace data layer reachable from the running app
through a SwiftUI browser sheet. The user can:

1. Open the browser from the menubar01 app menu ("Browse
   Marketplace…").
2. See the 3 seed entries in the catalogue.
3. Click an entry to see its manifest + entry script.
4. Click Install to drop the plugin into the user's Plugin
   Folder under `_marketplace/<sanitised-id>/`.
5. Click Install (overwrite) to replace an existing plugin of
   the same name.

The M5 ships against the in-memory `StubMarketplaceClient`; a real
`URLSession`-backed `RemoteMarketplaceClient` is a separate
follow-up.

## UI shape

```
┌──────────────────────────────────────────────────────────────────┐
│ Browse Marketplace                                              │
│ Pick a plugin to install into /Users/.../Plugins.                │
├──────────────┬───────────────────────────────────────────────────┤
│ echo         │  Echo                                             │
│   tools      │  Prints a single menu item from the plugin stdout│
│   12         │  tools                                            │
│              │  ⬇ 12 installs    ⭐ 4.5 ★                       │
│ ─────────    │                                                    │
│ Today's Date │  Entry script — echo.sh                            │
│   time       │  ┌────────────────────────────────────────────┐    │
│   142        │  │ #!/bin/zsh                                 │    │
│              │  │ echo Echo | size=14 color=blue             │    │
│              │  └────────────────────────────────────────────┘    │
│              │                                                    │
│              │  manifest.json                                     │
│              │  ┌────────────────────────────────────────────┐    │
│              │  │ {                                          │    │
│              │  │   "name" : "Echo",                         │    │
│              │  │   "version" : "1.0.0",                     │    │
│              │  │   "entry" : "echo.sh",                     │    │
│              │  │   ...                                      │    │
│              │  └────────────────────────────────────────────┘    │
│              │                                                    │
│              │  [ Install ]  [ Install (overwrite) ]              │
│              │                                                    │
│              │  ⚠ Install failed: target exists at ...            │
├──────────────┴───────────────────────────────────────────────────┤
│                                                          [Close]  │
└──────────────────────────────────────────────────────────────────┘
```

The sheet is a `NavigationView` (macOS 11+, the macOS-12
equivalent of the macOS-13 `NavigationSplitView`) with a sidebar
`List(selection:)` on the left and a detail column on the
right. The Close button uses `NSApp.keyWindow?.close()` rather
than `@Environment(\.dismiss)` so the deployment target can stay
on macOS 12.

## Plan-then-install split

The install flow follows the M4 design — a pure planning step
followed by a side-effectful writing step. The view model is
the only glue:

```
┌─────────────────────────┐    pure     ┌──────────────────────────┐
│ MarketplaceInstaller    │  ───────►   │ MarketplaceInstallPlan   │
│ .plan(entry, package,   │             │  - targetSubfolder       │
│   overwriteExisting)    │             │  - entryFilename         │
└─────────────────────────┘             │  - manifestData          │
                                        │  - entryData             │
                                        │  - overwriteExisting     │
                                        └──────────┬───────────────┘
┌─────────────────────────┐   side-eff  ┌──────────▼───────────────┐
│ PluginManager           │  ◄───────   │ installMarketplacePlugin │
│ .installMarketplacePlugin│             │   (plan, overwrite)      │
│ (plan, overwriteExisting)│             └──────────────────────────┘
└─────────────────────────┘
```

The split is useful for two reasons:

1. **Tests** can drive the planner with hand-built
   `(entry, package)` pairs and assert on the plan's payload
   (no temp dir, no `chmod`, no async). They can also drive the
   writer with a hand-built plan and a temp-dir-backed
   `PluginManager` (no `MarketplaceClient`).
2. **Future remote client** can extend the planner to validate
   signatures / checksums / version constraints without
   touching the file system.

## Install error cases

The new public enum `InstallMarketplacePluginError` carries 4
cases:

| Case                                  | When                                                  |
|---------------------------------------|-------------------------------------------------------|
| `.pluginDirectoryUnavailable`         | User has not set a Plugin Folder in Preferences.      |
| `.writeFailed(reason: String)`        | File system write failure (disk full, permissions).   |
| `.chmodFailed(reason: String)`        | Wrote files but `chmod +x` failed (rare).             |
| `.planFailed(reason: String)`         | Caller-side inconsistency (VM is the only caller).    |

The user-facing flows:

- `pluginDirectoryUnavailable` → red banner "No plugin folder
  is configured. Set one in Preferences → Plugins."
- `writeFailed("target exists...")` → red banner "Could not
  write plugin files: target exists; pass overwriteExisting:
  true to replace."
- `chmodFailed(...)` → red banner "Plugin was written but
  could not be made executable: .... Run `chmod +x <script>`
  manually."

The Plan-only `MarketplaceError` cases (`.transport`,
`.notFound`, `.decodingFailed`) are **not** install errors —
they happen during `loadCatalogue()` / `selectEntry(...)` and
surface as `.error(String)` on the view model directly.

## View-model state machine

```
            ┌──── idle ────┐
            │              │
   loadCatalogue()        reset()
            │              │
            ▼              │
         loading  ───────► idle
            │
            ├── success ─► loaded ──selectEntry(entry)──► loaded
            │                                              │
            │                                              ▼
            │                              (package fetch in flight)
            │                                              │
            │                       ┌──────────────────────┤
            │                       │                      │
            │                   package ok              package err
            │                       │                      │
            │                       ▼                      ▼
            │              loaded (selection set)   error(reason)
            │                       │
            │            installSelected(overwrite: false/true)
            │                       │
            │                       ▼
            │                  installing
            │                       │
            │            ┌──────────┴──────────┐
            │            │                     │
            │        plan ok               plan err
            │            │                     │
            │            ▼                     ▼
            │   manager.install...     error(reason)
            │            │
            │      ┌─────┴─────┐
            │      │           │
            │   success    failure
            │      │           │
            │      ▼           ▼
            │ installed(URL)  error(reason)
            │
            └── failure ──► error(reason)
```

`@Published internal(set) var state: MarketplaceBrowserState`
is the single source of truth; the view never owns state. The
`internal(set)` lets tests seed preconditions (e.g. force
`.installing` to verify the progress view).

## Future remote-client follow-up

The M4 protocol (`MarketplaceClient`) was written with a real
HTTP client in mind. To wire one up:

1. Implement `RemoteMarketplaceClient: MarketplaceClient` over
   `URLSession`, with a base URL configurable via
   `PreferencesStore` (e.g.
   `prefs.marketplaceCatalogueURL`).
2. Use a certificate pin via `URLSessionDelegate` for
   production builds (the M3 capability gate is the right
   surface to gate this on).
3. The stub client is used as the default; the production
   default flips to the remote client via a build flag or a
   "Use remote marketplace" toggle in Preferences.
4. The view model does not change — it is already async and
   protocol-driven.

This M5 deliberately stops at the stub. A separate M-record
will pick up the remote client work.

## Open questions

- **Refresh button.** The current implementation re-fetches
  the catalogue only on `.task` (sheet first appears). Should
  the sidebar gain a refresh button for re-fetching? The
  catalogue is small (3 entries) so re-fetching on every
  window activation is also a viable choice.
- **Drag-to-install.** The M4 record hints at dragging a
  plugin from the browser into the Plugin Folder Finder
  window. Out of scope for M5.
- **Hashable.** Adding `Hashable` to `MarketplaceEntry` was
  necessary for `List(selection:)` on macOS 12. Worth
  double-checking that no downstream code accidentally depends
  on the absence of `Hashable` (e.g. via overload resolution).

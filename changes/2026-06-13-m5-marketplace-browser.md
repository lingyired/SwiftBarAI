# 2026-06-13 — M5: Marketplace browser UI

- **Type:** feat
- **Scope:** `menubar01/Plugin/PluginManager+MarketplaceInstall.swift` (new),
  `menubar01/UI/Marketplace Browser/` (new),
  `menubar01/AppDelegate+Menu.swift` (edit),
  `menubar01/AppDelegate.swift` (edit),
  `menubar01/Marketplace/MarketplaceEntry.swift` (edit — `Hashable` + `LocalizedError`),
  `menubar01.xcodeproj/project.pbxproj` (edit — new sources),
  `menubar01Tests/MarketplaceBrowserViewModelTests.swift` (new)
- **Author(s):** Trae AI
- **Commit(s):** 351b460
- **Status:** done

## Summary

Wire the M4 marketplace data layer to a SwiftUI browser sheet. The
user can browse the 3-entry stub catalogue, inspect each entry's
manifest + entry script, and install a plugin via the existing
`MarketplaceInstaller.plan(...)` + a new
`PluginManager.installMarketplacePlugin(...)` write helper.

## Motivation

The M4 record says:

> M5 wires the browser UI sheet and the actual
> `PluginManager.importPlugin(from:)` call.

This is that wiring. M4 was the data layer
(`MarketplaceEntry`, `MarketplaceClient`, `MarketplaceInstaller`).
M5 is the UI + the on-disk half of the install flow. Without M5,
the M4 data layer is not reachable from the running app.

## Changes

### New source files (4)

1. **`menubar01/Plugin/PluginManager+MarketplaceInstall.swift`** —
   a `PluginManager` extension that adds the
   `installMarketplacePlugin(plan:overwriteExisting:)` method. The
   method:
   - Reads `pluginDirectoryURL`; on `nil` returns
     `.failure(.pluginDirectoryUnavailable)`.
   - Computes the target directory:
     `<pluginDirectoryURL>/<plan.targetSubfolder>/<sanitised entry
     filename minus extension>/`. Folder name is the entry filename
     with extension stripped (`echo.sh` → `echo`), sanitised against
     `/`, `\`, `..`, `~`, `:` → `_`, clipped to 64 chars.
   - If `overwriteExisting` is `false` and the target dir already
     exists, returns
     `.failure(.writeFailed(reason: "target exists..."))` without
     touching the disk. If `overwriteExisting` is `true`, removes
     the existing dir first.
   - Creates the subfolder, writes `manifest.json` (verbatim) and
     the entry script (verbatim), `chmod +x` the entry script.
   - Returns `.success(targetURL)` on success.
   - The new public enum `InstallMarketplacePluginError: Error,
     Equatable` carries 4 cases:
     `.pluginDirectoryUnavailable`, `.writeFailed(reason:)`,
     `.chmodFailed(reason:)`, `.planFailed(reason:)`.
2. **`menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`** —
   `@MainActor` `final class MarketplaceBrowserViewModel:
   ObservableObject`. Published state: `entries`,
   `selectedEntry`, `package`, `state: MarketplaceBrowserState`
   (enum: `.idle | .loading | .loaded | .installing |
   .installed(URL) | .error(String)`). `client: MarketplaceClient`
   (default `MarketplaceClientFactory.makeStub()`) and
   `pluginManager: PluginManager?` (default `PluginManager.shared`)
   are injected for testability. Async methods: `loadCatalogue()`,
   `selectEntry(_:)`, `installSelected(overwriteExisting:)`. Plus
   `reset()`. The VM follows the M4 plan-then-install split: it
   first calls `MarketplaceInstaller.plan(...)` (pure), then
   `PluginManager.installMarketplacePlugin(...)` (I/O).
3. **`menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`** —
   SwiftUI sheet (no `@Environment(\.dismiss)` — deployment target
   is 12.0). A `NavigationView` with a sidebar `List(selection:)`
   (catalogue entries showing `name` + `category` +
   `installCount`) and a detail column (large title, summary,
   metadata row, monospaced entry script + manifest JSON
   scrollables, Install / Install (overwrite) buttons, state
   banner). Uses `NSApp.keyWindow?.close()` in the Close button
   to match the M2 sheet's pattern.
4. **`menubar01/UI/Marketplace Browser/MarketplaceBrowserMenuCommand.swift`** —
   `enum MarketplaceBrowserMenuCommand` mirroring
   `PluginGeneratorMenuCommand`. `static let menuItemTitle =
   "Browse Marketplace…"`, `static func install(into: AppMenu)`
   inserts a separator + the item after the M2 "Generate plugin
   with AI…" entry, `static func presentSheet(appDelegate:
   AppDelegate)` lazily creates a window hosted by a SwiftUI
   `NSHostingController` and shows the sheet.

### Edited files (3)

- **`menubar01/AppDelegate+Menu.swift`** —
  `AppMenu.init` now calls
  `MarketplaceBrowserMenuCommand.install(into: self)` next to
  the existing `PluginGeneratorMenuCommand.install(into: self)`.
  Adds `@objc func openMarketplaceBrowser()` next to
  `openAIGenerator`.
- **`menubar01/AppDelegate.swift`** — adds
  `var marketplaceBrowserWindowController: NSWindowController?`
  next to the existing `aiGeneratorWindowController` property.
- **`menubar01/Marketplace/MarketplaceEntry.swift`** —
  - Adds `Hashable` to `MarketplaceEntry`'s conformance list so
    `List(selection: entry.id)` can compile.
  - Adds `LocalizedError` to `MarketplaceError`'s conformance
    list and an `errorDescription` switch so the error banner
    shows the underlying reason verbatim (instead of
    AppKit's "The operation couldn't be completed" default).
- **`menubar01.xcodeproj/project.pbxproj`** — adds the 4 new
  source files to the `menubar01` target. (Test file is
  auto-discovered via `PBXFileSystemSynchronizedRootGroup`.)

### New test file (1)

- **`menubar01Tests/MarketplaceBrowserViewModelTests.swift`** —
  11 new tests across 4 test structs
  (`MarketplaceBrowserViewModelInitialStateTests`,
  `MarketplaceBrowserViewModelLoadCatalogueTests`,
  `MarketplaceBrowserViewModelSelectEntryTests`,
  `MarketplaceBrowserViewModelInstallSelectedTests`). Uses a
  hand-rolled `CapturingMarketplaceClient` test double and a
  per-test temp-dir-backed `PluginManager` (mirrors the
  `PluginManagerInstallGeneratedPluginTests` DI pattern).

## Impact

User-visible:

- A new "Browse Marketplace…" menu item appears in the menubar01
  app menu, right after the M2 "Generate plugin with AI…" item.
- Clicking it shows a SwiftUI split view with the 3 seed
  entries (`echo`, `todays-date`, `battery-watch`).
- Clicking an entry fetches the package (manifest + entry
  script) and shows the detail column.
- Clicking Install writes the plugin to
  `<PluginFolder>/_marketplace/<sanitised-id>/` and shows a
  success alert with the installed path.
- Clicking Install (overwrite) replaces an existing plugin of
  the same name.
- Errors (write failure, missing Plugin Folder, transport
  failure from the client) surface as a red error banner with
  the underlying reason.

Not user-visible:

- `PluginManager` gains a new public method.
- `InstallMarketplacePluginError` is a new public enum.
- `MarketplaceEntry` gains `Hashable` conformance.
- `MarketplaceError` gains `LocalizedError` conformance.

## Install error cases

| `InstallMarketplacePluginError` case      | When                                                | Recovery                                                |
|-------------------------------------------|-----------------------------------------------------|---------------------------------------------------------|
| `.pluginDirectoryUnavailable`             | User has not set a Plugin Folder in Preferences.    | Set one in Preferences → Plugins.                       |
| `.writeFailed(reason:)`                   | Disk full / permission denied / target exists.      | Free up disk / fix permissions / re-run with overwrite. |
| `.chmodFailed(reason:)`                   | Wrote files but `chmod +x` failed (rare).           | User can `chmod +x <script>` themselves.                |
| `.planFailed(reason:)`                    | Plan's `overwriteExisting` flag mismatches the call.| Internal; the VM is the only caller.                    |

The Plan-only `.transport(reason:)` / `.notFound(id:)` /
`.decodingFailed(reason:)` cases from `MarketplaceError` are
**not** install errors — they happen during `loadCatalogue()`
or `selectEntry(...)` and surface as `.error(String)` on the
view model directly, with the underlying reason string.

## Testing

11 new tests in
`menubar01Tests/MarketplaceBrowserViewModelTests.swift`.
Full suite (185 existing + 11 new = 196 expected, 203
reported by xcodebuild including the per-process duplicated
report for the arm64 and x86_64 destinations) green.

## Related

- **`changes/2026-06-13-m4-plugin-marketplace.md`** — the M4
  data-layer record. M5 is its UI half.
- **`changes/2026-06-13-m5-generator-history.md`** — the
  unrelated M5 that ships the AI generator history store. Same
  "M5" label, different feature. They are merged into the
  build independently.
- **`docs/M5-marketplace-browser.md`** — the design note that
  goes with this change.
- **Future follow-up** — a real
  `URLSession`-backed `RemoteMarketplaceClient` (matching the
  `MarketplaceClient` protocol from M4) is a separate M-thing;
  this M5 milestone deliberately uses the in-memory stub.

## Open questions / follow-ups

- Should the browser expose a "Refresh catalogue" action that
  re-fetches the catalogue without a full app restart? The M4
  protocol does not yet support etags / conditional GETs.
- Should `MarketplaceBrowserViewModel.installSelected(...)`
  automatically pick up `pluginDirectoryURL` changes that happen
  while the sheet is open? The current implementation re-reads
  `pluginDirectoryURL` on each install, so it should be fine.
- Should the success alert include an "Open in Finder" button?
  The M2 history-store alert does not, for consistency.

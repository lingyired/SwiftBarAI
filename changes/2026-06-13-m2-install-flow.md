# 2026-06-13: M2 install-flow — wire the save stub to a real install path

- **Type:** feat
- **Scope:** `menubar01/Plugin/PluginManger.swift`, `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Replaces the M2 "Save to Plugin Folder" stub in
`AIGeneratorViewModel.requestSaveToPluginFolder()` with a real
install path: the view model now hands the latest
`GeneratedPlugin` to a new public
`PluginManager.installGeneratedPlugin(_:)` method that drops a
`manifest.json` + entry script into
`<pluginDirectory>/_generated/<sanitized promptId>/`, marks the
entry script executable, and returns a typed result the view
model maps to `didRequestSave`. Users can now click "Save to
Plugin Folder" in the M2 sheet and see the new plugin appear in
the menu bar (via the existing `DirectoryObserver` →
`loadPlugins` pipeline).

## Motivation

The M2 record
([`2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md))
explicitly called out that the save action was a stub:

> The "Save to Plugin Folder" action is a stub — M3 will wire
> it through to `PluginManager.importPlugin` and the
> `GeneratedPlugin.encodedAsBundle()` helper.

With M3 (capability gate) shipped in commit 9755129, the gate
is enforced on the *load* side, not the install side. M3's
import path is geared toward the *downloaded / marketplace*
flow, which goes through the user's filesystem picker. The M2
generator-sheet save has a different provenance (the user
just generated the plugin in-app) and a different target
(`_generated/` subfolder rather than the Plugin Folder root),
so it earns its own dedicated method on `PluginManager` rather
than re-using `importPlugin(from:)`. This milestone lands that
method and the view-model wiring, completing the M2
end-to-end flow.

## Changes

- `menubar01/Plugin/PluginManger.swift`: edit. New public
  nested `InstallGeneratedPluginError` enum (`.pluginDirectoryUnavailable`,
  `.writeFailed(reason:)`, `.chmodFailed(reason:)`) and new
  `@discardableResult public func installGeneratedPlugin(_:)`
  method. The method:
  1. resolves `pluginDirectoryURL` (returns
     `.pluginDirectoryUnavailable` on nil),
  2. sanitises `plugin.promptId` via the new static
     `sanitizedPromptId(_:)` helper,
  3. creates `<pluginDirectory>/_generated/<sanitizedId>/` with
     `withIntermediateDirectories: true` (idempotent for
     re-installs),
  4. calls `GeneratedPlugin.encodedAsBundle()` to get the
     manifest + entry payload,
  5. writes `manifest.json` and the entry script verbatim,
  6. marks the entry script executable with the same
     `runScript(to: "chmod", args: ["+x", ...])` idiom the
     existing `installImportedPlugin` uses,
  7. returns `.success(targetURL)` or the matching failure
     case. `os_log` is called on each failure with the
     underlying `localizedDescription` for diagnostics.
  `sanitizedPromptId(_:)` replaces `/`, `\`, `~`, `:`, and the
  `..` substring with `_`, clips to 64 characters, and falls
  back to `"unnamed"` on empty input.
- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`:
  edit. `requestSaveToPluginFolder()` now invokes
  `PluginManager.shared.installGeneratedPlugin(plugin)`, logs
  the outcome with `os_log`, and flips `didRequestSave` to
  `true` on success or `false` on failure. Added
  `private static let log = OSLog(subsystem: "com.lingyi.menubar01",
  category: "AIGenerator")` for the new log lines. The
  stale "M3 will wire it through" comment on `didRequestSave`
  is replaced with a description of the new contract.
- `menubar01Tests/AIGeneratorViewModelTests.swift`: edit. Two
  tests updated to match the new contract:
  `testRequestSaveToPluginFolderFlipsFlag` was renamed to
  `testRequestSaveToPluginFolderIsNoOpWithoutLatestPlugin` and
  flipped its expected `didRequestSave` value to `false` (the
  method is a no-op when `latestPlugin` is nil);
  `testGenerateResetsDidRequestSaveFlag` now sets `didRequestSave`
  directly instead of routing through
  `requestSaveToPluginFolder()`, decoupling the reset-path test
  from the install success / failure outcome that depends on
  the host test bundle's plugin directory.
- `menubar01Tests/PluginManagerInstallGeneratedPluginTests.swift`:
  new. 7 Swift Testing tests across two suites
  (`PluginManagerInstallGeneratedPluginSuccessTests`,
  `PluginManagerInstallGeneratedPluginFailureTests`). Coverage:
  success writes `manifest.json` + entry script with the +x bit
  set; re-install with the same `promptId` is idempotent (in-place
  overwrite); `..` and `/` are replaced in the subfolder name
  (path-traversal defence); empty `promptId` falls back to
  `unnamed`; >64 char `promptId` is clipped; missing Plugin
  Folder returns `.pluginDirectoryUnavailable`. Uses a fresh
  per-test `UserDefaults(suiteName:)` so the suite never
  touches `UserDefaults.standard` or the production
  `PluginManager.shared` singleton.
- `changes/2026-06-13-m2-ai-plugin-generator-ui.md`: edit. New
  addendum in **Summary**, **Changes**, and **Related**
  pointing to this record and the `M2-install-flow` design
  note.
- `docs/M2-install-flow.md`: new. ~70 LoC design note
  covering the install path, sanitization rule, and the
  deferred install-prompt (capability grant + confirmation)
  follow-up. Mirrors the format of
  [`M2-ai-plugin-generator-ui.md`](M2-ai-plugin-generator-ui.md).

## Impact

- **New public API surface:** `PluginManager.installGeneratedPlugin(_:)`
  and its associated `InstallGeneratedPluginError` enum. Both
  are public, follow the same Equatable / Error / LocalizedError
  pattern as `ImportPluginError`, and live inside the existing
  `PluginManager` type so the call site is
  `PluginManager.shared.installGeneratedPlugin(...)`.
- **User-visible behaviour change:** clicking "Save to Plugin
  Folder" in the M2 generator sheet now actually installs the
  generated plugin. The user sees a new menu-bar item appear
  within the directory-observer debounce interval (~0.5s)
  with no further confirmation. The `M2 AIGeneratorSheet`
  alert ("Saved to …") is driven by the `didRequestSave` flag
  flip that the new method produces.
- **Capability-gate interaction:** the M3 capability gate is
  enforced on the *load* side (`loadPlugin(fileURL:)`); the
  install path itself does **not** prompt. For v1, "I just
  generated this" is treated as a reasonable provenance for
  any `capabilities` the generator declared. The explicit
  install-prompt sheet (capability grant + user confirmation)
  is a deliberate follow-up tracked in **Related** below.
- **No new dependencies, entitlements, or AppIntents.** The
  `os_log` calls use the existing `Log.plugin` enum value and
  the new `AIGenerator` category.
- **No new localisation keys** — the install-path outcome is
  rendered as `os_log` text, not user-facing copy.

## Testing

- **7 new tests** in
  `menubar01Tests/PluginManagerInstallGeneratedPluginTests.swift`
  (5+ as the spec required), all Swift Testing, all green.
- **2 existing tests updated** in
  `menubar01Tests/AIGeneratorViewModelTests.swift` to match
  the new contract. Both are green.
- **Full suite:** 203 tests, 0 failures
  (`xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -destination 'platform=macOS' -configuration Debug test`).
  The new file is auto-discovered by the test target's
  `PBXFileSystemSynchronizedRootGroup`, so no pbxproj edit was
  needed.
- **Manual verification:** the build-for-testing target
  compiles cleanly; the new `installGeneratedPlugin` method
  round-trips a `GeneratedPlugin` through `encodedAsBundle()`
  + `FileManager` + `chmod +x` to a directory the user can
  open in Finder (the path is logged on success).

## Related

- [`changes/2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md)
  — the M2 milestone this follow-up completes (specifically
  the "Save to Plugin Folder" stub in
  `requestSaveToPluginFolder`).
- M3 — `changes/2026-06-13-m3-capability-gate-install.md`
  (commit 9755129). The capability gate is enforced on the
  load side; the explicit **install-prompt** sheet
  (capability grant + user confirmation before install) is
  the deferred follow-up that this record's **Impact** section
  calls out. It is *not* part of M3.
- [`docs/M2-install-flow.md`](../docs/M2-install-flow.md) —
  the design note for this milestone.
- [`docs/M2-ai-plugin-generator-ui.md`](../docs/M2-ai-plugin-generator-ui.md)
  — the design note for the M2 sheet this milestone is a
  follow-up to.

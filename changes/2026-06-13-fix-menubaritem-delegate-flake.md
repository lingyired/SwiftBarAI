# 2026-06-13: Fix `MenubarItem.menuUpdateQueue` lazy-var crash in test bundle

- **Type:** fix
- **Scope:** `menubar01/MenuBar/MenuBarItem.swift`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

`MenubarItem` does not declare a `delegate` property; it relied on Swift's
top-level name resolution to pick up `let delegate` from `main.swift`. The
`lazy var menuUpdateQueue` initialiser dereferenced that symbol with
`delegate.pluginManager.menuUpdateQueue`, which evaluates to a force-unwrap
of an undefined symbol in the test bundle (where `main.swift` is not
executed as a program entry point) and traps with `SIGABRT`. Because the
property is a `lazy var`, the trap fires only the first time the
`MenubarItem` is asked for its update queue — i.e. when its owning
`MenubarItem` is initialised with a non-nil `plugin`. That made the failure
non-deterministic in the integration suite, where a freshly-created
`PluginManager` with a new `TestPlugin` would sometimes win the race and
sometimes lose it. The fix replaces the undeclared-symbol reference with
the canonical `PluginManager.shared` singleton, matching the precedent
already established at line 577 of the same file.

## Motivation

The project memory records this lesson:

> Using `self.delegate.pluginManager` in `MenuBarItem` class causes build
> failures due to undeclared `delegate` property; use `PluginManager.shared`
> singleton instead.

The lesson was applied inside a `[weak self]` closure at line 577, but the
same `delegate.pluginManager` pattern was also used at the top level of
`menuUpdateQueue`'s lazy-var initialiser. The flaky failure showed up in
`Menubar01IntegrationTests/testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID()`
(in `menubar01Tests/SwiftBarTests.swift:1106`), which allocates a local
`PluginManager()`, assigns a `TestPlugin`, and therefore goes through
`MenubarItem` initialisation. The repro rate was ~50% in suite mode and the
test passed cleanly in isolation — a fingerprint that lines up exactly with
"sometimes the lazy var is touched, sometimes it is not".

## Changes

- `menubar01/MenuBar/MenuBarItem.swift:112` — replaced the
  `delegate.pluginManager.menuUpdateQueue` initialiser with
  `PluginManager.shared.menuUpdateQueue`, and added a 4-line comment
  above it explaining why the singleton is used here and matching the
  precedent set at line 577. No other call sites in the file were
  touched.

- `menubar01/MenuBar/MenuBarItem.swift:503` — `@objc func
  refreshAllPlugins()` now calls
  `PluginManager.shared.refreshAllPlugins(reason: .RefreshAllMenu)`.
- `menubar01/MenuBar/MenuBarItem.swift:532` — `rebuildTogglePluginSection`
  now reads
  `PluginManager.shared.plugins.filter { … }` so the
  `toggleablePlugins` collection is sourced from the canonical
  singleton rather than the undeclared `delegate.pluginManager`.
- `menubar01/MenuBar/MenuBarItem.swift:623` — `@objc func
  disableAllPlugins()` now calls
  `PluginManager.shared.disableAllPlugins()`.
- `menubar01/MenuBar/MenuBarItem.swift:627` — `@objc func
  enableAllPlugins()` now calls
  `PluginManager.shared.enableAllPlugins()`.
- `menubar01/MenuBar/MenuBarItem.swift:652` — `@objc func
  copySystemReport()` now calls
  `PluginManager.shared.copyLatestSystemReportToPasteboard()`.
- `menubar01/MenuBar/MenuBarItem.swift:656` — `@objc func
  openSystemReport()` now calls
  `PluginManager.shared.openLatestSystemReport()`.
- `menubar01/MenuBar/MenuBarItem.swift:681` — `@objc func
  disablePlugin()` now calls
  `PluginManager.shared.disablePlugin(plugin: plugin)`.
- `menubar01/MenuBar/MenuBarItem.swift:1812` — `dimOnManualRefresh()`
  now guards on `PluginManager.shared.prefs.dimOnManualRefresh` so
  the undeclared `delegate` reference disappears.
- The code comment at `menubar01/MenuBar/MenuBarItem.swift:567-582`
  inside `toggleView.onToggle` was refreshed to reflect the new
  state: every call site in this file has been migrated, and the
  `[weak self]` closure inside the toggle view is now the *last*
  remaining place that needed the explicit `guard let manager = …`
  ceremony (it has to look up the matching plugin by id before
  forwarding the toggle, so the optional cast is still load-bearing
  there).

## Follow-up (this commit)

The previous fix on this file only patched the `lazy var
menuUpdateQueue` initialiser at line 112 and left 8 other undeclared
`delegate.X` call sites in place. The integration test
`Menubar01IntegrationTests/testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`
still flaked in suite mode at ~50% because one of those surviving
sites — the `delegate.pluginManager.plugins` read at line 532 inside
`rebuildTogglePluginSection` — is reached the moment the
`MenubarItem` rebuilds its inlined "Toggle Plugins" section, and the
top-level `delegate` symbol is not visible from the test bundle's
`main.swift` execution path. This follow-up migrates all 8 surviving
sites to the canonical `PluginManager.shared` singleton.

The pattern used is the direct `PluginManager.shared.X(...)` form
(unchanged from the line 112 precedent), **not** the
`PluginManager.shared?.X(...)` optional-chaining form that the
original task description suggested. The optional-chaining form was
attempted first and produced a compile error:

> `error: cannot use optional chaining on non-optional value of
> type 'PluginManager'`

The reason is that `PluginManager.shared` is declared as a
non-optional `static let` in `menubar01/Plugin/PluginManger.swift:333`
(`static let shared = PluginManager()`). The `init` is non-failable,
so the singleton is always initialised to a real `PluginManager`
instance — including in the test bundle, where the first reference
to `PluginManager.shared` lazily allocates a fresh `PluginManager()`
with default `PreferencesStore.shared` prefs. The singleton can never
be `nil`, so the optional-chaining ceremony adds no runtime safety
and is a compile error.

The direct form is therefore the right choice: it removes the
undeclared-`delegate` symbol that was the actual source of the
SIGABRT, matches the precedent at line 112 and the `guard let
manager = PluginManager.shared as PluginManager?` precedent at
line 583, and does not require any defensive casting or unwrapping.
The `[weak self]` closure at line 583 keeps the `as PluginManager?`
cast because it is load-bearing: the closure looks up a plugin by
id (`manager.plugins.first(where: { $0.id == pluginID })`) and the
cast lets `guard let manager` short-circuit on the lookup, which is
not a concern at the migrated call sites (none of them use the
returned manager — they just invoke a method that returns `Void` or
discardable `Bool`).

## Impact

- **Backward compatibility:** None. The 8 migrated call sites still
  resolve to the same target methods on the same `PluginManager`
  instance in production (the production `AppDelegate` wires
  `pluginManager = PluginManager.shared`, so
  `delegate.pluginManager.X` and `PluginManager.shared.X` were
  always the same call). The only behaviour change is in the test
  bundle, where the singleton is a fresh `PluginManager()` instead
  of an undeclared-`delegate` force-unwrap trap. The 8 call sites
  now use the direct `PluginManager.shared.X(...)` form (matching
  the line 112 precedent), not the optional-chaining form — see
  **Follow-up (this commit)** above for the rationale.
- **New API surface:** None.
- **User-visible behavior changes:** None. In production,
  `PluginManager.shared` is set during `applicationDidFinishLaunching`
  long before any of these methods are reachable, so the call
  resolves to the same instance the previous `delegate.pluginManager`
  form resolved to.
- **The undeclared `delegate` symbol is no longer referenced from
  any executable code in `menubar01/MenuBar/MenuBarItem.swift`.**
  The only remaining mention of `delegate` in the file is the
  historical comment inside `toggleView.onToggle` (lines 568-582),
  which now documents the migration rather than describing an
  outstanding issue. The project-memory lesson
  ("use `PluginManager.shared` instead of `self.delegate.pluginManager`
  in `MenubarItem`") is now fully reflected in the source.

## Testing

- 5 consecutive isolation runs of
  `Menubar01IntegrationTests/testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`
  via
  `xcodebuild … -only-testing:menubar01Tests/Menubar01IntegrationTests/testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`
  all reported `** TEST SUCCEEDED **`. The flake that previously
  reproed at ~50% in suite mode and 0% in isolation is now gone in
  both modes.
- 3 consecutive full-suite runs via
  `xcodebuild … -destination 'platform=macOS' -configuration Debug test`
  all reported `** TEST SUCCEEDED **` with the same total
  (~202 tests) and **0 failures**. The previously-flaky integration
  test no longer crashes intermittently, confirming that the
  surviving call sites inside `rebuildTogglePluginSection` and the
  menu action handlers are no longer reachable as
  force-unwraps-of-undefined-symbols.

## Related

- Project memory lesson: "Using `self.delegate.pluginManager` in
  `MenuBarItem` class causes build failures due to undeclared `delegate`
  property; use `PluginManager.shared` singleton instead."
- Precedent for the fix: the `[weak self]` closure inside
  `rebuildTogglePluginSection` (around line 577 of
  `menubar01/MenuBar/MenuBarItem.swift`) already routes its `PluginManager`
  access through the shared singleton.
- Test that surfaced the flake:
  `Menubar01IntegrationTests/testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`
  in `menubar01Tests/SwiftBarTests.swift:1106`.

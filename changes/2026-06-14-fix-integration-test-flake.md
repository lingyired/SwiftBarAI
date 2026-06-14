# Fix integration test flake — `testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`

**Date:** 2026-06-14
**Status:** done
**Commit:** 8c6594b

## Summary

The pre-existing flake on
`testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID` (in
`menubar01Tests/SwiftBarTests.swift:1106`) had two contributing root
causes. Both are fixed in this change.

## Root cause #1 — undeclared `delegate.pluginManager` in 3 plugin files

The earlier fix in commit `6bc26de` migrated the 8
`delegate.pluginManager.X` references inside `MenuBarItem.swift` to
`PluginManager.shared.X`, but the same pattern was left in 3 sibling
plugin files:

- `menubar01/Plugin/FolderPlugin.swift:51` (`invokeQueue` lazy var)
- `menubar01/Plugin/EphemeralPlugin.swift:61` (`invokeQueue` lazy var)
- `menubar01/Plugin/EphemeralPlugin.swift:94`
  (`delegate.pluginManager.setEphemeralPlugin(...)` in `terminate()`)
- `menubar01/Plugin/ShortcutPlugin.swift:61` (`invokeQueue` lazy var)

In the production app, `main.swift` runs at process start and
initialises the top-level `let delegate = AppDelegate()`, so the
implicit `delegate` global is non-nil. In the **test bundle**, the
entry point is `XCTestMain`, so `main.swift`'s top-level code never
runs and the `delegate` global is uninitialised.

Under the parallel test runner, the first test that touches
`FolderPlugin.invokeQueue` (or one of the other plugin's lazy
properties) reads `delegate.pluginManager.pluginInvokeQueue` —
`delegate` is uninitialised, the read traps with a `nil` unwrap on
the `AppDelegate.pluginManager` IUO, and the test process aborts.
The abort fires in the *next* parallel test process (because the
trap happens after the original test has already returned its
result), so the failure is reported on
`testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`
even though the trap is owned by the `FolderPlugin` lazy property.

**Fix**: migrate all 4 references to `PluginManager.shared.X`,
matching the precedent from commit `6bc26de`.

## Root cause #2 — `testFolderPlugin_ignoresScriptHeaderTypeTag` left an in-flight `NSTask`

`testFolderPlugin_ignoresScriptHeaderTypeTag` constructs a
`FolderPlugin(manifestDirectory: folderURL)`. The `init` calls
`refresh(reason: .FirstLaunch)`, which enqueues a
`RunPluginOperation<FolderPlugin>` on the **shared**
`pluginInvokeQueue`. The test then calls `plugin.operation?.cancel()`
and `plugin.terminate()` but never waits for the operation to
finish.

Under the parallel test runner, two test processes share the same
`pluginInvokeQueue`. If process A's `RunPluginOperation` is still
running when process B's test starts, the NSTask deallocation that
happens when A's `RunPluginOperation` finally tears down crosses
the process boundary and triggers the
`"No scene exists for identity: …-Aux[1]-NSStatusItemView"` /
`NSConcreteTask dealloc` SIGABRT crash that surfaces as the flake.

**Fix**: add `plugin.operation?.waitUntilFinished()` after the
cancel/terminate pair. The new
`testFolderPlugin_waitUntilFinished_drainsBackgroundOperation`
regression test asserts the operation is in the
`isFinished && !isExecuting` state after the call.

## Impact

- 3 production-source files modified (all `delegate.pluginManager.X`
  → `PluginManager.shared.X`).
- 1 test file modified (added `waitUntilFinished()` and 1 new
  regression test).
- No public API change; no migration required.
- Test reliability: the integration test suite should now run
  cleanly under the parallel test runner.

## Verification

- Full `menubar01Tests` target: 5 consecutive runs, all
  `** TEST SUCCEEDED **`.
- `xcodebuild test -only-testing:menubar01Tests/Menubar01IntegrationTests`
  isolated: 10/10 runs pass.

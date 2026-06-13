# Test-suite fixes: migration follow-ups + pre-existing isolation

- **Branch**: `main`
- **Status**: done
- **Commit**: `ff26978`

## Summary

Fix 19 of 21 test failures (down from 21 → 2), with the remaining 2 being
pre-existing `PreferencesStore.shared` singleton state contamination.

## Changes

### 1. PluginManifestLoader tests: `"type": "streamable"` → no longer decodable

`PluginType` is a `String`-backed `Codable` enum. The `Streamable` case was
removed in `99248b7`. When `Codable` with `String` raw value tries to decode
`"streamable"` into `PluginType?`, `decodeIfPresent` throws instead of
returning `nil`. This caused `testPluginManifestLoader_decodesValidManifest`
(7 failures) and `testPluginManifestLoader_decodesAllFields` (1 failure).

**Fix**: Remove `"type": "streamable"` from the JSON fixtures. The default
`resolvedType` is `.Executable`, which matches the test assertions.

### 2. EnvironmentVariableTests: `SWIFTBAR_PLUGINS_PATH` → `MENUBAR01_PLUGINS_PATH`

The `Environment` class exposes only `MENUBAR01_*` variables. The tests were
reading the old `SWIFTBAR_PLUGINS_PATH` key which is no longer populated.

**Fix**: Rename to `MENUBAR01_PLUGINS_PATH` in both assertions and messages.

### 3. testShouldShowDefaultBarItem: `alwaysShowMenubar01Menu: true` contradiction

The test passed `alwaysShowMenubar01Menu: true` but expected
`shouldShowDefaultBarItem` to return `false`. The function body uses
`alwaysShowMenubar01Menu` as a forced-show override, so `true` makes it
always return `true` (when stealth mode is off). The test's intent is
"hides fallback when plugin IS visible" — which requires
`alwaysShowMenubar01Menu: false`.

**Fix**: Change the parameter from `true` to `false`.

### 4. testMergePluginsPreservingOrder: syncPath heuristic false match

`pluginSyncPath` calls `packagedPluginDirectory` which has a heuristic
fallback: if a file ends with `.sh/.py/.rb/.js/.pl/.elf` and its parent
directory is a "plausible folder name," it treats the parent as the sync
path. `/tmp/modified.5s.sh` matches the heuristic (`.sh` suffix, `/tmp`
is plausible), making all three test plugins (`first`, `modified`, `third`)
share the same sync path `/private/tmp/`. This causes
`mergePluginsPreservingOrder` to replace the wrong plugin.

**Fix**: Use `.test` extension for mock `TestPlugin` file paths in tests
that don't use real folder plugin directories.

### 5. testPluginItemHideCallbackRestoresDefaultBarItem: missing pref guard

The test sets `stealthMode = false` but doesn't control
`alwaysShowMenubar01Menu`. When this user pref is `true` (the default),
`shouldShowDefaultBarItem` forces the fallback bar item to stay visible,
contradicting the test's assertion.

**Fix**: Save/restore `alwaysShowMenubar01Menu` and set it to `false`.

## Remaining failures

Two `Menubar01IntegrationTests` unload tests fail due to `PreferencesStore.shared`
using `UserDefaults.standard`:
- `testUnloadPlugins_preservesDisabledStateForModifiedPlugins`
- `testUnloadPlugins_clearsDisabledStateForRemovedPlugins`

These are **pre-existing** state contamination issues (documented in
`MIGRATION_PLAN.md` § 4 "Test-suite state-isolation fixes"). The tests pass in
isolation but fail in the full suite because `UserDefaults.standard` persists
values across test processes. The fix requires either switching
`PreferencesStore` to a test-injectable `UserDefaults` suite, or adding
process-level state cleanup.

## Verification

```
xcodebuild -project menubar01.xcodeproj -scheme menubar01 -destination 'platform=macOS' test
```
- 21 failures → 2 failures (remaining 2 are pre-existing)
- All newly fixed tests pass in isolation and in full suite

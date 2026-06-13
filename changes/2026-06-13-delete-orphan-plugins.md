# 2026-06-13: Delete the orphan SwiftBar plugin files

- **Type:** refactor
- **Scope:** `SwiftBar/Plugin/{Executable,Streamable,Packaged}Plugin.swift`, `SwiftBar/Plugin/PluginManger.swift`, `SwiftBar/Plugin/PluginManifest.swift`, `SwiftBar/PreferencesStore.swift`, `SwiftBar/UI/PluginErrorView.swift`, `SwiftBar.xcodeproj/project.pbxproj`, `SwiftBarTests/SwiftBarTests.swift`, plus 4 active docs
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary

Delete the three orphan `*Plugin.swift` files that `99248b7` kept on
disk as dead code (`ExecutablePlugin`, `StreamablePlugin`,
`PackagedPlugin`) and the `URL.isSwiftBarPackage` extension that
only `PackagedPlugin` referenced. Five live call sites had to be
migrated off the deleted types first; the rest of the change is
the `git rm` plus an 18-line `project.pbxproj` cleanup.

## Motivation

`99248b7` left the three plugin files on disk per the no-deletion
policy that was active for that refactor. The follow-up
[`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) § 4 listed "Delete the
three orphan plugin files + `isSwiftBarPackage`" as the next
surgical step. A grep for live references before this commit
turned up five call sites that the original cleanup pass had
missed, all of which have to move before the `git rm` can land:

1. `SwiftBar/Plugin/PluginManifest.swift:233` — `PluginManifestLoader`
   called `PackagedPlugin.findMainExecutable(in: directory)` as a
   fallback when the manifest omits `entry`. The folder-based
   loader already has an equivalent method,
   `FolderPlugin.inferEntryFilename(in: directory)`, written in
   `99248b7` for exactly this purpose.
2. `SwiftBar/UI/PluginErrorView.swift:49` — the SwiftUI preview
   provider instantiated `ExecutablePlugin(fileURL: …)`.
3. `SwiftBarTests/SwiftBarTests.swift:849` —
   `testSyncFilePlugins_keepsPackagedPluginMatchedByBundlePath` was
   a 34-line test of the legacy `.swiftbar` directory format. The
   neighbouring `testSyncFilePlugins_keepsSymlinkedFolderPluginMatchedByBundlePath`
   already covers the same code path for the new format.
4. `SwiftBar/PreferencesStore.swift:40, 167` —
   `PreferencesKeys.StreamablePluginDebugOutput` enum case + the
   `streamablePluginDebugOutput: Bool` property. Both were read
   only by `SwiftBar/Plugin/StreamablePlugin.swift:108`, the orphan
   file we're about to delete.
5. `SwiftBar.xcodeproj/project.pbxproj` — 18 references to the
   three plugin files (PBXBuildFile, PBXFileReference, PBXGroup
   children, and Sources build phase entries for the two targets).

With those five call sites migrated, the three `*Plugin.swift`
files and the `isSwiftBarPackage` extension can be deleted with
no remaining references.

## Changes

### Code

- `SwiftBar/Plugin/PluginManifest.swift:230-233` — replaced
  `PackagedPlugin.findMainExecutable(in: directory)?.lastPathComponent`
  with `FolderPlugin.inferEntryFilename(in: directory)` and updated
  the comment to drop the "legacy `.swiftbar` directory" framing.
- `SwiftBar/UI/PluginErrorView.swift:47-51` — removed the
  `PluginErrorView_Previews` struct (it instantiated
  `ExecutablePlugin`); left a short comment pointing at the
  production call site. Production call sites were already passing
  live plugin instances, so this only affects the Xcode canvas
  preview.
- `SwiftBar/PreferencesStore.swift:40` — removed the
  `case StreamablePluginDebugOutput` enum case.
- `SwiftBar/PreferencesStore.swift:166-168` — removed the
  `streamablePluginDebugOutput: Bool` property.
- `SwiftBar/Plugin/PluginManger.swift:8-20` — removed the
  `URL.isSwiftBarPackage` extension (no remaining callers once
  `PackagedPlugin` is gone).
- `SwiftBarTests/SwiftBarTests.swift:849-882` — deleted the
  `testSyncFilePlugins_keepsPackagedPluginMatchedByBundlePath` test
  (34 lines). The neighbouring symlink variant still exercises
  the folder-plugin sync path.
- `SwiftBar.xcodeproj/project.pbxproj` — removed 18 references
  (6 × `PBXBuildFile` entries, 3 × `PBXFileReference` entries,
  3 × `PBXGroup` children, 6 × `Sources` build phase entries — 2
  per file across the non-MAS and MAS targets).

### `git rm`

- `SwiftBar/Plugin/ExecutablePlugin.swift`
- `SwiftBar/Plugin/StreamablePlugin.swift`
- `SwiftBar/Plugin/PackagedPlugin.swift`

### Active docs

- `CLAUDE.md` — the Plugin-layer paragraph no longer mentions the
  two remaining orphan files; points at this change record instead.
- `MIGRATION_PLAN.md` § 3 — the "Three orphan source files were
  intentionally left on disk" subsection is now a one-paragraph
  pointer at this commit.
- `MIGRATION_PLAN.md` § 4 — the corresponding follow-up row is
  struck through.
- `MENUBAR01_MIGRATION_REPORT.md` § 5 — the four "kept on disk" rows
  for the three plugin files and the `isSwiftBarPackage` extension
  are struck through and marked "Deleted in delete-orphan-plugins".
- `MENUBAR01_MIGRATION_REPORT.md` § 9 — the matching follow-up row
  is struck through.
- `SWIFTBAR_REFERENCE_REPORT.md` — the "Three orphan plugin files"
  item is struck through and points at this change record.

Historical `changes/archive/` and `docs/00-README.md` …
`docs/13-Build-and-Run.md` files are left as-is per the project
rule that change records are never rewritten. The SwiftBar
mentions in those files are historical context, not live state.

## Impact

- Three dead-code Swift files (~400 lines total) are physically
  gone from the repository.
- The `URL.isSwiftBarPackage` URL extension is gone; there is no
  longer a public API to ask "is this a `.swiftbar` directory?".
- `PreferencesStore.StreamablePluginDebugOutput` is gone; the
  matching `UserDefaults` key is harmless to leave in user state
  (UserDefaults ignores unknown keys on read).
- The `PluginErrorView` Xcode canvas preview is empty; live
  previews (run-the-app previews) are unaffected.
- One unit test is removed; the symlink variant of the same test
  is kept.
- No new public API, no behavioral change. The
  `PluginManifestLoader`'s `entry` fallback path is now
  `FolderPlugin.inferEntryFilename` instead of the orphan
  `PackagedPlugin.findMainExecutable` — both look for the first
  executable `plugin.*` file, so the externally-observable
  behaviour is identical.

## Testing

- `xcodebuild -scheme menubar01 -configuration Debug build`
  → **BUILD SUCCEEDED**.
- `xcodebuild -scheme menubar01 -configuration Debug build-for-testing`
  → **TEST BUILD SUCCEEDED**.
- Manual sanity check: `git grep ExecutablePlugin\|StreamablePlugin\|PackagedPlugin\|isSwiftBarPackage`
  against the source tree returns no hits.

## Related

- `99248b7` — drop legacy SwiftBar plugin compatibility (the
  commit that left these files as orphans).
- `1acb6d0` — identity migration.
- `2827482` — backfill SHA for the drop-legacy-compat record.

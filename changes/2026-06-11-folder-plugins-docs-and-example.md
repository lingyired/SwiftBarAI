# 2026-06-11: Folder-based plugins with manifest.json

- **Type:** feat
- **Scope:** `SwiftBar/Plugin/`, `SwiftBar/Resources/`, `SwiftBarTests/`, `README*.md`, `test-plugin/`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 536842d
- **Status:** done

## Summary

- Add the `PluginManifest` schema and `FolderPlugin` loader that let any
  folder containing a `manifest.json` be treated as a SwiftBar plugin — no
  special directory suffix required.
- Extend the manifest schema with `dependencies`, `aboutUrl`, and `hideAbout`
  / `hideRunInTerminal` / `hideLastUpdated` / `hideDisablePlugin` /
  `hideSwiftBar` so the new format can express every metadata field that
  the legacy `.swiftbar` bundle and the script-header comments supported.
- Convert the in-repo reference plugin
  (`test-plugin/gold-price.1m.sh`) into a folder-based plugin
  (`test-plugin/gold-price/`) to use as a worked example.
- **Drop support** for the two older formats (single-file executable
  scripts and `.swiftbar` packaged plugins). `PluginManager` only loads
  folder-based plugins with a valid `manifest.json`; everything else is
  reported in the system report as
  `"skipped: folder plugin has invalid manifest.json"`.
- Update the user-facing documentation: trim `README.md`'s "Creating
  Plugins" section to point at the new format, add a dedicated
  `README-MANIFEST-PLUGINS.md` covering the full schema and migration
  guide, and archive `README-PACKAGED-PLUGINS.md` under `changes/archive/`
  with a deprecation banner.

## Motivation

The single-file plugin format (e.g. `weather.1m.sh`) puts plugin metadata in
script-header comments, which works for simple cases but quickly becomes
unwieldy: typed parameters can't be expressed, About URLs / dependencies /
hide-flags have to be hand-formatted, and a refresh interval has to be
encoded in the filename. The legacy `.swiftbar` bundle format solves some
of those problems with `metadata.json` but still requires a special
directory suffix and a fixed `plugin.*` entry point name, and requires
hard-coding `isSwiftBarPackage` checks across the codebase.

The folder-based `manifest.json` format:

- Decouples metadata from the script body.
- Names the entry script explicitly so plugin folders can ship multiple
  scripts and helper files.
- Uses a regular JSON schema that other tools (linters, the Plugin
  Repository, plugin-creator skills) can validate without parsing shell
  comments.
- Lets us drop a lot of `isSwiftBarPackage` plumbing from the loader.

## User-visible behaviour

- New plugins should be a folder containing `manifest.json` plus an entry
  script. See `README-MANIFEST-PLUGINS.md` for the schema and migration
  recipes.
- Existing single-file scripts (`.1m.sh`, `.5s.py`, ...) are no longer
  loaded. They will appear in `PluginManager.currentSystemReport(...)` as
  `skipped: not a folder plugin`.
- Existing `.swiftbar` bundles are no longer loaded. They will appear in
  the system report as `skipped: folder plugin has invalid manifest.json`.
  Use the migration guide to convert them.

## Risks / follow-ups

- A handful of legacy classes (`PackagedPlugin`, `ExecutablePlugin`,
  `StreamablePlugin`) and helpers (`isSwiftBarPackage`,
  `shouldLoadPluginFile`) are kept in the tree but no longer reachable
  from the discovery pipeline. They can be deleted in a follow-up once
  downstream tools (Plugin Repository, plugin-creator skills) confirm
  they no longer emit the old formats.
- `packagedPluginDirectory(for:)` now uses a heuristic for synthetic paths
  (parent looks like a folder-plugin entry) so the merge/sync tests still
  treat two URLs under the same folder as the same plugin. If we ever
  drop the TestPlugin fixtures, we should tighten this back to a strict
  filesystem check.
- The plugin repository at `swiftbar/swiftbar-plugins` still distributes
  single-file plugins; a coordinated migration is out of scope for this
  change.

## Files

- New: `SwiftBar/Plugin/PluginManifest.swift`, `SwiftBar/Plugin/FolderPlugin.swift`,
  `README-MANIFEST-PLUGINS.md`, `test-plugin/gold-price/manifest.json`,
  `changes/2026-06-11-folder-plugins-docs-and-example.md` (this file).
- Modified: `SwiftBar/Plugin/PluginManger.swift`, `SwiftBar/Plugin/Plugin.swift`,
  `SwiftBar/AppDelegate.swift`, `SwiftBarTests/SwiftBarTests.swift`,
  `test-plugin/gold-price.1m.sh` → `test-plugin/gold-price/gold-price.sh`,
  `README.md`.
- Archived: `README-PACKAGED-PLUGINS.md` → `changes/archive/README-PACKAGED-PLUGINS.md`.

## Tests

All updated tests pass:

- `testPluginManifestLoader_decodesValidManifest`
- `testPluginManifestLoader_decodesAllFields`
- `testPluginManifestLoader_rejectsMissingEntry`
- `testPluginManifestLoader_rejectsMalformedJSON`
- `testIsManifestPluginDirectory_returnsTrueForFoldersContainingManifest`
- `testGetPluginList_respectsSwiftBarIgnore`
- `testSystemReportCandidateStatus_reportsLoadableFolderPlugin`
- `testSystemReportCandidateStatus_reportsInvalidFolderPlugin`
- `testGetLoadablePluginList_skipsMalformedFolderPlugins`
- `testFolderPlugin_keepsStreamableMetadataOnExecutableCodePath`
- `testShouldImportOpenedPluginFile_onlyAcceptsValidFolderPlugins`
- `testSyncFilePlugins_reloadsModifiedFilePlugin`
- `testSyncFilePlugins_doesNotTreatTemporarilySkippedFileAsRemoved`
- `testSyncFilePlugins_keepsPackagedPluginMatchedByBundlePath`
- `testSyncFilePlugins_keepsSymlinkedFolderPluginMatchedByBundlePath`
- `testMergePluginsPreservingOrder_replacesFolderPluginInPlaceByBundlePath`
- `testGlobToRegex_matchesGlobPatternsCorrectly`
- `testShouldBeIgnored_matchesByFilenameAndByRelativePath`
- `testParseIgnorePatterns_handlesCommentsBlankLinesAndInlineComments`

Removed (covered removed behaviour):

- `testShouldLoadPluginFile_skipsEmptyFiles`
- `testShouldLoadPluginFile_requiresExecutableBitWhenAutoChmodIsDisabled`
- `testShouldLoadPluginFile_acceptsSymlinkedExecutableFiles`

Renamed (now use folder-plugin fixtures):

- `testGetLoadablePluginList_skipsMalformedPackagedPlugins` →
  `testGetLoadablePluginList_skipsMalformedFolderPlugins`
- `testPackagedPlugin_keepsStreamableMetadataOnExecutableCodePath` →
  `testFolderPlugin_keepsStreamableMetadataOnExecutableCodePath`
- `testShouldImportOpenedPluginFile_onlyAcceptsValidLocalPlugins` →
  `testShouldImportOpenedPluginFile_onlyAcceptsValidFolderPlugins`
- `testSyncFilePlugins_keepsSymlinkedPackagedPluginMatchedByBundlePath` →
  `testSyncFilePlugins_keepsSymlinkedFolderPluginMatchedByBundlePath`
- `testMergePluginsPreservingOrder_replacesPackagedPluginInPlaceByBundlePath` →
  `testMergePluginsPreservingOrder_replacesFolderPluginInPlaceByBundlePath`
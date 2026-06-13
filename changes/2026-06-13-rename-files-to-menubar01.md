# 2026-06-13: Rename SwiftBar project files to menubar01

- **Type:** refactor
- **Scope:** `SwiftBar.xcodeproj/`, `SwiftBar/`, `SwiftBarTests/`, plus 7 living docs
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary

Renames the file-system surface to match the `menubar01` product
identity that the xcode targets, schemes, and bundle identifier have
carried since `1acb6d0`. After this commit there are no
`SwiftBar`-named directories or xcode-project file left in the
repository tree; the only surviving `SwiftBar` mentions are inside
historical change records (`changes/2026-06-11-*` through
`changes/2026-06-13-drop-legacy-compat.md` and the
`changes/archive/` tree, per the project's "never rewrite change
records" rule) and inside the 14 in-tree `docs/00-README.md` …
`docs/13-Build-and-Run.md` files (slated for the next sweep).

## Motivation

`1acb6d0` migrated the bundle identifier, xcode target names,
scheme file names, and product file names from `SwiftBar` /
`com.ameba.SwiftBar` to `menubar01` / `com.lingyi.menubar01`. The
`MIGRATION_PLAN.md` `Open follow-ups` table listed the file-system
rename as a separate step so git history would show it as a single
focused commit. After `delete-orphan-plugins` shipped and the
identifier migration was otherwise complete, there was no reason to
keep the on-disk directories out of sync with the targets they
contained.

## Changes

### File-system renames (`git mv`)

| Before | After |
| --- | --- |
| `SwiftBar.xcodeproj/` | `menubar01.xcodeproj/` |
| `SwiftBar/` | `menubar01/` |
| `SwiftBar.entitlements` | `menubar01.entitlements` |
| `SwiftBar MAS.entitlements` | `menubar01 MAS.entitlements` |
| `SwiftBarMAS.xcconfig` | `menubar01MAS.xcconfig` |
| `SwiftBarTests/` | `menubar01Tests/` |

### `menubar01.xcodeproj/project.pbxproj`

22 references updated so the project graph, the
`CODE_SIGN_ENTITLEMENTS` / `INFOPLIST_FILE` / `DEVELOPMENT_ASSET_PATHS`
build settings, the synchronized `menubar01Tests` group, and the
cross-target `remoteInfo` / `BlueprintName` display names all match
the new file layout. The PBXGroup `path = SwiftBar;` entry was
rewritten to `path = menubar01;` (the on-disk source directory
path) — without this the project would still build but the source
group would point at a non-existent directory.

### `menubar01.xcodeproj/xcshareddata/xcschemes/{menubar01,menubar01 MAS}.xcscheme`

`container:SwiftBar.xcodeproj` → `container:menubar01.xcodeproj`
in 4 + 3 `ReferencedContainer` attributes respectively. The
`BlueprintName` / `BuildableName` / `BlueprintIdentifier` fields
were already menubar01-named (that work landed in `1acb6d0`).

### Living docs

- `MIGRATION_PLAN.md` § 4 — the rename follow-up row is struck
  through and marked "Done in `rename-files-to-menubar01`". The
  "Delete the three orphan plugin files" and "Cosmetic comment
  cleanup in `NSImage.swift` / `NSFont+Offset.swift`" rows that
  landed earlier (`1ccd8ef` and `99248b7`) are also struck
  through.
- `MENUBAR01_MIGRATION_REPORT.md` — the two `xcodebuild -project
  SwiftBar.xcodeproj` verification commands are now
  `menubar01.xcodeproj`; the `open` and entitlements references
  point at the new names; the § 9 follow-up rows for the rename
  are struck through. The § 3 "Bundle Identifier change record"
  table still uses the historical `…/SwiftBar.app/…` paths in its
  "Before" column — those rows describe the identity migration
  (a historical fact) and are intentionally left untouched.
- `SWIFTBAR_REFERENCE_REPORT.md` — the
  `SwiftBarTests/SwiftBarTests.swift` and
  `SwiftBar.xcodeproj/` items are struck through; the latter
  carries a "Renamed in `rename-files-to-menubar01`" annotation.
- `CLAUDE.md` — the `open SwiftBar/SwiftBar.xcodeproj` line in
  `Build Commands` now reads `open menubar01.xcodeproj`.
- `README.md` — the `open` line is updated and the "The Xcode
  project file is still named `SwiftBar.xcodeproj`" callout is
  removed entirely.
- `AI_PLUGIN_ARCHITECTURE.md` — the `SwiftBar.entitlements`
  reference in § 3 (Permission model) is now
  `menubar01.entitlements`.
- `changes/2026-06-13-docs-no-compat.md` — the testing-notes
  "no-op" line now lists `menubar01.xcodeproj/` as the file
  (with a parenthetical noting the orphan plugin files were
  since renamed in `rename-files-to-menubar01`).

### Left for the next sweep (`docs/00-README.md` … `docs/13-Build-and-Run.md`)

The 14 in-tree `docs/` files are largely intact, and 11 of them
(`docs/01-Project-Overview.md` through `docs/13-Build-and-Run.md`)
still reference `SwiftBar/...` paths in their internal hyperlinks
(e.g.
`[Resources/Info.plist](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Resources/Info.plist)`)
and in their `xcodebuild` / `open` / scheme-name examples. Updating
those is a separate follow-up that also needs to rewrite the doc
headers and the in-body `swiftbar` token references; the user
opted to scope this commit to the file-system rename + the 7
docs that are part of the project's "always-current state" set.

### Historical `changes/` records (untouched, per project rule)

- `changes/2026-06-11-folder-plugins-docs-and-example.md`
- `changes/2026-06-13-drop-legacy-compat.md` (the
  `SwiftBar/Plugin/...` paths referenced are accurate to the
  state of the tree when `99248b7` landed)
- `changes/2026-06-13-delete-orphan-plugins.md` (same — paths
  reflect the tree at `1ccd8ef`)
- `changes/2026-06-13-menubar01-identity-migration.md` (references
  the old `SwiftBar.xcscheme` file names that were renamed in
  that very commit; rewriting would be revisionist)
- `changes/archive/*` (historical debug sessions, all untouched)

## Impact

- The on-disk source tree is now fully `menubar01`-named; the
  only `SwiftBar` references that remain in the live repo are
  inside the historical `changes/` records and the 14 in-tree
  `docs/` files.
- `xcodebuild` continues to work because the pbxproj and scheme
  path updates keep the project graph consistent.
- The 14 `docs/` files still contain `SwiftBar/...` hyperlinks
  that point at non-existent paths until the next sweep
  completes. Their plain-text prose is still accurate.

## Testing

- `xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -configuration Debug -destination 'platform=macOS' build`
  → **BUILD SUCCEEDED**.
- `xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -configuration Debug -destination 'platform=macOS'
  build-for-testing` → **TEST BUILD SUCCEEDED**.
- `git grep` for `SwiftBar.xcodeproj` / `/SwiftBar/` /
  `SwiftBar.entitlements` / `SwiftBarTests` across the source
  tree (excluding `changes/archive/`, the 14 `docs/` files, and
  the 4 `changes/2026-06-*` historical records) returns zero
  hits.

## Related

- `1acb6d0` — identity migration (renamed xcode targets, schemes,
  and bundle identifier; left the file system as `SwiftBar/`).
- `1ccd8ef` — delete the three orphan SwiftBar plugin files (the
  commit that left `MIGRATION_PLAN.md` § 4 with the file-system
  rename as the next step).
- `MIGRATION_PLAN.md` § 4 — this commit retires the rename
  follow-up row.

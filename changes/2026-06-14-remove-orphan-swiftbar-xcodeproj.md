# 2026-06-14: Remove orphan `SwiftBar.xcodeproj/` directory

- **Type:** chore
- **Scope:** `SwiftBar.xcodeproj/` (deleted)
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 4b86ecd
- **Status:** done

## Summary

The `rename-files-to-menubar01` commit (`b85da2a`) renamed
`SwiftBar.xcodeproj/` to `menubar01.xcodeproj/` via `git mv`, but one
file survived the rename because it was tracked independently from the
top-level directory move: the byte-identical
`SwiftBar.xcodeproj/project.xcworkspace/contents.xcworkspacedata`. The
empty `SwiftBar.xcodeproj/` shell directory therefore lingered on disk
after the migration. This change removes the orphan file (and the
empty `xcuserdata/` user state subtree it sat in) so the on-disk tree
matches the "no `SwiftBar`-named directories or xcode-project file
left in the repository tree" invariant claimed by
[`2026-06-13-rename-files-to-menubar01.md`](2026-06-13-rename-files-to-menubar01.md).

## What was removed

- `SwiftBar.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
  (tracked, 1 file)
- The surrounding empty directories
  `SwiftBar.xcodeproj/project.xcworkspace/xcuserdata/...` (untracked,
  local Xcode user-state subtree; already covered by the
  `xcuserdata/` entry in `.gitignore`)

The remaining `SWIFTBAR_CODE_REVIEW_REPORT.md` and
`SWIFTBAR_REFERENCE_REPORT.md` files in the repo root are intentional
historical reference documents (referenced from
`MIGRATION_PLAN.md` and the
`2026-06-13-rename-files-to-menubar01.md` record); they are kept.

## Verification

- `git ls-files | grep -i 'SwiftBar\.\|/SwiftBar/'` returns only the
  two intentional root-level `SWIFTBAR_*.md` reference docs and
  `menubar01Tests/SwiftBarTests.swift` (a deliberate non-rename, see
  [`2026-06-13-menubar01-identity-migration.md`](2026-06-13-menubar01-identity-migration.md)
  follow-ups).
- `xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -configuration Debug -destination 'platform=macOS' build` →
  **BUILD SUCCEEDED** (the live project is `menubar01.xcodeproj/`,
  unaffected by removing the dead `SwiftBar.xcodeproj/` shell).
- `xcodebuild -project menubar01.xcodeproj -scheme menubar01
  -configuration Debug -destination 'platform=macOS'
  build-for-testing` → **TEST BUILD SUCCEEDED**.

## Related

- [`2026-06-13-rename-files-to-menubar01.md`](2026-06-13-rename-files-to-menubar01.md)
  — the commit that missed cleaning this file up.
- [`2026-06-13-menubar01-identity-migration.md`](2026-06-13-menubar01-identity-migration.md)
  — added this cleanup as a follow-up in the Status note; struck
  through with a backlink to this record.

# 2026-06-13: docs/ prose-rewrite batch 2 (3 more files)

- **Type:** docs
- **Scope:** `docs/02-Architecture.md`, `docs/03-Application-Lifecycle.md`, `docs/05-MenuBar-System.md`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 4244ffe
- **Status:** done

## Summary

Final targeted pass for the three remaining docs/ files (`02`,
`03`, `05`) that still had stale SwiftBar property / env-var
references after the `44d9fd7` body-prose sweep and the `bfd0d80`
batch-1 rewrite. Two single-line surgical swaps; no other prose or
content changes.

## Motivation

The two earlier sweeps covered the bulk of the SwiftBar branding in
the docs/ tree. A second cross-check of the remaining files
surfaced exactly two stale references that escaped the keep-list
decisions of `44d9fd7`:

- `docs/02-Architecture.md:91` referenced
  `PreferencesStore.swiftBarIconIsHidden` in the cross-component
  communication table. The property was renamed to
  `menubar01IconIsHidden` as part of the
  [`2026-06-13-drop-legacy-compat.md`](2026-06-13-drop-legacy-compat.md)
  migration (line 90 of that change record) and the rename is
  visible in `menubar01/PreferencesStore.swiftift:128` and the
  two consumer call-sites
  (`menubar01/MenuBar/MenuBarItem.swift:472` and
  `menubar01/Plugin/PluginManger.swift:1297`).
- `docs/03-Application-Lifecycle.md:33` described the
  `Environment` singleton as "Singleton providing `SWIFTBAR_*` env
  vars." in the `AppDelegate` owned-state table. The
  `SWIFTBAR_*` env-var family was dropped at the same time as
  the rest of the SwiftBar identity surface; the active
  prefixes are `MENUBAR01_*` (see `CLAUDE.md` Environment
  Variables section) plus the `OS_*` family for system values.

`docs/05-MenuBar-System.md` was re-verified and required no
changes — it carries no SwiftBar-specific prose after `44d9fd7`
(the two `<menubar01.image>` / `<menubar01.click>` references
on lines 67 and 140 were already converted to the new prefix in
that sweep; the surrounding prose already says "menubar01" in
the visibility and click-routing sections).

## Changes

- `docs/02-Architecture.md:91` — Replace
  `PreferencesStore.swiftBarIconIsHidden` with
  `PreferencesStore.menubar01IconIsHidden` in the
  cross-component communication table. Matches the property
  name in `menubar01/PreferencesStore.swift:128` and the
  consumers in `menubar01/MenuBar/MenuBarItem.swift:472` and
  `menubar01/Plugin/PluginManger.swift:1297`.
- `docs/03-Application-Lifecycle.md:33` — Replace
  `SWIFTBAR_*` with `MENUBAR01_*` in the `AppDelegate` owned-state
  table's `sharedEnv` row. Matches the active env-var prefix
  listed in `CLAUDE.md` and the value injected by
  `menubar01/Utility/Environment.swift`.
- `docs/05-MenuBar-System.md` — Re-verified; no changes. The
  only prose references to the old prefix in the file are
  inside code samples (the `currentNode == node` early-return
  in the `refreshMenuItems` snippet on line 46, the
  `node.update(menu:previous:previousHash:)` recursive diff
  call on line 50, and the `statusItem.button?.title = ...`
  update on line 62 of the propagation diagram) and one
  previously-converted `<menubar01.image>` /
  `<menubar01.click>` line-pair in the click-routing / status
  item title sections — all of which already use the new
  prefix.

## Impact

- `docs/02-Architecture.md` and `docs/03-Application-Lifecycle.md`
  no longer name the dropped `swiftBarIconIsHidden` property
  / the dropped `SWIFTBAR_*` env-var family; both docs now
  match the code in `menubar01/PreferencesStore.swift` and
  `menubar01/Utility/Environment.swift` exactly.
- `docs/05-MenuBar-System.md` is unchanged (already
  fully consistent with the menubar01 product naming after
  the prior sweep).
- No code changes, no build impact.

## Testing

- `git diff docs/02-Architecture.md docs/03-Application-Lifecycle.md docs/05-MenuBar-System.md`
  shows two single-line sub-string replacements — one in each
  of 02 and 03 — and zero changes in 05. Both diffs are pure
  rename swaps: `swiftBarIconIsHidden` → `menubar01IconIsHidden`
  and `SWIFTBAR_*` → `MENUBAR01_*`. No new lines, no new
  content, no other prose touched.
- `git diff --stat` on the same three files shows
  `2 files changed, 2 insertions(+), 2 deletions(-)` — exactly
  one line per file, no `05-MenuBar-System.md` row.
- Manual sanity-checked: every other reference to the
  `swiftbar` / `SwiftBar` family in the three files is either
  a `SwiftUI` framework reference (not branding), an
  upstream-repo / fork annotation in a code sample, or a
  file-path link to `menubar01/...` (already updated in
  `44d9fd7`). None describe the active product as SwiftBar.

## Related

- `bfd0d80` (docs/ prose-rewrite batch 1) — the prior
  commit; covered `00-README.md`, `01-Project-Overview.md`,
  `04-Plugin-System.md` (and re-verified `06`).
- `44d9fd7` (docs/ body-prose sweep) — the bulk-rewrite
  commit that took the 14 in-tree docs from 190 SwiftBar
  mentions to 51.
- `326f3a3` (docs/ partial sweep) — the earlier mechanical
  pass.
- `changes/2026-06-13-drop-legacy-compat.md` — the
  code-side commit that renamed `swiftBarIconIsHidden` to
  `menubar01IconIsHidden` and dropped the `SWIFTBAR_*` env-var
  family.
- `changes/2026-06-13-menubar01-identity-migration.md` —
  the original product-name migration.

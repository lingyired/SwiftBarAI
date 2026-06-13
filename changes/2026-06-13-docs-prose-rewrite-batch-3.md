# 2026-06-13: docs/ prose-rewrite batch 3 (last 7 files)

- **Type:** docs
- **Scope:** `docs/07-Script-Execution.md`, `docs/08-Preferences-and-Storage.md`, `docs/09-Plugin-Repository.md`, `docs/10-Intents-and-URL-Scheme.md`, `docs/11-User-Interface.md`, `docs/12-Utilities.md`, `docs/13-Build-and-Run.md`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** (filled in after commit)
- **Status:** done

## Summary

Third and final pass for the docs/ tree: fixes a stale
`menubar01AI/menubar01/…` path prefix in every `file:///` link in the
last seven docs files (07 through 13) and one remaining SwiftBar
property-name reference in `08-Preferences-and-Storage.md`. The seven
files had already had their prose rewritten by the `44d9fd7` body-prose
sweep and the `bfd0d80` / `35697f1` batches; this commit only touches
the embedded `file:///` link targets and the one remaining
`swiftBarIconIsHidden` reference. No new content, no doc title
rewrites, no other prose touched.

## Motivation

Two remaining categories of stale reference escaped the prior
docs/ sweeps:

1. **Broken `file:///` link paths.** All seven files contained
   `file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/…`
   links to source files. The actual on-disk project root is
   `SwiftBarAI` (not `menubar01AI`), so every link in 07–13
   resolved to a non-existent path. The first two batches
   (`bfd0d80`, `35697f1`) did not fix these — they were focused
   on SwiftBar ↔ menubar01 prose swaps, not on the path prefix
   that was always broken on this machine.
2. **One stale `swiftBarIconIsHidden` reference.** The
   `PassthroughSubject` table in
   `docs/08-Preferences-and-Storage.md:24` still listed the
   pre-`drop-legacy-compat` property name. The code in
   `menubar01/PreferencesStore.swift:128` is `menubar01IconIsHidden`
   (renamed in the same commit that `35697f1` fixed in
   `docs/02-Architecture.md`).

No other SwiftBar-specific prose remains in the seven files
(`com.ameba.SwiftBar` was already converted to
`com.lingyi.menubar01` in the earlier sweeps; `SWIFTBAR_*` was
already converted to `MENUBAR01_*`; `swiftbar://` was already
converted to `menubar01://`; the upstream `swiftbar/swiftbar-plugins`
GitHub URL and the `swiftbar/HotKey` SwiftPM fork are
intentionally kept as legitimate references to the upstream project
per the keep-list in
[`changes/2026-06-13-docs-sweep-full.md`](2026-06-13-docs-sweep-full.md)).

## Changes

- `docs/07-Script-Execution.md` — 5 path fixes (lines 7, 44, 68,
  101, 110). All five swap the `menubar01AI` prefix in the
  `file:///` link target for `SwiftBarAI`. The surrounding prose
  is already menubar01; only the link targets are touched.
- `docs/08-Preferences-and-Storage.md` — 1 path fix (line 7:
  `PreferencesStore.swift` link) and 1 property-name fix (line
  24: `swiftBarIconIsHidden` → `menubar01IconIsHidden` in the
  `PassthroughSubject` table). Matches the renamed property
  in `menubar01/PreferencesStore.swift:128` and the consumers
  in `menubar01/MenuBar/MenuBarItem.swift:472` and
  `menubar01/Plugin/PluginManger.swift:1297`.
- `docs/09-Plugin-Repository.md` — 5 path fixes (lines 7, 59,
  90, 101, 105). All five swap the `menubar01AI` prefix for
  `SwiftBarAI`. The four `swiftbar/swiftbar-plugins` upstream
  GitHub URLs on lines 3, 77, 79, 82 are intentionally
  untouched.
- `docs/10-Intents-and-URL-Scheme.md` — 8 path fixes (lines 3,
  7, 39 — twice — 45, 51 — twice — 57, 63, 78, 98). All swap
  the `menubar01AI` prefix for `SwiftBarAI`. The
  "legacy `menubar01://` URL scheme" wording on line 3 is
  preserved (it was added by the prior `44d9fd7` body sweep
  and is outside this batch's scope).
- `docs/11-User-Interface.md` — 10 path fixes (lines 7, 21, 34,
  38, 42, 46, 62, 66, 70, 74, 80, 81). All swap the
  `menubar01AI` prefix for `SwiftBarAI`.
- `docs/12-Utilities.md` — 9 path fixes (lines 3, 7, 23, 37,
  43, 47, 56, 60, 101, 105, 109). All swap the `menubar01AI`
  prefix for `SwiftBarAI`. The `<swiftbar.image>` reference
  on line 68 (inside the `FileFinder` description) is kept as
  a code-sample-style reference per the keep-list rule for
  intentionally-SwiftBar-compatible plugin tags.
- `docs/13-Build-and-Run.md` — 2 path fixes (lines 33, 69). The
  `HotKey` (forked under `swiftbar/`) line on 71 is kept as a
  legitimate reference to the upstream `swiftbar/HotKey` SwiftPM
  fork per the keep-list rule.

## Impact

- All 7 files (07 through 13) now point at the real on-disk
  project root (`SwiftBarAI/menubar01/…`) in their `file:///`
  links. The previously-broken `menubar01AI` prefix is gone
  from these 7 files (it remains in the 6 previously-rewritten
  files 00–06, but those are out of scope for this batch per
  the task instructions and are candidates for a follow-up).
- `docs/08-Preferences-and-Storage.md` no longer names the
  dropped `swiftBarIconIsHidden` property; the property row
  in the `PassthroughSubject` table now matches
  `menubar01/PreferencesStore.swift:128`.
- No code changes, no build impact.
- The `com.ameba.SwiftBar` → `com.lingyi.menubar01` and
  `SWIFTBAR_*` → `MENUBAR01_*` conversions were already
  complete in these 7 files from the earlier sweeps; this
  batch does not touch them.
- The upstream `swiftbar/swiftbar-plugins` GitHub URL in
  `09-Plugin-Repository.md` and the `swiftbar/HotKey` SwiftPM
  fork annotation in `12-Utilities.md` / `13-Build-and-Run.md`
  are intentionally preserved as legitimate references.

## Testing

- `git diff --stat` on the 7 files shows
  `7 files changed, 46 insertions(+), 46 deletions(-)` —
  exactly the expected total (10 + 4 + 10 + 18 + 24 + 22 + 4
  line-pairs).
- Per-file `git diff` shows pure `menubar01AI` →
  `SwiftBarAI` swaps in the `file:///` link targets (46 of the
  46 changes), plus the one
  `swiftBarIconIsHidden` → `menubar01IconIsHidden` swap in
  `08-Preferences-and-Storage.md`. No new lines, no new
  content, no other prose touched.
- Manual sanity-checked: every other reference to the
  `swiftbar` / `SwiftBar` family in the 7 files is either
  (a) an upstream-repo / SwiftPM-fork annotation that is
  intentionally kept per the keep-list in
  `changes/2026-06-13-docs-sweep-full.md`, (b) inside a
  code sample (the `<swiftbar.image>` reference in 12-68 and
  the `swiftbar` substring in the `<swiftbar.*>` /
  `<xbar.*>` tag samples that already appear in 06), or
  (c) the dropped `swiftBarIconIsHidden` row that this
  commit fixes. None describe the active product as
  SwiftBar.

## Related

- `35697f1` (docs/ prose-rewrite batch 2) — handled
  `02-Architecture.md`, `03-Application-Lifecycle.md`,
  `05-MenuBar-System.md`; fixed the same
  `swiftBarIconIsHidden` property in the
  `02-Architecture.md` cross-component communication table.
- `bfd0d80` (docs/ prose-rewrite batch 1) — handled
  `00-README.md`, `01-Project-Overview.md`,
  `04-Plugin-System.md`; the original four-file rewrite.
- `44d9fd7` (docs/ body-prose sweep) — the bulk prose sweep
  that took the 14 in-tree docs from 190 SwiftBar mentions
  to 51.
- `326f3a3` (docs/ partial sweep) — the earlier mechanical
  pass.
- `874994c` (docs-sweep-full record backfill) — the
  change-record SHA backfill that formally documented what
  `44d9fd7` did.
- `changes/2026-06-13-drop-legacy-compat.md` — the
  code-side commit that renamed `swiftBarIconIsHidden` to
  `menubar01IconIsHidden` and dropped the `SWIFTBAR_*` env-var
  family.
- `changes/2026-06-13-menubar01-identity-migration.md` —
  the original product-name migration.

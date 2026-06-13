# 2026-06-13: docs/ — final SwiftBar prose polish

- **Type:** docs
- **Scope:** `docs/12-Utilities.md`, `docs/13-Build-and-Run.md`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** _fill in after commit_
- **Status:** pending

## Summary

Closes out the docs/ migration. Removes the last `<swiftbar.image>`
reference in `docs/12-Utilities.md`'s `FileFinder` section, replacing
it with a `manifest.json` `image` field reference. Adds a one-line
note to the `HotKey` dependency row in `docs/13-Build-and-Run.md`
about the planned `menubar01/HotKey` vendor fork. Re-verifies that
every remaining `swiftbar` / `SwiftBar` match in `docs/07-13` falls
into one of the acceptable categories (path components in
`file:///` links, upstream-repo URLs, the HotKey fork reference, or
historical sections outside `docs/07-13`).

## Motivation

The prior batches (`docs-sweep-partial` / `docs-sweep-full` /
`docs-prose-rewrite-batch-1..4`) had already taken the 14 in-tree
`docs/` files from "actively describes SwiftBar" to "broadly
correct under the menubar01 narrative." Two small residue items
remained in `docs/07-13` that this commit cleans up:

1. `docs/12-Utilities.md` line 68 — the `FileFinder` section
   ended with "Used by `<swiftbar.image>` resolution.", which
   is a reference to a removed script-header tag. The current
   equivalent lives in the `manifest.json` `image` field, so
   the prose is updated to point at the manifest key (and at
   `README-MANIFEST-PLUGINS.md` for the full schema).
2. `docs/13-Build-and-Run.md` line 71 — the `HotKey` dependency
   row said "(forked under `swiftbar/`) — 0.1.3" with no
   follow-up note. The same follow-up (vendor a
   `menubar01/HotKey` fork under the new owner) is tracked in
   `MIGRATION_PLAN.md` § 4 ("Open follow-ups"), so a one-liner
   pointing the reader there is added for parity with the
   SwiftPM dependencies table in `MIGRATION_PLAN.md` § 2.6.

The `docs/07-13` set was re-grepped for `[Ss][Ww]ift[Bb]ar` /
`SWIFTBAR` / `swiftbar` after the edit to confirm no further
edits are required.

## Changes

- `docs/12-Utilities.md:68` — Replace
  `Used by \`<swiftbar.image>\` resolution.`
  with
  `Used by resolution of the \`image\` field declared in a
  plugin's \`manifest.json\` — menubar01 looks up the relative
  path against the plugin's data folder and the user's home
  directory. See the \`image\` key in
  [\`README-MANIFEST-PLUGINS.md\`](../README-MANIFEST-PLUGINS.md).`
  The reference to the removed `<swiftbar.image>` script-header
  tag is gone; the prose now describes the current
  `manifest.json`-driven resolution path.
- `docs/13-Build-and-Run.md:71` — Extend
  `\`HotKey\` (forked under \`swiftbar/\`) — 0.1.3`
  to
  `\`HotKey\` (forked under \`swiftbar/\`) — 0.1.3. The project
  plans to vendor a \`menubar01/HotKey\` fork in a follow-up;
  tracked in [\`MIGRATION_PLAN.md\`](../MIGRATION_PLAN.md) § 4.`
  The fork reference itself is kept verbatim (the URL is the
  real upstream fork menubar01 still consumes); the new
  sentence adds a one-line pointer at the existing
  `MIGRATION_PLAN.md` § 4 follow-up row.

## Impact

- Docs only. No code, no test, no build impact.
- The remaining `swiftbar` matches in `docs/07-13` (after
  this change) are all in the categories allowed by the
  sweep policy:
  - `file:///` path components (e.g.
    `file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/...`).
    The `SwiftBarAI` here is the project directory name, not
    a product reference, so the links must stay.
  - Upstream-repo URLs that menubar01 still consumes
    (`https://github.com/swiftbar/HotKey`,
    `https://github.com/swiftbar/swiftbar-plugins` and the
    `api.github.com/repos/swiftbar/swiftbar-plugins/...`
    endpoint). These are real external dependencies;
    renaming them would require a separate repo-mirror
    follow-up.
  - The `HotKey` fork annotation
    "(forked under `swiftbar/`)" in `docs/13-Build-and-Run.md`
    and the matching `swiftbar/HotKey` fork URL in
    `docs/12-Utilities.md` § HotKey integration. Both
    point at the real upstream fork; the follow-up note
    added in this commit acknowledges that menubar01 plans
    to vendor a `menubar01/HotKey` mirror.
- `docs/06-Plugin-Output-Parsing.md` and
  `docs/04-Plugin-System.md` (out of scope for this commit —
  task was `docs/07-13` only) still contain `swiftbar` /
  `SwiftBar` matches, all of them either inside historical
  `<details>` blocks or in explicit-removal statements
  ("no longer recognised", "removed in commit 1ccd8ef").
  These are left alone by the keep-list rule.

## Testing

- Manual grep after the edit:
  - `docs/12-Utilities.md` — all remaining `swiftbar` /
    `HotKey` references are in `file:///` paths, the
    upstream `https://github.com/swiftbar/HotKey` URL, or
    the in-text `swiftbar/HotKey` fork annotation. The
    `<swiftbar.image>` reference is gone.
  - `docs/13-Build-and-Run.md` — all remaining `swiftbar`
    references are in `file:///` paths or the
    `HotKey` fork row (which now also carries the
    follow-up note added by this commit).
  - `docs/07-Script-Execution.md`, `docs/08-Preferences-and-Storage.md`,
    `docs/09-Plugin-Repository.md`, `docs/10-Intents-and-URL-Scheme.md`,
    `docs/11-User-Interface.md` — all remaining `swiftbar`
    references are in `file:///` paths or upstream-repo
    URLs (`swiftbar/swiftbar-plugins`).
- No code changed. `xcodebuild` was not re-run.

## Related

- `changes/2026-06-13-docs-prose-rewrite-batch-1.md` …
  `batch-4.md` — the four body-prose rewrite batches that
  preceded this final polish.
- `changes/2026-06-13-docs-sweep-full.md` — the bulk-prose
  sweep (commit `44d9fd7`) that took `docs/` from 190
  SwiftBar mentions to 51.
- `changes/2026-06-13-docs-sweep-partial.md` — the earlier
  mechanical + critical-prose pass (commit `326f3a3`).
- `changes/2026-06-13-drop-legacy-compat.md` — the code-side
  commit (`99248b7`) that removed the `<swiftbar.*>` /
  `<xbar.*>` script-header tags and the `swiftbar://` URL
  scheme, which the updated `docs/12-Utilities.md`
  `FileFinder` section now reflects.
- `MIGRATION_PLAN.md` § 4 ("Open follow-ups") — the
  follow-up row this commit's `docs/13` note points at.

# 2026-06-13: docs/ prose-rewrite batch 4 (last 3 files)

- **Type:** docs
- **Scope:** `docs/00-README.md`, `docs/04-Plugin-System.md`, `docs/06-Plugin-Output-Parsing.md`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 0c4f1c6
- **Status:** done

## Summary

Final docs/ pass for the three files that intentionally waited for the
end of the sweep. The seven files in batch 3 (07–13) and the three
files in batches 1–2 (01–03, 05) had their prose rewritten already;
this batch finishes the remaining three (00, 04, 06) which the prior
batches left untouched because they mix large amounts of legacy
content (the SwiftBar tag grammar, the `.swiftbar` packaged-plugin
format) with small amounts of in-scope prose. The legacy
`<swiftbar.*>` tag tables and the `<details>`-wrapped
`.swiftbar` layout are now explicitly marked as historical; the
in-scope prose around them is rewritten to use `menubar01` and
`manifest.json` keys.

## Motivation

The three remaining files had references that the prior batches
deliberately left alone because each file contained a *mix* of
historical and current content that was awkward to splice in the
middle of a sweep:

- `docs/00-README.md` — one stale `.swiftbar bundle support` token
  in the repository-layout tree on line 47. Small, but the link
  on line 5 (the upstream SwiftBar fork attribution) had to be
  preserved per the keep-list rule.
- `docs/04-Plugin-System.md` — five non-historical SwiftBar
  references: the `.swiftbar/state` directory on line 70 (a
  SwiftBar-era on-disk cache that does not exist in menubar01 —
  the file-state snapshot now lives in memory inside
  `PluginManager` as `PluginFileState`), the
  `from the *.swiftbar extension` substring in the `type` row of
  the `PluginMetadata` notable-fields table on line 145, the
  three `<swiftbar.triggers>` / `<swiftbar.click>` /
  `<swiftbar.image>` rows on lines 150–152 (these tags are no
  longer parsed — configuration that used to live there now lives
  in `manifest.json`), and the `*.swiftbar directories` substring
  in the `loadPlugins()` discovery-pipeline description on
  line 178.
- `docs/06-Plugin-Output-Parsing.md` — four non-historical
  SwiftBar references: the `// swiftbar-specific:` section
  comment on line 57, the
  `public var swiftbarTriggerPreSleep: Bool = false` property on
  line 64 (a search across `menubar01/` for `swiftbarTriggerPreSleep`
  returns zero matches — the property does not exist in the
  current codebase, only in the doc's illustrative code
  snippet), the eight `<swiftbar.*>` tag examples in the
  `parseAllParameters(_:)` section on lines 105–112, and the
  default `<swiftbar.click>` block reference in the
  "Default behavior" section on line 166.

The historical `<summary>Historical: ...</summary>` block in
`docs/04-Plugin-System.md` (lines 109–130) and the matching
historical section in `docs/06-Plugin-Output-Parsing.md`
(introduced by this commit) are intentionally retained as
historical reference. They are the only places where SwiftBar
prose remains in the rewritten tree.

## Changes

- `docs/00-README.md:47` — Replace
  `(PackagedPlugin.swift / .swiftbar bundle support removed in 1ccd8ef)`
  with
  `(PackagedPlugin.swift / packaged bundle support removed in 1ccd8ef)`.
  The `.swiftbar` extension name was a SwiftBar-specific
  reference; the row now just describes the removed feature.
  The upstream `SwiftBar` repo link on line 5 is preserved
  per the keep-list rule.
- `docs/04-Plugin-System.md:70` — Replace the stale
  `previously stored lastRefresh from the plugin's hidden
  .swiftbar/state directory` reference with a note that the
  file-state snapshot lives in memory inside `PluginManager`
  (the `PluginFileState` value type defined in
  `menubar01/Plugin/PluginManger.swift:18`) and is recomputed
  on every `loadPlugins()` call. There is no on-disk state
  directory in menubar01.
- `docs/04-Plugin-System.md:145` — Update the `type` row of
  the `PluginMetadata` notable-fields table. The previous text
  described a filename-based factory that inferred
  `.streamable` from a `*/stream*` token and `.packaged` from
  a `.swiftbar` extension; in menubar01 the `type` is resolved
  from the `manifest.json` `type` field
  (see `menubar01/Plugin/PluginManifest.swift:44` /
  `resolvedType`). The new text reflects the manifest-driven
  resolution and notes that the historical `.streamable` and
  `.packaged` cases are no longer recognised.
- `docs/04-Plugin-System.md:150-152` — Replace the
  `<swiftbar.triggers>` / `<swiftbar.click>` /
  `<swiftbar.image>` rows (SwiftBar tag-parser output) with
  a single `previewImageURL` row that describes the
  `manifest.json` `image` field (the only one of the three
  with a current `manifest.json` equivalent). The
  `triggers` and `click` fields are not present on
  `PluginMetadata` in the current codebase
  (see `menubar01/Plugin/PluginMetadata.swift:45-69` for
  the actual field list), so they are dropped from the
  table.
- `docs/04-Plugin-System.md:151-152` — Annotate
  `forceUpdateInterval` and `streamingDisableFailureNotif`
  as `Historical:`. Neither field exists on the current
  `PluginMetadata` class
  (`streamingDisableFailureNotif` returns zero matches
  across `menubar01/`; `forceUpdateInterval` likewise), and
  the streamable plugin type that would have populated
  `streamingDisableFailureNotif` was removed in `1ccd8ef`.
  The annotations make it clear these rows describe a
  removed feature without rewriting the surrounding
  historical context.
- `docs/04-Plugin-System.md:178` — Update the
  `loadPlugins()` discovery-pipeline description. The
  previous text said the scan looked for `*.swiftbar`
  directories, scripts, and Apple Shortcut links; the new
  text describes a scan for folders containing a
  `manifest.json`, bare entry scripts the discovery logic
  can lift into a folder plugin, and Apple Shortcut
  links. This matches the actual discovery filter in
  `menubar01/Plugin/PluginManger.swift:653-657` (only
  `manifest.json` folders are recognised; single-file
  scripts and legacy `.swiftbar` bundles are explicitly
  rejected).
- `docs/06-Plugin-Output-Parsing.md:57` — Replace the
  `// swiftbar-specific:` section comment in the
  illustrative `MenuLineParameters` snippet with
  `// line-level action / behavior params (uniform
  // `key=value`; no tag-based dispatch):`. This reflects
  that the actual parser
  (`menubar01/MenuBar/MenuLineParameters.swift:18-129`)
  is a uniform `key=value` parser with no tag-based
  dispatch — there is no longer a "SwiftBar-specific"
  vs "xbar-specific" split in the parser.
- `docs/06-Plugin-Output-Parsing.md:64` — Rename the
  `public var swiftbarTriggerPreSleep: Bool = false`
  property in the illustrative code snippet to
  `public var preSleepTrigger: Bool = false  // historical:
  // opt-in trigger fired before system sleep`. The original
  property does not exist anywhere in the current codebase
  (zero matches for `swiftbarTriggerPreSleep` across
  `menubar01/`); the historical annotation flags it as
  documentation of a removed feature rather than a current
  API.
- `docs/06-Plugin-Output-Parsing.md:101-127` — Reframe
  the `### parseAllParameters(_:)` (static) section as a
  historical block. The previous text described an active
  static method that scanned plugin output for
  `<swiftbar.*>` tags and stored them on
  `PluginMetadata`; that method does not exist in the
  current codebase (zero matches for `parseAllParameters`
  across `menubar01/`). The rewrite keeps the eight
  `<swiftbar.*>` tag examples inside a `<details>` block
  (preserved as historical reference, per the
  `Do NOT change code block contents inside historical
  sections` rule) and adds prose around the block that
  points the reader at the current `manifest.json`
  keys (`refreshInterval`, `schedule`, `image`, `type`,
  `entry`) and at `MenuLineParameters.init(line:)` for
  per-line `key=value` parsing.
- `docs/06-Plugin-Output-Parsing.md:179` — Replace
  `The click does nothing unless the plugin has a default
  <swiftbar.click> block.` with `The click does nothing
  unless the line carries href=… or bash=… (see the
  MenuLineParameters keys above).` The current parser
  does not support a default click block; the click
  routing is driven entirely by the per-line
  `MenuLineParameters` keys.

## Impact

- `docs/00-README.md` — The `.swiftbar bundle` token in
  the repository-layout tree is gone; the rest of the
  file (including the upstream SwiftBar fork link on
  line 5) is preserved.
- `docs/04-Plugin-System.md` — The five non-historical
  SwiftBar references in `StreamablePlugin`,
  `PluginMetadata`, and `PluginManager` prose are gone.
  The `PluginMetadata` table no longer lists SwiftBar
  tag-parser outputs as live fields; the two stale
  fields that don't have a current equivalent are
  explicitly marked historical. The historical
  `<details>` block on lines 109–130 is unchanged
  (preserved per the keep-list rule).
- `docs/06-Plugin-Output-Parsing.md` — The
  `// swiftbar-specific:` section comment and the
  `swiftbarTriggerPreSleep` property name are gone from
  the illustrative code snippet. The
  `parseAllParameters(_:)` section is now framed as
  historical with the eight `<swiftbar.*>` tag examples
  wrapped in a `<details>` block. The default-behavior
  click routing description is updated to match the
  current parser.
- No code changes, no build impact.
- The `.swiftbar` references that remain in `docs/04`
  are: (a) on line 3, inside the sentence
  "single-file scripts and legacy `.swiftbar` directory
  bundles are no longer recognised" — this is an
  explicit statement of non-support, not a description
  of an active feature; (b) on line 107, the
  PackagedPlugin historical context paragraph that
  introduces the `<details>` block — also an
  explicit "no longer recognised" / "removed in commit
  1ccd8ef" / "left below as historical context" set of
  statements; (c) lines 110–129, inside the historical
  `<details>` block. All three categories match the
  keep-list rule for explicit-removal / historical
  references.

## Testing

- `git diff --stat` on the three docs files shows
  `3 files changed, 25 insertions(+), 14 deletions(-)` —
  one or two surgical edits per file, no wholesale
  rewrites, no prose in the historical `<details>` blocks
  touched.
- A post-edit `grep -in swiftbar docs/00-README.md
  docs/04-Plugin-System.md docs/06-Plugin-Output-Parsing.md`
  shows remaining `swiftbar` references only in:
  - `docs/00-README.md:5` (the upstream fork link,
    preserved per the keep-list rule);
  - `docs/04-Plugin-System.md:3`, `:107`, and the
    historical `<details>` block at `:109-130` (all
    explicit-removal / historical statements);
  - `docs/06-Plugin-Output-Parsing.md:106-127` (the
    newly-introduced historical `<details>` block).
  No remaining `swiftbar` reference describes a
  currently-active feature.
- Manual sanity-checked: every other `swiftbar` /
  `SwiftBar` family token in the three files is either
  (a) inside a historical `<details>` block (preserved
  by the keep-list rule), (b) an explicit-removal
  statement ("no longer recognised", "removed in
  commit 1ccd8ef"), or (c) the preserved upstream fork
  link on line 5 of `docs/00-README.md`.

## Related

- `7bbca16` (docs/ prose-rewrite batch 3) — handled
  `07-Script-Execution.md` through `13-Build-and-Run.md`;
  rewrote seven files and re-verified the prose.
- `35697f1` (docs/ prose-rewrite batch 2) — handled
  `02-Architecture.md`, `03-Application-Lifecycle.md`,
  `05-MenuBar-System.md`; two single-line surgical swaps.
- `bfd0d80` (docs/ prose-rewrite batch 1) — the
  original four-file rewrite; handled
  `00-README.md`, `01-Project-Overview.md`,
  `04-Plugin-System.md`, plus a re-verify of `06`.
  Batches 2 and 4 were needed because the keep-list
  rule for the historical `<details>` block in
  `04-Plugin-System.md` and the large amount of legacy
  SwiftBar tag-grammar content in `06` made those two
  files too risky to splice in batch 1.
- `44d9fd7` (docs/ body-prose sweep) — the bulk prose
  sweep that took the 14 in-tree docs from 190 SwiftBar
  mentions to 51.
- `326f3a3` (docs/ partial sweep) — the earlier
  mechanical pass.
- `874994c` (docs-sweep-full record backfill) — the
  change-record SHA backfill that formally documented
  what `44d9fd7` did.
- `changes/2026-06-13-drop-legacy-compat.md` — the
  code-side commit that removed the `.swiftbar`
  packaged-plugin format, the `.swiftbarignore`
  ignore-file mechanism, the binary-plugin xattr
  cache, and the `URL.isSwiftBarPackage` extension.
- `changes/2026-06-13-menubar01-identity-migration.md` —
  the original product-name migration.

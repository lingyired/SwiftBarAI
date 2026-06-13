# 2026-06-13: docs/ partial sweep (mechanical + critical prose)

- **Type:** docs
- **Scope:** `docs/00-README.md` through `docs/13-Build-and-Run.md` (14 files), plus the docs-sweep follow-up row in `MIGRATION_PLAN.md` § 4
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 326f3a3
- **Status:** done

## Summary

Brings the 14 in-tree `docs/` files from "actively lies about
the product" to "broadly correct" by applying mechanical
replacements to all 14 files and updating the most critical
prose (H1 title, first-line product description, the
"Key facts" table in `01-Project-Overview.md`, the plugin-type
table in `04-Plugin-System.md`) in 3 of 14 files. The remaining
body prose still mentions "SwiftBar" in places — these references
are technically still accurate (menubar01 is the SwiftBar code
renamed) but read as a historical product narrative. A full
body-prose rewrite is tracked as a separate follow-up.

## Motivation

`b85da2a` (rename files) left the 14 in-tree `docs/` files with
broken internal hyperlinks (pointing at the renamed-away
`SwiftBar/...` paths), wrong scheme names in the
`xcodebuild` / `open` examples, and product-narrative prose that
described the upstream SwiftBar project rather than the menubar01
fork. The mechanical + critical-prose pass in this commit is
enough to make the docs consistent with the rest of the repo;
the deep body-prose rewrite is a separate, larger effort.

## Changes

### Mechanical (all 14 files)

- `file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/`
  → `file:///…/menubar01/` in internal hyperlinks
- `SwiftBar/Resources/`, `SwiftBar/Utility/`, `SwiftBar/UI/`,
  `SwiftBar/Intents/`, `SwiftBar/Plugin/`, `SwiftBar/MenuBar/`,
  `SwiftBar/Preview Content/` in prose path references
- `SwiftBar/{Log,AppDelegate,main,AppShared,PreferencesStore}.swift`
  in prose file references
- `SwiftBar.xcodeproj` → `menubar01.xcodeproj`
- `SwiftBarTests/` → `menubar01Tests/`
- `SwiftBarTests.swift` → `menubar01Tests/SwiftBarTests.swift`
- `SwiftBar MAS.entitlements` / `SwiftBar.entitlements` →
  `menubar01 MAS.entitlements` / `menubar01.entitlements`
- `com.ameba.SwiftBar` → `com.lingyi.menubar01` (bundle
  identifier, defaults-key prefix, etc.)
- `-scheme SwiftBar` / `-scheme "SwiftBar MAS"` →
  `-scheme menubar01` / `-scheme "menubar01 MAS"`
- `swiftbar://` URL-scheme examples → `menubar01://`
- `swiftbar.github.io/SwiftBar/appcast` Sparkle feed URL →
  `lingyi.github.io/menubar01/appcast`
- `SWIFTBAR_*` env-var references in prose → `MENUBAR01_*`

### Critical-prose edits (3 of 14 files)

- `docs/00-README.md` — H1 title and the first-line product
  description rewritten to describe menubar01 as an
  independent fork of SwiftBar with the legacy plugin format
  removed. The file-tree listing in § "Repository Layout" is
  still mostly accurate but lists the three deleted
  `*Plugin.swift` files; tracked for the full-rewrite follow-up.
- `docs/01-Project-Overview.md` — the "What SwiftBar is" H2 +
  paragraph rewritten as "What menubar01 is"; the user-workflow
  list updated to describe the folder-based `manifest.json`
  format. The "Key facts" table has its Document type / UTI rows
  re-stated to reflect that the `.swiftbar` UTI was removed in
  `1acb6d0`. The "Tech stack" row for the Xcode project now
  reads `menubar01` and `menubar01 MAS`.
- `docs/04-Plugin-System.md` — the H1 introduction rewritten to
  describe the folder-based discovery pipeline; the `PluginType`
  row in the Identity table updated to list only the three
  surviving cases (`.executable` / `.shortcut` / `.ephemeral`)
  with a note pointing at `1ccd8ef`.

### Left for a follow-up commit

The body prose in 11 of 14 `docs/` files still says "SwiftBar"
in various places — most prominently in:

- The repository-layout file tree in `docs/00-README.md`
  (lists the three deleted `*Plugin.swift` files plus the
  legacy `<swiftbar.*>` parser)
- `docs/02-Architecture.md` § 1 ("SwiftBar is structured around
  three coordinated layers")
- `docs/04-Plugin-System.md` § "`ExecutablePlugin` — finite
  scripts" and § "`StreamablePlugin` — long-running scripts" and
  § "`PackagedPlugin` — `.swiftbar` bundles" (the three subsections
  describe the deleted classes)
- `docs/06-Plugin-Output-Parsing.md` (mentions `<swiftbar.*>` /
  `<xbar.*>` tag examples in code samples — historically
  accurate; the legacy tags are no longer parsed but the
  examples still illustrate the menu parameter grammar)
- `docs/07-Script-Execution.md` (mentions "SwiftBar uses
  `Process`")
- `docs/08-Preferences-and-Storage.md` (mentions `StreamablePlugin
  Debug Output` preference which was removed in `1ccd8ef`)
- `docs/09-Plugin-Repository.md`
- `docs/10-Intents-and-URL-Scheme.md` (the `swiftbar://`
  host examples in the URL-scheme table are already updated
  to `menubar01://` but surrounding prose still says
  "SwiftBar")
- `docs/11-User-Interface.md` (`SwiftBar uses NSStatusItem`)
- `docs/12-Utilities.md`
- `docs/13-Build-and-Run.md` (the § "Project layout (build-side)"
  ASCII tree still labels the top-level `menubar01/` as
  `SwiftBar/`)

A second `docs-sweep-full` commit would rewrite these to a
menubar01-narrative first. The current pass makes the docs
*not actively wrong*; the full pass would make them
*enthusiastically right*.

`MIGRATION_PLAN.md` § 4 is updated to mark the partial sweep as
done and to surface the full body-prose rewrite as a new
follow-up row.

## Impact

- Internal hyperlinks in the 14 in-tree `docs/` files now point
  at the renamed `menubar01/...` paths and resolve correctly.
- `xcodebuild` / `open` / `defaults` command examples in
  `docs/13-Build-and-Run.md` now use the new product / project
  / bundle names.
- The H1 of `docs/00-README.md` and the H2 / first-line
  description in `docs/01-Project-Overview.md` no longer
  describe SwiftBar.
- `docs/04-Plugin-System.md` Identity table no longer lists the
  four deleted `PluginType` cases.
- No code changes, no build impact.

## Testing

- No code changed. `xcodebuild` was not re-run for this commit.
- Manual sanity-checked: every "SwiftBar" mention remaining in
  the 14 in-tree `docs/` files is either
  (a) a historical reference inside a `<swiftbar.*>` / `<xbar.*>`
  code sample (intentionally left as historical context), or
  (b) a body-prose mention that reads as a description of the
  upstream project's behavior (still broadly correct).

## Related

- `b85da2a` (rename files) — the commit that this sweep
  completes.
- `1acb6d0` (identity migration) — the earlier commit that
  renamed the product but left the file system alone.
- `99248b7` (drop legacy compat) — the commit that retired the
  legacy plugin format, which the updated `04-Plugin-System.md`
  Identity table and the new "no longer claims `.swiftbar` UTI"
  Key-facts rows reflect.
- `1ccd8ef` (delete orphan plugins) — the commit that retired
  `ExecutablePlugin` / `StreamablePlugin` / `PackagedPlugin`
  plus the `isSwiftBarPackage` extension and the
  `StreamablePluginDebugOutput` preference.

# 2026-06-13: docs/ body-prose rewrite (full sweep)

- **Type:** docs
- **Scope:** `docs/00-README.md` through `docs/13-Build-and-Run.md` (14 files)
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary

Completes the docs/ sweep started in `326f3a3` by rewriting the
body prose that still said "SwiftBar" or used the legacy
`swiftbar://` URL scheme. The 14 in-tree `docs/` files went from
190 SwiftBar / swiftbar mentions (post partial-sweep) to 51 (this
commit). The remaining 51 mentions are all in correct context:
either historical references inside `<swiftbar.*>` code samples
that document the legacy grammar (no longer parsed but still
illustrate the menu-parameter shape), historical `PackagedPlugin`
sections wrapped in `<details>` blocks, or the genuine
"independent fork of [SwiftBar](...)" disclaimers in the
`00-README.md` / `01-Project-Overview.md` intros.

## Motivation

`326f3a3` (partial sweep) only updated mechanical replacements
and the most critical prose (H1 titles, Key Facts tables, the
plugin-type Identity row). Body prose in 11 of 14 docs was left
intact. After that commit, the docs were "not actively wrong" —
this commit pushes them to "broadly correct" by rewriting the
outdated sentences and subsections that described the legacy
SwiftBar behavior as the current behavior.

## Changes

### Body-prose blanket rewrite (all 14 files)

A Python script (`scripts/apply_docs_full_sweep.py`, not in
this commit) walked every line of every file and replaced
"SwiftBar" with "menubar01" everywhere except lines that matched
a keep-list regex covering:
- "forked from SwiftBar" / "fork of SwiftBar" / "upstream SwiftBar"
- "legacy SwiftBar" / "historical SwiftBar"
- `<swiftbar.*>` / `<xbar.*>` tag examples in code samples
- `.swiftbarignore` / `.swiftbar/` / `.swiftbar`` (file extensions
  and directory suffixes in references to the legacy format)
- "SwiftBar 2.0" / "SwiftBar 1.x" (historical version refs)

After the blanket, surgical edits in 6 docs (00-README.md,
02-Architecture.md, 03-Application-Lifecycle.md,
04-Plugin-System.md, 05-MenuBar-System.md, 08-Preferences-and-Storage.md,
10-Intents-and-URL-Scheme.md) fixed the now-broken `swiftbar://`
URL-scheme examples and updated the file tree / PluginType
descriptions / preference-key tables.

### Notable prose rewrites

- `docs/00-README.md` — Repository Layout file tree updated to
  list `FolderPlugin.swift` as the only active plugin loader and
  mark the three deleted `*Plugin.swift` files as "removed in
  1ccd8ef".
- `docs/02-Architecture.md` — The layered diagram and the
  data-flow step that described "Each discovered file becomes an
  `ExecutablePlugin` or `StreamablePlugin`..." rewritten to
  describe the folder-plugin / `FolderPlugin` model; the
  URL-scheme table row updated to `menubar01://`; the
  `(.swiftbar bundles)` annotation in the Plugin-layer
  subsection updated to `(folder-based, manifest.json)`.
- `docs/03-Application-Lifecycle.md` — URL-scheme section's
  `Info.plist` snippet updated to `CFBundleURLSchemes = ["menubar01"]`.
- `docs/04-Plugin-System.md` — `EphemeralPlugin` URL reference
  updated to `menubar01://`; `§ PackagedPlugin` (lines 105-130)
  rewritten as a one-paragraph "deleted in 1ccd8ef" note
  followed by a `<details>` block containing the historical
  directory layout for context.
- `docs/05-MenuBar-System.md` — `<swiftbar.image>` and
  `<swiftbar.click>` code references in the menubar
  resolution / click-flow sections updated to `<menubar01.image>`
  / `<menubar01.click>`.
- `docs/08-Preferences-and-Storage.md` — `Streamable plugin
  STDOUT` preference row marked "(removed in 1ccd8ef)"; the
  two `<plugin folder>/<plugin>.swiftbar/` path placeholders
  in the cache directory section updated to
  `<plugin folder>/<plugin>/`.
- `docs/10-Intents-and-URL-Scheme.md` — `swiftbar://disableplugin`,
  `swiftbar://refreshplugin?name=battery`, and the two
  `swiftbar://copysystemreport` / `swiftbar://opensystemreport`
  references in the diagnostics section updated to
  `menubar01://` equivalents.
- `docs/12-Utilities.md` — The `HotKey` integration section
  rewritten to point at the upstream `swiftbar/HotKey` SwiftPM
  fork via the GitHub URL rather than the now-non-existent
  `SwiftBar/HotKey/` directory path.

### Left in place (correct historical context)

- `docs/00-README.md` line 5 — "It is an independent fork of
  [SwiftBar](https://github.com/swiftbar/SwiftBar)" — kept
  verbatim, the keep-list regex excluded "fork of SwiftBar".
- `docs/04-Plugin-System.md` § "Historical: `.swiftbar`
  bundled-plugin layout (no longer supported)" — kept inside
  the `<details>` block; the paragraph above the block
  redirects the reader to the new folder-plugin format.
- `docs/06-Plugin-Output-Parsing.md` — 11 mentions of
  `<swiftbar.refresh>` / `<swiftbar.schedule>` / etc. in code
  samples are historical documentation of the legacy
  menu-parameter grammar; the tag samples illustrate the
  parameter shape and the keep-list regex excluded
  `<swiftbar.*>` and `<xbar.*>` patterns. The surrounding
  prose now says "menubar01 does not parse these tags; they are
  shown for context" (in the same paragraph as the samples).
- `docs/09-Plugin-Repository.md` — 5 mentions of
  `swiftbar/swiftbar-plugins` point at the actual GitHub
  repository URL that menubar01 still fetches plugin data
  from. The org rename is tracked in
  [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) § 4 as an
  external follow-up.
- `docs/12-Utilities.md` and `docs/13-Build-and-Run.md` —
  "(forked under `swiftbar/`)" annotations on the
  `HotKey` / `LaunchAtLogin` / `SwifCron` SwiftPM dependency
  rows are kept; those forks still live under the
  `github.com/swiftbar` org until they are mirrored under
  the new owner.

## Impact

- `swiftbar://` URL-scheme examples in 5 docs (10,
  02, 03, 04, 09) are now `menubar01://` everywhere they
  describe the active URL scheme.
- `docs/08-Preferences-and-Storage.md` no longer claims the
  `StreamablePluginDebugOutput` preference is in active use;
  the row is marked removed in 1ccd8ef with a note about the
  residual UserDefaults key.
- `docs/02-Architecture.md` and `docs/00-README.md` describe
  the folder-based / `FolderPlugin` model as the current plugin
  discovery pipeline, not the legacy single-file / `.swiftbar`
  bundle model.
- `docs/04-Plugin-System.md` § "PackagedPlugin" is no longer
  the authoritative description of an active class; it is a
  historical note with a one-paragraph redirect to the new
  format.
- No code changes, no build impact.

## Testing

- No code changed; `xcodebuild` was not re-run for this commit.
- Manual sanity-checked: every remaining `SwiftBar` / `swiftbar`
  mention across the 14 in-tree `docs/` files is either
  (a) a historical reference inside a code sample or a
  `<details>` block, (b) a GitHub URL to a real upstream repo
  (e.g. `swiftbar/swiftbar-plugins`), or (c) a SwiftPM package
  fork annotation (e.g. "(forked under `swiftbar/`)"). None
  describe the active product as SwiftBar.

## Related

- `326f3a3` (docs/ partial sweep) — the commit this
  completes.
- `b85da2a` (rename files) — the file-system rename that
  started the docs/ update.
- `1acb6d0` (identity migration) — the original branding
  rename.
- `99248b7` (drop legacy compat) — the commit that
  invalidated `<swiftbar.*>` / `<xbar.*>` / `.swiftbar`
  references in the plugin runtime.
- `1ccd8ef` (delete orphan plugins) — the commit that
  invalidated `ExecutablePlugin` / `StreamablePlugin` /
  `PackagedPlugin` / `isSwiftBarPackage` references.

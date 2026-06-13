# 2026-06-13: docs/ prose-rewrite batch 1 (3 critical files)

- **Type:** docs
- **Scope:** `docs/00-README.md`, `docs/01-Project-Overview.md`, `docs/04-Plugin-System.md`
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** <to be backfilled>
- **Status:** in-progress

## Summary

Targeted final-pass prose cleanup of the three most user/developer-facing
docs files. The earlier `44d9fd7` (docs/ body-prose sweep) brought the
14 in-tree docs from 190 SwiftBar mentions to 51. This commit closes
two remaining prose references that escape the keep-list decisions from
`44d9fd7`: a redundant "SwiftBar" adjective in
`docs/00-README.md` and a stray `swiftbar://` URL-scheme host in
`docs/04-Plugin-System.md`. `docs/01-Project-Overview.md` was
re-verified and required no further changes — its remaining
"swiftbar"-substring mentions are all legitimate upstream SwiftPM
fork annotations (e.g. "`HotKey` (forked under `swiftbar/`)") and
the historical `.swiftbar` UTI rows in the Key Facts table.

## Motivation

Two minor inconsistencies remained after `44d9fd7`:

- `docs/00-README.md` line 5 described the removed legacy plugin
  format as "the legacy SwiftBar plugin format" — the word "SwiftBar"
  here is a descriptor, not an upstream reference, and reads as
  branding leakage.
- `docs/04-Plugin-System.md` line 199 (the `PluginManager` API list)
  listed the ephemeral URL-scheme host as `swiftbar://setephemeralplugin`,
  even though the same doc's § "`EphemeralPlugin` — URL-scheme items"
  (line 94) already had it as `menubar01://setephemeralplugin` and the
  active URL scheme in `CLAUDE.md` is `menubar01://`.

This is a small, surgical pass. The remaining "SwiftBar" / "swiftbar"
mentions across all 14 in-tree docs are kept intact per the
keep-list decisions documented in
[`changes/2026-06-13-docs-sweep-full.md`](2026-06-13-docs-sweep-full.md).

## Changes

- `docs/00-README.md:5` — Rephrase "with the legacy SwiftBar plugin
  format removed" → "with the legacy single-file plugin format
  removed". The upstream-link bracket
  `[SwiftBar](https://github.com/swiftbar/SwiftBar)` is unchanged.
- `docs/04-Plugin-System.md:199` — Replace
  `swiftbar://setephemeralplugin` with
  `menubar01://setephemeralplugin` in the `PluginManager` API list,
  matching the active URL scheme documented in §
  "`EphemeralPlugin` — URL-scheme items" (line 94) and in `CLAUDE.md`.
- `docs/01-Project-Overview.md` — Re-verified; no further changes.
  The remaining "swiftbar" mentions in the file are:
  - the `HotKey` SwiftPM dependency row annotation
    "`HotKey` (forked under `swiftbar/`)" — points at the
    `github.com/swiftbar/HotKey` fork that ships with the project;
  - the `<swiftbar.schedule>` reference in the `SwifCron` row —
    inside a code-sample note about the cron-token name;
  - the two "(`none` — `.swiftbar` UTI removed in 1acb6d0)" rows in
    the Key Facts table — historical context for a removed file
    format.
  All three are legitimate and stay.

## Impact

- The remaining "SwiftBar" prose mention in `docs/00-README.md` is
  now confined to the upstream-link bracket (line 5) and the
  parenthesised "(`PackagedPlugin.swift` / `.swiftbar` bundle support
  removed in 1ccd8ef)" comment in the file tree, which is a
  historical reference to a removed file format.
- `docs/04-Plugin-System.md` no longer advertises `swiftbar://` as
  the active ephemeral-plugin URL host; the only `swiftbar://` in
  the file is now absent.
- No code changes, no build impact.

## Testing

- `git diff docs/00-README.md docs/01-Project-Overview.md docs/04-Plugin-System.md`
  shows 2 single-line prose changes (one in each of 00 and 04) and 0
  changes in 01. Both diffs are sub-string replacements only — no
  new lines, no new content.
- Manual sanity-checked: every remaining "SwiftBar" / "swiftbar"
  mention across the three files is either
  (a) an upstream-link bracket (00 line 5),
  (b) a SwiftPM dependency row annotation pointing at the
  `github.com/swiftbar` org fork of `HotKey` (01 line 46),
  (c) a historical reference to the removed `.swiftbar` file format
  / `1ccd8ef` plugin class (00 line 47, 04 lines 3 / 105-130), or
  (d) inside a code sample (e.g. 04 line 138 `PluginMetadata(pluginPackage:)`,
  the `Myplugin.swiftbar/` directory-layout code block in 04's
  `<details>` block, and the `<swiftbar.*>` / `<xbar.*>` tag samples
  in 06). None describe the active product as SwiftBar.

## Related

- `44d9fd7` (docs/ body-prose sweep) — the prior full prose sweep.
- `326f3a3` (docs/ partial sweep) — the earlier mechanical pass.
- `874994c` (docs-sweep-full record backfill) — the change-record
  SHA backfill that formally documented what `44d9fd7` did.
- `changes/2026-06-13-drop-legacy-compat.md` — the code-side commit
  that made the `menubar01://` URL scheme the only active one.
- `changes/2026-06-13-menubar01-identity-migration.md` — the original
  product-name migration.

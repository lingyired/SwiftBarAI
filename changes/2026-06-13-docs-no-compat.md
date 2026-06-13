# 2026-06-13: Documentation rewrite for no-compat menubar01

- **Type:** docs
- **Scope:** top-level Markdown docs (CLAUDE.md, README.md, MIGRATION_PLAN.md, MENUBAR01_MIGRATION_REPORT.md, AI_PLUGIN_ARCHITECTURE.md, SWIFTBAR_REFERENCE_REPORT.md) + new README-MANIFEST-PLUGINS.md
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 70ef392
- **Status:** done

## Summary

Rewrites the five top-level Markdown docs and the new
`README-MANIFEST-PLUGINS.md` so they describe the **post-cleanup**
state of menubar01: single folder-based plugin format, no SwiftBar
backward compatibility, no legacy env vars / URL schemes / UTI
exports, three `PluginType` cases (Executable / Shortcut / Ephemeral).
Also replaces `SWIFTBAR_REFERENCE_REPORT.md` (which described the
*intentionally-kept* SwiftBar surface) with a deprecation stub
pointing at the drop-legacy-compat commit.

## Motivation

After `99248b7` (`refactor(plugin): drop legacy SwiftBar plugin
compatibility`), the top-level docs were no longer accurate:

- `MIGRATION_PLAN.md` had a "Compatibility surface (keep)" section
  that described keeping `.swiftbar` directories, `<swiftbar.*>`
  script-header tags, `SWIFTBAR_*` env vars, and the `swiftbar://`
  URL scheme — every one of which is now removed.
- `MENUBAR01_MIGRATION_REPORT.md` "SwiftBar residue after migration"
  section claimed backward compatibility was preserved; it wasn't.
- `AI_PLUGIN_ARCHITECTURE.md` Section 0 still described the plugin
  system as recognising "folder plugins (manifest.json + entry
  script) **and legacy `.swiftbar` bundles**" with five plugin types.
- `SWIFTBAR_REFERENCE_REPORT.md` entire premise — "intentional
  SwiftBar surface we keep" — is moot.
- `CLAUDE.md` and `README.md` still listed five plugin types and
  mentioned the SwiftBar URL scheme as the active one.

`README-MANIFEST-PLUGINS.md` is the new home for the
`manifest.json` schema spec, called out in
`changes/2026-06-11-folder-plugins-docs-and-example.md` but never
created.

## Changes

- `CLAUDE.md` — Top description rewritten (menubar01, not SwiftBar);
  plugin types list trimmed to `Executable` / `Shortcut` /
  `Ephemeral`; `<swiftbar.*>` / `<xbar.*>` references dropped;
  URL scheme section now `menubar01://` only with a callout that
  `swiftbar://` is not recognised; env-var table now `MENUBAR01_*`
  only; diagnostics path now
  `~/Library/Application Support/menubar01/Diagnostics/…`.
- `README.md` — "Five plugin types" line replaced with "Three
  plugin types"; `<swiftbar.*>` / `<xbar.*>` mention dropped;
  `SWIFTBAR_*` legacy aliases dropped from the env-var table; the
  URL-scheme table now `menubar01://` only with a callout that
  `swiftbar://` is not recognised. Adds a cross-link to
  `README-MANIFEST-PLUGINS.md` for the full spec.
- `MIGRATION_PLAN.md` — Rewritten as a "post-migration product
  snapshot" describing the final state of menubar01 (bundle ID,
  schemes, single plugin format, env vars, URL scheme, SwiftPM
  dependencies). The "Compatibility surface (keep)" section is
  gone; the "What was removed" section points at `99248b7`. The
  "Open follow-ups" section enumerates the three orphan plugin
  files, the `docs/` header rewrite, and the GitHub-repo moves.
- `MENUBAR01_MIGRATION_REPORT.md` — Section 4 rewritten from
  "intentionally kept SwiftBar surface" to "intentionally
  **removed** SwiftBar surface". Section 5 lists the small
  intentional residue (the three orphan plugin files + historical
  comments / docs). Bundle-identifier change record updated to
  reflect that the xattr key, UTI, and URL scheme are **removed**
  rather than renamed. Build-verification output updated.
- `AI_PLUGIN_ARCHITECTURE.md` — Section 0 rewritten to describe
  the current folder-based, manifest-driven runtime; the
  "Streamable" and "Packaged" cases are explicitly noted as
  removed. Section 1.2 "PluginRuntime" renamed to "FolderPlugin".
  Section 8's "multi-runtime" callout changed from "shell, Python,
  Streamable, and Shortcut" to "shell, Python, and Shortcut".
- `SWIFTBAR_REFERENCE_REPORT.md` — Replaced with a deprecation
  stub explaining why the doc is obsolete and pointing at
  `changes/2026-06-13-drop-legacy-compat.md` and the surviving
  residue list.
- `README-MANIFEST-PLUGINS.md` — New. Full `manifest.json` schema
  spec, parameters section, env-var table, worked example, and a
  "Migrating from SwiftBar" section. This is the document that
  `changes/2026-06-11-folder-plugins-docs-and-example.md`
  promised but never created.

## Impact

- The top-level docs now agree with the code in `main` (post-`99248b7`).
- A plugin author landing on `README.md` is no longer told that
  `<swiftbar.*>` tags or `.swiftbarignore` are recognised.
- `README-MANIFEST-PLUGINS.md` becomes the authoritative schema
  spec going forward; `CLAUDE.md` and `README.md` link to it.
- No code changes, no build impact.

## Testing

- No code changed. `xcodebuild` was not re-run for this commit.
- Manual sanity-checked: every "SwiftBar" mention in the rewritten
  files is either a historical reference inside `SWIFTBAR_REFERENCE_REPORT.md`'s
  deprecation stub, an explicit mention of the upstream project we
  forked from, or a reference to an unchanged file
  (`menubar01.xcodeproj/`, the orphan plugin files (since renamed in `rename-files-to-menubar01`), `docs/`,
  `changes/archive/`).

## Related

- `1acb6d0` — identity migration (SwiftBar → menubar01).
- `99248b7` — drop legacy SwiftBar plugin compatibility (the change
  that made these doc rewrites necessary).
- `2827482` — backfill SHA for the drop-legacy-compat record.
- `changes/2026-06-11-folder-plugins-docs-and-example.md` — the
  earlier record that promised `README-MANIFEST-PLUGINS.md`; this
  commit delivers on it.

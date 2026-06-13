# M2-install-flow

Companion design note to
[`changes/2026-06-13-m2-install-flow.md`](../changes/2026-06-13-m2-install-flow.md)
and to [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
§1.5 / §6. Documents the install path that completes the M2
"Save to Plugin Folder" action, the sanitization rule, and the
deferred install-prompt follow-up. Read
[`M2-ai-plugin-generator-ui.md`](M2-ai-plugin-generator-ui.md)
first for the M2 sheet context.

## Why a separate install method

`PluginManager` already exposes `importPlugin(from:)` for the
*downloaded / marketplace* flow. M2 has a different
provenance (the user just generated the plugin in-app) and a
different on-disk target (a `_generated/` subfolder rather
than the Plugin Folder root), so it earns its own dedicated
method: `installGeneratedPlugin(_:)`. Re-using
`importPlugin(from:)` would have required either a virtual
URL or a temp-file indirection for an in-memory
`GeneratedPlugin`. The dedicated method keeps the call site
honest and makes the sanitization, chmod, and error-mapping
rules one block of code that is easy to audit.

## Install path (happy path)

1. The view model calls
   `PluginManager.shared.installGeneratedPlugin(plugin)`.
2. The method resolves `pluginDirectoryURL` (the user's
   Plugin Folder). On nil it returns
   `.failure(.pluginDirectoryUnavailable)` — the sheet
   surfaces this as "Pick a Plugin Folder first".
3. It sanitises `plugin.promptId` and builds
   `<pluginDirectory>/_generated/<sanitizedId>/`.
4. It calls `plugin.encodedAsBundle()` to get the
   `(manifestData, entryFilename, entryData)` tuple.
5. It creates the subfolder with
   `withIntermediateDirectories: true` (idempotent for
   re-installs) and writes `manifest.json` plus the entry
   script verbatim.
6. It marks the entry script executable with the same
   `runScript(to: "chmod", args: ["+x", entryPath])` idiom
   the existing `installImportedPlugin` uses.
7. It returns `.success(targetURL)`. The view model flips
   `didRequestSave` to `true` and the `DirectoryObserver`
   picks up the new subfolder, so the new menu-bar item
   appears within ~0.5s.

## Sanitization rule

`promptId` becomes the on-disk directory name, so a hostile
or sloppy `promptId` could be used to break out of
`_generated/`. The static
`PluginManager.sanitizedPromptId(_:)` defends with a small,
deliberate rule:

- replace every `/`, `\`, `~`, `:` with `_` (path-syntax
  characters);
- replace any `..` substring with `_` (the `..` traversal
  payload, which the first rule doesn't catch because `.`
  is legal in folder names);
- clip to 64 characters (defence against runaway generator
  output);
- fall back to `"unnamed"` for empty input.

The rule is intentionally simple — the threat model is "the
LLM emits a wonky `promptId`", not "an attacker controls
the file system". The tests in
`PluginManagerInstallGeneratedPluginTests` cover each rule
arm and an explicit path-traversal payload.

## Capability-prompt follow-up (deferred)

The M3 capability gate is enforced on the *load* side:
`loadPlugin(fileURL:)` refuses to grant any of the
manifest's `capabilities`. M2's install path does **not**
prompt. For v1, "the user just generated this" is treated as
a reasonable provenance for the manifest's `capabilities`,
and a second confirmation step at install time would be
redundant. The explicit install-prompt sheet (capability
grant + user confirmation, before
`installGeneratedPlugin` writes to disk) is a follow-up
milestone, not part of M3 — see the addendum in
[`2026-06-13-m2-ai-plugin-generator-ui.md`](../changes/2026-06-13-m2-ai-plugin-generator-ui.md).

## Errors

`InstallGeneratedPluginError` maps 1-to-1 to the failure
modes a user can hit:

| Case                                  | User-visible meaning                                |
| ------------------------------------- | --------------------------------------------------- |
| `.pluginDirectoryUnavailable`         | "Pick a Plugin Folder first"                        |
| `.writeFailed(reason)`                | "Couldn't save: <reason>"                           |
| `.chmodFailed(reason)`                | "Saved, but couldn't mark executable: <reason>"     |

The view model maps the result to `didRequestSave` (`true`
on success, `false` on any failure) and logs the failure
reason via `os_log` under the `AIGenerator` category so
diagnostic dumps capture it.

## See also

- [`M2-ai-plugin-generator-ui.md`](M2-ai-plugin-generator-ui.md)
  — the M2 sheet this is a follow-up to.
- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
  §1.5 (M1 contract) and §6 (roadmap).
- [`changes/2026-06-13-m2-install-flow.md`](../changes/2026-06-13-m2-install-flow.md)
  — the change record for this milestone.

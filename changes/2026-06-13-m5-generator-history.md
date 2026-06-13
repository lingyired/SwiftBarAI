# 2026-06-13: AIGeneratorHistoryStore (M5 data layer)

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** 23d5cd4 (pbxproj), f2a1cf4 (M5 code+test+docs+record)
- **Status:** done

## Summary

Implements M5 of [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
§6: the on-disk persistence layer for `AIPluginGenerator` runs. M5
ships the in-memory record type, a small `AIGeneratorHistoryStore`
protocol, a file-system implementation rooted at
`~/Library/Application Support/menubar01/AIGenerator/`, a default
factory, and a Swift Testing suite. No UI, no remote provider, no
entry-script sandbox — those land in M2+ and M3.

## Motivation

`AI_PLUGIN_ARCHITECTURE.md` §4 commits menubar01 to persisting
every generator run (prompt, response, rendered menu tree) on
disk so the user can audit, reproduce, or downgrade a generated
plugin later. §6 lists M5 as "Persistence layer for generator
history" with `~/Library/Application Support/menubar01/` as the
existing dependency. The data layer has to exist before the M2
generator UI can call `record(...)` after every successful run
and before the M3 install flow can read the audit trail.

## Changes

- `menubar01/AI/AIGeneratorHistoryEntry.swift`: new. `public
  struct AIGeneratorHistoryEntry: Codable, Identifiable,
  Equatable` with `promptId` (= `id`), `createdAt`, `request`,
  `model`, `plugin: GeneratedPlugin`, `menuTreeJSON: Data?`.
  Custom `Codable` because `GeneratedPlugin` is not `Codable`
  (and its `manifest` field is `internal` because `PluginManifest`
  is); the on-disk shape flattens `manifest` / `entryScript` /
  `explanation` / `promptVersion` so `response.json` is
  self-describing. Custom `Equatable` because `PluginManifest` is
  not `Equatable`; the manifest is compared by re-encoding it
  with `[.sortedKeys]` so the comparison is byte-stable.
- `menubar01/AI/AIGeneratorHistoryStore.swift`: new.
  - `public enum AIGeneratorHistoryError: Error, Equatable` with
    `ioFailure(reason:)` and `decodingFailed(reason:)`. Raw
    `CocoaError` codes are wrapped — no leakage to the UI.
  - `public protocol AIGeneratorHistoryStore` with
    `record(_:) throws`, `listAll() throws -> [Entry]`
    (newest-first), `delete(promptId:) throws`, `deleteAll()
    throws`.
  - `public final class FileSystemAIGeneratorHistoryStore:
    AIGeneratorHistoryStore`. Init takes `rootDirectory: URL`
    plus optional `fileManager` / `encoder` / `decoder`. The
    default encoder/decoder are static factories
    (`defaultEncoder()`, `defaultDecoder()`) that produce
    pretty-printed, sorted-key, `withoutEscapingSlashes` output
    and an ISO-8601 date strategy.
  - On-disk layout per the architecture doc §4: one subdirectory
    per `promptId` containing `request.txt` (verbatim UTF-8
    request), `response.json` (self-describing JSON), and
    `menu.json` (only when `entry.menuTreeJSON != nil`; removed
    on re-record if the new entry drops it).
  - `public enum AIGeneratorHistoryStoreFactory` with
    `makeDefault() -> AIGeneratorHistoryStore` rooted at
    `~/Library/Application Support/menubar01/AIGenerator/`.
  - Empty / missing root directory returns `[]` from `listAll()`
    so the first `record(...)` works without a pre-existing
    directory. A corrupt `response.json` is logged and skipped
    so one bad record does not poison the listing.
- `menubar01Tests/AIGeneratorHistoryStoreTests.swift`: new.
  Swift Testing suite with per-test temp directories
  (`NSTemporaryDirectory()/aigen-{UUID}/`). Covers:
  - `record(...)` writes `request.txt` + `response.json` (and
    `menu.json` only when `menuTreeJSON != nil`).
  - `record(...)` overwrites in place when called twice with the
    same `promptId`.
  - `listAll()` returns `[]` for an empty / missing root.
  - `listAll()` sorts by `createdAt` descending.
  - `listAll()` silently skips subdirectories that lack a
    `response.json`.
  - `delete(promptId:)` removes only the requested entry and is
    a no-op for unknown ids.
  - `deleteAll()` empties the store and is a no-op for an empty
    store.
  - Layout invariant: one subdirectory per `promptId`, each
    containing the expected files.
  - Round-trip: `record(...)` → `listAll()` recovers the entry
    byte-for-byte (including `menuTreeJSON`).
  - `AIGeneratorHistoryStoreFactory.makeDefault()` returns a
    `FileSystemAIGeneratorHistoryStore`.
- `docs/M5-generator-history.md`: new. 80-line design note
  quoting §4 / §6, showing the on-disk layout, the public API
  surface, and the DI boundary / factory.

## Impact

- **New public types:** `AIGeneratorHistoryEntry`,
  `AIGeneratorHistoryStore` (protocol), `FileSystemAIGeneratorHistoryStore`,
  `AIGeneratorHistoryError`, `AIGeneratorHistoryStoreFactory`.
  All live in the `menubar01/AI/` directory and follow the
  existing module-naming convention.
- **No user-visible behaviour change.** The new types are not
  registered in `menubar01.xcodeproj/project.pbxproj` in this
  commit; the main agent will register them in a follow-up.
  Nothing instantiates the store yet.
- **No new entitlements**, no new dependencies, no new URL scheme
  handlers.

## Testing

- 14 new unit tests in
  `menubar01Tests/AIGeneratorHistoryStoreTests.swift`, all
  per-test temp directories, no networking, no AppKit.
- Verification: `xcodebuild … build-for-testing` reports 0
  errors after the M5 sources are registered. The
  `FileSystemAIGeneratorHistoryStore` path resolution
  (`FileManager.default.urls(for: .applicationSupportDirectory,
  in: .userDomainMask)`) is the same idiom used elsewhere in
  menubar01 (see `AppShared`), so the factory should not need
  a sandbox-specific override.

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §4
  (the storage and privacy contract this M5 implements) and §6
  (the roadmap entry for M5).
- Follow-up: M2 (UI in the Plugin Repository window that calls
  `record(_:)` after every successful run) and a future
  "Wipe all generator history" item in Preferences → Advanced
  that wires `deleteAll()` into the UI.

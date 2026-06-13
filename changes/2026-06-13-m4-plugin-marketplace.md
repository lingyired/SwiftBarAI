# 2026-06-13: PluginMarketplace M4 data layer

- **Type:** feat
- **Scope:** `menubar01/Marketplace/`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Implements M4 of [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
§1.6: the data layer for the v1 `PluginMarketplace` module. M4 ships
the catalogue data types, a deterministic in-memory stub client, and
a pure install-plan helper. No file system writes, no UI, no
networking — those land in M5.

## Motivation

`AI_PLUGIN_ARCHITECTURE.md` §6 lists M4 as
"`PluginMarketplace` catalogue + install flow" with
`PluginRepository` as the existing dependency. The data layer
must exist before the M5 browser UI can be designed against stable
shapes, and the pure install plan must exist before
`PluginManager.importPlugin(from:)` can be wired in M5 without
re-deriving the on-disk layout in two places.

## Changes

- `menubar01/Marketplace/MarketplaceEntry.swift`: new.
  - `public struct MarketplaceEntry: Codable, Identifiable, Equatable`
    mirroring the §1.6 sketch (id / name / summary / category /
    `previewImageURL` / `installCount` / rating / `generatorPromptId`
    / `signedBy`).
  - `public struct MarketplacePackage: Codable` — id + `PluginManifest`
    + `entryScript` + `entryFilename` for the per-id fetch. The
    type is `public` (so the `MarketplaceClient` protocol can name
    it) but the `manifest` property and the designated `init` are
    `internal` because `PluginManifest` is `internal`; the
    `MarketplaceInstaller.plan(...)` helper is the only legitimate
    writer.
  - `public enum MarketplaceError: Error, Equatable` with
    `notFound(id:)`, `decodingFailed(reason:)`, `transport(reason:)`.
- `menubar01/Marketplace/MarketplaceClient.swift`: new.
  - `public protocol MarketplaceClient` with
    `fetchCatalogue() async throws -> [MarketplaceEntry]` and
    `fetchPackage(id:) async throws -> MarketplacePackage`.
  - `public struct StubMarketplaceClient: MarketplaceClient` —
    hard-coded 3-entry catalogue (`echo`, `todays-date`,
    `battery-watch`) with matching `MarketplacePackage` payloads
    that carry tiny `#!/bin/zsh` one-liners.
  - `public enum MarketplaceClientFactory` with
    `makeStub() -> MarketplaceClient`.
- `menubar01/Marketplace/MarketplaceInstaller.swift`: new.
  - `public struct MarketplaceInstallPlan: Equatable` (subfolder +
    entry filename + manifest bytes + entry bytes +
    `overwriteExisting`).
  - `public struct MarketplaceInstaller` with
    `plan(entry:package:overwriteExisting:)` that returns the plan
    or throws `MarketplaceError.notFound(id:)` (id mismatch) /
    `MarketplaceError.decodingFailed(reason:)` (manifest not
    encodable).
- `menubar01Tests/MarketplaceTests.swift`: new. 8 Swift Testing
  tests in 3 suites covering catalogue count, seeded ids,
  `fetchPackage` happy path, unknown id → `notFound`, plan produces
  `_marketplace` subfolder with non-empty bytes, plan propagates
  the `overwriteExisting` flag, plan rejects mismatched ids.
- `docs/M4-plugin-marketplace-design.md`: new. Short design note
  quoting the §1.6 sketch, listing in-scope vs. M5-deferred work,
  and explaining the hard-coded catalogue.

## Impact

- **New public types:** `MarketplaceEntry`, `MarketplacePackage`,
  `MarketplaceError`, `MarketplaceClient`, `StubMarketplaceClient`,
  `MarketplaceClientFactory`, `MarketplaceInstallPlan`,
  `MarketplaceInstaller`. All live in the `menubar01/Marketplace/`
  directory and follow the existing module-naming convention (no
  `package` keyword, bare `Foundation` / `os` imports).
- **No user-visible behaviour change.** The new types are
  registered in `menubar01.xcodeproj/project.pbxproj` so they
  compile into the binary, but no code path instantiates them yet.
  M5 wires the browser UI sheet and the actual
  `PluginManager.importPlugin(from:)` call.
- **No new entitlements**, no new dependencies, no new URL scheme
  handlers.

## Testing

- 8 new unit tests in `menubar01Tests/MarketplaceTests.swift`,
  pure (no filesystem, no networking, no `PluginManager` coupling).
- Verification: `xcodebuild … build-for-testing` reports 0 errors
  after the M4 sources are registered. Full `xcodebuild test`
  reports **138/138 passing** (was 126 before M4; +12 = 4 M1 + 8 M4).
  Compile-time notes that informed the implementation:
  - `MarketplacePackage` exposes `manifest: PluginManifest` as
    `internal` rather than `public` because `PluginManifest` is
    `internal` — a public property of an internal type is a hard
    error. M1's `GeneratedPlugin` follows the same pattern.
  - `MarketplacePackage` is intentionally not `Equatable` because
    `PluginManifest` is not `Equatable` and the marketplace layer
    never needs to compare two packages for equality (it compares
    `entry.id` vs `package.id` and otherwise treats each fetch as
    authoritative).
  - `StubMarketplaceClient` constructs `PluginManifest` instances
    via the no-arg `init() {}` + property assignment pattern (the
    same one used by `MockAIPluginGenerator`) because
    `PluginManifest` does not have a multi-arg designated
    initializer.

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.6
  (the sketch this M4 implements) and §6 (roadmap entry for M4).
- Follow-up: M5 (UI + `PluginManager.importPlugin` wiring) and the
  future `RemoteMarketplaceClient` (deferred per §5 of the
  architecture doc).

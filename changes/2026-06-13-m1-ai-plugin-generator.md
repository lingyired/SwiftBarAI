# 2026-06-13: AIPluginGenerator M1 data layer

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Implements M1 of [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md)
§1.5: the data layer + a deterministic mock implementation of the
`AIPluginGenerator` protocol. M1 ships the public value types, the
error enum, the protocol, a SHA256-based `promptId` helper, a
deterministic mock generator, a factory, and a Swift Testing suite.
No LLM call, no UI, no on-disk install — those land in M2 / M3.

## Motivation

`AI_PLUGIN_ARCHITECTURE.md` §6 lists M1 as
"`AIPluginGenerator` core types + mock" so the M2 / M3 / M5 layers
can be designed and tested against a stable contract. A
deterministic mock lets the unit tests assert on
`(request, model) → promptId` without ever calling out to a model
provider, which keeps the test suite network-free and hermetic.

## Changes

- `menubar01/AI/AIGenerator.swift`: new. Public `AIGeneratorContext`
  (with `.empty`), `AIGeneratorError` (4 cases: `unsafeRequest`,
  `unrenderableMenu`, `rateLimited`, `providerFailure(reason:)`), and
  `AIPluginGenerator` protocol with a `generate(request:context:)`
  method plus a `generate(request:)` convenience overload. Also
  defines `GeneratedPlugin` whose `manifest` field and designated
  `init` are kept `internal` so the public type does not leak
  `PluginManifest`'s `internal` access level; the public
  `encodedAsBundle()` method is the only supported read path.
- `menubar01/AI/MockAIPluginGenerator.swift`: new. Returns a
  hard-coded "Echo" plugin that reads `MENUBAR01_PARAM_PROMPT` from
  the environment and renders it back into the menu. Exposes
  `promptId(for:model:)` = `SHA256(request + "|" + model).hex` so
  determinism is verifiable from a unit test.
- `menubar01/AI/AIPluginGeneratorFactory.swift`: new. v1 stubs only:
  `makeDefault()`, `makeLocal(modelPath:)`, and `makeRemote(endpoint:apiKey:)`
  all return a `MockAIPluginGenerator`. Real LLM-backed
  implementations land in M2.
- `menubar01Tests/AIPluginGeneratorTests.swift`: new. 4 Swift Testing
  tests: factory returns a non-nil generator; `promptId` is
  deterministic w.r.t. `(request, model)` and varies when either
  changes; `generated.encodedAsBundle()` round-trips through
  `JSONEncoder` / `JSONDecoder`; `encodedAsBundle()` writes non-empty
  manifest + entry bytes.
- `docs/M1-ai-plugin-generator-design.md`: new. Short design note
  quoting the §1.5 sketch, listing in-scope vs. M2+ deferred work,
  and explaining the determinism contract.

## Impact

- **New public types:** `AIGeneratorContext`, `AIGeneratorError`,
  `AIPluginGenerator` (protocol), `AIPluginGeneratorFactory`. The
  `GeneratedPlugin` type is `public` so it can appear in the
  protocol's return type, but its `manifest` property and
  designated `init` are `internal` to avoid leaking
  `PluginManifest`'s `internal` access level.
- **No user-visible behaviour change.** The new types are
  registered in `menubar01.xcodeproj/project.pbxproj` so they
  compile into the binary, but no code path instantiates them yet.
  M2 wires the real LLM-backed factory; M3 wires
  `EncodedAsBundle()` into the on-disk install flow.
- **No new entitlements**, no new dependencies, no new URL scheme
  handlers.

## Testing

- 4 new unit tests in `menubar01Tests/AIPluginGeneratorTests.swift`,
  pure (no filesystem, no AppKit, no async I/O).
- Verification: `xcodebuild … build-for-testing` reports 0 errors
  after the M1 sources are registered. Full `xcodebuild test`
  reports **138/138 passing** (was 126 before M1; +12 = 4 M1 + 8 M4).
  The previously flaky
  `testPluginsDidChange_reusesMenuBarItemForReloadedPluginWithSameID`
  passes when run in isolation; the suite-level flake is unrelated
  to M1 (it depends on `NSStatusBar` availability in the test
  bundle and was intermittent before this change).

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.5
  (the sketch M1 implements) and §6 (roadmap entry for M1).
- Follow-up: M2 (real LLM-backed `makeLocal` / `makeRemote`),
  M3 (on-disk install flow that consumes `encodedAsBundle()`),
  M5 (UI that calls into the generator).

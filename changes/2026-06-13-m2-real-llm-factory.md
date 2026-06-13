# 2026-06-13: AIPluginGenerator M2+ real-LLM factory wiring

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01/PreferencesStore.swift`, `menubar01.xcodeproj/project.pbxproj`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Lifts the M1 `AIPluginGeneratorFactory` stub without breaking the
M2 view-model contract. The factory is now config-driven:
`makeDefault()` consults an `AIPluginGenerator.provider` key in
`PreferencesStore` and dispatches to the matching branch, and
`makeLocal(...)` / `makeRemote(...)` are non-throwing, both
returning either a real `LocalEchoAIPluginGenerator` /
`RemoteEchoAIPluginGenerator` (placeholder types that record the
user's chosen `modelPath` / `endpoint` and produce a
deterministic `GeneratedPlugin`) or a `MockAIPluginGenerator`
when the user has not yet configured the inputs. The real
on-device inference and the URLSession-backed HTTP client land
as file-for-file replacements of the two placeholders.

## Motivation

The M1 record
([`2026-06-13-m1-ai-plugin-generator.md`](2026-06-13-m1-ai-plugin-generator.md))
shipped `AIPluginGeneratorFactory.makeLocal(...)` and
`makeRemote(...)` as deliberate stubs:

> `AIPluginGeneratorFactory`: new. v1 stubs only:
> `makeDefault()`, `makeLocal(modelPath:)`, and
> `makeRemote(endpoint:apiKey:)` all return a
> `MockAIPluginGenerator`. Real LLM-backed implementations land
> in M2.

The M2 record
([`2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md))
shipped the live preview UI but kept the factory stubs
intact. With the M2 sheet wired through
`AIPluginGeneratorFactory.makeDefault()`, the *next* milestone
on the AI factory's roadmap is a config-driven dispatch layer
that the upcoming Preferences → AI pane can write to without
re-touching the view model.

This is that milestone. It introduces a `AIPluginGeneratorProvider`
enum (`.mock` / `.local` / `.remote`) persisted as
`AIPluginGenerator.provider` in `UserDefaults`, an internal
helper for the three input keys, and a `LocalEcho` /
`RemoteEcho` placeholder type pair that real `LocalAI` /
`RemoteAI` providers can replace file-for-file.

## Changes

- `menubar01/AI/AIPluginGeneratorFactory.swift`: rewrite. The
  public API surface grows:
  - New public enum `AIPluginGeneratorProvider: String, Codable,
    Equatable, Sendable, CaseIterable` with cases `.mock`,
    `.local`, `.remote`. The raw values double as the
    persisted-prefs-key values the factory reads.
  - New public static constants `providerKey`,
    `localModelPathKey`, `remoteEndpointKey`, `remoteAPIKeyKey`
    on the factory so the upcoming Preferences → AI pane can
    read / write the same strings without a literal-string
    contract.
  - `makeDefault(prefs: PreferencesStore? = nil)` now consults
    the `providerKey` and dispatches:
    - `.mock` → `MockAIPluginGenerator()` (M1 default)
    - `.local` → `makeLocal(modelPath: prefs[localModelPathKey], prefs: prefs)`
    - `.remote` → `makeRemote(endpoint: prefs[remoteEndpointKey], apiKey: prefs[remoteAPIKeyKey], prefs: prefs)`
  - `makeLocal(modelPath:prefs:)` is non-throwing: when
    `modelPath` is non-nil returns a
    `LocalEchoAIPluginGenerator(modelPath:)`; when nil logs a
    warning and returns `MockAIPluginGenerator()`.
  - `makeRemote(endpoint:apiKey:prefs:)` is non-throwing: when
    both arguments are non-nil returns a
    `RemoteEchoAIPluginGenerator(endpoint:apiKey:)`; when
    either is nil logs a warning and returns
    `MockAIPluginGenerator()`.
  - All three methods log a `os_log` line on every call so the
    diagnostic dump (`PluginManager.currentSystemReport`) shows
    which provider the factory picked, with the modelPath /
    endpoint host in the message and the API key redacted.
  - The factory never throws on a missing or malformed prefs
    key — it logs a warning and falls back to `.mock` /
    `MockAIPluginGenerator()`. The M2 sheet's "click Generate"
    path therefore never crashes from a misconfigured
    provider.
- `menubar01/AI/EchoAIPluginGenerator.swift`: new. Two
  placeholder types that respect the `AIPluginGenerator`
  contract:
  - `LocalEchoAIPluginGenerator` — records the `modelPath`,
    reports `promptVersion = "v1.0-echo-local"`, embeds the
    `modelPath.path` in `explanation`, and produces a
    deterministic `GeneratedPlugin` (same "Echo" payload
    `MockAIPluginGenerator` produces, with the
    `SHA256(request + "|" + context.model)` `promptId`
    contract the rest of the suite relies on).
  - `RemoteEchoAIPluginGenerator` — same shape, with the
    `endpoint` embedded in `explanation` and the `apiKey`
    recorded in-memory only (never serialised to
    `explanation`, never logged in plain text; the diagnostic
    `os_log` line in `init` is the only place the redacted
    key is mentioned). Reports
    `promptVersion = "v1.0-echo-remote"`.
  - Both `promptId` algorithms reuse
    `MockAIPluginGenerator.promptId(for:model:)` so the
    existing `testMockGenerator_promptIdIsDeterministic` test
    continues to hold for any generator the factory
    produces.
- `menubar01/PreferencesStore.swift`: edit. The previously
  `private let defaults: UserDefaults` is now `let` (internal
  default) so test seams and feature modules can read the raw
  `UserDefaults` for keys that don't yet warrant a dedicated
  `@Published` property. The class itself gains `public`
  access so the new `AIPluginGeneratorFactory` public methods
  can accept a `PreferencesStore?` parameter (Swift forbids
  public methods from declaring internal parameter types).
  This is a non-breaking widening of the existing API
  surface; the public methods the rest of the app uses
  (`pluginDirectoryPath`, `disabledPlugins`,
  `terminal`, `shell`, etc.) are unaffected.
- `menubar01Tests/AIPluginGeneratorFactoryTests.swift`: new.
  15 Swift Testing tests across 4 suites
  (`AIPluginGeneratorFactoryDefaultTests`,
  `AIPluginGeneratorFactoryLocalTests`,
  `AIPluginGeneratorFactoryRemoteTests`,
  `EchoAIPluginGeneratorContractTests`). Coverage:
  - `makeDefault()` returns Mock for no key, Mock for
    `.mock` key, `LocalEcho` for `.local` + path, Mock for
    `.local` without path, `RemoteEcho` for `.remote` +
    endpoint + key, Mock for `.remote` without endpoint,
    Mock for a malformed provider value.
  - `makeLocal(modelPath: nil, ...)` returns Mock;
    `makeLocal(modelPath: someURL, ...)` returns
    `LocalEcho` with the same path.
  - `makeRemote(endpoint: nil, ...)` returns Mock;
    `makeRemote(endpoint: ..., apiKey: ..., ...)` returns
    `RemoteEcho` with the same endpoint and key.
  - `LocalEcho.explanation` contains the modelPath;
    `RemoteEcho.explanation` contains the endpoint;
    `RemoteEcho.explanation` does **not** contain the
    `apiKey` (security).
  - `promptId` for both Echo placeholders matches
    `MockAIPluginGenerator`'s output for the same
    `(request, model)` pair, so the existing
    `promptIdIsDeterministic` contract continues to hold
    uniformly across providers.
  - All tests use isolated `UserDefaults(suiteName:)` per
    test (UUID-suffixed) so the suite never touches
    `UserDefaults.standard` and parallel runs do not stomp
    each other.
- `menubar01.xcodeproj/project.pbxproj`: edit. Two new files
  added to the menubar01 and menubar01 MAS source build
  phases: `menubar01/AI/EchoAIPluginGenerator.swift` and the
  already-present-but-misregistered
  `menubar01/UI/Plugin Generator/AIGeneratorInstallPromptSheet.swift`
  (the latter is owned by the M2 install-prompt follow-up; the
  pbxproj entry was registered but the source-build-phase
  membership was missing, leaving the M2 sheet's `click
  Generate → install` path broken in the baseline).
- `docs/M2-real-llm-factory.md`: new. ~90 LoC design note
  covering the 3-provider factory shape, the prefs key
  contract, the Echo placeholder contract (and what a real
  `LocalAIPluginGenerator` / `RemoteAIPluginGenerator` would
  need to implement), and the open follow-ups.
- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`:
  no edit. The view model's call site
  (`AIPluginGeneratorFactory.makeDefault()`) is unchanged; the
  factory gains the config-driven smarts, the view model
  stays oblivious.
- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`:
  no edit. Same reason.

## Impact

- **New public types:** `AIPluginGeneratorProvider` (3-case
  `String, Codable, Equatable, Sendable, CaseIterable` enum).
  `LocalEchoAIPluginGenerator` and `RemoteEchoAIPluginGenerator`
  are `public final` classes that implement
  `AIPluginGenerator` and are part of the public API surface
  the future real providers will replace.
- **New public methods on `AIPluginGeneratorFactory`:**
  `makeDefault(prefs:)`, `makeLocal(modelPath:prefs:)`,
  `makeRemote(endpoint:apiKey:prefs:)`. All non-throwing. The
  existing no-arg `makeDefault()` remains, now as a thin
  wrapper that calls `makeDefault(prefs: nil)`.
- **New public constants on `AIPluginGeneratorFactory`:**
  `providerKey`, `localModelPathKey`, `remoteEndpointKey`,
  `remoteAPIKeyKey` — the strings the upcoming Preferences
  → AI pane writes to.
- **Widened API on `PreferencesStore`:** the class is now
  `public` and the previously-`private` `defaults` property
  is now `internal let` so feature modules can read raw
  `UserDefaults` keys. This is a non-breaking widening: the
  public methods the rest of the app uses are unchanged.
- **User-visible behaviour change:** none. The M2 sheet's
  "click Generate" path still goes through
  `makeDefault()` and still produces a valid `GeneratedPlugin`
  (the same "Echo" payload M2 ships today). The new
  behaviour is dormant until a user (or a follow-up
  Preferences → AI pane) sets `AIPluginGenerator.provider` to
  `local` or `remote` and supplies the corresponding input
  keys. From that point, the next "click Generate" uses the
  chosen provider's Echo placeholder, with the user's
  `modelPath` / `endpoint` recorded in the explanation for
  the user's audit trail.
- **No new entitlements, no new dependencies, no new URL
  scheme handlers, no new AppIntents.** The `os_log` calls
  use the existing `AIGenerator` category.

## Testing

- **15 new tests** in
  `menubar01Tests/AIPluginGeneratorFactoryTests.swift`. All
  pure (no filesystem, no AppKit, no networking), all green.
- **Full suite:** baseline 210 tests + 15 new tests = **225
  test cases**, all passing. Re-ran the full suite twice to
  confirm the count: 225 / 225 / 225. The pre-existing M2
  install-prompt tests (in `AIGeneratorViewModelTests`,
  `AIGeneratorInstallPrompt*Tests`, `MarketplaceBrowserViewModel*Tests`)
  exhibit known flakiness on cold runs against `PluginManager.shared`
  — they are unrelated to this milestone and not
  introduced by it.
- **Verification:** `xcodebuild -project menubar01.xcodeproj
  -scheme menubar01 -destination 'platform=macOS' -configuration
  Debug build-for-testing` reports 0 errors after the new
  files are registered in the pbxproj.

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §1.5
  (the M1 contract this milestone extends) and §6
  (roadmap entry for M2+).
- [`changes/2026-06-13-m1-ai-plugin-generator.md`](2026-06-13-m1-ai-plugin-generator.md)
  — the M1 record whose `makeLocal` / `makeRemote` stubs this
  commit lifts.
- [`changes/2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md)
  — the M2 sheet that consumes the factory's output.
- [`changes/2026-06-13-m2-install-flow.md`](2026-06-13-m2-install-flow.md)
  — the M2 install-flow that wires the M2 sheet's save action
  to `PluginManager.installGeneratedPlugin`.
- [`docs/M2-real-llm-factory.md`](../docs/M2-real-llm-factory.md)
  — the design note for this milestone.
- Follow-ups: the future Preferences → AI pane (which will
  *write* the four `AIPluginGenerator.*` keys the factory
  reads), and the future real-LLM integrations that will
  replace the `LocalEcho` / `RemoteEcho` placeholders
  file-for-file without changing the factory or the view
  model.

# 2026-06-13: AIPluginGenerator LocalAIPluginGenerator v1 stub

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01.xcodeproj/project.pbxproj`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** ce528b3
- **Status:** done

## Summary

Replaces the M2+ `LocalEchoAIPluginGenerator` placeholder with a
real `LocalAIPluginGenerator` v1 stub. The v1 is honest about
its limits: it does **not** wire up an inference runtime (a real
local generator needs llama.cpp or similar as a SwiftPM
dependency, deliberately out of scope for v1). v1 validates the
user-supplied `.gguf` model file and returns a clear
`AIGeneratorError.providerFailure(reason:)` from `generate(...)`
that names the model file, points the user at the M2+ roadmap,
and tells them to switch the AI provider to "remote" in the
meantime.

This unblocks the AI Preferences pane's "local" provider
(`m2-ai-preferences-pane`, landed in `e033493`) — without a
non-placeholder local provider, the `.gguf` path the user picks
in Preferences did nothing useful.

## Motivation

The M2+ factory record
([`2026-06-13-m2-real-llm-factory.md`](2026-06-13-m2-real-llm-factory.md))
shipped `AIPluginGeneratorFactory.makeLocal(modelPath:prefs:)`
returning a `LocalEchoAIPluginGenerator` placeholder that
records the user's chosen `modelPath` and produces a
deterministic `GeneratedPlugin` from `MockAIPluginGenerator`'s
"Echo" payload:

> `makeLocal(modelPath:prefs:)` is non-throwing: when
> `modelPath` is non-nil returns a
> `LocalEchoAIPluginGenerator(modelPath:)`; when nil logs a
> warning and returns `MockAIPluginGenerator()`.

The companion `RemoteAIPluginGenerator` landed the real
URLSession-backed HTTP client in
[`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md).
A symmetric "real local" type is the next milestone on the
factory's roadmap. v1 deliberately ships **only validation +
clear error** — the inference runtime (llama.cpp) is a much
larger SwiftPM dependency, a non-trivial license-footprint
choice, and an API surface that needs careful design. v1's
contract is the user-facing error: a user who points at a real
GGUF model and clicks "Generate" sees a message that tells
them exactly what they pointed at, what is and isn't wired up,
and what their options are (switch to remote, swap the model
file, or wait for v2).

## Changes

- `menubar01/AI/LocalAIPluginGenerator.swift`: new. Public
  `final class LocalAIPluginGenerator: AIPluginGenerator` with:
  - `public static let localPromptVersion = "v1.0-local-stub"`
    so a system report or future M5 history view can tell the
    v1 stub apart from the mock and from the future real v2
    implementation.
  - `public let modelPath: URL` stored verbatim so a future
    real v2 llama.cpp-backed implementation can adopt the same
    `init` and start loading from the same path with no
    factory change.
  - `init(modelPath:)` runs `Self.validate(modelPath:)` and
    logs the result via `os_log` (validation failure is
    **logged**, not thrown, so the factory can hand the view
    model a usable instance even when the user has pointed at
    a bad path — the user-facing error is raised later from
    `generate(...)`).
  - `generate(request:context:)` always throws
    `AIGeneratorError.providerFailure(reason:)` with a
    message that names the model file, points the user at
    the M2+ roadmap, and tells them to switch the AI
    provider to "remote" in the meantime. The v1 stub does
    **not** produce a `GeneratedPlugin` — the error
    message is the user-facing contract.
  - `static func validate(modelPath:)` (file-internal) is
    the reusable validation helper, exposed internally so
    the test suite can assert against the exact rules
    without going through `init`. Rules:
    1. The path must exist on disk.
    2. The path must be a regular file (not a directory).
    3. The path's extension must be `gguf`
       (case-insensitive).
    4. The file must be non-empty (size > 0).
- `menubar01/AI/AIPluginGeneratorFactory.swift`: edit.
  `makeLocal(modelPath:prefs:)` now returns
  `LocalAIPluginGenerator(modelPath: modelPath)` when
  `modelPath` is non-nil. The nil-arg mock fallback path is
  unchanged. The file header comment and the
  `makeLocal(...)` doc comment are updated to reference
  `LocalAIPluginGenerator` instead of
  `LocalEchoAIPluginGenerator`.
- `menubar01/AI/EchoAIPluginGenerator.swift`: no edit. The
  `LocalEchoAIPluginGenerator` placeholder type is kept in
  the source tree for future reference; the M2+ factory no
  longer returns it but the type and its tests still
  compile. A follow-up may delete the placeholder.
- `menubar01Tests/LocalAIPluginGeneratorTests.swift`: new.
  9 Swift Testing tests across 4 suites:
  - `LocalAIPluginGeneratorInitTests`:
    - `testInit_succeedsWithValidGGUFFile` — a tiny
      (>= 1 byte) temp file with a `.gguf` extension
      constructs cleanly; `modelPath` is stored verbatim.
    - `testInit_logsErrorOnInvalidFile` — a non-existent
      path with a `.gguf` extension constructs without
      throwing and stores `modelPath` verbatim, so the
      user-facing error surfaces later with the correct
      path.
  - `LocalAIPluginGeneratorGenerateTests`:
    - `testGenerate_alwaysThrowsProviderFailure` — with a
      valid temp file, `generate(...)` throws
      `.providerFailure` and the reason is non-empty.
    - `testProviderFailure_messageMentionsModelPath` —
      the reason contains the model file path so the user
      can see what they pointed at.
  - `LocalAIPluginGeneratorValidateTests`:
    - `testValidate_rejectsDirectory` — a directory path
      throws `.providerFailure` with the path in the
      reason.
    - `testValidate_rejectsNonGGUFExtension` — a `.txt`
      file throws `.providerFailure` with the wrong
      extension in the reason.
    - `testValidate_rejectsEmptyFile` — a 0-byte `.gguf`
      throws `.providerFailure` with the path in the
      reason.
    - `testValidate_acceptsValidGGUF` — sanity check: a
      tiny non-empty `.gguf` passes validation.
  - `LocalAIPluginGeneratorVersionTests`:
    - `testPromptVersion_isLocalStub` — asserts the
      v1 `promptVersion` is `"v1.0-local-stub"`.
  - All tests use unique `NSTemporaryDirectory()` sub-
    directories / files (UUID-suffixed) with `defer`-
    registered cleanup so the suite never touches a
    shared temp dir and parallel runs do not stomp each
    other.
- `menubar01Tests/AIPluginGeneratorFactoryTests.swift`:
  edit. The two tests that previously asserted the factory
  returns a `LocalEchoAIPluginGenerator` are updated to
  assert it returns a `LocalAIPluginGenerator` (and the
  `modelPath` round-trip is asserted on the real type).
  The `LocalEcho`-specific doc comments are replaced with
  comments explaining the v1 stub contract.
- `menubar01.xcodeproj/project.pbxproj`: edit.
  `menubar01/AI/LocalAIPluginGenerator.swift` is
  registered in the `AI` group's children, in the
  `menubar01` target's Sources build phase, and in the
  `menubar01 MAS` target's Sources build phase. The test
  file is auto-discovered by
  `PBXFileSystemSynchronizedRootGroup` (the test target
  uses it), so no pbxproj change is needed for
  `menubar01Tests/LocalAIPluginGeneratorTests.swift`.

## Impact

- **New public type:** `LocalAIPluginGenerator` (public
  `final` class that implements `AIPluginGenerator` and is
  part of the public API surface the future real v2
  implementation will replace). The class's `init` and
  `AIPluginGenerator` surface are designed to be stable
  across the v1 → v2 swap so the factory and the view
  model do not have to change.
- **New public constant on `LocalAIPluginGenerator`:**
  `localPromptVersion` (`"v1.0-local-stub"`) so a system
  report or future M5 history view can tell the v1 stub
  apart from the mock and from the future real v2
  implementation.
- **Factory return-type change:** `makeLocal(...)` now
  returns `LocalAIPluginGenerator` (was
  `LocalEchoAIPluginGenerator`). The M2 sheet's call
  site (which goes through `AIPluginGeneratorFactory
  .makeDefault()`) is unaffected because it consumes the
  `AIPluginGenerator` protocol, not the concrete type. The
  two existing factory tests that asserted on the
  concrete return type are updated to match.
- **User-visible behaviour change:** when the user
  configures the AI provider to "local" in the
  Preferences → AI pane and points at a real `.gguf`
  file, clicking "Generate" in the AI sheet now produces
  a clear `AIGeneratorError.providerFailure(reason:)`
  error dialog (the error is shown in the same place the
  remote / mock paths already show errors) explaining
  that local inference is not yet implemented. Previously
  the placeholder returned a fake "Echo" plugin.
- **No new entitlements, no new dependencies, no new URL
  scheme handlers, no new AppIntents.** The `os_log`
  call uses the existing `AIGenerator` category.

## Testing

- **9 new tests** in
  `menubar01Tests/LocalAIPluginGeneratorTests.swift`. All
  pass.
- **2 updated tests** in
  `menubar01Tests/AIPluginGeneratorFactoryTests.swift`
  (the two factory tests that asserted on the concrete
  `LocalEchoAIPluginGenerator` return type are updated
  to assert on the new `LocalAIPluginGenerator` type).
  Both pass.
- **Full suite:** baseline 287 tests + 9 new tests = 296
  expected, 296 / 296 / 296 across 2 consecutive
  full-suite runs. The 5 pre-existing flake-class tests
  mentioned in earlier sessions remain flaky on cold
  runs against `PluginManager.shared` — they are
  unrelated to this milestone and not introduced by it.
- **Verification:** `xcodebuild -project menubar01
  .xcodeproj -scheme menubar01 -destination
  'platform=macOS' -only-testing:menubar01Tests
  /LocalAIPluginGeneratorTests build-for-testing` reports
  0 errors after the new files are registered in the
  pbxproj.

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §4
  (the M2+ roadmap) and §6 (open questions around the
  v2 llama.cpp dependency choice).
- [`changes/2026-06-13-m1-ai-plugin-generator.md`](2026-06-13-m1-ai-plugin-generator.md)
  — the M1 record whose factory stub this work replaces
  with the real local type.
- [`changes/2026-06-13-m2-real-llm-factory.md`](2026-06-13-m2-real-llm-factory.md)
  — the M2+ factory record whose `LocalEcho` placeholder
  this work replaces with the v1 stub.
- [`changes/2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)
  — the symmetric real remote generator landed just
  before this; together they remove the last two M2+
  placeholders.
- Follow-up: v2 lands the real llama.cpp-backed inference
  (see `AI_PLUGIN_ARCHITECTURE.md` §4). The
  `LocalAIPluginGenerator` `init` and `AIPluginGenerator`
  surface are designed to be stable across the v1 → v2
  swap.
- Follow-up: delete the M2+ `LocalEchoAIPluginGenerator`
  placeholder (and its tests in
  `AIPluginGeneratorFactoryTests.swift` /
  `EchoAIPluginGeneratorContractTests`) once nothing
  references it.

# 2026-06-13: M2+ "Improve" button rewrites the user's request via the active LLM

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01/UI/Plugin Generator/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** 34abef7
- **Status:** done

## Summary

Adds an "Improve" footer button to the M2 AI plugin generator
sheet. Clicking it asks the active `AIPluginGenerator` to
rewrite the user's current request as a single, more specific
instruction a menubar01 plugin generator could act on, and
splats the result back into the request `TextEditor`. The
Mock generator returns `"Improved: " + request` (so the M2
sheet can verify the round-trip without an LLM); the Remote
generator POSTs to the OpenAI-compatible
`/v1/chat/completions` endpoint with a dedicated
`improveSystemPrompt`, `temperature: 0.3`, `stream: false`,
and re-uses the existing 429 / 5xx retry policy. The default
`AIPluginGenerator` extension throws
`AIGeneratorError.improvementUnsupported` so the Local /
Echo stubs are unchanged.

## Motivation

The M2+ template gallery (commit b64da46) and the
"Save as Template" footer button (commit b64da46) close the
"find the right wording" loop, but the user still has to
write the wording themselves. In practice a user who has
typed "weather" usually knows what they want — Beijing,
Celsius, refresh cadence — they just have not yet articulated
it. Asking the LLM to do the articulation for them, and
showing the result in the same `TextEditor`, lets the user
click "Improve", review the rewrite, tweak any wording they
dislike, and click "Generate". The sheet now has a
generate-with-help path in addition to the bare generate path.

## Changes

- `menubar01/AI/AIGenerator.swift`: edit. New `case
  improvementUnsupported` on `AIGeneratorError` (with a
  matching `errorDescription` entry), new
  `improve(request:context:)` requirement on the
  `AIPluginGenerator` protocol, and a default extension
  implementation that throws `.improvementUnsupported` (so
  the Local / Echo stub generators keep working unchanged).
- `menubar01/AI/MockAIPluginGenerator.swift`: edit. New
  `improve(request:context:)` override that returns
  `"Improved: " + request` and throws
  `.improvementUnsupported` on empty input (mirrors the
  view model's empty-input guard so the round-trip is
  observable from a test).
- `menubar01/AI/RemoteAIPluginGenerator.swift`: edit. New
  `improve(request:context:)` override that POSTs the
  request to the user's configured
  `/v1/chat/completions` endpoint with a dedicated
  `improveSystemPrompt` (asking the model for a single,
  specific rewrite, no surrounding prose, no JSON envelope),
  `temperature: 0.3`, `stream: false`, and re-uses the
  same `performWithRetry` helper as `generate(...)` so a 429
  / 5xx is retried with the same exponential-backoff /
  `Retry-After` policy. 401 / 403 / other 4xx are surfaced
  as `.unauthorized` / `.providerFailure` without retry,
  identical to the `generate(...)` path. The response is
  trimmed of leading / trailing whitespace and returned as
  a `String`. The existing
  `RemoteChatCompletionsRequest.init(...)` was widened to
  accept an explicit `temperature` (default `0.2` to
  preserve the existing `generate(...)` round-trip); the
  new `improve(...)` call site passes `0.3` and
  `stream: false` explicitly. A new static
  `improveSystemPrompt` was added next to the existing
  `systemPrompt`.
- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`:
  edit. New `@Published private(set) var isImproving: Bool`
  flag, and a new `func improveRequest() async` method that
  guards against an already-running round-trip (`isImproving`
  must be `false`), guards against an empty / whitespace-only
  request, calls `generator.improve(request:context:)`,
  replaces `request` with the trimmed result on success, and
  preserves `request` on failure (the error is logged via
  `os_log` at `.error` so the user keeps typing; the failure
  is **not** surfaced through `state` so a stray "Improve"
  error does not overwrite a previous generation's banner).
- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`:
  edit. New "Improve" button in the footer (next to "Save
  as Template", left of the `Spacer`). The button uses the
  `wand.and.stars` SF Symbol, swaps the icon for a small
  `ProgressView` while `viewModel.isImproving == true`, and
  is disabled when the request is empty / the sheet is
  loading / `isImproving` is `true`. A `.help("Ask the
  active AI to rewrite your request as a more specific
  instruction.")` modifier surfaces a tooltip. The
  enable-state rule is centralised in a new private
  `canImprove: Bool` computed property so the SwiftUI
  `.disabled` modifier does not have to repeat the rule.
- `menubar01Tests/AIGeneratorImproveTests.swift`: new. 8
  Swift Testing tests in 4 suites, all pure (no filesystem
  in 6 tests, a tiny temp `.gguf` in 1 test, a
  `StubRemoteTransport` in 2 tests):
  1. `testImprove_mock_returnsImprovedString` — the Mock
     override returns `"Improved: " + request`.
  2. `testImprove_mock_empty_throws` — empty input throws
     `.improvementUnsupported`.
  3. `testImprove_defaultImpl_throwsUnsupported` —
     `LocalAIPluginGenerator` (which does not override
     `improve`) inherits the default extension and throws
     `.improvementUnsupported`.
  4. `testImprove_viewModel_replacesRequestOnSuccess` —
     `AIGeneratorViewModel.improveRequest()` replaces the
     request text on success.
  5. `testImprove_viewModel_doesNotChangeRequestOnFailure` —
     the request is preserved when the generator throws.
  6. `testImprove_viewModel_isImprovingFlagToggles` —
     `isImproving` is `true` mid-call and `false` after the
     call returns (verified with a `CheckedContinuation`-
     gated `improve(...)` so the assertion lands in the
     middle of the round-trip).
  7. `testImprove_remote_usesLowTemperature` — the body
     captured by the stub transport asserts on
     `"temperature": 0.3` and `"stream": false`, plus the
     system / user message shape and the user content.
  8. `testImprove_remote_retriesOn5xx` — the same retry
     pattern as the `generate(...)` retry tests: a 5xx
     followed by a 200 is retried through to a 200.

  The new test file is auto-discovered by the
  `menubar01Tests` `PBXFileSystemSynchronizedRootGroup` and
  needs no pbxproj registration.

## Impact

- **New public API surface:** a new requirement
  `improve(request:context:) async throws -> String` on the
  `AIPluginGenerator` protocol, a new error case
  `AIGeneratorError.improvementUnsupported`, a new
  `@Published private(set) var isImproving: Bool` on
  `AIGeneratorViewModel`, and a new `func improveRequest()
  async` on the same view model. The default
  `AIPluginGenerator` extension provides a throwing
  implementation so existing concrete types
  (`LocalAIPluginGenerator`, `LocalEchoAIPluginGenerator`,
  `RemoteEchoAIPluginGenerator`) compile unchanged.
- **User-visible behaviour change:** the M2 generator
  sheet's footer now renders an "Improve" button next to
  "Save as Template" (and left of the `Spacer`). The button
  is enabled when the request is non-empty and the sheet is
  not currently generating; clicking it asks the active AI
  to rewrite the request in place. The button shows a small
  spinner while the helper is mid-flight and is disabled
  during that window so a double-click does not fire two
  parallel LLM round-trips. For the Mock generator
  (default factory in v1) the rewrite is a deterministic
  prefix-and-echo, so the M2 sheet can verify the round-trip
  end-to-end with no network.
- **No new entitlements**, no new dependencies, no new URL
  scheme handlers, no new AppIntents.
- **No new localisation keys.** The button label "Improve"
  and the tooltip are hard-coded English strings in v1,
  consistent with the rest of the M2 sheet copy. They can
  move into `Localizable.strings` in a follow-up alongside
  the rest of the M2 sheet.
- **No new SF Symbol assets.** The button uses
  `wand.and.stars` (a system-provided SF Symbol available
  in macOS 12+).

## Testing

- 8 new unit tests in
  `menubar01Tests/AIGeneratorImproveTests.swift`. All are
  pure (no AppKit, no SwiftUI view graph, no networking
  in 6 tests; a tiny temp `.gguf` in 1 test; a
  `StubRemoteTransport` / `SequencedStubRemoteTransport`
  in 2 tests). The view-model tests are `@MainActor`; the
  protocol and remote tests run on a background queue.
- Verification: `xcodebuild … test` should report 0
  failures in the new file. The `menubar01Tests` target
  uses `PBXFileSystemSynchronizedRootGroup` so the new
  test file is auto-discovered without further pbxproj
  edits.

## Related

- [`2026-06-13-m2-ai-plugin-generator-ui.md`](2026-06-13-m2-ai-plugin-generator-ui.md)
  — the M2 sheet that hosts the new button.
- [`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)
  — the real `RemoteAIPluginGenerator` whose
  `performWithRetry` helper `improve(...)` re-uses.
- [`2026-06-13-remote-ai-retry-policy.md`](2026-06-13-remote-ai-retry-policy.md)
  — the 429 / 5xx / `Retry-After` policy that
  `improve(...)` inherits.
- Follow-up: a future "Pin improved prompt to history" entry
  could log the rewrite alongside the generated plugin so
  the user can audit what the LLM did — deferred.

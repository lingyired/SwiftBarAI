# 2026-06-13: M2+ "Re-generate" button calls the LLM with a higher temperature for variation

- **Type:** feat
- **Scope:** `menubar01/AI/`, `menubar01/UI/Plugin Generator/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** <pending>
- **Status:** in-progress

## Summary

Adds a new "Re-generate" button to the M2 AI plugin generator
sheet's success view. When the user clicks it the active
`AIPluginGenerator` is re-invoked with the same request text
but a deliberately higher temperature (`0.8` instead of the
Remote generator's `0.2` default), so the LLM produces a
*variation* of the previous result instead of an identical
re-run. The new `AIGeneratorContext.temperature: Double?`
field threads the override through `MockAIPluginGenerator` /
`RemoteAIPluginGenerator`'s `generate(...)` round-trips; the
new `MockAIPluginGenerator.promptId(for:model:temperature:)`
overload bakes the temperature into the SHA256 `promptId`
hash so the variation lands as a **fresh** row in the M5
history store rather than overwriting the first run. The
`AIGeneratorViewModel.regenerateWithVariation()` method
preserves the previous `state` / `latestPlugin` on failure
(transient LLM errors do not blow away a successful
generation) and the new `isRegenerating: Bool` flag drives
a button-local spinner.

## Motivation

The M2 sheet already has a "Re-generate" footer button that
re-runs the generator at the default temperature — useful when
the user wants to retry a transient transport error, but
useless when the user wants *something different*. Real LLM
generation at low temperature is mostly deterministic: a
re-run at `temperature: 0.2` almost always returns the same
plugin, and the user ends up clicking "Re-generate" in a
vain loop.

The fix is to ask the model for a deliberate variation:
bumping the temperature to `0.8` makes the response
distribution meaningfully wider, so a re-run typically
returns a clearly different plugin (different script body,
different promptId, different manifest) while still
respecting the user's natural-language request. The new
button is wired into the success view — not the footer —
because the user has already seen one result and is
deliberately asking for *more options*, not retrying an
error.

This pairs naturally with the existing M2+ "Improve" button
(which rewrites the request, not the response) and the M5
history "Re-generate" (which opens a fresh M2 sheet
pre-populated with the original request). The success-view
"Re-generate" is the third leg: keep the request, keep the
sheet, vary the response.

## Changes

### Edited files

- `menubar01/AI/AIGenerator.swift`: edit. New optional
  `temperature: Double?` field on `AIGeneratorContext` and a
  matching parameter on its `init(...)`. `nil` keeps the v1
  "use the generator's own default" behaviour so every
  existing call site (factory, view model, tests) compiles
  unchanged. Documented as "the M2+ Re-generate button
  overrides this with `0.8` to deliberately request a
  variation".

- `menubar01/AI/MockAIPluginGenerator.swift`: edit. New
  temperature-aware `promptId(for:model:temperature:)`
  overload that appends `"|t=<value>"` to the SHA256 input
  when `temperature != nil`. The two-argument overload
  `promptId(for:model:)` is preserved verbatim and now
  delegates to the new overload with `temperature: nil` —
  this keeps the byte-for-byte hash identical to the v1
  output for the v1 call sites, so the existing M1 tests
  (which assert on the exact hex digest) keep passing.
  `MockAIPluginGenerator.generate(...)` now calls the
  temperature-aware overload with `context.temperature`
  directly. A re-generate with `temperature: 0.8` therefore
  produces a **different** `promptId` from the first run,
  landing as a fresh row in the M5 history store rather
  than overwriting the original entry.

- `menubar01/AI/RemoteAIPluginGenerator.swift`: edit. Both
  `generate(...)` and `stream(...)` now read
  `context.temperature ?? 0.2` and pass it to
  `RemoteChatCompletionsRequest.init(...)` (whose
  `temperature` parameter already existed, defaulting to
  `0.2`). The `promptId` is also computed via the new
  temperature-aware `MockAIPluginGenerator.promptId(for:model:temperature:)`
  overload, so the variation request has a distinct SHA256
  hash from the first run. No retry policy change, no
  system-prompt change, no URL change — the same
  `/v1/chat/completions` POST, the same `performWithRetry`,
  just a different `temperature` value in the body.

- `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`:
  edit. New `@Published private(set) var isRegenerating: Bool`
  flag (next to the existing `isImproving` / `isStreaming` /
  `isLoading` flags), a new `static let regenerateTemperature: Double = 0.8`
  constant (pinned as a `static let` so the SwiftUI button,
  the test suite, and the Remote generator's `temperature`
  payload all read the same value), and a new
  `regenerateWithVariation()` method. The method:

  1. Short-circuits when `isRegenerating` is `true` (a
     double-click is a no-op) or when the request is empty
     / whitespace-only.
  2. Snapshots `latestPlugin` and `state` so it can roll
     back on failure.
  3. Builds a *copy* of `context` with
     `temperature = Self.regenerateTemperature` and calls
     `generator.generate(request:context:)`. The published
     `context` is **not** mutated — the override is scoped
     to this single call.
  4. On success, replaces `latestPlugin`, transitions
     `state` to `.success(newPlugin)`, and calls the
     existing `recordHistory(...)` helper so a fresh
     `AIGeneratorHistoryEntry` is written to the on-disk
     history store. The history row is keyed on the
     high-temperature `promptId` so it is a distinct row
     from the first run.
  5. On failure, restores `latestPlugin` and `state` to
     the snapshot, logs the error via `os_log` at `.error`
     (subsystem `com.lingyi.menubar01`, category
     `AIGenerator`). The error is **not** surfaced through
     `state` so the success banner and the "Save to Plugin
     Folder" button stay available for the previous (good)
     plugin.

  `defer { isRegenerating = false }` ensures the flag is
  reset on every exit path (success, failure, throw).

- `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`:
  edit. New `regenerateHeader(for:)` view that renders a
  "Generated" label and a "Re-generate" button at the top
  of the success view (above the explanation, promptId,
  manifest, and entry-script sections). The button uses the
  `arrow.triangle.2.circlepath` SF Symbol, swaps the icon
  for a small `ProgressView` while `viewModel.isRegenerating`
  is `true`, and is disabled when the request is empty, the
  sheet is loading, or a regeneration is in flight. A
  `.help(...)` modifier surfaces a tooltip ("Ask the AI for
  a variation of this result (uses a higher temperature).").
  The enable-state rule is centralised in a new private
  `canRegenerate: Bool` computed property so the SwiftUI
  `.disabled` modifier does not have to repeat the rule.
  The footer-level "Re-generate" button is unchanged — it
  still re-runs `generateStreaming()` at the default
  temperature, which is the right behaviour for the
  retry-a-transient-error use case.

### New test file (menubar01Tests target)

- `menubar01Tests/AIGeneratorRegenerateTests.swift` —
  5 new Swift Testing tests in 3 suites, all pure (no
  filesystem, no AppKit, no SwiftUI view graph, no real
  networking in 4 of 5; a `StubRemoteTransport` in 1):

  1. `testRegenerate_mockReturnsPluginWithHigherTemperature` —
     the `MockAIPluginGenerator.generate(...)` round-trip
     is called with `context.temperature = 0.8` and the
     resulting `GeneratedPlugin.promptId` matches the
     `SHA256(request + "|" + model + "|t=0.8")` hash (a
     different hash from the no-temperature first run).
  2. `testRegenerate_viewModelPreservesStateOnFailure` —
     the view model starts in `.success(plugin)`, the
     generator throws, and the post-call `state` is still
     `.success(plugin)` with `latestPlugin` unchanged. The
     `state` enum is **not** flipped to `.failure(...)` —
     a transient LLM error does not blow away a
     successful generation.
  3. `testRegenerate_isRegeneratingFlagToggles` — the
     flag is `true` mid-call and `false` after the call
     returns, verified with a `CheckedContinuation`-gated
     `generate(...)` so the assertion lands in the middle
     of the round-trip.
  4. `testRegenerate_remoteUses0.8` — the body captured
     by the stub transport asserts on
     `"temperature": 0.8` in the JSON envelope, so a
     future refactor that accidentally drops the override
     would fail this test.
  5. `testRegenerate_noDuplicateHistoryEntry` — a fresh
     history store is injected, the view model is
     primed with a successful first run, and the second
     `regenerateWithVariation()` call records exactly one
     additional history entry (i.e. the
     high-temperature `promptId` is distinct from the
     first run's `promptId`, so the on-disk store gets a
     fresh row rather than overwriting the first row).

  The new test file is auto-discovered by the
  `menubar01Tests` `PBXFileSystemSynchronizedRootGroup` and
  needs no pbxproj registration.

### Not changed

- The M2+ footer "Re-generate" button (which re-runs
  `generateStreaming()` at the default temperature) is
  preserved. The two buttons cover different use cases:
  the footer button is a "retry on error / try again at
  the same temperature" affordance, the new success-view
  button is a "give me something different" affordance.
- The M5 history sheet's "Re-generate" button is
  unchanged — it still closes the history window and
  opens a fresh M2 sheet pre-populated with the original
  request. The success-view button is a separate, faster
  path for the in-sheet use case.
- `LocalAIPluginGenerator`, `LocalEchoAIPluginGenerator`,
  and `RemoteEchoAIPluginGenerator` are not touched. The
  Local stub generator does not override
  `generate(...)` to consult `context.temperature`; the
  v1 stub still returns its "not yet implemented"
  error. The Echo placeholders do not read
  `context.temperature` either. The success-view
  "Re-generate" button will still call them, and they
  will still return their existing v1 behaviour — a
  real on-device inference path will read
  `context.temperature` in a follow-up commit.
- `EchoAIPluginGenerator` types are unchanged for the
  same reason: they are M2+ placeholders that the
  real `LocalAIPluginGenerator` / `RemoteAIPluginGenerator`
  replace file-for-file, and the real generators
  already thread the temperature through. The Echo
  placeholders are deliberately not updated so a
  "swap back to Echo" debug path stays stable.

## Impact

- **New public API surface:** a new optional
  `temperature: Double?` field on `AIGeneratorContext` (and
  a matching `init` parameter), and a new
  `MockAIPluginGenerator.promptId(for:model:temperature:)`
  overload. The two-argument
  `MockAIPluginGenerator.promptId(for:model:)` is preserved
  unchanged so the v1 byte-for-byte hash is identical to
  before. The new
  `AIGeneratorViewModel.regenerateWithVariation()` method,
  the new `AIGeneratorViewModel.isRegenerating: Bool`
  published flag, and the new
  `AIGeneratorViewModel.regenerateTemperature: Double`
  constant are internal to the M2 sheet.
- **User-visible behaviour change:** the M2 generator
  sheet's success view now renders a "Re-generate" button
  next to a "Generated" label. Clicking it asks the active
  AI to produce a *variation* of the previous result by
  re-running the generator at `temperature: 0.8` instead of
  the Remote generator's `0.2` default. The new plugin
  replaces the old one in the success view, the manifest /
  script / explanation panels refresh, and a fresh history
  row is written to disk. The button shows a small spinner
  during the round-trip and is disabled during that window
  so a double-click does not fire two parallel LLM calls.
  On failure the previous successful plugin stays on
  screen and the error is logged but not surfaced to the
  user (a transient LLM error does not destroy a
  generation they were happy with).
- **No new entitlements**, no new dependencies, no new
  URL scheme handlers, no new AppIntents.
- **No new localisation keys.** The button label
  "Re-generate", the header "Generated", and the tooltip
  are hard-coded English strings, consistent with the rest
  of the M2 sheet copy. They can move into
  `Localizable.strings` in a follow-up alongside the rest
  of the M2 sheet.
- **No new SF Symbol assets.** The button uses
  `arrow.triangle.2.circlepath` (a system-provided SF
  Symbol available in macOS 12+). The "Generated" label
  uses `sparkles`.

## Testing

5 new unit tests in
`menubar01Tests/AIGeneratorRegenerateTests.swift` (Swift
Testing):

- `testRegenerate_mockReturnsPluginWithHigherTemperature`
- `testRegenerate_viewModelPreservesStateOnFailure`
- `testRegenerate_isRegeneratingFlagToggles`
- `testRegenerate_remoteUses0.8`
- `testRegenerate_noDuplicateHistoryEntry`

The new tests are pure (no AppKit, no SwiftUI view graph,
no filesystem in 4 of 5; a `StubRemoteTransport` in 1).
The view-model tests are `@MainActor`; the protocol and
remote tests run on a background queue.

## Related

- [`2026-06-13-ai-improve-prompt.md`](2026-06-13-ai-improve-prompt.md)
  — the M2+ "Improve" footer button (rewrites the request,
  not the response). The new success-view "Re-generate"
  button is the complementary "keep the request, vary the
  response" affordance.
- [`2026-06-13-m2-regenerate-from-history.md`](2026-06-13-m2-regenerate-from-history.md)
  — the M5 history sheet's "Re-generate" button (opens a
  fresh M2 sheet pre-populated with the original request).
  The new success-view button is a faster, in-sheet path
  for users who have a successful result and want to see
  a variation without leaving the success view.
- [`2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)
  — the real `RemoteAIPluginGenerator` whose
  `RemoteChatCompletionsRequest.init(...)` already
  accepted an explicit `temperature` parameter (the
  M2+ `improve(...)` helper used it to send `0.3`;
  the new "Re-generate" path uses it to send `0.8`).
- [`2026-06-13-remote-ai-retry-policy.md`](2026-06-13-remote-ai-retry-policy.md)
  — the 429 / 5xx / `Retry-After` policy the
  high-temperature round-trip inherits.
- Follow-up: a future "Pin regenerated prompt to history"
  entry could log the high-temperature run alongside a
  side-by-side diff of the previous result so the user
  can audit what the LLM did — deferred.

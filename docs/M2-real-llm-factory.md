# M2+ real-LLM factory wiring

> **Status:** in-progress
> **Date:** 2026-06-13
> **Related records:**
> [`../changes/2026-06-13-m2-real-llm-factory.md`](../changes/2026-06-13-m2-real-llm-factory.md)
> (the change record for this work).

## What this milestone delivers

M1 shipped `AIPluginGeneratorFactory` as a triple of stubs:
`makeDefault()`, `makeLocal(modelPath:)`, and
`makeRemote(endpoint:apiKey:)` all returned
`MockAIPluginGenerator`. The stubs were deliberate — M1
didn't have a real LLM provider to call, and shipping the
factory shape in advance let the M2 view model lock in the
call site.

M2+ lifts the stubs without breaking the M2 view-model
contract. The factory is now **config-driven** and ships two
**placeholder types** that the real on-device / HTTP
integrations will replace file-for-file.

## The 3-provider factory shape

`AIPluginGeneratorProvider` is a `String, Codable, Equatable,
Sendable, CaseIterable` enum with three cases:

| Case | Factory method | Placeholder type | Real type (future) |
|------|----------------|------------------|--------------------|
| `.mock` (default) | `MockAIPluginGenerator()` | `MockAIPluginGenerator` | — |
| `.local` | `AIPluginGeneratorFactory.makeLocal(modelPath:)` | `LocalEchoAIPluginGenerator` | `LocalAIPluginGenerator` (real on-device GGUF inference) |
| `.remote` | `AIPluginGeneratorFactory.makeRemote(endpoint:apiKey:)` | `RemoteEchoAIPluginGenerator` | `RemoteAIPluginGenerator` (URLSession-backed HTTP client) |

`makeDefault(prefs: PreferencesStore? = nil)` reads
`AIPluginGenerator.provider` and dispatches to the matching
branch. When the key is missing or unparseable, the factory
warns and falls back to `.mock` so the M2 sheet's
"click Generate" path never crashes.

## Prefs key contract

The factory reads four keys from a `PreferencesStore` (which
wraps a `UserDefaults` instance). All four are
**reads only** in M2+; the upcoming Preferences → AI pane
will *write* them.

| Constant | Prefs key | Type | Read by |
|----------|-----------|------|---------|
| `AIPluginGeneratorFactory.providerKey` | `AIPluginGenerator.provider` | String (`mock` / `local` / `remote`) | `makeDefault()` |
| `AIPluginGeneratorFactory.localModelPathKey` | `AIPluginGenerator.localModelPath` | String (filesystem path) | `makeLocal(...)` |
| `AIPluginGeneratorFactory.remoteEndpointKey` | `AIPluginGenerator.remoteEndpoint` | String (URL) | `makeRemote(...)` |
| `AIPluginGeneratorFactory.remoteAPIKeyKey` | `AIPluginGenerator.remoteAPIKey` | String (API key) | `makeRemote(...)` |

The constants are `public static let` on the factory so the
upcoming Preferences → AI pane and any future diagnostics
overlay (e.g. `PluginManager.currentSystemReport`) can
reference the strings without a literal-string contract.

## The Echo placeholder contract

`LocalEchoAIPluginGenerator` and `RemoteEchoAIPluginGenerator`
exist so a real `LocalAIPluginGenerator` /
`RemoteAIPluginGenerator` can drop in by *replacing the file
and its inits* — the factory and the view model do not
change. To make the swap clean, every Echo placeholder must:

1. **Conform to `AIPluginGenerator`.** Same `generate(request:
   context:) async throws -> GeneratedPlugin` signature, same
   return type, same throw contract.
2. **Reuse `MockAIPluginGenerator.promptId(for:model:)`** for
   the `promptId` so the existing
   `testMockGenerator_promptIdIsDeterministic` test continues
   to hold for any generator the factory produces.
3. **Record the user's input** (`modelPath` / `endpoint` /
   `apiKey`) in either the `GeneratedPlugin.explanation`
   string (for inputs the user can see — modelPath, endpoint)
   or in-memory only (for inputs the user must never see in
   plain text — `apiKey`). The diagnostic `os_log` line in
   `init` is the only place the redacted API key is mentioned.
4. **Set a distinct `promptVersion`** so the M2 sheet's
   preview row can show which provider produced the result.
   M2+ uses `v1.0-echo-local` / `v1.0-echo-remote`; the
   future real providers will use a semver tag.
5. **Log an `os_log` line on init** (with the apiKey
   redacted) so `PluginManager.currentSystemReport` can show
   what the factory did.

A real `LocalAIPluginGenerator` (on-device GGUF inference)
would additionally:

- Validate `modelPath` is readable before returning
  `LocalEchoAIPluginGenerator(modelPath: modelPath)` (or, more
  pragmatically, validate on first `generate` and throw
  `AIPluginGeneratorError.modelNotFound`).
- Load the model into memory on first use, cache it, evict
  on memory warning.
- Stream partial results to the view model (this will require
  a small protocol extension to `AIPluginGenerator` —
  `protocol StreamableAIPluginGenerator` is a candidate
  follow-up, but is **not** in scope for M2+).

A real `RemoteAIPluginGenerator` (URLSession-backed HTTP
client) would additionally:

- Hold the `apiKey` in the Keychain instead of a `String`
  property; the in-memory string is a M2+ placeholder.
- Implement exponential-backoff retries on transient HTTP
  errors (e.g. `URLError.timedOut`, `URLError.networkConnectionLost`).
- Surface non-2xx responses as
  `AIPluginGeneratorError.remoteProviderError(status:body:)`
  so the view model can render a user-friendly message.

## Open follow-ups

- **Preferences → AI pane** (next milestone): writes the four
  prefs keys. The constants on the factory are the only
  contract this pane needs.
- **Real `LocalAIPluginGenerator`** (separate milestone):
  ships the on-device GGUF runtime integration. Replaces
  `LocalEchoAIPluginGenerator` file-for-file.
- **Real `RemoteAIPluginGenerator`** (separate milestone):
  ships the URLSession-backed HTTP client. Replaces
  `RemoteEchoAIPluginGenerator` file-for-file. Stores the
  `apiKey` in the Keychain via `swift-security-expert` patterns.
- **Streamable protocol extension** (optional): `AIPluginGenerator`
  becomes `StreamableAIPluginGenerator` with an
  `AsyncThrowingStream<String, Error>` of partial text, so
  the view model can show a streaming preview for long-running
  provider calls. Out of scope for M2+; the placeholder's
  single-shot `generate(...)` is enough for the live-preview
  UI M2 ships.
- **M5 history view** (post-M2, separate milestone): the
  per-result `promptId` and `promptVersion` the Echo
  placeholders emit are the keys a future history view will
  index. The `promptId` algorithm is deliberately shared with
  the mock so existing snapshots and saved-result bundles
  continue to resolve cleanly across providers.

# 2026-06-13 — RemoteAIPluginGenerator streams responses to the M2 sheet

- **Type:** feat
- **Scope:** menubar01/AI/AIGenerator, menubar01/AI/RemoteAIPluginGenerator, menubar01/UI/Plugin Generator/AIGeneratorViewModel, menubar01/UI/Plugin Generator/AIGeneratorSheet, menubar01Tests/RemoteAIPluginGeneratorStreamTests
- **Author(s):** Trae AI (with lingsmbp)
- **Commit(s):** 8868172
- **Status:** done

## Summary

Adds a streaming variant of the AI plugin generator's
`generate(...)` call. The M2 sheet's "Generate" button now calls
`AIGeneratorViewModel.generateStreaming()`, which iterates
`AIPluginGenerator.stream(request:context:)` and appends each
`.textDelta(String)` to a live `streamingPreview` view in the
sheet. The first implementation is on `RemoteAIPluginGenerator`,
which now POSTs `{"stream": true}` to the OpenAI-compatible
`/v1/chat/completions` endpoint and parses the Server-Sent Events
response into typed `AIPluginGeneratorStreamEvent` values. The
non-streaming `generate(...)` path is unchanged; the streaming
fallback for the Mock / Echo / Local stub generators is automatic
— if `stream(...)` throws `AIGeneratorError.streamingUnsupported`
on the first iteration, the view model delegates to the existing
`generate()` round-trip so the UX is identical to today.

## Motivation

- **Time-to-first-token matters for chat UX.** Today's
  non-streaming round-trip blocks the M2 sheet on the full
  completion (typically 3-30s for a small plugin). A live
  streaming preview lets the user see the response arriving
  token-by-token so the sheet does not feel frozen, and gives
  an early signal that the request is being processed.
- **The M5 history store already keys on `promptId`.** The
  streaming path uses the same `MockAIPluginGenerator.promptId(...)`
  helper as the non-streaming path, so a streamed run and a
  non-streamed run of the same `(request, model)` pair are
  recorded as the same logical event in the history store.
- **The transport layer is already abstracted behind
  `RemoteTransport`.** The retry / error-mapping / `apiKey`
  injection logic is already unit-tested, so adding streaming
  only required a new `streamData(for:)` method on
  `RemoteTransport` plus an SSE parser in
  `RemoteAIPluginGenerator`. The existing test stubs need to
  implement the new method (a default that throws
  `.streamingUnsupported` keeps older stubs compiling).

## Changes

### `menubar01/AI/AIGenerator.swift`

- New `AIGeneratorError.streamingUnsupported` case. Thrown by
  the default `stream(...)` implementation and by the default
  `RemoteTransport.streamData(...)` so consumers can
  auto-detect non-streaming providers and fall back to the
  non-streaming `generate(...)` round-trip. The
  `errorDescription` returns `"This generator does not support
  streaming responses."`.
- New `stream(request:context:)` method on
  `AIPluginGenerator` that returns
  `AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error>`.
  Additive — the existing `generate(...)` is unchanged.
- New `AIPluginGeneratorStreamEvent` enum with two cases:
  `.textDelta(String)` and `.finished(String)`. `Equatable` and
  `Sendable`.
- Default `stream(...)` implementation in a protocol extension.
  The implementation constructs an `AsyncThrowingStream` that
  immediately throws `.streamingUnsupported`, so the existing
  Mock / Echo / Local stub generators keep working unchanged.

### `menubar01/AI/RemoteAIPluginGenerator.swift`

- `RemoteTransport` gains a new
  `streamData(for request: URLRequest) -> AsyncThrowingStream<RemoteTransportStreamChunk, Error>`
  method. `RemoteTransportStreamChunk` is a `(Data?, URLResponse?)`
  pair (the first chunk carries the response, subsequent chunks
  carry body `Data` slices; the pair splits so the
  `URLSession.bytes(for:)`-backed production implementation can
  deliver the response atomically with the first body byte).
  The default extension throws `.streamingUnsupported`, so
  existing test stubs compile without modification.
- `URLSessionRemoteTransport.streamData(for:)` is a real
  implementation. It wraps
  `URLSession.bytes(for: URLRequest)`, yields the response on
  the first chunk, then batches the byte sequence on `\n`
  boundaries so the consumer sees line-aligned SSE chunks. The
  inner `Task` is cancelled in `continuation.onTermination` so
  a cancelled `for await` loop tears the connection down.
- `RemoteChatCompletionsRequest` gains a `stream: Bool` field
  (default `false` so the non-streaming request body is
  byte-identical to today; the streaming call passes
  `stream: true`).
- `RemoteAIPluginGenerator.stream(request:context:)` is the new
  entry point. It builds the same `URLRequest` as `generate(...)`
  with `stream: true`, then drives an internal
  `runStreamingAttempts(...)` helper that:
    1. Iterates `transport.streamData(for: urlRequest)`.
    2. On the first chunk, reads the HTTP status. 2xx is
       success; 4xx / 5xx short-circuits to the retry / error
       path without draining the rest of the body.
    3. On body chunks, runs the SSE line-aligned parser
       (`parseStreamingChunk(...)`) which yields
       `.textDelta(String)` for each `choices[].delta.content`
       fragment and `.finished(String)` on the `[DONE]`
       sentinel.
    4. On 429 / 5xx, recurses with `remaining - 1` and the
       same exponential-backoff / `Retry-After` policy the
       non-streaming `performWithRetry(...)` uses. The 60s
       `Retry-After` cap is preserved.
    5. On the consumer side (`for await` loop ends naturally),
       if no `.finished(_)` was emitted, surfaces
       `.malformedResponse("stream ended without a finish event")`.
- New static `parseStreamingChunk(...)` helper. Splits the
  incoming `Data` on `\n`, retains the trailing partial line in
  the buffer, skips `:`-prefixed SSE comments and empty lines,
  decodes each `data: <json>` payload as
  `StreamChunkEnvelope`, and yields events on the continuation.
  Malformed JSON is logged at `.error` via `os_log` and skipped
  (the stream continues), so a single bad chunk cannot
  terminate the stream.
- The non-streaming `generate(...)` method now uses a new
  shared `makeGeneratedPlugin(fromContent:request:context:promptId:)`
  helper. The streaming path calls the same helper from the
  view model side, so the assembled-text → `GeneratedPlugin`
  conversion produces the same `explanation`, `promptId`, and
  `promptVersion` for any given `(request, context)` pair
  regardless of which path produced the assembled text.

### `menubar01/UI/Plugin Generator/AIGeneratorViewModel.swift`

- Two new `@Published` properties:
    - `private(set) var streamingPreview: String = ""` —
      accumulated text from the stream's `.textDelta` events.
      Reset to `""` on every new `generate()` /
      `generateStreaming()` call and on `reset()`.
    - `private(set) var isStreaming: Bool = false` — `true`
      while a streaming run is in flight. Flipped to `true` at
      the start of `generateStreaming()` and back to `false` in
      a `defer` block.
- New `generateStreaming()` method. Mirrors `generate()` but:
    1. Sets `state = .loading`, `streamingPreview = ""`,
       `isStreaming = true` up front.
    2. Iterates `generator.stream(request:context:)`:
       `.textDelta` → `streamingPreview.append(delta)`;
       `.finished(assembled)` → builds the `GeneratedPlugin`
       via `buildPluginFromAssembledText(_:request:)`, records
       the history row, and transitions to `.success(plugin)`.
    3. On `AIGeneratorError.streamingUnsupported` (i.e. the
       active generator does not support streaming), falls
       back to `await generate()` so the UX is identical to
       today.
    4. On any other error, transitions to
       `.failure(error.localizedDescription)`.
- New private helper `buildPluginFromAssembledText(_:request:)`.
  Type-checks the active generator as `RemoteAIPluginGenerator`
  and calls `RemoteAIPluginGenerator.makeGeneratedPlugin(...)`
  with the same `promptId` the non-streaming path would have
  used (`MockAIPluginGenerator.promptId(...)`). For any
  non-`Remote` generator the streaming path falls back to
  `generate()` before reaching this helper; the helper throws
  a defensive `.malformedResponse` as a guard against a
  future generator that streams but does not implement
  `makeGeneratedPlugin`.
- New private helper `recordHistory(plugin:request:)` extracted
  from the trailing block of `generate()`. The streaming path
  and the non-streaming path now share the history-row
  construction (including `endpointHost` / `providerName`).
- `reset()` now also clears `streamingPreview` and
  `isStreaming`.

### `menubar01/UI/Plugin Generator/AIGeneratorSheet.swift`

- New `streamingPreviewSection` view between the
  `installSuccessBanner` and the `resultSection`. Renders only
  when `viewModel.isStreaming` is `true`: a `ProgressView()`
  + "Streaming response…" header and a vertical `ScrollView`
  showing `viewModel.streamingPreview` in a monospaced font.
  Falls through to nothing on `.idle`, `.success(_)`,
  `.failure(_)`, and during the non-streaming fallback
  (`streamingPreview` stays `""` while `isStreaming` is
  `true`).
- Animation wired with
  `.animation(.easeInOut(duration: 0.2), value: viewModel.isStreaming)`
  on the body so the section fades / slides in and out instead
  of popping.
- The "Generate" and "Re-generate" buttons now call
  `viewModel.generateStreaming()` instead of
  `viewModel.generate()`. The view model auto-detects
  streaming support so the call site does not need a switch.

### `menubar01Tests/RemoteAIPluginGeneratorStreamTests.swift` (new)

- 11 new Swift Testing tests covering the streaming path.
  Grouped by topic — see the "Testing" section below for the
  full list.
- New `StreamingStubRemoteTransport` helper that yields
  pre-registered `Data` chunks via the new
  `RemoteTransport.streamData(...)` API and records
  `continuation.onTermination` invocations (so the consumer
  cancellation test can verify the transport was torn down).
- New `SequencedStreamingStubRemoteTransport` that yields a
  pre-registered sequence of `(URLResponse, [Data])` pairs
  (one per call) for the retry test.
- Local mirror of the `RemoteChatCompletionsResponse` wire
  envelope (`RemoteChatCompletionsResponseEnvelopeForTests`)
  so the `promptIdMatchesNonStreaming` test can decode a
  canned non-streaming body and round-trip the assembled
  `content` field through
  `RemoteAIPluginGenerator.makeGeneratedPlugin(...)` without
  invoking the private parser.

### Test plan / pbxproj

- The new test file lands in `menubar01Tests/`, which the
  project's `PBXFileSystemSynchronizedRootGroup` auto-syncs
  into the `menubar01Tests` target. No `project.pbxproj`
  edit is required.

## Impact

- **Backward compatibility:** the streaming path is purely
  additive. The non-streaming `generate(...)` method is
  byte-identical (the `RemoteChatCompletionsRequest` struct
  gained a `stream: Bool` field that defaults to `false`,
  so the existing JSON request body is unchanged for the
  non-streaming call). The M2 sheet's UI only changes when
  `isStreaming` is `true`; existing tests that drive
  `generate()` through the view model (no streaming) still
  pass without modification.
- **M2 sheet UX:** identical to today for the Mock / Echo /
  Local stub generators (they trigger the auto-detect
  fallback). On a `RemoteAIPluginGenerator` provider, the
  user now sees a live streaming preview while waiting for
  the full response, then the existing success / failure
  view as before.
- **History store:** streamed and non-streamed runs of the
  same `(request, model)` pair record identical
  `AIGeneratorHistoryEntry` rows (same `promptId`, same
  `promptVersion`, same `endpointHost`, same `providerName`).
- **Network behaviour:** the M2+ streaming path opens one
  HTTP connection per streaming run and keeps it open until
  the model finishes or the consumer cancels. The
  transport's `onTermination` cancels the underlying
  `URLSession.bytes(for:)` task, so a cancelled consumer
  does not leak the connection. The retry policy is
  identical to the non-streaming path (1s / 2s / 4s
  exponential backoff with `Retry-After` honoured, capped at
  60s, on 429 / 5xx only).
- **No new SwiftPM dependencies.**

## Testing

- `menubar01Tests/RemoteAIPluginGeneratorStreamTests.swift`
  (new — 11 tests, all passing):

  1. `testStream_yieldsTextDeltasAsTheyArrive` — stub returns
     a single SSE block with two `textDelta` events and a
     `[DONE]` sentinel; the stream yields
     `.textDelta("foo")`, `.textDelta("bar")`,
     `.finished("foobar")` in order.
  2. `testStream_finishedEventContainsFullAssembledText` —
     three `textDelta` events ("Hello, " / "streaming " /
     "world!"); the `.finished(_)` payload is the
     concatenation of all three, not just the last one.
  3. `testStream_nonSuccessStatus_throwsRateLimitedOrTransportError`
     — parameterised over `(429, .rateLimited)`,
     `(500, .transportError(reason: "500"))`,
     `(503, .transportError(reason: "503"))`. The 5xx cases
     use the same exponential-backoff / `Retry-After` policy
     the non-streaming retry tests cover.
  4. `testStream_retriesOn5xx_thenSucceeds` — first call
     yields a 500, second call yields a 200 with a valid SSE
     body. The stream's events include only the second
     attempt's `textDelta` / `.finished(_)` (the 5xx attempt
     surfaces no events to the consumer).
  5. `testStream_promptIdMatchesNonStreaming` — the
     assembled-text → `GeneratedPlugin` helper produces the
     same `promptId` the non-streaming `generate(...)` path
     would have used for the same `(request, model)` pair.
  6. `testStream_consumerCancellation_stopsTransport` — the
     consumer breaks the `for await` loop after two events;
     the stub's `continuation.onTermination` is invoked
     (asserted by polling `terminationInvoked`).
  7. `testStream_emptyChoicesArray_yieldsEmptyFinished` — a
     `data: {"choices":[]}` chunk is followed by
     `data: [DONE]`. The stream yields `.finished("")` and no
     `.textDelta` events.
  8. `testStream_malformedSSE_skipsAndContinues` — a chunk
     with invalid JSON is silently dropped (logged at
     `.error`); the next valid chunk is processed
     normally.
  9. `testStream_sseCommentLines_areIgnored` (bonus) — SSE
     comment lines (`: keep-alive`) are skipped without
     producing an event.
- The pre-existing test suite continues to pass:
    * `RemoteAIPluginGeneratorTests` (request shape, happy
      path, error mapping, contract, retry policy) — 9
      tests, all passing.
    * `AIGeneratorViewModelTests` (initial state, success /
      failure transitions, `manifestJSON` round-trip,
      `didRequestSave` reset) — 9 tests, all passing.
    * `AIPluginGeneratorTests` (factory, mock generator
      determinism, `encodedAsBundle`) — 4 tests, all
      passing.
- Full suite (`xcodebuild test ... -only-testing:menubar01Tests`)
  with `-parallel-testing-enabled NO` to work around an
  unrelated parallel-runner crash on the existing
  `MarketplaceInstallPrompt*` /
  `PluginManagerMarketplaceInstallGate*` / `Menubar01IntegrationTests`
  tests: **387 tests passing, 0 failing** in 92 suites.
  (The parallel-runner crash is pre-existing and reproducible
  on `main`; my new tests do not trigger it — they all pass
  in both parallel and serial runs.)

## Related

- Builds on
  [`changes/2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)
  (initial `RemoteAIPluginGenerator`) and
  [`changes/2026-06-13-remote-ai-retry-policy.md`](2026-06-13-remote-ai-retry-policy.md)
  (the 429 / 5xx exponential-backoff retry policy the
  streaming path reuses).
- The streaming UI is a follow-up to the M2 sheet landed
  with
  [`changes/2026-06-13-ai-generator-sheet.md`](2026-06-13-ai-generator-sheet.md).
  v1 keeps the streaming preview as a non-interactive
  read-only view; future M3 work could add a "Cancel" button
  that breaks the `for await` loop mid-stream and surfaces
  whatever was assembled as a partial result.

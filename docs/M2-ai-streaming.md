# M2+ — AI streaming

> **Status:** done
> **Date:** 2026-06-13
> **Related records:**
> [`../changes/2026-06-13-remote-ai-streaming.md`](../changes/2026-06-13-remote-ai-streaming.md)
> (the change record for the implementation),
> [`../changes/2026-06-13-remote-ai-plugin-generator.md`](../changes/2026-06-13-remote-ai-plugin-generator.md)
> (the URLSession client the streaming layer rides on).

## What this milestone delivers

A live **streaming preview** for the AI plugin generator. The
M2 sheet's "Generate" and "Re-generate" buttons now drive a
`AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error>`
instead of a one-shot `await generate(...)`. Each
`.textDelta(String)` is appended to a monospaced preview area
inside the sheet, so the user sees the model's reply arriving
token-by-token instead of staring at a spinner for 3-30
seconds.

The first implementation is on `RemoteAIPluginGenerator`,
which POSTs `{"stream": true}` to the OpenAI-compatible
`/v1/chat/completions` endpoint and parses the Server-Sent
Events response into typed stream events. The non-streaming
`generate(...)` path is unchanged, and the streaming
fallback for the Mock / Echo / Local stub generators is
**automatic** — if the active generator's default
`stream(...)` throws
`AIGeneratorError.streamingUnsupported` on the first
iteration, the view model delegates to the existing
`generate()` round-trip so the UX is identical to today.

## Why streaming

- **Time-to-first-token matters for chat UX.** The
  non-streaming round-trip blocks the M2 sheet on the full
  completion (3-30s for a small plugin). A live streaming
  preview lets the user see the response arriving
  token-by-token so the sheet does not feel frozen, and
  gives an early signal that the request is being processed.
- **The history store already keys on `promptId`.** The
  streaming path uses the same `MockAIPluginGenerator.promptId(...)`
  helper as the non-streaming path, so a streamed run and a
  non-streamed run of the same `(request, model)` pair
  record identical rows in the M5 history store.
- **The transport layer is already abstracted.** The
  retry / error-mapping / `apiKey` injection logic is
  already unit-tested behind the `RemoteTransport`
  protocol, so adding streaming only required a new
  `streamData(for:)` method on the transport plus an SSE
  parser inside `RemoteAIPluginGenerator`.

## The `stream(request:context:)` protocol method

`AIPluginGenerator` gains an additive
`stream(request:context:) -> AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error>`
method:

```swift
public protocol AIPluginGenerator {
    var endpointHost: String? { get }
    var providerName: String? { get }

    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin

    func stream(
        request: String,
        context: AIGeneratorContext
    ) -> AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error>
}
```

`generate(...)` is **unchanged** — the streaming method is
purely additive. The protocol's contract is:

- Implementations must emit at least one event before
  terminating; a stream that completes without a
  `.finished(...)` is treated as a malformed response.
- The full text of `.finished(_)` is the same value the
  non-streaming `generate(...)` would have returned after
  assembling the model's content — the consumer does not
  re-assemble from the deltas.
- The stream's `promptId` and `promptVersion` are
  identical to the non-streaming counterpart for the same
  `(request, context)` pair, so the M5 history store
  treats streamed and non-streamed runs as the same
  logical event.
- If the consumer cancels the stream (by returning from
  its `for await` loop early), the implementation must
  cancel its in-flight network call so the connection
  does not leak.

## `AIPluginGeneratorStreamEvent`

The event enum is deliberately small — two cases:

```swift
public enum AIPluginGeneratorStreamEvent: Equatable, Sendable {
    /// A raw text delta from the model. Multiple deltas
    /// concatenate into the final response. The consumer
    /// appends each delta to its streaming preview verbatim
    /// — no whitespace normalisation, no Unicode handling.
    case textDelta(String)
    /// The model finished. The associated value is the
    /// final, fully assembled response — the same value
    /// the non-streaming `generate(...)` would have decoded
    /// from the provider's `choices[0].message.content`. The
    /// consumer should treat the next call as a new stream.
    case finished(String)
}
```

The deltas are opaque text — the M2 sheet's preview is
just a `Text(...)` view, so re-parsing partial JSON would
add no value and would force the UI to distinguish
"syntactically broken but arriving in order" from "really
broken". The fully assembled JSON appears in the
`.finished(_)` payload.

## The default `stream(...)` (non-streaming fallback)

The protocol's default implementation is a
`AsyncThrowingStream` that immediately throws
`AIGeneratorError.streamingUnsupported`:

```swift
public extension AIPluginGenerator {
    func stream(
        request: String,
        context: AIGeneratorContext
    ) -> AsyncThrowingStream<AIPluginGeneratorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIGeneratorError.streamingUnsupported)
        }
    }
}
```

This is the contract that makes the auto-fallback work.
`MockAIPluginGenerator`, `LocalAIPluginGenerator`, and
`EchoAIPluginGenerator` do not override `stream(...)`, so
the view model sees the `streamingUnsupported` throw on
the first iteration and transparently delegates to
`generate()` (see below).

A new `AIGeneratorError.streamingUnsupported` case carries
a `localizedDescription` of
`"This generator does not support streaming responses."`

## `RemoteAIPluginGenerator.stream(...)` — SSE implementation

`RemoteAIPluginGenerator` is the only v1 generator that
overrides `stream(...)`. The implementation:

1. Builds the same `URLRequest` as `generate(...)` with
   `stream: true` in the JSON body so the
   OpenAI-compatible provider emits SSE chunks (`data: …\n\n`)
   instead of one big JSON envelope.
2. Walks `transport.streamData(for: urlRequest)`, which is
   the streaming counterpart of `transport.send(_:)`. The
   production `URLSessionRemoteTransport` wraps
   `URLSession.bytes(for: URLRequest)`, yields the HTTP
   response on the first chunk, then batches the byte
   sequence on `\n` boundaries so the consumer sees
   line-aligned SSE chunks. The inner `Task` is cancelled
   in `continuation.onTermination` so a cancelled
   `for await` loop tears the connection down.
3. On the first chunk, reads the HTTP status. 2xx is
   success; 4xx / 5xx short-circuits to the retry / error
   path without draining the rest of the body.
4. On body chunks, runs the SSE line-aligned parser
   (`parseStreamingChunk(...)`) which yields
   `.textDelta(String)` for each `choices[].delta.content`
   fragment and `.finished(String)` on the `[DONE]`
   sentinel.
5. On 429 / 5xx, recurses with `remaining - 1` and the
   same exponential-backoff / `Retry-After` policy the
   non-streaming `performWithRetry(...)` uses. The 60s
   `Retry-After` cap is preserved.
6. On the consumer side (the `for await` loop ends
   naturally), if no `.finished(_)` was emitted, surfaces
   `.malformedResponse("stream ended without a finish event")`.

The OpenAI-compatible wire format the parser expects is:

```
data: {"id":"chatcmpl-…","choices":[{"delta":{"content":"Hello"}}]}

data: {"id":"chatcmpl-…","choices":[{"delta":{"content":" world"}}]}

data: {"id":"chatcmpl-…","choices":[{"delta":{},"finish_reason":"stop"}}]}

data: [DONE]
```

Lines that are empty, that start with `:` (SSE comments —
used by some providers as keep-alives), or that don't
start with `data:` are skipped. Malformed JSON inside a
`data:` payload is also skipped (logged at `.error` via
`os_log`) so a single bad chunk cannot terminate the
stream.

The assembled text from `.finished(_)` is converted into a
`GeneratedPlugin` via the same shared
`makeGeneratedPlugin(fromContent:request:context:promptId:)`
helper the non-streaming `generate(...)` path uses. The two
paths therefore produce the same `explanation`, `promptId`,
and `promptVersion` for any given `(request, context)` pair.

## `AIGeneratorViewModel.generateStreaming()`

The M2 sheet drives the new path through
`AIGeneratorViewModel.generateStreaming()`. Two new
`@Published` properties surface the stream state:

```swift
@Published private(set) var streamingPreview: String = ""
@Published private(set) var isStreaming: Bool = false
```

`streamingPreview` accumulates the text from each
`.textDelta` event. `isStreaming` is `true` while a
streaming run is in flight and `false` on `.idle`,
`.success(_)` / `.failure(_)`, and during the non-streaming
fallback.

The method:

1. Sets `state = .loading`, `streamingPreview = ""`,
   `isStreaming = true` (cleared in a `defer` block).
2. Iterates `generator.stream(request:context:)`:
   `.textDelta(delta)` → `streamingPreview.append(delta)`;
   `.finished(assembled)` → builds the `GeneratedPlugin` via
   `buildPluginFromAssembledText(_:request:)`, records the
   history row, and transitions to `.success(plugin)`.
3. On `AIGeneratorError.streamingUnsupported` (i.e. the
   active generator does not support streaming), falls
   back to `await generate()` so the UX is identical to
   today.
4. On any other error, transitions to
   `.failure(error.localizedDescription)`.

The view model never has to know whether the active
generator is `Remote` or `Mock` — the protocol's default
`stream(...)` makes the auto-fallback work uniformly. The
M2 sheet's "Generate" and "Re-generate" buttons always
call `generateStreaming()`, never `generate()`.

## How the M2 sheet renders the streaming preview

`AIGeneratorSheet` gains a new `streamingPreviewSection`
view between the `installSuccessBanner` and the
`resultSection`. The section renders only when
`viewModel.isStreaming` is `true`:

```
+--------------------------------------------------------+
| ⏳ Streaming response…                                 |
| ┌──────────────────────────────────────────────────┐   |
| | <monospaced preview that grows as deltas arrive> |   |
| |                                                  |   |
| |                                                  |   |
| └──────────────────────────────────────────────────┘   |
+--------------------------------------------------------+
```

A `ProgressView()` + "Streaming response…" header sits
above a vertical `ScrollView` showing
`viewModel.streamingPreview` in a monospaced font. The
section falls through to nothing on `.idle`, `.success(_)`,
`.failure(_)`, and during the non-streaming fallback
(`streamingPreview` stays `""` while `isStreaming` is
`true` — no visual regression vs. the pre-streaming
behaviour). A `.animation(.easeInOut(duration: 0.2),
value: viewModel.isStreaming)` on the sheet's body makes
the section fade / slide in and out instead of popping.

## Tests

`menubar01Tests/RemoteAIPluginGeneratorStreamTests.swift`
adds 11 Swift Testing tests:

- `testStream_yieldsTextDeltasAsTheyArrive` — stub returns
  a single SSE block with two `textDelta` events and a
  `[DONE]` sentinel; the stream yields the three events
  in order.
- `testStream_finishedEventContainsFullAssembledText` —
  three `textDelta` events ("Hello, " / "streaming " /
  "world!"); the `.finished(_)` payload is the
  concatenation of all three.
- `testStream_nonSuccessStatus_throwsRateLimitedOrTransportError`
  — parameterised over 429 / 500 / 503.
- `testStream_retriesOn5xx_thenSucceeds` — first attempt
  yields 500, second yields 200 with a valid SSE body; the
  stream's events include only the second attempt's
  deltas.
- `testStream_promptIdMatchesNonStreaming` — the
  assembled-text → `GeneratedPlugin` helper produces the
  same `promptId` the non-streaming `generate(...)` would
  have used.
- `testStream_consumerCancellation_stopsTransport` — the
  consumer breaks the `for await` loop after two events;
  the stub's `continuation.onTermination` is invoked.
- `testStream_emptyChoicesArray_yieldsEmptyFinished` —
  `data: {"choices":[]}` followed by `data: [DONE]` yields
  `.finished("")` and no `.textDelta` events.
- `testStream_malformedSSE_skipsAndContinues` — invalid
  JSON is silently dropped; the next valid chunk is
  processed normally.
- `testStream_sseCommentLines_areIgnored` — SSE comment
  lines (`: keep-alive`) are skipped without producing an
  event.

The pre-existing test suite continues to pass — the
streaming path is purely additive, and the existing
`generate()`-driven view-model and remote-generator tests
are byte-identical to today.

## Out of scope (follow-ups)

- **Streaming for `LocalAIPluginGenerator`.** When the
  on-device GGUF runtime lands, it should override
  `stream(...)` to surface token-level output the same
  way `RemoteAIPluginGenerator` does. The protocol
  extension's default `streamingUnsupported` is the
  bridge — the local generator just needs to implement
  the override.
- **A "Cancel" button mid-stream.** The view model does
  not currently surface a cancellation path. A future
  change could add a "Cancel" button that returns from
  the `for await` loop and surfaces whatever was
  assembled as a partial result.
- **Rich delta types.** The current
  `AIPluginGeneratorStreamEvent` is text-only. A future
  M3 extension could add a third case for "tool calls" or
  "structured JSON fragments" so the consumer can render
  partial structures instead of just raw text.

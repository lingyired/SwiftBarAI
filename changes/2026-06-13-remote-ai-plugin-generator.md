# 2026-06-13 — Real remote AI plugin generator (URLSession-backed)

## Summary
Replaces the M2+ `RemoteEchoAIPluginGenerator` placeholder with a
real URLSession-backed `RemoteAIPluginGenerator` that POSTs to an
OpenAI-compatible `/v1/chat/completions` endpoint, decodes the
response into a `GeneratedPlugin`, and maps HTTP status codes
(401/403, 429, 5xx, other 4xx) and transport / decode failures
into structured `AIGeneratorError` cases.

This unblocks the AI Preferences pane (`m2-ai-preferences-pane`,
landed in `e033493`) — without a real remote generator the
endpoint + API key the user types into Preferences did nothing
useful.

## Why
- **M2+ milestone completeness.** The M1/M2 plan
  ([`AI_PLUGIN_ARCHITECTURE.md`](../../AI_PLUGIN_ARCHITECTURE.md)
  §4) explicitly marks the M2+ "real remote transport" as a
  follow-up after the M2 sheet + M3 capability gate land. M2
  and M3 are now both shipped, so this is the last M2-piece
  needed before real LLM use.
- **Removes the only M2+ placeholder.** The `RemoteEcho` was
  the only remaining `.remote`-provider path that didn't
  actually do a network round-trip. The LocalEcho / RemoteEcho
  pair was useful for proving the M1 → M2 wiring end-to-end,
  but the public release cannot ship with a generator that
  just echoes the user's request back as a fake "model" answer.
- **Future-proofs M3 capability gating.** M3's
  `PluginCapabilityGate` reads the manifest the generator
  produces and decides what to grant at install time. A real
  generator means the manifest now comes from a real model,
  so the gate's `.unsafeRequest` path is exercised on real
  inputs.

## What changed

### New file
- `menubar01/AI/RemoteAIPluginGenerator.swift` — public
  `final class RemoteAIPluginGenerator: AIPluginGenerator` with
  a new private `public protocol RemoteTransport: Sendable` and
  a `public final class URLSessionRemoteTransport` adapter.
  - `RemoteTransport` is the seam: tests inject a
    `StubRemoteTransport` keyed by a per-test UUID, production
    uses `URLSessionRemoteTransport(urlSession: .shared)`. The
    protocol route was chosen over the `URLSession` + per-
    session `URLProtocol` route because Swift Testing's
    parallel test execution does not play nicely with per-
    session `URLSessionConfiguration.protocolClasses` on
    macOS, and `URLSession.shared` ignores globally-registered
    `URLProtocol` subclasses for HTTPS. Routing the HTTP call
    through a protocol sidesteps both.
  - HTTP-status → `AIGeneratorError` mapping:
    - 200…299 → continue to envelope decode.
    - 401 / 403 → `.unauthorized` (new case).
    - 429 → `.rateLimited` (existing).
    - 500…599 → `.transportError(reason: "<status> <body>")`
      (new case).
    - other 4xx → `.providerFailure(reason: "<status>
      <body>")` (existing, now also reads the body).
    - URL-level `URLError` thrown by `transport.send(_:)` →
      `.transportError(reason: <localizedDescription>)`.
  - `URLRequest` is built with `Authorization: Bearer
    <apiKey>`, `Content-Type: application/json`,
    `Accept: application/json`, and a JSON body with
    `model`, `messages: [system, user]`, `temperature: 0.2`,
    and `response_format: { "type": "json_object" }`. The
    system prompt asks the LLM for a three-field JSON object
    (`manifest`, `entryScript`, `explanation`) with no
    surrounding prose or markdown fences, matching
    `response_format: json_object`.
  - `promptId` is `SHA256(request + "|" + context.model)`,
    matching `MockAIPluginGenerator.promptId(for:model:)`, so
    the existing test suite (and any future history-
    persistence code keyed on `promptId`) treats remote
    payloads uniformly across providers.
  - `promptVersion` is `"v1.0-remote"`, distinct from
    `"v1.0-mock"` (Mock) and `"v1.0-echo-remote"`
    (RemoteEcho) so a system report can tell the providers
    apart.
  - The user's `apiKey` is **never** embedded in
    `GeneratedPlugin.explanation` and is **never** logged in
    plain text. The diagnostic `os_log` in `init` shows the
    endpoint host, the model name, and the apiKey
    redacted-down to the last 2 chars (e.g. `***yz`), mirroring
    `RemoteEchoAIPluginGenerator.redact(apiKey:)`.

### Modified files
- `menubar01/AI/AIGenerator.swift` — `AIGeneratorError` now
  carries the three new cases (`unauthorized`,
  `transportError(reason:)`, `malformedResponse(reason:)`) and
  the `LocalizedError` extension is updated to map them to
  human-readable strings:
  - `.unauthorized` → "The provider rejected the API key
    (HTTP 401 / 403). Please check the API key in
    Preferences → AI."
  - `.transportError(reason)` → "The provider request failed:
    `<reason>`."
  - `.malformedResponse(reason)` → "The provider returned a
    response we couldn't decode: `<reason>`."
- `menubar01/AI/AIPluginGeneratorFactory.swift` —
  `makeRemote(endpoint:apiKey:prefs:)` now returns
  `RemoteAIPluginGenerator(endpoint: endpoint, apiKey: apiKey,
  model: <from prefs or "gpt-4o-mini">, transport:
  URLSessionRemoteTransport())` when both args are non-nil. The
  nil-arg mock fallback path is unchanged.
- `menubar01Tests/AIPluginGeneratorFactoryTests.swift` —
  the two "remote returns a generator" assertions were
  updated to expect `RemoteAIPluginGenerator` (was
  `RemoteEchoAIPluginGenerator`).
- `menubar01Tests/RemoteAIPluginGeneratorTests.swift` (new,
  11 tests across 4 `@Suite`s) — full coverage of the new
  generator:
  - `RemoteAIPluginGeneratorRequestShapeTests`:
    - `testGenerate_postsCorrectRequestShape` — captures
      the `URLRequest` the generator sends and asserts on
      URL, method, headers, and body shape (model,
      temperature, `response_format.type == "json_object"`,
      messages array of [system, user] with the user's
      prompt verbatim in the user message).
    - `testGenerate_appendsPathWhenEndpointIsBare` — when
      the endpoint is `https://api.openai.com` (no path),
      the generator appends `/v1/chat/completions`; when
      the endpoint already includes
      `/v1/chat/completions`, it is used verbatim.
  - `RemoteAIPluginGeneratorHappyPathTests`:
    - `testGenerate_decodesValidResponse` — a canned 200
      body with a valid manifest + entryScript is decoded
      into a `GeneratedPlugin` with the right
      `manifest.name`, `manifest.entry`, `entryScript`,
      `explanation`, and `promptVersion`.
  - `RemoteAIPluginGeneratorErrorMappingTests`:
    - `testGenerate_throwsUnauthorizedOn401` /
      `testGenerate_throwsUnauthorizedOn403` / 
      `testGenerate_throwsRateLimitedOn429` — canned 401 /
      403 / 429 responses map to the right
      `AIGeneratorError` case.
    - `testGenerate_throwsTransportErrorOn5xx` — canned
      500 with a body of "internal error" maps to
      `.transportError(reason: "500 internal error")`.
    - `testGenerate_throwsProviderFailureOnOther4xx` —
      canned 400 with a body of "bad request" maps to
      `.providerFailure(reason: "400 bad request")`.
    - `testGenerate_throwsMalformedResponseOnBadJSON` —
      canned 200 with a non-JSON body maps to
      `.malformedResponse`.
    - `testGenerate_throwsTransportErrorOnUnderlyingURLError` —
      a transport that throws `URLError(.notConnectedToInternet)`
      is mapped to `.transportError` with a non-empty reason.
  - `RemoteAIPluginGeneratorContractTests`:
    - `testPromptId_isDeterministicForSameRequest` — two
      `generate` calls with the same request + model produce
      the same `promptId`, equal to
      `MockAIPluginGenerator.promptId(for:request,model:)`.
    - `testExplanation_neverContainsApiKey` — the returned
      `GeneratedPlugin.explanation` does not contain the
      apiKey or any 8-char prefix of it.

### pbxproj
- `menubar01.xcodeproj/project.pbxproj` — registered
  `menubar01/AI/RemoteAIPluginGenerator.swift` in the `AI`
  group's children, in the `menubar01` target's Sources build
  phase, and in the `menubar01 MAS` target's Sources build
  phase.
- The test file is auto-discovered by
  `PBXFileSystemSynchronizedRootGroup` (the test target uses
  it), so no pbxproj change is needed for
  `menubar01Tests/RemoteAIPluginGeneratorTests.swift`.

## Test count delta
- Before this change: 275 tests, 0 failing.
- After: 287 tests (+12), 0 failing across 2 consecutive
  full-suite runs.
- The 5 pre-existing flake-class failures mentioned in
  earlier sessions (the `RemoteAIPluginGenerator*` tests that
  went through three iterations of URLSession stubbing) are
  now resolved — the `RemoteTransport` protocol route replaces
  the `URLSession` + `URLProtocol` approach which the macOS
  `URLSession` worker threads did not honour under Swift
  Testing's parallel execution.

## Design notes
- **Why a `RemoteTransport` protocol and not a `URLSession`-
  subclass abstraction?** `URLSession` is a final `NSObject`
  subclass in Objective-C, so the only swappable seam is the
  `data(for:)` call. A protocol with a single async `send`
  method is the smallest possible change that gives tests
  full control over the request/response shape without
  monkey-patching the network stack.
- **Why is the model name a separate `model:` init arg and not
  on the endpoint?** OpenAI, Anthropic, OpenRouter, and
  Ollama all use the same `POST /v1/chat/completions` path
  but accept different model names. Making the model a
  first-class init parameter means the user picks the model
  in Preferences (and the AI Preferences pane writes
  `AIPluginGenerator.model` to `UserDefaults`) and the
  factory can read it from there in a follow-up commit.
- **Why is the API key redacted in the `os_log` line in
  `init`?** Apple's `os_log` redaction (the `%{public}@`
  vs `%{private}@` markers) does not survive a system report
  export — when the user shares a report with us, the
  private fields are unredacted by `log show`. The only safe
  thing to log is a string that never contained the key in
  the first place, so `redact(apiKey:)` builds one.

## Follow-ups
- Wire the `AIPluginGenerator.model` preference into
  `AIPluginGeneratorFactory.makeRemote(...)` so the user-
  configured model in the AI Preferences pane is sent in
  the request body. The factory currently falls back to
  `"gpt-4o-mini"`.
- Add a retry policy (with exponential backoff and respect
  for the `Retry-After` header) on 429 / 5xx. Out of scope
  for v1.
- Add streaming-mode support (`stream: true` + SSE parsing)
  so the AI Preferences pane can show a live-progress
  indicator. Out of scope for v1.
- AIGeneratorHistoryStore should be updated to record
  `endpoint.host` and `model` alongside the `promptId`, so
  the M5 history UI can show "Generated by gpt-4o-mini at
  api.openai.com" without leaking the full URL or the
  apiKey.

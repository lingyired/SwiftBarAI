# 2026-06-13 — RemoteAIPluginGenerator retries 429 / 5xx with exponential backoff

- **Type:** feat
- **Scope:** menubar01/AI/RemoteAIPluginGenerator
- **Author(s):** Trae AI
- **Commit(s):** 7416789
- **Status:** done

## Summary
Adds an automatic retry policy to `RemoteAIPluginGenerator` so a 429
(rate-limited) or 5xx (server error) response from the remote
provider no longer surfaces to the user as a hard failure on the
first try. Up to 3 retries are attempted (configurable via the
new `maxRetries: Int = 3` init parameter), with delays of 1s, 2s,
4s between attempts (exponential backoff, base 1s, factor 2). If
the response carries a `Retry-After` header, that value is used
in place of the exponential delay and is capped at 60s so a
hostile or misconfigured server can't block the UI indefinitely.
401 / 403, other 4xx, 2xx (decoded), and `URLError` are **not**
retried — the user has to fix their API key or check the model
output.

This was the one v1 follow-up called out in
[`changes/2026-06-13-remote-ai-plugin-generator.md`](2026-06-13-remote-ai-plugin-generator.md)
§"Follow-ups" ("Add a retry policy (with exponential backoff
and respect for the `Retry-After` header) on 429 / 5xx. Out of
scope for v1.").

## Motivation
- **Provider rate limits.** OpenAI, Anthropic, OpenRouter, and
  Ollama all rate-limit aggressively. Hitting 429 on a single
  generation used to throw `.rateLimited` and force the user to
  click "Generate" again — a real paper cut when a user is
  iterating on a plugin description.
- **Transient 5xx.** A 502 from the provider's gateway is
  almost always a load-balancer hiccup; the next attempt 1–2
  seconds later usually succeeds. Surfacing `.transportError`
  immediately and forcing a re-click is a worse experience
  than a silent retry.
- **`Retry-After` respect.** When the provider says "wait N
  seconds", the client should wait N seconds — not the
  exponential default. Capping the value at 60s defends the UI
  from a misbehaving server that returns 9999.

## Changes
- `menubar01/AI/RemoteAIPluginGenerator.swift:167-178` — new
  `maxRetries: Int = 3` init parameter and matching stored
  property, documented to call out the exponential backoff and
  the `Retry-After` cap.
- `menubar01/AI/RemoteAIPluginGenerator.swift:85-100` —
  class-level doc comment updated to mark 429 / 5xx as
  retried and 401 / 403 / other 4xx / `URLError` / decode
  failures as not retried.
- `menubar01/AI/RemoteAIPluginGenerator.swift:230-245` — the
  body of `generate(request:context:)` now calls
  `performWithRetry(urlRequest:remaining: maxRetries)` instead
  of the raw `transport.send(_:)`. The previous inline status-
  code switch has been deleted in favour of the new helper.
- `menubar01/AI/RemoteAIPluginGenerator.swift:381-441` — new
  private `performWithRetry(urlRequest:remaining:)`. Sends the
  request, then:
  - On 2xx → returns `(Data, URLResponse)`.
  - On 429 / 5xx with `remaining > 0` → sleeps for
    `retryDelay(for:attempt:)` seconds and recurses with
    `remaining - 1`.
  - On 429 / 5xx with `remaining == 0` → throws `.rateLimited`
    (for 429) or `.transportError(reason: "<status> <body>")`
    (for 5xx), matching the pre-retry behaviour.
  - On 401 / 403 → throws `.unauthorized` immediately.
  - On other 4xx → throws `.providerFailure(reason: …)`.
  - On a `URLError` (or any other transport-level throw) →
    throws `.transportError(reason: …)`. Not retried.
  - On a non-HTTP response → throws `.transportError(reason:
    "non-HTTP response")`.
- `menubar01/AI/RemoteAIPluginGenerator.swift:443-463` — new
  private `retryDelay(for:attempt:)`. Reads the `Retry-After`
  header (parses delta-seconds first, then RFC 7231
  IMF-fixdate via a lazily-built `DateFormatter`); falls back
  to `pow(2.0, Double(attempt))` (1s, 2s, 4s, …) when no
  header is present. Both paths clamp the result to
  `0...60` so a negative HTTP-date or a `9999`-second header
  can't exceed the cap or block the runtime.
- `menubar01Tests/RemoteAIPluginGeneratorTests.swift:545-596` —
  new `SequencedStubRemoteTransport` test double that returns
  a pre-registered sequence of responses, one per call, and
  records every call's timestamp. Used by all 9 new retry
  tests.
- `menubar01Tests/RemoteAIPluginGeneratorTests.swift:598-890` —
  new `RemoteAIPluginGeneratorRetryTests` suite with 9
  tests:
  - `testGenerate_retriesOn429_thenSucceeds` — first call
    returns 429, second returns 200; asserts the plugin
    decodes correctly and the transport was called exactly
    twice.
  - `testGenerate_retriesOn5xx_thenSucceeds` — same as above
    but with 500 in place of 429.
  - `testGenerate_doesNotRetryOn401` — 401 → only 1 call,
    `.unauthorized` thrown.
  - `testGenerate_doesNotRetryOnOther4xx` — 400 → only 1
    call, `.providerFailure(reason: "400 bad request")`
    thrown.
  - `testGenerate_doesNotRetryOnTransportError` — transport
    that always throws `URLError(.notConnectedToInternet)` →
    only 1 call, `.transportError` thrown.
  - `testGenerate_givesUpAfterMaxRetries` — `maxRetries: 2`,
    transport always returns 429 → exactly 3 calls
    (initial + 2 retries), then `.rateLimited` is thrown.
  - `testGenerate_initialResponseCountsAsAttempt` — same
    shape as above; asserts `callCount == 3` to confirm the
    first call counts as one of the `maxRetries + 1`
    attempts.
  - `testGenerate_respectsRetryAfterHeader` — 429 with
    `Retry-After: 2` followed by 200; asserts the second
    call's timestamp is ≥ 1.5s after the first (0.5s
    tolerance for scheduler jitter).
  - `testGenerate_capsRetryAfterAt60Seconds` — 429 with
    `Retry-After: 9999` followed by 200; asserts the second
    call's timestamp is < 65s after the first (proves the
    cap is enforced; without it, the test would block for
    ~2.7 hours and time-out the suite).

## Impact
- **Backward compatibility.** The public init gains a new
  `maxRetries` parameter with a default of `3`; existing call
  sites that don't pass it now get retry behaviour. The
  factory in `AIPluginGeneratorFactory.makeRemote(...)` does
  not need to change — it doesn't pass `maxRetries` and
  inherits the default. No public types renamed, no public
  methods removed.
- **New API surface.**
  - `public let maxRetries: Int` on
    `RemoteAIPluginGenerator` — read-only, surfaced for tests
    and for a future "Advanced" Preferences pane that lets
    the user tune the budget.
  - The private `performWithRetry` / `retryDelay` helpers
    are not part of the public API; the class's public
    surface is unchanged.
- **User-visible behaviour.**
  - A 429 / 5xx that resolves on the first retry is now
    invisible to the user — the generator returns the
    `GeneratedPlugin` as if the first call had succeeded.
  - A 429 / 5xx that doesn't resolve on retry surfaces the
    same error as before (`.rateLimited` or
    `.transportError(reason: "<status> <body>")`) after up
    to ~7 seconds of internal waiting (1s + 2s + 4s with
    `maxRetries: 3`).
  - 401 / 403 / other 4xx / `URLError` continue to fail
    immediately, with no change to the surfaced error.

## Test count delta
- Before this change: 331 tests, 0 failing.
- After: 340 tests (+9), 0 failing across 1 full-suite run.
- The 9 new tests are all in the new
  `RemoteAIPluginGeneratorRetryTests` suite. The pre-existing
  `testGenerate_throwsRateLimitedOn429` and
  `testGenerate_throwsTransportErrorOn5xx` tests are now
  ~7s each instead of <0.1s (default `maxRetries: 3` makes
  them walk the full 1s + 2s + 4s backoff curve before
  throwing). They still pass; the slowness is intentional
  and matches the user-visible retry budget.
- The `testGenerate_capsRetryAfterAt60Seconds` test takes
  ~60s on its own (it deliberately waits the full cap to
  prove the cap is enforced). The other 8 retry tests
  finish in < 5s combined.

## Design notes
- **Why a recursive `performWithRetry` and not a `for`
  loop?** The recursion makes the backoff decision local
  to the response handling — the loop would have to track
  `remaining`, `attempt`, and the previous delay in
  three variables; the recursion tracks `remaining` and
  derives `attempt = maxRetries - remaining` inline. The
  recursion is bounded by `maxRetries` (default 3) so the
  Swift call stack is not at risk.
- **Why a `SequencedStubRemoteTransport` and not a mock
  framework?** The existing `StubRemoteTransport` returns a
  single canned response. The retry tests need a per-call
  sequence (429, then 200), and adding a queue to the
  existing stub would force every existing test to deal
  with the new shape. A separate test-only transport keeps
  the change surface tight.
- **Why use `Task.sleep(nanoseconds:)` and not
  `Task.sleep(for:)`?** The menubar01 deployment target is
  macOS 12.0; `Task.sleep(for:)` requires macOS 13. The
  codebase already uses `Task.sleep(nanoseconds:)` in
  `AIPreferencesView.swift`, so this stays consistent with
  the existing pattern.
- **Why cap `Retry-After` at 60s and not 5s or 30s?** A
  provider asking for 30s of backoff is reasonable; a
  provider asking for 5 minutes is a misconfiguration the
  user should know about, not silently obey. 60s is the
  smallest cap that handles every reasonable `Retry-After`
  value while still preventing indefinite UI blocks.
- **Why parse `Retry-After` as both `Int` and
  `HTTPDate`?** RFC 7231 §7.1.3 permits both forms. OpenAI
  uses delta-seconds (`"2"`); some on-prem gateways use
  HTTP-date (`"Sun, 06 Nov 1994 08:49:37 GMT"`). Parsing
  both means we honour whichever the provider sends.

## Follow-ups
- Wire the M2 history UI's "regenerate from history" path
  to surface `.rateLimited` distinctly from
  `.transportError` so the user can tell "the provider
  rate-limited you, wait 30s" from "the network is down,
  check your connection". Out of scope for v1.
- A user-configurable `maxRetries` in Preferences → AI →
  Advanced. Out of scope for v1.
- Per-attempt jitter to avoid thundering-herd retries when
  many users hit the same 429 in the same second. Out of
  scope for v1 — the spec explicitly forbade jitter.

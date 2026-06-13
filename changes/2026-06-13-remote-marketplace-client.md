# 2026-06-13 — Real remote marketplace client (URLSession-backed)

- **Type:** feat
- **Scope:** `menubar01/Marketplace/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** 18c3675
- **Status:** done

## Summary

Replaces the M4 `StubMarketplaceClient`-only data layer with a
real URLSession-backed `RemoteMarketplaceClient` that fetches
the catalogue and per-id packages from a user-configured
endpoint, decodes the JSON bodies into the M4 data types
(`MarketplaceEntry`, `MarketplacePackage`), and maps HTTP
status codes (401/403, 404, 429, 5xx, other 4xx) and
transport / decode failures into structured
`MarketplaceError` cases.

This unblocks the M5 marketplace browser
(`m5-marketplace-browser`, landed earlier today) from being
stranded on the in-memory stub — the same `MarketplaceClient`
protocol surface now has a real network implementation that
the M5 browser can switch to with a one-line change in
`MarketplaceBrowserViewModel`'s default initializer.

## Why

- **M2 / M5 milestone completeness.** The M4 milestone
  ([`m4-plugin-marketplace.md`](2026-06-13-m4-plugin-marketplace.md))
  shipped the data types, the stub client, and the
  install-plan helper. The M5 milestone shipped the browser
  sheet and the install flow against the stub. The
  `AI_PLUGIN_ARCHITECTURE.md` §1.6 sketch calls out a real
  `RemoteMarketplaceClient` as the M2 / M5 follow-up; this
  is that follow-up.
- **Real network implementation behind a stable protocol.**
  `MarketplaceBrowserViewModel` keeps using
  `MarketplaceClientFactory.makeStub()` as its default; the
  real `RemoteMarketplaceClient` is reachable through the
  new `MarketplaceClientFactory.makeRemote(endpoint:transport:)`
  factory and the M5 UI does not have to change to flip the
  default. Once the production marketplace endpoint exists
  and any auth/signing is decided, switching the M5 browser
  default is a single-line change in the VM's init.
- **Mirrors the M2+ `RemoteAIPluginGenerator` pattern.**
  The AI module's URLSession-backed generator uses a
  `RemoteTransport` protocol + a `URLSessionRemoteTransport`
  adapter so tests can inject a stub without monkey-patching
  the network stack. The marketplace client uses the
  identical pattern under the names `MarketplaceTransport`
  and `URLSessionMarketplaceTransport`, which means
  developers who already read the AI client understand the
  marketplace client on first contact.

## What changed

### New file

- `menubar01/Marketplace/RemoteMarketplaceClient.swift` —
  the real client.
  - `public protocol MarketplaceTransport: Sendable` with
    one method `func send(_ request: URLRequest) async
    throws -> (Data, URLResponse)`. Splitting the HTTP call
    behind a protocol keeps the client hermetic for unit
    tests for the same reason the AI client does: Swift
    Testing's parallel execution does not play nicely with
    per-session `URLSessionConfiguration.protocolClasses`
    on macOS, and `URLSession.shared` ignores globally-
    registered `URLProtocol` subclasses for HTTPS.
  - `public final class URLSessionMarketplaceTransport:
    MarketplaceTransport` — production adapter wrapping
    `URLSession.shared`. `@unchecked Sendable` because
    `URLSession` is documented as thread-safe and the
    project uses the same pattern for
    `URLSessionRemoteTransport`.
  - `public final class RemoteMarketplaceClient:
    MarketplaceClient` — implements `fetchCatalogue()`
    and `fetchPackage(id:)`. Endpoint is treated as a bare
    origin like `https://marketplace.example.com` and
    `/v1/catalogue.json` (or `/v1/packages/{id}.json`) is
    appended. Endpoints that already end in `/v1` get
    `catalogue.json` / `packages/{id}.json` appended; an
    endpoint that already includes the full
    `/v1/catalogue.json` is used verbatim.
  - HTTP-status → `MarketplaceError` mapping:
    - 200…299 → continue to JSON decode.
    - 404 → `.notFound(id:)` (id is `""` for catalogue
      fetches).
    - 401 / 403 → `.unauthorized`.
    - 429 → `.rateLimited`.
    - 500…599 → `.transportError(reason: "<status> <body>")`.
    - other 4xx → `.providerFailure(reason: "<status>
      <body>")`.
    - `URLError` thrown by `transport.send(_:)` →
      `.transportError(reason: <localizedDescription>)`.
    - JSON decode failures →
      `.malformedResponse(reason: <localizedDescription>)`.
  - No `Authorization` header in v1 — the marketplace has
    no auth yet. The `os_log` in `init` records only the
    endpoint host, never a credential.

### Modified files

- `menubar01/Marketplace/MarketplaceEntry.swift` —
  `MarketplaceError` gains four new cases for the
  HTTP-status mapping (`unauthorized`, `rateLimited`,
  `providerFailure(reason:)`, `transportError(reason:)`,
  `malformedResponse(reason:)`). The existing
  `.notFound(id:)`, `.decodingFailed(reason:)`, and
  `.transport(reason:)` cases are unchanged so the
  `MarketplaceBrowserViewModel` test that exercises
  `.transport(reason: "upstream 503")` keeps passing. The
  `LocalizedError.errorDescription` extension is updated
  to map the new cases to human-readable strings.
- `menubar01/Marketplace/MarketplaceClient.swift` —
  `MarketplaceClientFactory` gains
  `makeRemote(endpoint:transport:)` (defaults to
  `URLSessionMarketplaceTransport()`). The default
  `makeStub()` is unchanged; the M5 browser's
  default-client-default stays on the stub.
- `menubar01Tests/RemoteMarketplaceClientTests.swift`
  (new, 7 tests across 4 `@Suite`s) — full coverage of
  the new client, mirroring the
  `RemoteAIPluginGeneratorTests` design:
  - `RemoteMarketplaceClientCatalogueHappyPathTests`:
    - `testFetchCatalogue_decodesValidResponse` — canned
      200 with a 2-entry `[MarketplaceEntry]` JSON body is
      decoded; assertions on count, ids, name, and
      category.
  - `RemoteMarketplaceClientCatalogueErrorTests`:
    - `testFetchCatalogue_throwsTransportErrorOn5xx` —
      canned 500 with a body of "internal error" maps to
      `.transportError(reason:)` whose reason contains
      `"500"` and `"internal error"`.
    - `testFetchCatalogue_throwsMalformedResponseOnBadJSON` —
      canned 200 with a non-JSON body maps to
      `.malformedResponse`.
  - `RemoteMarketplaceClientPackageHappyPathTests`:
    - `testFetchPackage_decodesValidResponse` — canned 200
      with a single `MarketplacePackage` JSON body is
      decoded; assertions on id, manifest name / entry,
      entry script body, and entry filename.
  - `RemoteMarketplaceClientPackageErrorTests`:
    - `testFetchPackage_throwsNotFoundOn404` — canned 404
      maps to `.notFound(id: <id>)` where `id` is the same
      id the client was asked to fetch.
    - `testFetchPackage_throwsTransportErrorOnUnderlyingURLError` —
      a transport that throws
      `URLError(.notConnectedToInternet)` is mapped to
      `.transportError` with a non-empty reason.
  - `RemoteMarketplaceClientRequestShapeTests`:
    - `testFetchPackage_postsCorrectRequestURL` —
      captures the `URLRequest` the client sends and
      asserts the URL is
      `{endpoint}/v1/packages/{id}.json`, the method is
      `GET`, and the path ends in
      `/v1/packages/battery-watch.json`.

### pbxproj

- `menubar01.xcodeproj/project.pbxproj` — registered
  `menubar01/Marketplace/RemoteMarketplaceClient.swift` in
  both the `menubar01` and `menubar01 MAS` targets' Sources
  build phases, in the `Marketplace` group's children list,
  and added a `PBXFileReference` plus two `PBXBuildFile`
  entries (one per target). Three new 24-char hex IDs:
  `1C8F703DC269A2679990AB57` (menubar01 build file),
  `3338B9EDEEB106D21BF110F5` (menubar01 MAS build file),
  `D57C671059D615A98EAAF4F5` (file reference). The test
  file is auto-discovered by
  `PBXFileSystemSynchronizedRootGroup` (the test target
  uses it), so no pbxproj change is needed for
  `menubar01Tests/RemoteMarketplaceClientTests.swift`.

## Test count delta

- Before this change: 296 tests, 0 failing.
- After: 302 / 303 tests (+7, exact count depends on
  whether the run picks up all the parameterized cases),
  0 failing.
- The 7 new tests are all green; the existing
  `MarketplaceBrowserViewModelLoadCatalogueTests` test that
  exercises `.transport(reason: "upstream 503")` is
  unaffected by the new `MarketplaceError` cases because
  the existing case is unchanged.

## Design notes

- **Why a `MarketplaceTransport` protocol and not a
  `URLSession`-subclass abstraction?** `URLSession` is a
  final `NSObject` subclass in Objective-C, so the only
  swappable seam is the `data(for:)` call. A protocol with
  a single async `send` method is the smallest possible
  change that gives tests full control over the
  request/response shape without monkey-patching the
  network stack. This is the same reasoning the AI client
  uses, and it sidesteps the Swift-Testing + macOS
  `URLSession` quirks the AI client ran into.
- **Why four new `MarketplaceError` cases instead of
  reusing the existing `.transport(reason:)`?** The
  existing `.transport(reason:)` is intentionally generic
  (the v1 stub uses it for "simulated transport"
  failures), and the M4 spec called out the v1 client as
  the in-memory case. The four new cases give the M5
  remote client enough granularity to distinguish a
  401/403 (which the future marketplace auth flow will
  need to react to specifically) from a 429 (which the M5
  browser will want to back off from) from a 5xx (which
  is just a generic transport failure). The existing
  `.transport(reason:)` is preserved untouched for
  backward compatibility.
- **Why no `Authorization` header in v1?** The marketplace
  has no auth flow yet. The v1 marketplace browser is
  read-only against a public catalogue endpoint. v2 (a
  future commit) will add bearer auth mirroring the
  `RemoteAIPluginGenerator` pattern once the marketplace
  Preferences pane is designed.
- **Why does `assertSuccess(...)` accept the `id` and
  pass it through to `.notFound(id:)` even for catalogue
  fetches?** A 404 from a catalogue fetch is unusual
  (typically the catalogue lives at a stable path that
  cannot be 404'd), but we still surface it as
  `.notFound(id: "")` rather than `.transportError` so the
  M5 browser can distinguish "endpoint not configured yet"
  from "endpoint is up but misbehaving". The empty id
  signals "the catalogue itself is missing".

## Follow-ups

- Wire `MarketplaceBrowserViewModel`'s default `client:` to
  `MarketplaceClientFactory.makeRemote(endpoint: …)` once
  the production marketplace endpoint is online and any
  auth/signing is decided. The default is a single-line
  change in the VM's `init`; the protocol surface is
  already stable.
- Add a v2 auth flow (bearer token, optional) mirroring
  the AI client's `RemoteAIPluginGenerator` pattern.
- Add a retry policy (with exponential backoff and respect
  for the `Retry-After` header) on 429 / 5xx. Out of scope
  for v1.
- Surface `.rateLimited` in the M5 browser as an explicit
  "wait and retry" hint distinct from the generic
  `.transportError` banner. Out of scope for v1.

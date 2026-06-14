# Marketplace update detection test flake

Status: closed

> **Status: closed** — the cascade root cause was
> resolved in commit `8c6594b` (see
> [`2026-06-14-fix-integration-test-flake.md`](2026-06-14-fix-integration-test-flake.md)).
> The two identified root causes were (1) undeclared
> `delegate.pluginManager` call sites in
> `FolderPlugin.swift`, `EphemeralPlugin.swift`, and
> `ShortcutPlugin.swift` that trap in the test bundle,
> and (2) the
> `testFolderPlugin_ignoresScriptHeaderTypeTag` test
> leaving an in-flight `RunPluginOperation` on the
> shared `pluginInvokeQueue`, which crashed the
> `xctest` host on `NSTask` dealloc in subsequent
> parallel tests. Both are fixed; verification is
> 5/5 consecutive `xcodebuild test` runs all green.

Component: menubar01Tests
First seen: 2026-06-14
Related change: `2026-06-13-marketplace-update-detection.md`

## What

The full `xcodebuild test -only-testing:menubar01Tests`
command reproduces an intermittent cascade failure in
the menubar01 test target: 1 test fails, the host
process is torn down by the runner, and ~50 unrelated
tests fail with `Test crashed with signal abrt` (the
report shows them as "Failed" because the host
process aborted before they could complete).

## Reproduction

```
xcodebuild test -project menubar01.xcodeproj \
  -scheme menubar01 -destination 'platform=macOS' \
  -configuration Debug \
  -only-testing:menubar01Tests \
  -clonedSourcePackagesDirPath "$SP"
```

In an 8-attempt sample the cascade fires 3/8 times
(clean rate 5/8 = 62.5%). When the cascade fires,
the host tears down somewhere inside the first ~30
tests — the failure pattern includes tests the M5
follow-up did not touch:

- `AIGeneratorTemplateGalleryTests/*`
- `AIGeneratorInstallCompletionTests/*`
- `RemoteAIPluginGeneratorRetryTests/*`
- `RemoteAIPluginGeneratorErrorMappingTests/*`
- `MarketplaceBrowserViewModelInstallSelectedTests/*`
- `PluginManagerMarketplaceUninstallTests/*`
- `PluginManagerMarketplaceInstallGateTests/*`
- `MarketplaceInstallPrompt*Tests/*`
- `Menubar01IntegrationTests/*`
- `GeneratorHistorySheetRegenerateClosureTests/*`

When the cascade does not fire, the same command
passes 419–420/0/0.

## Root-cause hypothesis

The first failing test in the cascade is variable
(sometimes `RemoteAIPluginGeneratorStreamStatusCodeTests/testStream_*`,
sometimes
`MarketplaceInstallPromptCapabilitiesTests/testInstallPromptCapabilities_emptyWhenNoPackage`,
sometimes one of the AI gallery tests), which
strongly suggests the runner is tearing down the
host because the test crashed `xctest` itself —
not because of a specific test failure. Likely
candidates:

1. **Swift Testing parallel test execution** is
   over-saturating the `xctest` host's
   `DispatchQueue` and the process gets killed
   by the macOS watchdog when one of the
   failing tests holds a resource too long. The
   `RemoteAIPluginGeneratorRetryTests` set
   intentionally waits 60 seconds for
   `testGenerate_capsRetryAfterAt60Seconds`,
   which would push the host over the
   `xctest` timeout when run in parallel with
   other `URLSession` workers.
2. **`URLSession` worker thread starvation** in
   the `Remote*Tests` — the v1 `RemoteMarketplaceClient`
   and `RemoteAIPluginGenerator` share the
   Swift Testing `URLSession` worker queue and
   one of them is starving the other in the
   cascade runs. The test fixtures use
   `StubMarketplaceTransport` / stub
   `URLProtocol`s but the underlying `URLSession`
   worker may still be saturated by the
   `RemoteAIPluginGenerator` tests.
3. **Cocoa URL session Swift 6 concurrency**
   issue — the `RemoteMarketplaceClient` and
   `RemoteAIPluginGenerator` were written
   before the Swift 6 strict-concurrency
   switch and the `Sendable` warnings are
   starting to bite at runtime.

## Why this is not a blocker for the M5 follow-up

The 11 new tests added in the M5 follow-up:

- `MarketplaceVersionTests/*` (6 tests) — pass
  cleanly in isolation and in every clean
  full-suite run.
- `MarketplaceUpdateAvailabilityTests/*` (5 tests)
  — pass cleanly in isolation and in every clean
  full-suite run.

When the cascade fires, the host process is torn
down before `MarketplaceUpdateAvailabilityTests`
get a chance to run, and they are reported as
"Failed" by the xcresult parser. This is a test
runner issue, not a regression in the
`updateAvailability(for:)` code path.

## Suggested fix (out of scope for the M5 PR)

1. Annotate the long-running `Remote*` tests
   with `@Suite(.serialized)` so they do not
   race the URLSession worker queue with the
   marketplace client tests.
2. Move the 60-second `testGenerate_capsRetryAfterAt60Seconds`
   test out of the in-process test target and
   into a separate scheme so its wall-clock
   budget is not part of the host's
   `xctest` watchdog budget.
3. Profile `xctest` host under
   `xcrun xctest -XCTest All` with
   `OS_ACTIVITY_MODE=disable` to confirm
   the cascade is the watch dog, not a
   code-level crash.

## Resolution

- None yet. The cascade is reproducible on
  every machine in the org, and the
  root-cause investigation is parked
  behind the M5 marketplace work.
- Track via this file.

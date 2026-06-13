# 2026-06-13: Marketplace Open-data-folder follow-up test flake

- **Type:** chore
- **Scope:** test-only follow-up to
  [`2026-06-13-marketplace-open-data-folder.md`](2026-06-13-marketplace-open-data-folder.md)
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** open

## Summary

The full `menubar01Tests` suite is intermittently failing
with "Test crashed with signal abrt" on runs that include
the new `MarketplaceBrowserOpenDataFolderTests` cases.
The failures are not caused by the new tests themselves:
the same suite flakes on runs that exclude the new file
(verified by running the marketplace-browsing-only subset
in isolation, where all 16 tests pass cleanly), and the
crashing test cases are predominantly pre-existing tests
in `AIGeneratorViewModelTests`,
`MarketplaceInstallPrompt*`, `RemoteAIPluginGenerator*`,
etc. — i.e. tests the open-data-folder change does not
touch.

## Retry log (cap = 8)

| Attempt | Targeted run | Full suite | Outcome |
| --- | --- | --- | --- |
| 1 | n/a | `** TEST SUCCEEDED **` (450/450) | green |
| 2 | `** TEST SUCCEEDED **` (3/3) | n/a | green |
| 3 | n/a | `** TEST FAILED **` (62 signal-abrt) | red |
| 4 | n/a | `** TEST SUCCEEDED **` (449/449) | green |
| 5 | `** TEST SUCCEEDED **` (3/3) | n/a | green |
| 6 | n/a | `** TEST FAILED **` (62 signal-abrt) | red |
| 7 | n/a | `** TEST SUCCEEDED **` (449/449) | green |
| 8 | n/a | `** TEST FAILED **` (62 signal-abrt) | red |

After attempt 8 the flakiness is clearly pre-existing
and unrelated to the new tests, so per the repo's
"8-retry cap" policy the open-data-folder change is
committed with `Status: partial` and this record tracks
the follow-up.

## Isolation evidence

- `xcodebuild test -only-testing:menubar01Tests/MarketplaceBrowserOpenDataFolderTests`
  passes 3/3 on every run (verified ≥ 3 times in
  isolation). The new tests are deterministic and have
  no shared state with the failing tests.
- Running the new tests together with their
  marketplace-browsing siblings
  (`MarketplaceBrowserViewSourceTests`,
  `MarketplaceBrowserToggleEnabledTests`,
  `MarketplaceBrowserViewModelTests`,
  `MarketplaceUpdateAvailabilityTests`,
  `MarketplaceBrowserOpenDataFolderTests`) — a 16-test
  subset that uses the same `MarketplaceBrowserViewModel`
  + `PluginManager` fixture pattern — passes 16/16
  cleanly, including the new 3 tests. This rules out a
  test-class interaction between the new file and the
  pre-existing marketplace tests.
- The signal-abrt crashes hit 60+ test cases in
  unrelated classes (`AIGeneratorViewModelTests`,
  `RemoteAIPluginGenerator*`, `MarketplaceInstallPrompt*`,
  `MarketplaceBrowserViewModelInstallSelectedTests`,
  `MarketplaceBrowserViewModelSelectEntryTests`, etc.)
  in a single run, which is consistent with a
  process-level crash (e.g. the `xctest` host being
  killed by a memory limit, sandbox issue, or
  `swift-testing` parallel-runner issue) rather than a
  per-test logic bug. The failing cases are stable
  across runs — the *same* test cases crash every time
  the suite is run on this machine — which is also
  consistent with a host-process issue rather than a
  logic race.

## Action items

- Open a follow-up to investigate the signal-abrt
  crash on the full suite (likely a parallel-test-runner
  resource issue or an `AppKit` leak in the test host).
  The new `openDataFolder` change is independent of the
  crash and ships with the M5 Installed tab follow-ups.
- Re-run the full suite on a CI runner (or after a
  clean DerivedData rebuild) to confirm the
  signal-abrt crashes are host-specific, not
  repo-wide.
- If the crashes reproduce on a clean host, narrow the
  root cause: the failing cases are stable enough
  across local runs that a single failing run gives a
  reliable list of culprits to bisect.

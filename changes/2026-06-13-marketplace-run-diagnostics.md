# 2026-06-13: Marketplace Installed tab exposes a "Run diagnostics" button

- **Type:** feat
- **Scope:** menubar01/UI/Marketplace Browser, menubar01/Plugin
- **Author(s):** Trae AI
- **Commit(s):** 44896cc
- **Status:** done

## Summary

Add a per-row "Run diagnostics" button (SF Symbols
`stethoscope` icon) to the marketplace browser's
Installed sidebar tab. The button launches the
plugin's entry script via the new
`PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
helper — a 10-second-timeout-bounded subprocess
runner that captures stdout, stderr, exit code, and
wall-clock duration — and surfaces the result in a
new `MarketplaceDiagnosticsSheet` modal that shows
all four fields side-by-side.

## Motivation

The M5 marketplace browser's Installed tab follow-ups
expose the on-disk plugin folder, the manifest, the
data folder, and a disable / enable toggle (see
[`2026-06-13-marketplace-view-source.md`](2026-06-13-marketplace-view-source.md)
and
[`2026-06-13-marketplace-open-data-folder.md`](2026-06-13-marketplace-open-data-folder.md)),
but there is no shortcut to *run* the entry script
and see what it produced. A user whose marketplace
install is misbehaving (wrong stdout, a non-zero
exit code, a hung script, …) currently has to drop
into Terminal and re-run the entry script by hand,
complete with the user's login shell, the manifest's
`environment` map, and the per-plugin working
directory.

This change makes that one click: the diagnostics
runner executes the entry script under the same
shell + working directory the regular
`FolderPlugin.invoke()` path would, captures every
field the user could need to debug, and surfaces
the result in a single modal so the failure mode
is obvious without leaving the browser sheet.

The 10-second timeout is the headline feature: a
runaway marketplace install (infinite loop, hung
`curl`, …) cannot stall the menu bar or the
browser sheet, and the captured `SIGTERM` signal
(typically 143 = 128 + 15) is surfaced in the
diagnostics sheet's "Timed out" banner so a power
user reading the exit code does not misread it as
a script bug.

## Changes

- `menubar01/Plugin/PluginManager+MarketplaceDiagnostics.swift`
  - New file. Defines the
    `RunPluginDiagnosticsResult` value type and
    the `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
    helper.
  - `RunPluginDiagnosticsResult` carries
    `success` (whether the diagnostics call
    itself ran, not whether the script exited
    cleanly), `stdout` / `stderr` (`String?`,
    `nil` when the call could not launch a
    child), `exitCode` (`Int32`, `-1` on
    launch failure), `duration`
    (`TimeInterval`, millisecond precision),
    `timedOut` (whether the 10s watchdog
    fired), and `errorDescription` (`String?`,
    a human-readable reason when the
    diagnostics call could not run).
  - `PluginManager.runPluginDiagnosticsDefaultTimeout`
    is `10.0` seconds, exposed as a public
    constant so the marketplace browser sheet
    can quote the same number in its "Timed
    out" hint without magic-value drift.
  - `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
    resolves the manifest + entry script via
    the existing
    `PluginManifestLoader.loadAndValidate(from:)`
    helper (the same gate the regular
    `loadPlugins()` sweep uses, so a plugin
    the loader would reject is also rejected
    by the diagnostics path), launches the
    child through the user's configured login
    shell (mirroring `runScript` so a `-l`
    flag is inserted for `bash` / `zsh`),
    captures stdout + stderr + exit code +
    wall-clock duration, and terminates the
    child with `SIGTERM` (followed by a
    `SIGKILL` 2s later for the rare script
    that traps `SIGTERM`) if the timeout
    elapses. Logs the result via `os_log` on
    `Log.plugin` at `.info` level so the
    existing `persistLatestSystemReport(...)`
    flow picks it up.
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserViewModel.swift`
  - Adds `var runDiagnosticsRunner: (URL,
    TimeInterval) -> RunPluginDiagnosticsResult`
    with a default that delegates to
    `PluginManager.shared.runPluginDiagnostics(at:timeoutSeconds:)`.
    The default is captured in a
    `Task.detached` capture list, not at
    `init` time, so a test can swap the
    closure after `init` and the swap is
    observed by every subsequent call.
  - Adds the
    `MarketplaceBrowserViewModel.PendingDiagnostics`
    value type (snapshot + result pair,
    `Equatable`).
  - Adds `@Published private(set) var
    pendingDiagnostics: PendingDiagnostics?`
    (the snapshot the diagnostics sheet
    renders) and `@Published private(set) var
    isRunningDiagnostics: Bool` (the
    in-flight flag the row's button uses to
    disable itself and show a `ProgressView`).
  - Adds
    `func runDiagnostics(snapshot: InstalledPluginSnapshot)`
    that runs the injected runner in a
    detached `Task` (so the main actor is
    not blocked by the child's
    `waitUntilExit()`) and assigns the
    result back to `pendingDiagnostics` on
    `@MainActor`. The method does not touch
    the `MarketplaceBrowserState` machine —
    running diagnostics is a regular in-app
    action that does not need a banner
    (mirroring `viewSource(snapshot:)` /
    `openDataFolder(snapshot:)` /
    `toggleEnabled(for:)`).
  - Adds
    `func dismissPendingDiagnostics()` for
    the parent sheet's `.sheet(...)`
    completion handler to clear the binding
    on dismiss.
- `menubar01/UI/Marketplace Browser/MarketplaceBrowserSheet.swift`
  - Adds a small icon-only `Button` to the
    bottom row of `installedRow(for:)`,
    placed immediately after the "Open
    data folder" button. The button is
    `Image(systemName: "stethoscope")` at
    `.mini` / `.borderless` style, with a
    "Run diagnostics for <name>" tooltip
    and a `ProgressView` swap-in while a
    round-trip is in flight. The button is
    disabled while
    `viewModel.isRunningDiagnostics` is
    `true` so the user cannot double-click
    while a slow entry script is still
    running. Clicking the button calls
    `viewModel.runDiagnostics(snapshot:)`.
  - Adds a `.sheet(isPresented:)` modifier
    that presents the new
    `MarketplaceDiagnosticsSheet` when
    `viewModel.pendingDiagnostics` becomes
    non-`nil`. The dismiss path delegates
    to `viewModel.dismissPendingDiagnostics()`.
- `menubar01/UI/Marketplace Browser/MarketplaceDiagnosticsSheet.swift`
  - New file. Defines the modal sub-sheet
    that renders `pendingDiagnostics`. The
    sheet has three sections: a status
    banner (red for "could not run
    diagnostics", yellow for "timed out"),
    a summary row (exit code + duration
    with millisecond precision + a "Clean
    exit" / "Non-zero exit" hint), and two
    monospaced text panes (stdout and
    stderr) with `.textSelection(.enabled)`
    so the user can copy the output
    verbatim for a bug report. The sheet
    has a single Close button that
    delegates back to the parent sheet's
    `dismissPendingDiagnostics()`.
- `menubar01Tests/MarketplaceBrowserRunDiagnosticsTests.swift`
  - New file with 3 Swift Testing tests:
    1. `testRunDiagnostics_runnerReceivesSnapshotURLAndDefaultTimeout`
       — stages a marketplace install,
       builds a real
       `InstalledPluginSnapshot` via
       `refreshInstalledPlugins()`, injects
       a recording `runDiagnosticsRunner`,
       calls `runDiagnostics(snapshot:)`,
       and asserts the runner is called
       exactly once with the snapshot's
       folder URL and the production-default
       10s timeout. Also asserts
       `isRunningDiagnostics` is reset to
       `false` and the state machine is
       untouched.
    2. `testRunDiagnostics_populatesPendingDiagnosticsWithResult`
       — drives a round-trip with a canned
       non-zero exit code + non-empty
       stderr result and asserts the
       `PendingDiagnostics` value lands in
       the VM with both fields preserved
       (the snapshot for the sheet's
       header, the result for the four
       rendered panes).
    3. `testRunDiagnostics_realRunnerRunsEntryScriptAndReturnsResult`
       — end-to-end test of the
       production
       `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
       path: stages a real marketplace
       install with an `exit 7` entry
       script, calls the production runner
       (no injected closure), and asserts
       the captured `exitCode` /
       `stdout` / `duration` shape matches
       what the diagnostics sheet would
       render. The duration is asserted
       non-negative and below the 10s
       timeout — the load-bearing shape,
       not a host-dependent number.
  - The test file uses a per-test temp
    directory + per-test
    `UserDefaults(suiteName:)` (mirroring
    the `MarketplaceBrowserViewSourceTests`
    / `MarketplaceBrowserOpenDataFolderTests`
    pattern) and a small
    `@MainActor`-bound
    `DiagnosticsRunnerRecorder` helper
    class so the closures can mutate a
    counter without tripping Swift 6
    strict-concurrency warnings around
    captured `var`s. The detached `Task`
    result is waited on with a bounded
    `RunLoop` poll so a hung task cannot
    stall the test past 2 seconds.

## Impact

- **User-visible behavior:** the Installed tab
  in the marketplace browser now shows a small
  "stethoscope" icon button on every
  installed-plugin row, placed next to the
  "folder" "Open data folder" button. Clicking
  it launches the entry script under the same
  shell + working directory the regular
  `FolderPlugin.invoke()` would, and surfaces
  the result (stdout, stderr, exit code,
  duration, "timed out" hint) in a new modal
  sheet. Disabled while a round-trip is in
  flight (the icon swaps to a `ProgressView`).
- **New API surface:**
  - `RunPluginDiagnosticsResult` (public value
    type).
  - `PluginManager.runPluginDiagnosticsDefaultTimeout`
    (public constant, 10 seconds).
  - `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
    (public method).
  - `MarketplaceBrowserViewModel.runDiagnosticsRunner`
    (internal `var` dependency, mirroring
    `viewSourceOpener` /
    `openDataFolderRevealer`).
  - `MarketplaceBrowserViewModel.PendingDiagnostics`
    (internal value type).
  - `MarketplaceBrowserViewModel.pendingDiagnostics`
    (internal `@Published private(set)`).
  - `MarketplaceBrowserViewModel.isRunningDiagnostics`
    (internal `@Published private(set)`).
  - `MarketplaceBrowserViewModel.runDiagnostics(snapshot:)`
    (internal).
  - `MarketplaceBrowserViewModel.dismissPendingDiagnostics()`
    (internal).
  - `MarketplaceDiagnosticsSheet` (internal
    `View`).
- **Process side effect:** clicking "Run
  diagnostics" launches a child process that
  runs the marketplace install's entry script.
  The process is killed with `SIGTERM` (followed
  by `SIGKILL` 2s later) if it does not exit
  within 10 seconds. The child inherits the
  parent process's environment plus the
  manifest's `environment` map.
- **No state-machine changes** — running
  diagnostics does not transition
  `MarketplaceBrowserState` and does not show a
  banner. Errors are surfaced inside the
  diagnostics sheet (red status banner +
  `errorDescription` text) instead.

## Testing

`xcodebuild test -only-testing:menubar01Tests/MarketplaceBrowserRunDiagnosticsTests`
— all 3 new tests pass cleanly. The full suite
(`xcodebuild test -only-testing:menubar01Tests`)
runs the new 3 tests in addition to the existing
suite; the 3 follow-up tests are isolated
per-test via `UserDefaults(suiteName:)` and the
injected runner closure, so they do not touch
any pre-existing flakiness surface.

## Related

- Builds on the M5 marketplace browser surface
  ([`2026-06-13-m5-marketplace-browser.md`](2026-06-13-m5-marketplace-browser.md))
  and the Installed tab follow-ups
  ([`2026-06-13-marketplace-uninstall-and-update.md`](2026-06-13-marketplace-uninstall-and-update.md),
  [`2026-06-13-marketplace-installed-toggle.md`](2026-06-13-marketplace-installed-toggle.md),
  [`2026-06-13-marketplace-update-detection.md`](2026-06-13-marketplace-update-detection.md),
  [`2026-06-13-marketplace-view-source.md`](2026-06-13-marketplace-view-source.md),
  [`2026-06-13-marketplace-open-data-folder.md`](2026-06-13-marketplace-open-data-folder.md)).
- The diagnostics runner mirrors
  `FolderPlugin.invoke()`'s subprocess shape
  (the user's login shell, the manifest's
  `environment`, the package directory as the
  working directory, `waitUntilExit()` on the
  child) so a "Run diagnostics" run and a
  regular refresh see the same environment.
  See
  `menubar01/Plugin/FolderPlugin.swift:271`
  for the regular invoke path.
- The 10s timeout is exposed as a public
  constant so the diagnostics sheet can quote
  it verbatim in its "Timed out" hint.

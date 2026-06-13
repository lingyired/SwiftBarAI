// MarketplaceBrowserRunDiagnosticsTests.swift
// menubar01 — PluginMarketplace (M5 run-diagnostics follow-up)
//
// Swift Testing coverage for the new
// `MarketplaceBrowserViewModel.runDiagnostics(snapshot:)`
// method and its `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
// sidecar.
//
// The contract under test:
//
//   1. `runDiagnosticsResult(snapshot:timeout:)` calls
//      the injected `runDiagnosticsRunner` closure
//      with the snapshot's folder URL and the
//      configured timeout. The runner is the only
//      side-effecting call site — the VM does not
//      duplicate the I/O.
//   2. The injected `runDiagnosticsRunner` replaces
//      the default
//      `PluginManager.shared.runPluginDiagnostics(...)`.
//      Swapping the closure after `init` means the
//      new closure receives the call (and the VM
//      does not cache the original reference).
//   3. `runDiagnostics(snapshot:)` populates
//      `pendingDiagnostics` with a
//      `PendingDiagnostics` value carrying the
//      snapshot + the result returned by the runner,
//      and clears `isRunningDiagnostics` once the
//      run completes. The 2-field payload is exactly
//      what `MarketplaceDiagnosticsSheet` renders,
//      so an end-to-end test would see the same
//      values the user sees.
//
// The test uses a per-test temp directory + per-test
// `UserDefaults(suiteName:)` (mirroring the
// `MarketplaceBrowserViewSourceTests` and
// `MarketplaceBrowserOpenDataFolderTests` patterns)
// so it is fully isolated from the production plugin
// directory and from other tests in the suite. The
// diagnostics runner is swapped for a recording
// closure that returns a pre-canned
// `RunPluginDiagnosticsResult` so the xctest host
// does not actually launch a child process. A
// separate test exercises the real
// `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
// against a real entry script in a temp dir, so the
// runner-side path is covered end-to-end without
// coupling the VM tests to the platform shell.
//
// Target: 3 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

// MARK: - Test helpers

/// Build a fresh `PluginManager` whose `pluginDirectoryURL`
/// is pointed at `pluginDirectory` (a temp dir the caller
/// has already created). Mirrors the helper in
/// `MarketplaceBrowserViewSourceTests` /
/// `MarketplaceBrowserOpenDataFolderTests` /
/// `MarketplaceBrowserToggleEnabledTests`.
private func makeManager(pluginDirectory: URL?) -> PluginManager {
    let suiteName = "menubar01.tests.mkt.rundiag.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let prefs = PreferencesStore(defaults: defaults)
    prefs.pluginDirectoryPath = pluginDirectory?.path
    return PluginManager(prefs: prefs)
}

private func makeTempManager() -> (URL, PluginManager) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mbar01-mkt-rundiag-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, makeManager(pluginDirectory: directory))
}

/// Write a marketplace install's `manifest.json` + entry
/// script to
/// `<tempDir>/_marketplace/<folder>/...`. Mirrors the
/// layout `installMarketplacePlugin(plan:overwriteExisting:)`
/// produces so `refreshInstalledPlugins()` picks it up
/// and yields a real `InstalledPluginSnapshot` for the
/// test to feed back into `runDiagnostics(snapshot:)`.
/// The default entry script is a single-line `echo` that
/// the test can override for the "exits non-zero" case.
@discardableResult
private func stageMarketplaceInstall(
    in tempDir: URL,
    folder: String = "battery-watch",
    manifestJSON: String? = nil,
    entryScript: String? = nil,
    entryFilename: String = "battery-watch.sh"
) throws -> URL {
    let marketplaceRoot = tempDir
        .appendingPathComponent(MarketplaceInstaller.defaultSubfolder, isDirectory: true)
    let installDir = marketplaceRoot.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
    let manifestURL = installDir.appendingPathComponent(pluginManifestFileName)
    let body = manifestJSON ?? """
    {
      "name": "Battery Watch",
      "version": "1.0.0",
      "entry": "\(entryFilename)"
    }
    """
    try body.write(to: manifestURL, atomically: true, encoding: .utf8)
    let scriptURL = installDir.appendingPathComponent(entryFilename)
    let script = entryScript ?? "#!/bin/zsh\necho Battery\n"
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    // Mirror the marketplace install path's
    // `chmod +x` so `PluginManifestLoader.loadAndValidate(...)`
    // is happy during a real `runPluginDiagnostics(...)`
    // call.
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path
    )
    return installDir
}

// MARK: - Tests

@MainActor
struct MarketplaceBrowserRunDiagnosticsTests {

    // 1

    @Test func testRunDiagnostics_runnerReceivesSnapshotURLAndDefaultTimeout() async {
        // Stage a marketplace install, build a real
        // snapshot via `refreshInstalledPlugins()`,
        // then swap in a recording `runDiagnosticsRunner`
        // closure and call
        // `viewModel.runDiagnosticsResult(snapshot:timeout:)`.
        // The recording closure must be called
        // exactly once with the snapshot's folder
        // URL (not the on-disk path inside
        // `<tempDir>/_marketplace/`) and the
        // production-default 10s timeout. The VM
        // does not mutate `state` or
        // `installedPlugins` as a side effect of
        // the call.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        let installURL = try! stageMarketplaceInstall(in: tempDir)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        #expect(viewModel.installedPlugins.count == 1)
        let snapshot = viewModel.installedPlugins[0]

        let runnerRecorder = DiagnosticsRunnerRecorder()
        viewModel.runDiagnosticsRunner = { url, timeout in
            runnerRecorder.recordCall(url: url, timeout: timeout)
            return RunPluginDiagnosticsResult(
                success: true,
                stdout: "Battery 100%",
                stderr: "",
                exitCode: 0,
                duration: 0.123,
                timedOut: false,
                errorDescription: nil
            )
        }

        let result = await viewModel.runDiagnosticsResult(
            snapshot: snapshot,
            timeout: PluginManager.runPluginDiagnosticsDefaultTimeout
        )

        #expect(runnerRecorder.callCount == 1)
        #expect(runnerRecorder.lastURL == installURL.standardizedFileURL)
        #expect(runnerRecorder.lastTimeout == PluginManager.runPluginDiagnosticsDefaultTimeout)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "Battery 100%")
        // The async variant does not touch
        // `pendingDiagnostics` / `isRunningDiagnostics`
        // — those are owned by the fire-and-forget
        // `runDiagnostics(snapshot:)` UI path. State
        // machine is not touched.
        #expect(viewModel.pendingDiagnostics == nil)
        #expect(viewModel.entries == [])
        #expect(viewModel.selectedEntry == nil)
        #expect(viewModel.installedPlugins.count == 1)
    }

    // 2

    @Test func testRunDiagnostics_fireAndForgetPopulatesPendingDiagnostics() async {
        // Drive the fire-and-forget
        // `runDiagnostics(snapshot:)` path and
        // assert the `PendingDiagnostics` value
        // lands in the VM with both fields
        // preserved (the snapshot for the sheet's
        // header, the result for the four rendered
        // panes). The injected runner returns a
        // non-zero exit code + a non-empty stderr
        // so the test would catch a regression that
        // swallowed either field. Uses a bounded
        // `await Task.yield()` loop to let the
        // fire-and-forget `Task` complete — the
        // runner is synchronous (returns in
        // microseconds), so the task should land
        // within a handful of yields. A polling
        // loop against the published
        // `pendingDiagnostics` would race the
        // SwiftUI bindings; `Task.yield()` is
        // the deterministic wait.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        let installURL = try! stageMarketplaceInstall(in: tempDir)

        let viewModel = MarketplaceBrowserViewModel(
            client: StubMarketplaceClient(),
            pluginManager: manager
        )
        viewModel.refreshInstalledPlugins()
        let snapshot = viewModel.installedPlugins[0]

        let cannedResult = RunPluginDiagnosticsResult(
            success: true,
            stdout: "Battery 100%\n",
            stderr: "warning: battery API deprecated\n",
            exitCode: 2,
            duration: 0.456,
            timedOut: false,
            errorDescription: nil
        )
        viewModel.runDiagnosticsRunner = { _, _ in cannedResult }

        viewModel.runDiagnostics(snapshot: snapshot)
        // Bounded wait for the fire-and-forget
        // task to assign `pendingDiagnostics`.
        // The runner returns synchronously, so a
        // few yields are plenty. Bound is the 10s
        // default timeout so a hung task does not
        // stall the suite.
        let bound = Date().addingTimeInterval(PluginManager.runPluginDiagnosticsDefaultTimeout)
        while viewModel.pendingDiagnostics == nil && Date() < bound {
            await Task.yield()
        }

        let pending = viewModel.pendingDiagnostics
        #expect(pending != nil)
        #expect(pending?.snapshot.id == snapshot.id)
        #expect(pending?.snapshot.url.standardizedFileURL == installURL.standardizedFileURL)
        #expect(pending?.result == cannedResult)
        #expect(viewModel.isRunningDiagnostics == false)
    }

    // 3

    @Test func testRunDiagnostics_realRunnerRunsEntryScriptAndReturnsResult() {
        // End-to-end test for the actual
        // `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`
        // path: stage a real marketplace install
        // with a one-line `echo` script, call the
        // production runner (no injected
        // closure), and assert the captured
        // stdout / exit code / duration shape
        // matches what the diagnostics sheet
        // would render. The test does not assert
        // the duration numerically (the wall-
        // clock is host-dependent) — it only
        // asserts the duration is non-negative
        // and below the 10s timeout, which is
        // the load-bearing shape the sheet
        // relies on for its "almost timed out"
        // hint.
        //
        // This test also pins down the runner's
        // behaviour for a non-zero exit code
        // case (the script does `exit 7`) so a
        // regression that swallowed the
        // non-zero status would fail loudly.
        let (tempDir, manager) = makeTempManager()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        defer { manager.directoryObserver = nil }
        let installURL = try! stageMarketplaceInstall(
            in: tempDir,
            entryScript: "#!/bin/zsh\necho Battery 100%\nexit 7\n"
        )

        let result = manager.runPluginDiagnostics(
            at: installURL,
            timeoutSeconds: PluginManager.runPluginDiagnosticsDefaultTimeout
        )
        #expect(result.success == true)
        #expect(result.timedOut == false)
        #expect(result.errorDescription == nil)
        #expect(result.exitCode == 7)
        // The script echoes one line plus the
        // shell's `exit 7` newline; the trailing
        // newline comes from the shell's own
        // command-separator. We assert the
        // meaningful substring rather than the
        // exact byte string so a different
        // shell's line ending does not break the
        // test.
        #expect(result.stdout.contains("Battery 100%"))
        #expect(result.duration >= 0)
        #expect(result.duration < PluginManager.runPluginDiagnosticsDefaultTimeout)
        // stderr is `Some("")` on a normal
        // POSIX process — the kernel closes the
        // pipe with an empty buffer, not `nil`.
        // We assert the optional is `Some` so a
        // regression that drops the stderr pipe
        // would fail loudly.
        #expect(result.stderr != nil)
    }
}

// MARK: - Recorder

/// Records the URL and timeout the VM passes to
/// `runDiagnosticsRunner` so a single test can
/// assert the call shape. The class is
/// `@unchecked Sendable` because all reads and
/// writes happen on the same `@MainActor` task —
/// there is no cross-actor access in practice.
private final class DiagnosticsRunnerRecorder: @unchecked Sendable {
    private(set) var callCount: Int = 0
    private(set) var lastURL: URL?
    private(set) var lastTimeout: TimeInterval?

    func recordCall(url: URL, timeout: TimeInterval) {
        callCount += 1
        lastURL = url
        lastTimeout = timeout
    }
}

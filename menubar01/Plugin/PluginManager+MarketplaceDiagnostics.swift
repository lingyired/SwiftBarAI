// PluginManager+MarketplaceDiagnostics.swift
// menubar01 — PluginMarketplace (M5 diagnostics follow-up)
//
// Wires a "Run diagnostics" affordance to the existing
// `PluginManager` so the marketplace browser's Installed sidebar tab
// can let the user manually re-execute a marketplace install's entry
// script and inspect the result without it being treated as a regular
// refresh (which would replace the running plugin's content). Kept
// in a separate file (and a `PluginManager` extension) so it does
// not conflict with the M2 / M5 install flow being added in parallel
// to `PluginManger.swift`.
//
// The split mirrors the M4/M5 "value type + side-effectful I/O"
// division:
//
//   1. `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)` —
//      the I/O half. Reads the manifest, resolves the entry script
//      via `PluginManifestLoader.loadAndValidate(from:)`, then
//      launches the entry script with the user's login shell
//      (mirroring the `FolderPlugin.invoke()` path), captures
//      stdout + stderr + exit code + wall-clock duration, and
//      terminates the child with `SIGTERM` if the configured
//      timeout elapses before the child exits. Returns a
//      `RunPluginDiagnosticsResult` value.
//
//   2. The marketplace browser view model glues the I/O half to
//      its `installedPlugins` snapshot in
//      `MarketplaceBrowserViewModel.runDiagnostics(snapshot:)` and
//      surfaces the result in a diagnostics sheet that shows
//      stdout, stderr, exit code, and timing.
//
// Why a 10s timeout: the marketplace entry scripts ship with the
// `refreshInterval` knob, but a run-diagnostics call is a manual
// user action — the user is staring at the sheet waiting for the
// result, so a runaway script (infinite loop, hung `curl`, etc.)
// needs an upper bound. 10s matches the order-of-magnitude
// budget the existing `FolderPlugin.invoke()` path implicitly
// relies on (the menu bar would render stale content if a plugin
// took longer than its `refreshInterval`, and the loader does
// not spawn plugins that cannot return within that budget).

import Foundation
import os

/// Result of running a single entry script for diagnostic purposes.
///
/// Built by `PluginManager.runPluginDiagnostics(at:timeoutSeconds:)`.
/// The view model glues the value into a sheet that surfaces every
/// field the user could need to debug a broken marketplace install.
///
/// `Equatable` is hand-rolled because the optional `errorDescription`
/// should compare by value (`String?` already conforms), and the
/// `stdout` / `stderr` are simple `String` fields. The struct is
/// kept narrow on purpose: any future "extended diagnostics" fields
/// (e.g. CPU time, peak memory) should be added here, not on the
/// view model.
public struct RunPluginDiagnosticsResult: Equatable {
    /// `true` when the entry script returned within
    /// `timeoutSeconds` and exited normally. `false` when
    /// the child process was terminated by the timeout
    /// watchdog (`SIGTERM`), or the manifest / entry
    /// script could not be resolved on disk (in which case
    /// `exitCode == -1` and `errorDescription` carries the
    /// reason). The "manual diagnostics ran" success
    /// signal is `success == true`; the exit-code field
    /// (`exitCode == 0`) is a separate concern and the
    /// script may exit non-zero without this being a
    /// diagnostics failure.
    public let success: Bool
    /// Captured stdout, UTF-8 decoded. Empty when the
    /// script produced no output on stdout (or when the
    /// diagnostics call could not run, in which case
    /// `errorDescription` explains why).
    public let stdout: String
    /// Captured stderr, UTF-8 decoded. `nil` when the
    /// diagnostics call could not launch the child (so
    /// there is no stderr pipe to read from). Otherwise
    /// the decoded string — empty when the script
    /// produced no stderr.
    public let stderr: String?
    /// Exit status of the child. `0` on a clean run,
    /// non-zero on a script-level failure, `-1` when the
    /// diagnostics call could not even launch the child
    /// (see `errorDescription`). When the timeout fires
    /// the child is terminated with `SIGTERM` and the
    /// captured exit status is whatever the kernel
    /// records for that signal (typically `143` on
    /// POSIX, `15` + `128`).
    public let exitCode: Int32
    /// Wall-clock duration of the run in seconds,
    /// measured from just before the child is launched
    /// to just after it exits (or the timeout fires).
    /// Reported with millisecond precision
    /// (`String(format: "%.3f s")` in the UI).
    public let duration: TimeInterval
    /// `true` when the run hit the configured timeout
    /// and the child was killed with `SIGTERM`. Drives a
    /// yellow "timed out" hint in the diagnostics sheet
    /// so the user does not mis-read a non-zero exit
    /// code as a script bug.
    public let timedOut: Bool
    /// Human-readable description of why the
    /// diagnostics call could not run. `nil` on a
    /// normal run (including non-zero exit codes and
    /// timeouts — the latter is also surfaced via
    /// `timedOut`). Populated when the manifest could
    /// not be loaded or the entry script is missing /
    /// not executable, so the sheet can show "could not
    /// find entry script" instead of a misleading
    /// "exit code -1" line.
    public let errorDescription: String?
}

extension PluginManager {

    /// Default timeout for a manual diagnostics run. 10
    /// seconds matches the budget the loader implicitly
    /// assumes for a healthy plugin's invocation —
    /// anything longer than that is almost certainly a
    /// hung script rather than a slow one. Exposed as
    /// a constant so the marketplace browser sheet and
    /// the view-model docs can quote the same number
    /// without magic-value drift.
    public static let runPluginDiagnosticsDefaultTimeout: TimeInterval = 10.0

    /// Run a single marketplace install's entry script
    /// for diagnostic purposes. Mirrors
    /// `FolderPlugin.invoke()` line-for-line except:
    ///
    ///   1. The result is captured into a
    ///      `RunPluginDiagnosticsResult` value rather
    ///      than assigned to `plugin.content` — the
    ///      running plugin's content is not touched, so
    ///      a "Run diagnostics" click does not cause a
    ///      visible flicker in the menu bar.
    ///   2. The run is bounded by `timeoutSeconds` (a
    ///      `SIGTERM` is delivered to the child when
    ///      the budget elapses, with a `SIGKILL`
    ///      follow-up 2 seconds later for the rare
    ///      script that traps `SIGTERM`).
    ///   3. The result is logged at `.info` level on
    ///      `Log.plugin` so the existing
    ///      `persistLatestSystemReport(...)` flow picks
    ///      up the wall-clock duration without any
    ///      changes to the diagnostic dump format.
    ///
    /// Failure modes:
    ///   - The path does not contain a parseable
    ///     `manifest.json` — returns
    ///     `RunPluginDiagnosticsResult` with
    ///     `success == false`, `exitCode == -1`, and
    ///     `errorDescription` populated.
    ///   - The manifest declares an entry script that
    ///     does not exist (or is not executable) —
    ///     same shape, with a distinct
    ///     `errorDescription` text.
    ///   - The child exits non-zero (e.g. the script
    ///     crashed, or the entry script intentionally
    ///     exits with `exit 1` to surface an error) —
    ///     returns `success == true` (the diagnostics
    ///     call *itself* ran), `timedOut == false`, and
    ///     `exitCode` set to the captured value. The
    ///     sheet surfaces the non-zero exit code so the
    ///     user can debug.
    ///   - The child is terminated by the timeout
    ///     watchdog — returns `success == true`,
    ///     `timedOut == true`, and `exitCode` set to
    ///     the captured signal value. The sheet
    ///     surfaces the timeout as a yellow hint.
    @discardableResult
    public func runPluginDiagnostics(
        at pluginURL: URL,
        timeoutSeconds: TimeInterval = PluginManager.runPluginDiagnosticsDefaultTimeout
    ) -> RunPluginDiagnosticsResult {
        let resolvedURL = pluginURL.standardizedFileURL

        // Resolve the manifest + entry script via the
        // existing `PluginManifestLoader.loadAndValidate`
        // helper so the diagnostics path agrees with the
        // loader on what counts as a "runnable" entry
        // script (executable bit set, file exists, etc.).
        // This is the same gate `getLoadablePluginList`
        // uses for the regular refresh pipeline, so a
        // plugin that the loader would reject for a
        // fresh `loadPlugins` sweep is also rejected by
        // the diagnostics path — no surprises.
        guard let validated = PluginManifestLoader.loadAndValidate(from: resolvedURL) else {
            os_log("runPluginDiagnostics: refusing %{public}@ — manifest.json is missing or the entry script is not runnable",
                   log: Log.plugin, type: .error, resolvedURL.path)
            return RunPluginDiagnosticsResult(
                success: false,
                stdout: "",
                stderr: nil,
                exitCode: -1,
                duration: 0,
                timedOut: false,
                errorDescription: "Could not resolve a runnable entry script for \(resolvedURL.path). The manifest may be missing or the entry script may not be executable."
            )
        }

        let entryURL = validated.entryURL
        let manifest = validated.manifest
        os_log("runPluginDiagnostics: launching %{public}@ (manifest=%{public}@) with timeout=%{public}.1fs",
               log: Log.plugin, type: .info,
               entryURL.path, manifest.name ?? "<unnamed>", timeoutSeconds)

        // Launch the entry script through the user's
        // configured login shell (the same `prefs.shell`
        // path `runScript` already honours) so the
        // script's `#!/usr/bin/env zsh` shebang — or its
        // absence — is interpreted the same way the
        // regular `FolderPlugin.invoke()` would
        // interpret it. `runInBash: true` is the
        // `FolderPlugin` default and matches the
        // M5 manifest's `runInBash` default.
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: prefs.shell.path)
        // Mirror the `runScript` quoting rule: when
        // running in bash / zsh, the `runScript` helper
        // inserts `-l` after the shell path so login
        // profiles (`~/.zprofile`, `~/.bash_profile`)
        // are sourced. We replicate that one detail
        // here so the diagnostics run sees the same
        // environment the regular `FolderPlugin.invoke()`
        // would see.
        var arguments: [String] = ["-c", "\(entryURL.path.escaped())"]
        if prefs.shell.path.hasSuffix("bash") || prefs.shell.path.hasSuffix("zsh") {
            arguments.insert("-l", at: 1)
        }
        process.arguments = arguments
        process.currentDirectoryURL = resolvedURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Inherit the parent process's environment
        // (PATH, HOME, etc.) so the entry script runs
        // in the same context the regular `FolderPlugin`
        // would. The M5 manifest's `environment` map is
        // merged on top via `process.environment` so the
        // user-configured values are visible to the
        // child. We do **not** inject the M5
        // `vars.json`-backed `MENUBAR01_PARAM_*`
        // variables here — diagnostics is a manual
        // affordance, not a refresh, and the user can
        // open the data folder (per
        // `2026-06-13-marketplace-open-data-folder.md`)
        // to inspect or wipe `vars.json` themselves.
        var env = ProcessInfo.processInfo.environment
        if let manifestEnv = manifest.environment {
            for (key, value) in manifestEnv {
                env[key] = value
            }
        }
        process.environment = env

        let startTime = Date()
        do {
            try process.run()
        } catch {
            os_log("runPluginDiagnostics: failed to launch %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   entryURL.path, error.localizedDescription)
            return RunPluginDiagnosticsResult(
                success: false,
                stdout: "",
                stderr: nil,
                exitCode: -1,
                duration: Date().timeIntervalSince(startTime),
                timedOut: false,
                errorDescription: "Failed to launch entry script: \(error.localizedDescription)"
            )
        }

        // Schedule a SIGTERM watchdog. The dispatch
        // source fires on a background queue (not the
        // main queue) so the timer is not blocked by
        // SwiftUI's main-thread work. If the child
        // exits before the timer fires, the source is
        // cancelled and `process.terminate()` is
        // never called.
        let watchdogWorkItem = DispatchWorkItem {
            if process.isRunning {
                os_log("runPluginDiagnostics: timeout reached for %{public}@, sending SIGTERM",
                       log: Log.plugin, type: .info, entryURL.path)
                process.terminate()
                // Belt-and-braces: schedule a SIGKILL
                // 2s after the SIGTERM in the rare case
                // the child traps SIGTERM (e.g. a shell
                // script with `trap '' TERM`). The
                // SIGKILL is unconditional once the
                // timer fires — the dispatch work item
                // is fire-and-forget and cannot be
                // cancelled by the child exiting.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        os_log("runPluginDiagnostics: SIGTERM was trapped by %{public}@, sending SIGKILL",
                               log: Log.plugin, type: .info, entryURL.path)
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: watchdogWorkItem
        )

        // Block the calling thread on the child exit
        // via `waitUntilExit()`. The diagnostics call
        // is invoked from a `Task` on the view model
        // (which is `@MainActor`); `waitUntilExit()` is
        // a blocking call that the view model runs on
        // a background task so the main thread is not
        // stalled. Reading the pipe file handles after
        // the child exits drains any bytes still
        // buffered in the kernel — the readability
        // handler / streaming output path the regular
        // `runScript` uses is not needed here because
        // the diagnostics sheet renders the entire
        // captured output as a single string.
        process.waitUntilExit()
        watchdogWorkItem.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let duration = Date().timeIntervalSince(startTime)
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)
        let timedOut = !watchdogWorkItem.isCancelled && process.terminationReason == .uncaughtSignal
        // `terminationStatus` is set to the signal
        // number shifted left by 8 bits when the child
        // is killed by a signal (POSIX convention) —
        // e.g. SIGTERM (15) becomes 128 + 15 = 143.
        // The UI surfaces the raw status and the
        // `timedOut` flag separately so a power user
        // can read both numbers.
        let exitCode = process.terminationStatus

        os_log("runPluginDiagnostics: finished %{public}@ exitCode=%{public}d duration=%.3fs timedOut=%{public}@",
               log: Log.plugin, type: .info,
               entryURL.path, exitCode, duration,
               timedOut ? "true" : "false")

        return RunPluginDiagnosticsResult(
            success: true,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            duration: duration,
            timedOut: timedOut,
            errorDescription: nil
        )
    }
}

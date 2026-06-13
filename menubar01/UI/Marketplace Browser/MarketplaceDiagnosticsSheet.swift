// MarketplaceDiagnosticsSheet.swift
// menubar01 — PluginMarketplace (M5 diagnostics follow-up)
//
// Modal sub-sheet that renders the result of
// `MarketplaceBrowserViewModel.runDiagnostics(snapshot:)`. Presented
// by `MarketplaceBrowserSheet` from a `.sheet(...)` modal so it
// stacks cleanly on top of the browser sheet and dismisses
// independently — mirroring the pattern the
// `MarketplaceInstallPromptSheet` (M5 install-prompt follow-up)
// uses for its sub-sheet.
//
// The sheet shows four pieces of information the user needs to
// debug a broken marketplace install:
//   1. **stdout** — captured UTF-8 stdout of the entry script.
//   2. **stderr** — captured UTF-8 stderr of the entry script
//      (rendered in a separate pane so a noisy stderr does not
//      drown out the actual menu output).
//   3. **exit code** — the child's `terminationStatus` (with a
//      hint explaining `0` vs. non-zero).
//   4. **duration** — the wall-clock run time, with millisecond
//      precision so a 9.95s run is recognisably "almost timed
//      out" rather than a flat "10s".
//
// Plus a banner for the two states the user-visible behaviour
// cares about most: the run timed out (a yellow hint so the user
// does not mis-read a non-zero exit code as a script bug), and
// the diagnostics call could not even run (e.g. the manifest is
// missing) — the banner renders the `errorDescription` so the
// user sees the actual reason instead of "exit code -1".
//
// The sheet is intentionally read-only. There is no "Re-run"
// button inside the sheet — clicking "Run diagnostics" again on
// the parent sheet is the canonical re-run path, and a
// "Re-run" button inside the sheet would race the dismiss
// animation in awkward ways (the parent sheet's binding would
// have to flip false→true inside the same `.sheet` modifier).
// Mirrors the design of the M2 / M5 install-prompt sheet, which
// also lives one level above the action button it services.

import SwiftUI

/// Sub-sheet that renders the result of a single
/// `runDiagnostics(snapshot:)` round-trip. The
/// sheet is presented by
/// `MarketplaceBrowserSheet` from a `.sheet(...)`
/// modal and dismissed by the user's Close click.
@MainActor
struct MarketplaceDiagnosticsSheet: View {

    /// The snapshot + result the sheet renders.
    /// Built by the parent sheet when the
    /// `runDiagnostics(snapshot:)` round-trip
    /// completes; passed in as a `let` so the sheet
    /// cannot accidentally mutate it.
    let pending: MarketplaceBrowserViewModel.PendingDiagnostics

    /// Dismiss callback invoked by the sheet's
    /// Close button. The parent sheet's
    /// `.sheet(...)` binding delegates to
    /// `viewModel.dismissPendingDiagnostics()`.
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics for \(pending.snapshot.name)")
                .font(.headline)
            Text(pending.snapshot.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            statusBanner
            summaryRow
            stdoutSection
            stderrSection
            HStack {
                Spacer()
                Button("Close", role: .cancel) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
    }

    // MARK: - Sections

    /// Banner shown when the run was unable to
    /// complete (e.g. the manifest is missing or
    /// the entry script is not executable). Renders
    /// `pending.result.errorDescription` verbatim
    /// so the user sees the actual reason instead
    /// of a misleading "exit code -1" line. Not
    /// rendered when the run completed (success or
    /// not) — the exit code + stderr pane carry
    /// enough information for the user to
    /// diagnose a script-level failure.
    @ViewBuilder
    private var statusBanner: some View {
        if let errorDescription = pending.result.errorDescription {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Could not run diagnostics")
                        .font(.subheadline.weight(.semibold))
                    Text(errorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if pending.result.timedOut {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timed out")
                        .font(.subheadline.weight(.semibold))
                    Text("The entry script did not exit within \(Int(PluginManager.runPluginDiagnosticsDefaultTimeout))s and was sent SIGTERM. The non-zero exit code is the signal, not a script bug.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Two-column summary row: exit code on the
    /// left, duration on the right. The exit code
    /// is rendered with a small hint
    /// ("0 = clean exit, non-zero = script-level
    /// failure") so a power user reading the
    /// number does not have to scroll up to the
    /// docs to recall the convention.
    private var summaryRow: some View {
        HStack(spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exit code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(pending.result.exitCode)")
                        .font(.system(.body, design: .monospaced))
                }
            } icon: {
                Image(systemName: "power")
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.3f s", pending.result.duration))
                        .font(.system(.body, design: .monospaced))
                }
            } icon: {
                Image(systemName: "stopwatch")
            }
            Spacer(minLength: 0)
            if pending.result.exitCode == 0 && !pending.result.timedOut {
                Label("Clean exit", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if !pending.result.timedOut {
                Label("Non-zero exit", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Captured stdout pane. Renders an
    /// empty-state hint when stdout is empty
    /// (the script may have written only to
    /// stderr — that is fine, but the empty
    /// pane is jarring without a hint). The
    /// `.textSelection(.enabled)` modifier lets
    /// the user copy the output verbatim, which
    /// is the canonical "share a log with a
    /// bug report" path.
    @ViewBuilder
    private var stdoutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("stdout")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if pending.result.stdout.isEmpty {
                Text("(empty)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(pending.result.stdout)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Captured stderr pane. Mirrors `stdoutSection`
    /// line-for-line except the empty-state hint is
    /// different ("(empty)" → "Script produced no
    /// stderr."). When `pending.result.stderr` is
    /// `nil` (the diagnostics call could not even
    /// launch the child) we render a third empty-
    /// state hint that does not name the field by
    /// value — the `errorDescription` banner already
    /// carries the reason, and we want to avoid
    /// surfacing the "no stderr" message in a way
    /// that the user could misread as a normal
    /// success.
    @ViewBuilder
    private var stderrSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("stderr")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch pending.result.stderr {
            case .none:
                Text("(not captured — diagnostics call did not launch a child process)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .some(let stderr) where stderr.isEmpty:
                Text("Script produced no stderr.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .some(let stderr):
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(stderr)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

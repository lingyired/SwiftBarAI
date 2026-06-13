// GeneratorHistoryExporter.swift
// menubar01 — AI Plugin Generator (M5 history follow-up)
//
// Helper that bundles a single `AIGeneratorHistoryEntry`'s on-disk
// audit log (`request.txt`, `response.json`, and the optional
// `menu.json`) into a `.zip` for the user to share with support.
//
// Lives in its own file (rather than in the SwiftUI sheet) so
// the view stays a pure renderer and the export logic is
// unit-testable from the test bundle without booting an
// `NSHostingController` / `NSSavePanel`. The view's "Export…"
// button calls `GeneratorHistoryExporter.exportEntry(_:store:to:)`,
// which shells out to `/usr/bin/zip` (macOS 12+ ships with it).

import AppKit
import Foundation
import os

/// Result of an `GeneratorHistoryExporter.exportEntry(...)` call.
///
/// Modelled as an `enum` so the SwiftUI sheet can route the
/// result to a single "Exported" / "Export failed" alert without
/// duplicating the error-string plumbing.
enum GeneratorHistoryExportResult: Equatable {
    /// The zip was written to `destination`.
    case success(destination: URL)
    /// The user cancelled the save panel.
    case cancelled
    /// The selected entry has no on-disk directory. The reason
    /// string is the resolved path the caller would have zipped.
    case missingDirectory(reason: String)
    /// `/usr/bin/zip` exited with a non-zero status. The reason
    /// includes the captured stderr.
    case zipFailed(reason: String)
    /// `Process.run()` itself threw (e.g. zip binary not found).
    case launchFailed(reason: String)
}

enum GeneratorHistoryExporter {
    /// Name of the zip-root manifest file written alongside the
    /// entry's audit log. Support tooling reads this to learn
    /// which model + endpoint produced the bundle without
    /// having to crack open `<promptId>/response.json`.
    static let manifestFilename = "MANIFEST.json"

    /// Zip `entry`'s on-disk subdirectory (`{store.rootDirectory}/{entry.promptId}/`)
    /// into a temporary file and then hand that file to
    /// `chooseDestinationAndCopy(_:)` for the save panel.
    ///
    /// Split out from `exportEntry(_:store:)` so the test suite
    /// can verify the actual zip layout without driving an
    /// `NSSavePanel` (which is a UI modal).
    @MainActor
    static func exportEntry(
        _ entry: AIGeneratorHistoryEntry,
        store: AIGeneratorHistoryStore
    ) -> GeneratorHistoryExportResult {
        let sourceDir = store.rootDirectory
            .appendingPathComponent(entry.promptId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            return .missingDirectory(reason: sourceDir.path)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(entry.promptId).zip"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else {
            return .cancelled
        }
        return runZip(
            sourceDirectory: sourceDir,
            destination: destination,
            entry: entry
        )
    }

    /// Run `/usr/bin/zip -r <destination> .` in `sourceDirectory`
    /// and surface the result as a `GeneratorHistoryExportResult`.
    /// Exposed for the test bundle, which points the call at a
    /// temp file rather than driving an `NSSavePanel`.
    ///
    /// When `entry` is non-nil, a `MANIFEST.json` is written
    /// into `sourceDirectory` (which becomes the zip root after
    /// `zip -r .`) before the zip is invoked. The manifest
    /// records `appVersion` / `appBuild` / `exportedAt` /
    /// `entryCount` / `provider` so a support bundle can be
    /// traced back to the model + endpoint that produced it
    /// without re-decoding the entry's `response.json`.
    @discardableResult
    static func runZip(
        sourceDirectory: URL,
        destination: URL,
        entry: AIGeneratorHistoryEntry? = nil
    ) -> GeneratorHistoryExportResult {
        if let entry = entry {
            do {
                try writeManifest(
                    into: sourceDirectory,
                    entryCount: 1,
                    provider: providerString(for: entry)
                )
            } catch {
                return .zipFailed(
                    reason: "Failed to write \(manifestFilename): \(error.localizedDescription)"
                )
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", destination.path, "."]
        process.currentDirectoryURL = sourceDirectory
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                revealInFinder(destination)
                return .success(destination: destination)
            } else {
                let captured = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let reason = captured.isEmpty
                    ? "zip exited with status \(process.terminationStatus)"
                    : "zip exited with status \(process.terminationStatus): \(captured)"
                return .zipFailed(reason: reason)
            }
        } catch {
            return .launchFailed(reason: error.localizedDescription)
        }
    }

    /// Convenience wrapper that runs the zip into a temp file,
    /// then uses `unzip -l` (also a system binary) to print the
    /// archive's table of contents. The test bundle uses this to
    /// verify that `request.txt` / `response.json` (and, when
    /// present, `menu.json`) made it into the bundle.
    @discardableResult
    static func listContents(ofZipAt zipURL: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", zipURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        } catch {
            return ""
        }
    }

    private static let log = OSLog(
        subsystem: "com.lingyi.menubar01",
        category: "GeneratorHistory"
    )

    /// Pop Finder with `url` highlighted. Called from
    /// `runZip(...)` on the success path so the user lands
    /// next to the new zip without having to dig it out of the
    /// `NSSavePanel`'s chosen directory. The call is dispatched
    /// onto the main queue — `NSWorkspace` is documented to
    /// be safe from any thread, but the `UI`-flavoured method
    /// `activateFileViewerSelecting(...)` is the one we want
    /// here, and the project keeps its UI work on the main
    /// thread for consistency with the rest of the exporter's
    /// callers.
    ///
    /// Fire-and-forget: a failure to launch Finder (e.g. the
    /// user has never opened Finder) does not surface as an
    /// error to the caller — the zip is already on disk, so
    /// the export is still a success.
    private static func revealInFinder(_ url: URL) {
        os_log(
            "runZip: revealing exported zip in Finder at %{public}@",
            log: log,
            type: .info,
            url.path
        )
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Manifest

    /// Write `MANIFEST.json` at `zipDirectory/`, populated with the
    /// app version + build, the export timestamp, the number of
    /// entries being bundled, and a `provider` string derived
    /// from the entry's `endpointHost` / `model`.
    ///
    /// Called from `runZip(sourceDirectory:destination:entry:)`
    /// before the zip is invoked. `zipDirectory` is the cwd of
    /// the `zip -r .` invocation, so the file lands at the
    /// archive's root alongside the entry's audit log.
    private static func writeManifest(
        into zipDirectory: URL,
        entryCount: Int,
        provider: String
    ) throws {
        let payload = HistoryExportManifest(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            exportedAt: Date(),
            entryCount: entryCount,
            provider: provider
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = zipDirectory.appendingPathComponent(manifestFilename)
        try data.write(to: url, options: [.atomic])
    }

    /// Derive the `provider` string for `MANIFEST.json` from an
    /// entry. Mirrors the redacted host information already
    /// surfaced on the history sheet so the support bundle is
    /// self-describing: a remote endpoint shows up as
    /// `"remote:<host>"`, anything else with a non-empty model
    /// is `"local"`, and the catch-all is `"unknown"`.
    private static func providerString(for entry: AIGeneratorHistoryEntry) -> String {
        if let host = entry.endpointHost, !host.isEmpty {
            return "remote:\(host)"
        }
        if !entry.model.isEmpty {
            return "local"
        }
        return "unknown"
    }
}

/// Codable shape for the zip-root `MANIFEST.json`. `Date` is
/// encoded as an ISO-8601 string by the encoder's
/// `dateEncodingStrategy`, so the on-disk field is a stable,
/// machine-parseable timestamp.
private struct HistoryExportManifest: Codable {
    let appVersion: String
    let appBuild: String
    let exportedAt: Date
    let entryCount: Int
    let provider: String
}

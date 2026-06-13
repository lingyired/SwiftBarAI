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
        return runZip(sourceDirectory: sourceDir, destination: destination)
    }

    /// Run `/usr/bin/zip -r <destination> .` in `sourceDirectory`
    /// and surface the result as a `GeneratorHistoryExportResult`.
    /// Exposed for the test bundle, which points the call at a
    /// temp file rather than driving an `NSSavePanel`.
    @discardableResult
    static func runZip(
        sourceDirectory: URL,
        destination: URL
    ) -> GeneratorHistoryExportResult {
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
}

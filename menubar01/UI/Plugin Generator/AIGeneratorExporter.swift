// AIGeneratorExporter.swift
// menubar01 — AI Plugin Generator (M2+ follow-up)
//
// Helper that turns an in-memory `GeneratedPlugin` into a `.zip`
// archive the user can save anywhere on disk. Sits next to
// `AIGeneratorSheet` so the view stays a pure renderer and the
// export logic is unit-testable from the test bundle without
// booting an `NSHostingController` / `NSSavePanel`. The view's
// "Export…" button calls `AIGeneratorExporter.exportPlugin(_:)`,
// which shells out to `/usr/bin/zip` (macOS 12+ ships with it).
//
// Layout invariant: the resulting zip contains `manifest.json`
// and the entry script at the **root** of the archive (not
// inside a subfolder), so the user can unzip it directly into
// a plugin folder of their choosing and the two files land at
// the plugin folder's top level — exactly the layout
// `PluginManager.installGeneratedPlugin(_:)` writes today.

import AppKit
import Foundation
import os

/// Result of an `AIGeneratorExporter.exportPlugin(_:)` call.
///
/// Modelled as an `enum` so the SwiftUI sheet can route the
/// result to a single "Exported" / "Export failed" alert
/// without duplicating the error-string plumbing. Mirrors
/// `GeneratorHistoryExportResult` in shape but does not have a
/// `missingDirectory` case — the v1 export path always starts
/// from an in-memory `GeneratedPlugin`, so a missing source
/// directory cannot happen.
public enum AIGeneratorExportResult: Equatable {
    /// The zip was written to `destination`.
    case success(destination: URL)
    /// The user cancelled the save panel.
    case cancelled
    /// Writing the manifest / entry script to the staging
    /// temp directory failed. The reason is the underlying
    /// `Error.localizedDescription`.
    case writeFailed(reason: String)
    /// `/usr/bin/zip` exited with a non-zero status. The
    /// reason includes the captured stderr.
    case zipFailed(reason: String)
    /// `Process.run()` itself threw (e.g. zip binary not
    /// found). The reason is `Error.localizedDescription`.
    case launchFailed(reason: String)
}

public enum AIGeneratorExporter {

    /// Write `plugin.manifest` (JSON-encoded) and
    /// `plugin.entryScript` into a fresh per-call temp
    /// directory, then return the directory URL.
    ///
    /// The caller owns the returned directory and is
    /// responsible for zipping it and for removing it from
    /// disk afterwards. Production callers go through
    /// `exportPlugin(_:)`, which does both via `defer`;
    /// the test bundle calls this helper directly and cleans
    /// up the temp dir in its own `defer` block.
    ///
    /// The directory name uses a per-call `UUID` so two
    /// concurrent exports (or a re-export after a failed
    /// earlier run) do not collide on the same staging path.
    /// The `manifest.json` and entry filename are pinned to
    /// the values documented in the v1 install format so a
    /// successful export unzips straight into a plugin
    /// folder.
    ///
    /// The entry script is written with the executable bit
    /// set (mirroring the `chmod +x` step
    /// `PluginManager.installGeneratedPlugin(_:)` performs
    /// on install), so a user who unzips the export into an
    /// empty plugin folder and points the Plugin Folder at
    /// it gets a working plugin without having to manually
    /// `chmod` the entry script.
    public static func writeToTempDir(_ plugin: GeneratedPlugin) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("menubar01-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let manifestURL = dir.appendingPathComponent(pluginManifestFileName)
        let manifestData = try JSONEncoder().encode(plugin.manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        let entryURL = dir.appendingPathComponent(entryFilename(for: plugin))
        guard let entryData = plugin.entryScript.data(using: .utf8) else {
            throw AIGeneratorExportError.entryEncodingFailed
        }
        try entryData.write(to: entryURL, options: .atomic)
        // Set the executable bit on the entry script so the
        // exported zip is self-contained — a downstream
        // unzip + Plugin Folder install does not need a
        // separate `chmod +x` step. `Data.write(...)` does
        // not honour the umask-executable default on every
        // platform, so we set the bits explicitly. The
        // existing `0o644` (owner read/write, group/other
        // read) is the standard umask default, so we OR in
        // the owner-execute bit rather than replacing the
        // whole mode.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: entryURL.path)) ?? [:]
        let existing = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let executable = existing | 0o111
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: executable)],
            ofItemAtPath: entryURL.path
        )

        return dir
    }

    /// Show an `NSSavePanel`, write the plugin to a staging
    /// temp directory, run `/usr/bin/zip -r <destination> .`
    /// from the staging dir, and clean up. The end result is
    /// a single zip on disk with `manifest.json` + the entry
    /// script at the archive root.
    @MainActor
    public static func exportPlugin(_ plugin: GeneratedPlugin) -> AIGeneratorExportResult {
        let pluginName = plugin.manifest.name ?? "generated-plugin"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pluginName).zip"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else {
            return .cancelled
        }

        let tempDir: URL
        do {
            tempDir = try writeToTempDir(plugin)
        } catch {
            os_log(
                "AIGeneratorExporter: write to temp dir failed: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            return .writeFailed(reason: error.localizedDescription)
        }
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return runZip(sourceDirectory: tempDir, destination: destination)
    }

    /// Run `/usr/bin/zip -r <destination> .` in
    /// `sourceDirectory` and surface the result as an
    /// `AIGeneratorExportResult`. Exposed for the test bundle,
    /// which points the call at a known temp file rather than
    /// driving an `NSSavePanel`.
    ///
    /// The `zip -r .` invocation archives the staging dir's
    /// contents at the zip's root, so the resulting archive
    /// contains `manifest.json` and the entry script at the
    /// top level (matching the v1 install layout produced by
    /// `PluginManager.installGeneratedPlugin(_:)`).
    @discardableResult
    public static func runZip(
        sourceDirectory: URL,
        destination: URL
    ) -> AIGeneratorExportResult {
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

    /// Resolve the entry script's on-disk filename. Mirrors
    /// the logic in `GeneratedPlugin.encodedAsBundle()` so the
    /// exported zip and the install path write the same name
    /// to disk. Falls back to `"plugin.sh"` when the manifest
    /// leaves `entry` nil / empty, matching the v1 default.
    static func entryFilename(for plugin: GeneratedPlugin) -> String {
        if let entry = plugin.manifest.entry, !entry.isEmpty {
            return entry
        }
        return "plugin.sh"
    }

    private static let log = OSLog(
        subsystem: "com.lingyi.menubar01",
        category: "AIGenerator"
    )

    /// Pop Finder with `url` highlighted. Called from
    /// `runZip(...)` on the success path so the user lands
    /// next to the new zip without having to dig it out of
    /// the `NSSavePanel`'s chosen directory. The call is
    /// dispatched onto the main queue — `NSWorkspace` is
    /// documented to be safe from any thread, but the
    /// `UI`-flavoured method `activateFileViewerSelecting(...)`
    /// is the one we want here, and the project keeps its UI
    /// work on the main thread for consistency with the rest
    /// of the exporter's callers.
    ///
    /// Fire-and-forget: a failure to launch Finder (e.g. the
    /// user has never opened Finder) does not surface as an
    /// error to the caller — the zip is already on disk, so
    /// the export is still a success.
    private static func revealInFinder(_ url: URL) {
        os_log(
            "AIGeneratorExporter: revealing exported zip in Finder at %{public}@",
            log: log,
            type: .info,
            url.path
        )
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Internal-only error thrown by `writeToTempDir(_:)` when the
/// plugin's `entryScript` cannot be encoded as UTF-8. In
/// practice the entry script is always a `String`, so this
/// path is unreachable for any well-formed `GeneratedPlugin`;
/// it exists so the function's `throws` contract is total.
enum AIGeneratorExportError: Error, LocalizedError {
    case entryEncodingFailed

    var errorDescription: String? {
        switch self {
        case .entryEncodingFailed:
            return "The plugin's entry script could not be encoded as UTF-8."
        }
    }
}

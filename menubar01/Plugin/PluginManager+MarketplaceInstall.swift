// PluginManager+MarketplaceInstall.swift
// menubar01 — PluginMarketplace (M5)
//
// Wires the M4 `MarketplaceInstallPlan` value type to the existing
// `PluginManager` so the marketplace browser UI can land a
// plugin on disk via a single call. Kept in a separate file (and
// a `PluginManager` extension) so it does not conflict with the
// M2 install flow being added in parallel to `PluginManger.swift`.
//
// The split mirrors the M4 "pure-logic plan + side-effectful
// install" division:
//
//   1. `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`
//      — pure, no I/O, validates the (entry, package) pair and
//      produces a `MarketplaceInstallPlan`.
//   2. `PluginManager.installMarketplacePlugin(plan:overwriteExisting:)`
//      — the I/O half. Reads `pluginDirectoryURL`, sanitises the
//      target subfolder name, writes `manifest.json` + the entry
//      script, and `chmod +x` the entry script. The view model
//      glues the two halves together.

import Foundation
import os

/// Errors surfaced by `PluginManager.installMarketplacePlugin(...)`.
///
/// `Equatable` so the browser view model can pattern-match on the
/// failure case in the success alert / error banner. The cases
/// are intentionally narrow — `writeFailed` and `chmodFailed` are
/// distinct because the user can recover from a `chmod` failure
/// (run `chmod +x` themselves) in a way they cannot from a
/// directory write failure.
public enum InstallMarketplacePluginError: Error, Equatable {
    /// The user has not yet picked a Plugin Folder in Preferences.
    case pluginDirectoryUnavailable
    /// File system write failed (e.g. parent dir not writable,
    /// disk full, permissions). `reason` is the underlying error's
    /// `localizedDescription` so the UI can show it verbatim.
    case writeFailed(reason: String)
    /// The plugin was written but `chmod +x` on the entry script
    /// failed. `reason` is the underlying error's
    /// `localizedDescription`.
    case chmodFailed(reason: String)
    /// The caller passed an inconsistent pair of arguments — e.g.
    /// a plan that conflicts with `overwriteExisting`. Reserved
    /// for future expansion; the v1 implementation only uses it
    /// to signal "the caller asked to overwrite but the plan's
    /// own flag disagrees".
    case planFailed(reason: String)
}

extension PluginManager {

    // MARK: - Constants

    /// Maximum length of the sanitised on-disk folder name. The
    /// `MarketplaceEntry.id` is already a slug, but the file name
    /// is the entry filename minus its extension — keep the clip
    /// liberal so long entry script names (e.g. `Weather.sh`) do
    /// not get truncated silently.
    private static let maxFolderNameLength = 64

    // MARK: - Public install method

    /// Install a marketplace plugin from a pre-built
    /// `MarketplaceInstallPlan`.
    ///
    /// The plan carries everything the writer needs (target
    /// subfolder name, entry filename, manifest bytes, entry
    /// script bytes). The caller (the browser view model) is
    /// responsible for calling `MarketplaceInstaller.plan(...)`
    /// first — this method does **not** re-derive the plan.
    ///
    /// On success the plugin lands at:
    /// ```
    /// <pluginDirectoryURL>/<plan.targetSubfolder>/<sanitised folder name>/manifest.json
    /// <pluginDirectoryURL>/<plan.targetSubfolder>/<sanitised folder name>/<plan.entryFilename>
    /// ```
    /// and the entry script is `chmod +x`'d. The folder name is
    /// the entry filename with its extension stripped (so
    /// `echo.sh` becomes `echo`). The folder is then sanitised
    /// against `/`, `\`, `..`, `~`, `:` → `_` and clipped to 64
    /// characters. The folder is **not** symlinked or relocated —
    /// the user can delete it from the Plugin Folder to
    /// "uninstall".
    ///
    /// - Parameters:
    ///   - plan: A `MarketplaceInstallPlan` produced by
    ///     `MarketplaceInstaller.plan(entry:package:overwriteExisting:)`.
    ///   - overwriteExisting: If `false` and the target directory
    ///     already exists, the method returns
    ///     `.failure(.writeFailed(reason: "..."))` without touching
    ///     the disk. If `true` the existing directory is removed
    ///     first.
    /// - Returns: `.success(targetURL)` on success, or a
    ///   `InstallMarketplacePluginError` describing what went
    ///   wrong.
    @discardableResult
    public func installMarketplacePlugin(
        plan: MarketplaceInstallPlan,
        overwriteExisting: Bool
    ) -> Result<URL, InstallMarketplacePluginError> {
        // Sanity check the plan's overwrite flag against the caller's.
        // We don't want a caller to pass `overwriteExisting: true` if
        // the plan was built with `overwriteExisting: false` (and
        // vice versa) — the plan is the single source of truth.
        guard plan.overwriteExisting == overwriteExisting else {
            os_log("installMarketplacePlugin: plan.overwriteExisting=%{public}@ does not match caller's overwriteExisting=%{public}@",
                   log: Log.plugin, type: .error,
                   String(describing: plan.overwriteExisting),
                   String(describing: overwriteExisting))
            return .failure(.planFailed(
                reason: "plan.overwriteExisting (\(plan.overwriteExisting)) does not match overwriteExisting argument (\(overwriteExisting))"
            ))
        }

        guard let pluginDirectoryURL else {
            os_log("installMarketplacePlugin: plugin directory is unset", log: Log.plugin, type: .error)
            return .failure(.pluginDirectoryUnavailable)
        }

        let folderName = sanitisedFolderName(from: plan.entryFilename)
        let targetDirectory = pluginDirectoryURL
            .appendingPathComponent(plan.targetSubfolder, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .standardizedFileURL

        // Overwrite handling: when the caller does not allow
        // overwriting, refuse early without touching the disk.
        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            if !overwriteExisting {
                os_log("installMarketplacePlugin: target exists at %{public}@, refusing without overwrite",
                       log: Log.plugin, type: .info, targetDirectory.path)
                return .failure(.writeFailed(
                    reason: "target exists at \(targetDirectory.path); pass overwriteExisting: true to replace"
                ))
            }
            do {
                try FileManager.default.removeItem(at: targetDirectory)
            } catch {
                os_log("installMarketplacePlugin: failed to remove existing target at %{public}@: %{public}@",
                       log: Log.plugin, type: .error,
                       targetDirectory.path, error.localizedDescription)
                return .failure(.writeFailed(
                    reason: "failed to remove existing target: \(error.localizedDescription)"
                ))
            }
        }

        // Create the directory tree and write the manifest +
        // entry script. Failures are wrapped so the UI can show
        // the underlying error verbatim.
        do {
            try FileManager.default.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            os_log("installMarketplacePlugin: failed to create target directory at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   targetDirectory.path, error.localizedDescription)
            return .failure(.writeFailed(
                reason: "failed to create target directory: \(error.localizedDescription)"
            ))
        }

        let manifestURL = targetDirectory.appendingPathComponent(pluginManifestFileName)
        do {
            try plan.manifestData.write(to: manifestURL, options: [.atomic])
        } catch {
            os_log("installMarketplacePlugin: failed to write manifest at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   manifestURL.path, error.localizedDescription)
            return .failure(.writeFailed(
                reason: "failed to write manifest.json: \(error.localizedDescription)"
            ))
        }

        let entryURL = targetDirectory.appendingPathComponent(plan.entryFilename)
        do {
            try plan.entryData.write(to: entryURL, options: [.atomic])
        } catch {
            os_log("installMarketplacePlugin: failed to write entry script at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   entryURL.path, error.localizedDescription)
            return .failure(.writeFailed(
                reason: "failed to write entry script: \(error.localizedDescription)"
            ))
        }

        // Mark the entry script executable. This is the same
        // chmod +x invocation `installImportedPlugin(from:moveItem:)`
        // uses for single-file plugins; we surface its own error
        // case so the UI can tell the user to chmod manually.
        do {
            try runScript(to: "chmod", args: ["+x", entryURL.path.escaped()])
        } catch {
            os_log("installMarketplacePlugin: failed to chmod +x entry at %{public}@: %{public}@",
                   log: Log.plugin, type: .error,
                   entryURL.path, error.localizedDescription)
            return .failure(.chmodFailed(
                reason: "failed to chmod +x \(entryURL.path): \(error.localizedDescription)"
            ))
        }

        os_log("installMarketplacePlugin: installed plugin to %{public}@", log: Log.plugin, type: .info, targetDirectory.path)
        return .success(targetDirectory)
    }

    // MARK: - Helpers

    /// Compute the on-disk folder name for a marketplace plugin
    /// from the entry script filename. Strips the extension, then
    /// replaces `/`, `\`, `..`, `~`, `:` with `_` (so a malicious
    /// package cannot escape the plugin folder), and clips to
    /// `maxFolderNameLength` characters.
    ///
    /// Examples:
    /// - `echo.sh`           → `echo`
    /// - `Weather.zsh`       → `Weather`
    /// - `../escape.sh`      → `_escape`
    /// - `foo:bar.sh`        → `foo_bar`
    /// - `aaaaaaaaaa…` (80c) → `aaaa…` (64 chars)
    private func sanitisedFolderName(from entryFilename: String) -> String {
        let stem = (entryFilename as NSString).deletingPathExtension
        let disallowed: Set<Character> = ["/", "\\", "~", ":"]
        var sanitised = ""
        sanitised.reserveCapacity(stem.count)
        for character in stem {
            if character == "." && sanitised.hasSuffix(".") {
                // Collapse `..` runs into a single `_` so the
                // classic ".." escape becomes a flat folder name.
                sanitised.append("_")
                continue
            }
            if disallowed.contains(character) {
                sanitised.append("_")
                continue
            }
            sanitised.append(character)
        }
        if sanitised.isEmpty {
            sanitised = "marketplace_plugin"
        }
        if sanitised.count > Self.maxFolderNameLength {
            sanitised = String(sanitised.prefix(Self.maxFolderNameLength))
        }
        return sanitised
    }
}

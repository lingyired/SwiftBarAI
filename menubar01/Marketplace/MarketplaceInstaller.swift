// MarketplaceInstaller.swift
// Pure-logic plan that turns a (entry, package) pair into the on-disk
// artefacts the future M5 installer will write. M4 deliberately does
// not touch the file system — the plan is a value type so the
// installer can be tested in isolation and so the actual write can
// happen in a different module / actor in M5.

import Foundation
import os

/// What the installer needs to know to write a marketplace plugin to
/// disk. Returned by `MarketplaceInstaller.plan(entry:package:)`.
///
/// The shape is intentionally minimal: the target subfolder name,
/// the entry script filename, the serialised manifest bytes, the
/// entry script bytes, and an overwrite flag. The actual
/// `<plugins>/_marketplace/<id>/manifest.json` and `.../<id>.sh` paths
/// are derived by the M5 caller from the parent plugin directory
/// (which is owned by `PluginManager`).
public struct MarketplaceInstallPlan: Equatable {
    /// Folder name relative to the user's Plugin Folder. Always
    /// `"_marketplace"` for v1 — keeps uninstall and audit tools
    /// simple by giving marketplace-installed plugins a stable
    /// parent.
    public let targetSubfolder: String
    /// Filename the entry script should be written to inside
    /// `targetSubfolder`. Provided by the package (not derived) so
    /// generators can ship non-default extensions like `.zsh`.
    public let entryFilename: String
    /// Serialised `manifest.json` body. The installer writes this
    /// verbatim so the file on disk matches what the package
    /// declared byte-for-byte.
    public let manifestData: Data
    /// UTF-8 encoded entry script body. The installer is responsible
    /// for setting the executable bit.
    public let entryData: Data
    /// `true` if the installer should overwrite an existing plugin
    /// at the same path; `false` if it should refuse. The M5 UI
    /// will surface this to the user before invoking the installer.
    public let overwriteExisting: Bool

    public init(
        targetSubfolder: String,
        entryFilename: String,
        manifestData: Data,
        entryData: Data,
        overwriteExisting: Bool
    ) {
        self.targetSubfolder = targetSubfolder
        self.entryFilename = entryFilename
        self.manifestData = manifestData
        self.entryData = entryData
        self.overwriteExisting = overwriteExisting
    }
}

/// Builds a `MarketplaceInstallPlan` from a catalogue entry and its
/// matching `MarketplacePackage`. No file system access, no
/// `PluginManager` wiring — both are deferred to M5.
///
/// The split exists so the data layer (M4) is fully unit-testable
/// without standing up `PluginManager` and so the M5 UI can
/// preview / diff / dry-run the install before any bytes are
/// written.
public struct MarketplaceInstaller {
    /// Default subfolder under the user's Plugin Folder where
    /// marketplace-installed plugins land. Exposed so callers do
    /// not need to hard-code the magic string.
    public static let defaultSubfolder = "_marketplace"

    /// Validates the entry/package pair and returns the
    /// `MarketplaceInstallPlan` the M5 installer will execute.
    ///
    /// - Throws `MarketplaceError.notFound(id:)` if `entry.id` and
    ///   `package.id` do not match. The catalogue row and the
    ///   payload must be loaded from the same source — a mismatch
    ///   means the client or the caller mixed them up.
    /// - Throws `MarketplaceError.decodingFailed(reason:)` if the
    ///   package's manifest is not encodable to JSON. This should
    ///   never happen for a well-formed `PluginManifest`; the
    ///   explicit error path exists so a corrupt catalogue surfaces
    ///   a typed error rather than a generic Swift `EncodingError`.
    public static func plan(
        entry: MarketplaceEntry,
        package: MarketplacePackage,
        overwriteExisting: Bool = false
    ) throws -> MarketplaceInstallPlan {
        guard entry.id == package.id else {
            throw MarketplaceError.notFound(id: entry.id)
        }

        let manifestData: Data
        do {
            manifestData = try JSONEncoder().encode(package.manifest)
        } catch {
            throw MarketplaceError.decodingFailed(
                reason: "Failed to encode manifest for \(package.id): \(error.localizedDescription)"
            )
        }

        return MarketplaceInstallPlan(
            targetSubfolder: defaultSubfolder,
            entryFilename: package.entryFilename,
            manifestData: manifestData,
            entryData: Data(package.entryScript.utf8),
            overwriteExisting: overwriteExisting
        )
    }
}

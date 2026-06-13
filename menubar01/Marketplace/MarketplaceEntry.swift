// MarketplaceEntry.swift
// Data layer for the v1 PluginMarketplace module (see
// AI_PLUGIN_ARCHITECTURE.md §1.6). M4 ships a stubbed client only — no
// networking, no on-disk installation. The shapes defined here are the
// ones the future M5 UI and installer will consume.

import Foundation
import os

/// A single item in the marketplace catalogue.
///
/// Mirrors the public sketch in `AI_PLUGIN_ARCHITECTURE.md` §1.6.
/// `id` is the stable slug used as the lookup key for
/// `MarketplaceClient.fetchPackage(id:)` and as the on-disk folder
/// name when the package is later installed.
public struct MarketplaceEntry: Codable, Identifiable, Equatable, Hashable {
    /// Stable, human-readable slug that uniquely identifies the entry.
    /// Used as the on-disk subfolder name under `_marketplace/`.
    public let id: String
    /// Display name shown in the marketplace browser.
    public let name: String
    /// One-line summary shown in the catalogue row.
    public let summary: String
    /// Coarse category bucket (e.g. `"time"`, `"system"`, `"tools"`).
    /// The v1 browser uses this to filter and group entries.
    public let category: String
    /// Catalogue-reported version string (e.g. `"1.2.3"`).
    /// Used by the M5 update-detection follow-up to surface a
    /// "Update available" badge on the Installed tab against
    /// the on-disk manifest's `version`. `nil` when the
    /// catalogue row omits the key (the badge logic treats
    /// `nil` as unparseable / `.unknown`). The
    /// `MarketplaceClient` stub client populates this with
    /// `"1.0.0"` for the three seed entries; the
    /// `RemoteMarketplaceClient` test fixtures omit the key
    /// to exercise the `Codable` default-decode path.
    public let version: String?
    /// Optional URL to a preview screenshot. `nil` means the browser
    /// should fall back to a generic icon.
    public let previewImageURL: URL?
    /// Total install count, as reported by the catalogue. Intended for
    /// display only — not authoritative.
    public let installCount: Int
    /// Average user rating on a 0.0 – 5.0 scale. The v1 catalogue
    /// always emits values in that range; the browser clamps on
    /// display.
    public let rating: Double
    /// Provenance: the stable prompt identifier of the
    /// `AIPluginGenerator` run that produced the entry. Used by the
    /// browser to deep-link back to the generator and to gate
    /// reproducibility of marketplace plugins.
    public let generatorPromptId: String
    /// Optional publisher signature. `nil` for unsigned entries —
    /// signing is explicitly out of scope for the v1 marketplace
    /// (see `AI_PLUGIN_ARCHITECTURE.md` §5).
    public let signedBy: String?

    public init(
        id: String,
        name: String,
        summary: String,
        category: String,
        version: String = "",
        previewImageURL: URL? = nil,
        installCount: Int = 0,
        rating: Double = 0,
        generatorPromptId: String,
        signedBy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.version = version
        self.previewImageURL = previewImageURL
        self.installCount = installCount
        self.rating = rating
        self.generatorPromptId = generatorPromptId
        self.signedBy = signedBy
    }
}

/// The installable payload returned by
/// `MarketplaceClient.fetchPackage(id:)`: a manifest + the entry
/// script as text + the filename the installer should use on disk.
///
/// `MarketplacePackage` is intentionally separate from
/// `MarketplaceEntry` so the (small, cached) catalogue can be served
/// cheaply while the (larger, per-id) package fetch is done
/// on-demand. M4's stub client returns both from in-memory storage.
///
/// The type itself is `public` so the `MarketplaceClient` protocol
/// can name it in a public method signature, but the `manifest`
/// property and the designated initializer are kept `internal`
/// because `PluginManifest` is `internal` — exposing them publicly
/// would be a compile error. External callers receive the package
/// from `fetchPackage(id:)` and read the public `id` / `entryScript`
/// / `entryFilename` fields; the manifest surfaces only through
/// `MarketplaceInstaller.plan(...)` which is the only legitimate
/// writer.
///
/// Not `Equatable`: `PluginManifest` is not `Equatable`, and the
/// marketplace layer never needs to compare two packages for
/// equality — it compares entry vs. package `id` and otherwise treats
/// each fetch as authoritative.
public struct MarketplacePackage: Codable {
    /// Must match the `id` of the `MarketplaceEntry` it was fetched
    /// for. `MarketplaceInstaller.plan(entry:package:)` enforces this
    /// invariant and refuses mismatched pairs.
    public let id: String
    /// The `manifest.json` body. Stored as the full struct so the
    /// installer can validate it, fold it into a `FolderPlugin`, and
    /// serialise it back to disk without an extra decode step.
    ///
    /// `internal` so the public type does not leak
    /// `PluginManifest`'s access level.
    let manifest: PluginManifest
    /// Entry script source, including the shebang line. Encoded as
    /// `Data` at install time via
    /// `Data(package.entryScript.utf8)`.
    public let entryScript: String
    /// Filename the installer should write the entry script to inside
    /// the target subfolder. Conventionally ends in `.sh` or `.zsh`.
    public let entryFilename: String

    /// `internal` because `manifest: PluginManifest` is internal —
    /// a public initializer that takes an internal parameter is a
    /// hard error. The stub client constructs packages inside the
    /// module; external callers receive pre-built values from
    /// `MarketplaceClient.fetchPackage(id:)`.
    init(
        id: String,
        manifest: PluginManifest,
        entryScript: String,
        entryFilename: String
    ) {
        self.id = id
        self.manifest = manifest
        self.entryScript = entryScript
        self.entryFilename = entryFilename
    }
}

/// Errors surfaced by the marketplace data layer.
///
/// The cases are intentionally narrow — transport and decoding
/// failures are wrapped generically because the v1 client is
/// in-memory and the v2 remote client will surface its own HTTP /
/// TLS errors through the `transport` case. Conforms to
/// `LocalizedError` so `error.localizedDescription` returns the
/// underlying `reason` string verbatim (instead of the default
/// "The operation couldn't be completed" that AppKit surfaces
/// for unannotated `Error` values).
public enum MarketplaceError: Error, Equatable, LocalizedError {
    /// The requested id was not present in the catalogue.
    case notFound(id: String)
    /// A payload that should have been valid JSON (manifest, etc.)
    /// could not be encoded or decoded.
    case decodingFailed(reason: String)
    /// Generic transport-layer failure. Kept for the v1 stub's
    /// in-memory "simulated transport" path; the real
    /// `RemoteMarketplaceClient` uses the more specific
    /// `.transportError`, `.providerFailure`, and
    /// `.malformedResponse` cases below.
    case transport(reason: String)
    /// The remote endpoint returned 401 / 403 — the marketplace
    /// request is unauthorised. Surfaced as a distinct case so
    /// the future marketplace Preferences pane can prompt the
    /// user to re-enter credentials without conflating the
    /// failure with a generic provider error. (M4 ships no
    /// auth flow; this case is for the future M2 / M5 remote
    /// client's v2+ auth path.)
    case unauthorized
    /// The remote endpoint returned 429 — the marketplace
    /// service rate-limited the request. Distinct from
    /// `.transportError` so the M5 browser can back off and
    /// retry without conflating throttling with a real
    /// transport failure.
    case rateLimited
    /// The remote endpoint returned a 4xx that is not 401 /
    /// 403 / 404 / 429. The `reason` is `"<status> <body>"`.
    case providerFailure(reason: String)
    /// The remote endpoint returned 5xx. The `reason` is
    /// `"<status> <body>"` so the diagnostic dump shows the
    /// upstream server's own failure message verbatim.
    case transportError(reason: String)
    /// The remote endpoint returned a 2xx with a body the
    /// client could not parse as the expected JSON shape. The
    /// `reason` is the underlying `DecodingError` description.
    case malformedResponse(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Plugin not found in catalogue: \(id)"
        case .decodingFailed(let reason):
            return "Could not decode marketplace payload: \(reason)"
        case .transport(let reason):
            return reason
        case .unauthorized:
            return "The remote marketplace rejected the request (HTTP 401 / 403). The marketplace endpoint may require credentials."
        case .rateLimited:
            return "The remote marketplace rate-limited the request. Please wait a moment and try again."
        case .providerFailure(let reason):
            return "Marketplace provider error: \(reason)"
        case .transportError(let reason):
            return "Could not reach the remote marketplace: \(reason)"
        case .malformedResponse(let reason):
            return "The remote marketplace returned an unparseable response: \(reason)"
        }
    }
}

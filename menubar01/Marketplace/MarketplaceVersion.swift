// MarketplaceVersion.swift
// menubar01 — PluginMarketplace (M5 update-detection follow-up)
//
// A small, dependency-free semver-style version type used by the
// marketplace browser to decide whether a locally installed
// plugin is behind the catalogue's latest version. Three integers
// (major / minor / patch) and a `Comparable` conformance that
// walks them in order — enough for the update-availability
// surface the Installed tab needs ("is the catalogue newer than
// what I have on disk?").
//
// The parser is intentionally permissive: catalogue rows may
// ship `"1.2.3"`, `"v1.2.3"`, `"1.2"`, or `"1"`. Pre-release
// suffixes (`-beta1`, `+build7`) are **not** parsed — the v1
// marketplace does not ship pre-release metadata, and silently
// dropping the suffix is safer than crashing on it.

import Foundation

/// A semver-style `MAJOR.MINOR.PATCH` version used to compare
/// the locally installed `manifest.json` against the catalogue
/// row. Conforms to `Comparable`, `Hashable`, and `Sendable` so
/// the value can flow freely between actors (the
/// `MarketplaceBrowserViewModel` is `@MainActor` but the parser
/// is intentionally callable from any context).
public struct MarketplaceVersion: Equatable, Hashable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse `"1.2.3"` / `"v1.2.3"` / `"1.2"` / `"1"` into a
    /// version. Returns `nil` for unparseable strings (empty,
    /// non-numeric components, etc.).
    ///
    /// The parser strips a leading `v` / `V` and **rejects**
    /// inputs whose numeric components are not contiguous
    /// integers — `"1.2.3 (build 7)"` is rejected (returns
    /// `nil`) because dropping the suffix would silently
    /// disagree with a row that did parse the suffix. This
    /// is a deliberate conservatism trade-off — the
    /// "v1.2.3" / "1.2" / "1" zero-fill handles the common
    /// short forms and the trailing-junk case is rare
    /// enough that we surface it as `.unknown` rather than
    /// guessing.
    public init?(parsing: String) {
        let trimmed = parsing.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let rawComponents = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let parts = rawComponents.compactMap { Int($0) }
        // Reject if any component is not a pure non-negative
        // integer. Without this check `"1.x.3"` would
        // silently become `1.0.3` and the badge would lie
        // about the catalogue version.
        guard !parts.isEmpty,
              parts.count == rawComponents.count
        else { return nil }
        self.major = parts[0]
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public static func < (lhs: MarketplaceVersion, rhs: MarketplaceVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var displayString: String { "\(major).\(minor).\(patch)" }
}

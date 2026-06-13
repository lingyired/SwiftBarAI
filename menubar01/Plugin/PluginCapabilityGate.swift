// PluginCapabilityGate.swift
// menubar01 — Capability Gate (M3)
//
// The `PluginCapabilityGate` is the runtime guard that refuses to
// load a plugin whose `manifest.json` declares a capability the user
// has not yet granted. It owns a `UserDefaults`-backed store of
// `(pluginID, grantedCapabilities)` pairs and exposes the three
// operations the install flow needs:
//
//  - `grant(_:for:)` — the user has accepted the install-prompt
//    sheet and the gate records the grant. Idempotent: re-granting
//    the same set is a no-op so the install flow can call it
//    defensively on every load.
//  - `granted(for:)` — read the current grant set for a plugin.
//    Used by the About / Permissions sheet to render which
//    capabilities a given plugin has access to.
//  - `verify(manifest:)` — the *gate*. Called at the install
//    boundary (`PluginManager.installImportedPlugin` /
//    `loadPlugin(fileURL:)`); throws
//    `PluginCapabilityError.capabilityNotGranted` if any declared
//    capability is missing from the grant set.
//
// The store is a `[String: Set<PluginCapability>]` map persisted as
// a `Data` blob via `JSONEncoder`; the on-disk schema is
// `[pluginID: [capability-object, ...]]` where each
// capability-object is the manual `Codable` form from
// `PluginCapabilities.swift` (e.g. `{"type": "network", "hosts":
// ["api.openai.com"]}`). The public API surfaces `pluginID` as
// `String` (rather than the internal `PluginID` typealias) so the
// gate does not leak `PluginID`'s `internal` access level. This is
// intentionally the same pattern `PreferencesStore` uses for
// non-`@Published` payloads (commit 4e1fc52). The init accepts an
// injected `UserDefaults` so tests can pass a
// `UserDefaults(suiteName:)` for isolation.

import Foundation
import os

/// Runtime guard that refuses to load a plugin unless every
/// capability it declares in `manifest.json` has been granted by
/// the user. Stateless from the caller's perspective — the
/// underlying `UserDefaults` is the only source of truth.
public struct PluginCapabilityGate {
    /// `UserDefaults` key holding the JSON-encoded
    /// `[String: Set<PluginCapability>]` map. Versioned via a
    /// `v1` suffix so the schema can evolve without colliding
    /// with future revisions of the store.
    private static let storeKey = "PluginCapabilityGate.grants.v1"

    private let defaults: UserDefaults

    /// Creates a gate backed by `defaults`. Production callers omit
    /// the argument and get the `.standard` store; tests pass a
    /// per-suite `UserDefaults(suiteName:)` instance for isolation.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Grant / read API

    /// Record that `pluginID` has been granted `caps`. Idempotent:
    /// granting the same set twice is a no-op. Subsequent calls
    /// with a strict subset do **not** revoke — there is no
    /// `revoke(_:for:)` in v1 because the install flow is the only
    /// writer and it never needs to downgrade.
    ///
    /// `pluginID` is typed as `String` (rather than the internal
    /// `PluginID` typealias) so the public method does not leak an
    /// internal type.
    public func grant(_ caps: Set<PluginCapability>, for pluginID: String) {
        guard !caps.isEmpty else { return }
        var current = readStore()
        let existing = current[pluginID] ?? []
        let merged = existing.union(caps)
        guard merged != existing else { return }
        current[pluginID] = merged
        writeStore(current)
        os_log("Granted capabilities for plugin %{public}@: %{public}@",
               log: Log.plugin, type: .info,
               pluginID, caps.map(\.displayName).sorted().joined(separator: ","))
    }

    /// Returns the set of capabilities the user has granted to
    /// `pluginID`. Empty when the plugin has never been granted
    /// anything (or no such plugin exists in the store).
    public func granted(for pluginID: String) -> Set<PluginCapability> {
        readStore()[pluginID] ?? []
    }

    /// `true` when `pluginID` has been granted `capability`. The
    /// whole-capability value (including associated values) must
    /// match — `.network(hosts: ["a.com"])` is **not** satisfied
    /// by a grant of `.network(hosts: ["b.com"])`. The
    /// install-prompt sheet is responsible for asking the user
    /// to grant each declared shape explicitly.
    public func isGranted(_ capability: PluginCapability, for pluginID: String) -> Bool {
        granted(for: pluginID).contains(capability)
    }

    // MARK: - Verify (the gate itself)

    /// Throws `PluginCapabilityError.capabilityNotGranted` if any
    /// element of `requiredCapabilities` is missing from
    /// `granted(for:)`. An empty `requiredCapabilities` always
    /// verifies — there is nothing to gate.
    ///
    /// - Throws: `PluginCapabilityError.capabilityNotGranted` for
    ///   the first ungranted capability encountered (declaration
    ///   order is preserved so the host UI can show a deterministic
    ///   error).
    public func verify(
        pluginID: String,
        requiredCapabilities: [PluginCapability]
    ) throws {
        guard !requiredCapabilities.isEmpty else { return }
        let grantedSet = granted(for: pluginID)
        for capability in requiredCapabilities where !grantedSet.contains(capability) {
            os_log("Capability gate refused plugin %{public}@: %{public}@ not granted",
                   log: Log.plugin, type: .error,
                   pluginID, capability.displayName)
            throw PluginCapabilityError.capabilityNotGranted(
                pluginID: pluginID,
                capability: capability
            )
        }
    }

    /// Internal convenience: derive the pluginID from `manifest.name`
    /// (the manifest is the only argument and is the v1 source of
    /// truth; the on-disk path lives in `PluginManager` and is not
    /// part of the manifest's data). Plugins without a name use the
    /// placeholder `"<unnamed>"` — `PluginManifestLoader` always
    /// returns a non-empty `name` for loadable plugins, so this is
    /// only reachable from tests.
    ///
    /// This overload is `internal` because `PluginManifest` is
    /// `internal`; external callers should use the `String` + list
    /// overload above.
    func verify(manifest: PluginManifest) throws {
        let pluginID = manifest.name ?? "<unnamed>"
        try verify(pluginID: pluginID, requiredCapabilities: manifest.resolvedCapabilities)
    }

    // MARK: - Store I/O

    /// The on-disk schema is a direct `Codable` round-trip of
    /// `[String: Set<PluginCapability>]` — the manual
    /// `PluginCapability` encoder produces the
    /// `{type, ...parameter}` object form documented in
    /// `PluginCapabilities.swift`. The previous v0 schema
    /// (`[String: [String]]` of raw values) is no longer
    /// produced by the gate, so reading v0 data falls through
    /// the catch and resets to empty — acceptable because
    /// the v0 store shipped in M3 today (2026-06-13) and has
    /// no real users to migrate.
    private func readStore() -> [String: Set<PluginCapability>] {
        guard let data = defaults.data(forKey: Self.storeKey) else { return [:] }
        do {
            return try JSONDecoder().decode(
                [String: Set<PluginCapability>].self, from: data
            )
        } catch {
            os_log("PluginCapabilityGate: failed to decode grant store — resetting: %{public}@",
                   log: Log.plugin, type: .error, error.localizedDescription)
            return [:]
        }
    }

    private func writeStore(_ store: [String: Set<PluginCapability>]) {
        do {
            let data = try JSONEncoder().encode(store)
            defaults.set(data, forKey: Self.storeKey)
        } catch {
            os_log("PluginCapabilityGate: failed to encode grant store: %{public}@",
                   log: Log.plugin, type: .error, error.localizedDescription)
        }
    }
}

// PluginCapabilityError.swift
// menubar01 — Capability Gate (M3)
//
// Typed errors raised by `PluginCapabilityGate`. The two cases cover
// the only failure surfaces the v1 install flow needs:
// - the gate refused to load a plugin that declared an ungranted
//   capability (the host UI surfaces this as the
//   "missing permission" fallback described in
//   `AI_PLUGIN_ARCHITECTURE.md` §3), and
// - the manifest contains a string the v1 `PluginCapability` enum
//   does not recognise. The decode path treats unknown strings as
//   a soft "drop and log" — *not* a throw — so on-disk manifests
//   from future builds continue to load, but the gate exposes a
//   `unknownCapability(rawValue:)` error for the host UI to surface
//   the raw value (e.g. in a debug log / system report) when it
//   has to *name* an unknown capability.

import Foundation

/// Errors raised by the capability gate.
public enum PluginCapabilityError: Error, Equatable, Sendable {
    /// The plugin's manifest declares `capability`, but the user has
    /// not granted that capability for the plugin named `pluginID`.
    /// The install flow must surface this and abort loading.
    /// `pluginID` is typed as `String` (rather than the internal
    /// `PluginID` typealias) so this public error does not leak an
    /// internal type.
    case capabilityNotGranted(pluginID: String, capability: PluginCapability)

    /// The manifest contains a capability string that the running
    /// build's `PluginCapability` enum does not recognise. Surfaced
    /// for the host UI / system report; the manifest decoder
    /// itself drops these (with an `os_log` warning) rather than
    /// throwing — see `PluginManifest.resolvedCapabilities`.
    case unknownCapability(rawValue: String)
}

extension PluginCapabilityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .capabilityNotGranted(pluginID, capability):
            return "Plugin \"\(pluginID)\" is not authorized to use \(capability.displayName)."
        case let .unknownCapability(rawValue):
            return "Plugin declares an unknown capability: \"\(rawValue)\"."
        }
    }
}

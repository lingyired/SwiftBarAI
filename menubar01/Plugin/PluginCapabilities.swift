// PluginCapability.swift
// menubar01 — Capability Gate (M3)
//
// Canonical vocabulary for the capabilities a plugin can declare in its
// `manifest.json` (`"capabilities": ["network", "clipboard", ...]`).
// Mirrors §3 of `AI_PLUGIN_ARCHITECTURE.md`. The raw string form is
// what authors write in JSON; the typed enum is what the rest of
// menubar01 reasons about. The v1 set is intentionally small; new
// capabilities land in a follow-up.

import Foundation
import os

/// A permission class a plugin may request at install time.
///
/// The raw value is the canonical spelling authors write in their
/// `manifest.json`. When the v1 vocabulary grows the new cases
/// should be appended (never renamed) so that on-disk manifests from
/// older versions continue to decode — unknown strings are *dropped
/// with a warning* at the manifest boundary (see
/// `PluginManifest.resolvedCapabilities`).
public enum PluginCapability: String, Codable, CaseIterable, Equatable, Sendable {
    /// Outbound HTTP/TCP via the app's already-granted
    /// `com.apple.security.network.client` entitlement. Gated as
    /// "ask once at install, persist grant" in the v1 model.
    case network

    /// Read/write of `NSPasteboard.general`. Gated as "ask once at
    /// install, persist grant" in the v1 model.
    case clipboard

    /// Posting of `UNUserNotification` alerts. Gated by a
    /// `UNUserNotificationCenter.requestAuthorization(...)` call at
    /// install time, persisted in the gate.
    case notifications

    /// Reading events from `EventKit`/`EKEventStore`. Backed by the
    /// existing `NSCalendarsUsageDescription` Info.plist key.
    /// Gated as "ask once at install, persist grant" in the v1
    /// model.
    case calendar

    /// Human-readable name for the capability prompt UI.
    public var displayName: String {
        switch self {
        case .network: "Network access"
        case .clipboard: "Clipboard access"
        case .notifications: "Notifications"
        case .calendar: "Calendar access"
        }
    }

    /// One-line description shown beneath `displayName` in the
    /// install-prompt UI. Wording is intentionally short so it
    /// remains readable in the proposed `<plugin name> wants to …`
    /// row the future install sheet will surface.
    public var description: String {
        switch self {
        case .network:
            "Allows this plugin to make outbound network requests."
        case .clipboard:
            "Allows this plugin to read and write your clipboard."
        case .notifications:
            "Allows this plugin to post macOS notifications."
        case .calendar:
            "Allows this plugin to read your calendar events."
        }
    }
}

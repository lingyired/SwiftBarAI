// PluginCapabilities.swift
// menubar01 — Capability Gate (M3, extended)
//
// Canonical vocabulary for the capabilities a plugin can declare in its
// `manifest.json` (`"capabilities": [{"type": "network", "hosts": [...]}, ...]`).
// Mirrors §3 of `AI_PLUGIN_ARCHITECTURE.md`. The JSON form is the
// what authors write; the typed enum is what the rest of menubar01
// reasons about. The v1 vocabulary is small; new capabilities land
// in a follow-up.
//
// M3 extension (2026-06-13): the three "concrete" capabilities
// (`network(hosts:)`, `fileWrite(paths:)`, plus the unchanged
// `notifications`) carry associated values so the install-prompt
// sheet can render *"Network access to api.openai.com"* /
// *"Write to ~/Library/Logs/plugin.log"* / *"Notifications"*
// instead of a bare word. The other two cases (`clipboard`,
// `calendar`) keep their bare shape — they have no parameter
// surface today. The JSON wire format is a discriminated object:
//   {"type": "network", "hosts": ["api.openai.com"]}
//   {"type": "notifications"}
// The v1 string-array form (`"network"`, `"clipboard"`) is
// accepted at the manifest boundary for backward compatibility;
// see `PluginManifest.capabilities` for the dual-format decoder.

import Foundation
import os

/// A permission class a plugin may request at install time.
///
/// The wire format is a keyed object — `{ "type": "<case-name>",
/// "<param>": <value>, ... }` — produced by the manual
/// `init(from:)` / `encode(to:)` below. Cases that carry
/// associated values MUST include the parameter key (`hosts`,
/// `paths`); omitting it decodes to an empty list, which the
/// install-prompt sheet renders as *"Network access"* / *"Write
/// files"* (i.e. *any host* / *any file*). Renaming any case is
/// a breaking change for every shipped plugin's `manifest.json`;
/// appending new cases is fine.
public enum PluginCapability: Equatable, Hashable, Sendable {
    /// Outbound HTTP/TCP via the app's already-granted
    /// `com.apple.security.network.client` entitlement. The
    /// `hosts` list is the declared destination set; an empty
    /// list means *any host*. Gated as "ask once at install,
    /// persist grant" in the v1 model.
    case network(hosts: [String])

    /// Read/write of `NSPasteboard.general`. Gated as "ask once
    /// at install, persist grant" in the v1 model.
    case clipboard

    /// Posting of `UNUserNotification` alerts. Gated by a
    /// `UNUserNotificationCenter.requestAuthorization(...)`
    /// call at install time, persisted in the gate.
    case notifications

    /// Reading events from `EventKit`/`EKEventStore`. Backed by
    /// the existing `NSCalendarsUsageDescription` Info.plist
    /// key. Gated as "ask once at install, persist grant" in
    /// the v1 model.
    case calendar

    /// Writing files to the user's home directory at the
    /// declared `paths`. An empty list means *any path*. The
    /// runtime path enforcement is a follow-up; v1 just
    /// surfaces the declaration in the install-prompt sheet and
    /// records the grant in the gate.
    case fileWrite(paths: [String])

    /// Human-readable name for the capability prompt UI.
    public var displayName: String {
        switch self {
        case .network(let hosts):
            if hosts.isEmpty {
                return "Network access"
            } else {
                return "Network access to \(hosts.joined(separator: ", "))"
            }
        case .clipboard:
            return "Clipboard access"
        case .notifications:
            return "Notifications"
        case .calendar:
            return "Calendar access"
        case .fileWrite(let paths):
            if paths.isEmpty {
                return "Write files"
            } else {
                return "Write to \(paths.joined(separator: ", "))"
            }
        }
    }

    /// One-line description shown beneath `displayName` in the
    /// install-prompt UI. Wording is intentionally short so it
    /// remains readable in the proposed `<plugin name> wants to …`
    /// row the future install sheet will surface.
    public var description: String {
        switch self {
        case .network:
            return "Allows this plugin to make outbound network requests."
        case .clipboard:
            return "Allows this plugin to read and write your clipboard."
        case .notifications:
            return "Allows this plugin to post macOS notifications."
        case .calendar:
            return "Allows this plugin to read your calendar events."
        case .fileWrite:
            return "Allows this plugin to write files under your home directory."
        }
    }

    /// `true` when the user has already consented to this
    /// capability *implicitly* (e.g. the app's own entitlements
    /// or Info.plist strings). The install-prompt sheet uses
    /// this to auto-grant capabilities the user does not need
    /// to be re-prompted for. v1 returns `true` for `clipboard`
    /// (any foreground macOS app can read `NSPasteboard.general`
    /// without an entitlement, so surfacing the row in the
    /// install-prompt would just be noise) and `false` for the
    /// other four cases — those all require explicit consent.
    public var isGrantedByDefault: Bool {
        switch self {
        case .clipboard:
            return true
        case .network, .notifications, .calendar, .fileWrite:
            return false
        }
    }
}

// MARK: - Codable

extension PluginCapability: Codable {
    /// Discriminator string used as the `type` key in the
    /// JSON form. Kept private so the v1 wire vocabulary stays
    /// in one place; the manifest decoder reaches the same
    /// strings via `PluginCapabilityDescriptor` for the
    /// v1 string-array form.
    private enum Kind: String, Codable {
        case network
        case clipboard
        case notifications
        case calendar
        case fileWrite
    }

    private enum CodingKeys: String, CodingKey {
        case type, hosts, paths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .network:
            let hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
            self = .network(hosts: hosts)
        case .clipboard:
            self = .clipboard
        case .notifications:
            self = .notifications
        case .calendar:
            self = .calendar
        case .fileWrite:
            let paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
            self = .fileWrite(paths: paths)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .network(let hosts):
            try container.encode(Kind.network, forKey: .type)
            try container.encode(hosts, forKey: .hosts)
        case .clipboard:
            try container.encode(Kind.clipboard, forKey: .type)
        case .notifications:
            try container.encode(Kind.notifications, forKey: .type)
        case .calendar:
            try container.encode(Kind.calendar, forKey: .type)
        case .fileWrite(let paths):
            try container.encode(Kind.fileWrite, forKey: .type)
            try container.encode(paths, forKey: .paths)
        }
    }
}

// MARK: - CaseIterable

extension PluginCapability: CaseIterable {
    /// Auto-synthesis of `CaseIterable` is unavailable for
    /// enums that have **any** case with an associated value
    /// (the protocol has no way to enumerate the host/path
    /// list that `network(hosts:)` and `fileWrite(paths:)`
    /// would each require). The v1.1 surface has two
    /// parameterised cases plus three bare cases; we list
    /// each with an empty associated-value list as the
    /// "canonical empty" representation. The install-prompt
    /// sheet's `allCases` loop is only used to verify that
    /// every case has a non-empty `displayName` /
    /// `description` / `isGrantedByDefault`, so the
    /// associated-value payloads do not matter for the
    /// observable behaviour.
    public static var allCases: [PluginCapability] {
        [
            .network(hosts: []),
            .clipboard,
            .notifications,
            .calendar,
            .fileWrite(paths: [])
        ]
    }
}

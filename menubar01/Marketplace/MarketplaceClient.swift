// MarketplaceClient.swift
// Abstract client + a deterministic in-memory stub for the v1
// PluginMarketplace module (see AI_PLUGIN_ARCHITECTURE.md §1.6).
//
// M4 ships only the stub. A future `RemoteMarketplaceClient` will be
// added by `MarketplaceClientFactory.makeRemote(endpoint:)` once the
// remote catalogue endpoint exists and signing is decided.

import Foundation
import os

/// Abstract catalogue + package fetch surface used by the M5
/// marketplace browser.
///
/// The interface is intentionally `async throws` so the v2 remote
/// implementation can do its network work off the main thread; the
/// v1 stub returns synchronously wrapped in an async function.
public protocol MarketplaceClient {
    /// Returns the full marketplace catalogue. Order is stable for
    /// the v1 stub (declaration order) so the unit test can assert
    /// on count and ids without flakiness.
    func fetchCatalogue() async throws -> [MarketplaceEntry]

    /// Returns the installable payload for a single entry id. Throws
    /// `MarketplaceError.notFound(id:)` if the id is unknown.
    func fetchPackage(id: String) async throws -> MarketplacePackage
}

/// In-memory marketplace client used by M4.
///
/// The catalogue and the per-id packages are hard-coded so the
/// `MarketplaceTests` suite is deterministic and does not require
/// network or fixture files. The 3 seed entries exercise the three
/// common marketplace categories: `time`, `tools`, and `system`.
///
/// Do not add real `URLSession` calls here — that is the M2 / M5
/// remote client's job. The stub's value is that it lets the
/// marketplace UI, the installer plan, and the unit tests be
/// designed and exercised without standing up a backend.
public struct StubMarketplaceClient: MarketplaceClient {
    /// Public count of catalogue entries, asserted by `MarketplaceTests`.
    public static let stubCatalogueCount = 3

    private let entries: [MarketplaceEntry]
    private let packages: [String: MarketplacePackage]

    /// Builds a stub with the canonical 3-entry seed catalogue. Use
    /// this in production code paths and tests alike so the catalogue
    /// is uniform.
    public init() {
        let echo = MarketplaceEntry(
            id: "echo",
            name: "Echo",
            summary: "Prints a single menu item from the plugin stdout.",
            category: "tools",
            previewImageURL: nil,
            installCount: 12,
            rating: 4.5,
            generatorPromptId: "demo.echo.v1"
        )
        let date = MarketplaceEntry(
            id: "todays-date",
            name: "Today's Date",
            summary: "Shows today's date in the menu bar.",
            category: "time",
            previewImageURL: nil,
            installCount: 142,
            rating: 4.8,
            generatorPromptId: "demo.date.v1"
        )
        let battery = MarketplaceEntry(
            id: "battery-watch",
            name: "Battery Watch",
            summary: "Live battery percentage and charging state.",
            category: "system",
            previewImageURL: nil,
            installCount: 97,
            rating: 4.2,
            generatorPromptId: "demo.battery.v1"
        )
        self.entries = [echo, date, battery]

        var packageMap: [String: MarketplacePackage] = [:]

        var echoManifest = PluginManifest()
        echoManifest.name = "Echo"
        echoManifest.version = "1.0.0"
        echoManifest.description = "Prints a single menu item from the plugin stdout."
        echoManifest.author = "menubar01 marketplace"
        echoManifest.entry = "echo.sh"
        echoManifest.refreshInterval = 0
        packageMap["echo"] = MarketplacePackage(
            id: "echo",
            manifest: echoManifest,
            entryScript: "#!/bin/zsh\necho Echo | size=14 color=blue\n",
            entryFilename: "echo.sh"
        )

        var dateManifest = PluginManifest()
        dateManifest.name = "Today's Date"
        dateManifest.version = "1.0.0"
        dateManifest.description = "Shows today's date in the menu bar."
        dateManifest.author = "menubar01 marketplace"
        dateManifest.entry = "todays-date.sh"
        dateManifest.refreshInterval = 3600
        packageMap["todays-date"] = MarketplacePackage(
            id: "todays-date",
            manifest: dateManifest,
            entryScript: "#!/bin/zsh\ndate '+%a %b %-d'\n",
            entryFilename: "todays-date.sh"
        )

        var batteryManifest = PluginManifest()
        batteryManifest.name = "Battery Watch"
        batteryManifest.version = "1.0.0"
        batteryManifest.description = "Live battery percentage and charging state."
        batteryManifest.author = "menubar01 marketplace"
        batteryManifest.entry = "battery-watch.sh"
        batteryManifest.refreshInterval = 30
        packageMap["battery-watch"] = MarketplacePackage(
            id: "battery-watch",
            manifest: batteryManifest,
            entryScript: "#!/bin/zsh\npmset -g batt | awk '/InternalBattery/{print $2 \" \" $3}'\n",
            entryFilename: "battery-watch.sh"
        )
        self.packages = packageMap
    }

    public func fetchCatalogue() async throws -> [MarketplaceEntry] {
        return entries
    }

    public func fetchPackage(id: String) async throws -> MarketplacePackage {
        guard let package = packages[id] else {
            throw MarketplaceError.notFound(id: id)
        }
        return package
    }
}

/// Factory for `MarketplaceClient` instances.
///
/// M4 exposes `makeStub()` (the deterministic in-memory client).
/// The M2 / M5 follow-up adds `makeRemote(endpoint:transport:)`,
/// which returns the real URLSession-backed
/// `RemoteMarketplaceClient` defined in
/// `RemoteMarketplaceClient.swift`. Keeping the factory surface
/// stable means the M5 UI does not have to change when the real
/// client is wired in — the only call site that flips is the
/// `MarketplaceBrowserViewModel` default, which the future
/// "switch to remote" commit will swap from
/// `MarketplaceClientFactory.makeStub()` to
/// `MarketplaceClientFactory.makeRemote(endpoint: …)`.
public enum MarketplaceClientFactory {
    /// Returns the deterministic in-memory client. Default for
    /// development builds and the v1 marketplace browser.
    public static func makeStub() -> MarketplaceClient {
        return StubMarketplaceClient()
    }

    /// Returns the real URLSession-backed client pointed at
    /// `endpoint`. The transport is injectable so tests can
    /// swap in a stub without touching the network. The default
    /// `URLSessionMarketplaceTransport()` wraps
    /// `URLSession.shared`.
    public static func makeRemote(
        endpoint: URL,
        transport: MarketplaceTransport = URLSessionMarketplaceTransport()
    ) -> MarketplaceClient {
        return RemoteMarketplaceClient(endpoint: endpoint, transport: transport)
    }
}

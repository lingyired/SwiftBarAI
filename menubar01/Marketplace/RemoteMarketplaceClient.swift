// RemoteMarketplaceClient.swift
// menubar01 — PluginMarketplace (M2 / M5 follow-up)
//
// URLSession-backed implementation of `MarketplaceClient` that
// fetches the catalogue and per-id packages from a remote
// endpoint. This is the M2 / M5 follow-up to the M4
// `StubMarketplaceClient`: the M5 `MarketplaceBrowserSheet`
// keeps using the stub by default, and switching the default
// to the remote client is a one-line change in
// `MarketplaceBrowserViewModel.init` once the production
// endpoint exists and signing is decided.
//
// Architecture:
//   The actual HTTP call goes through a `MarketplaceTransport`
//   protocol so tests can inject a stub that captures the
//   request and returns a canned response without ever
//   touching the network. The default
//   `URLSessionMarketplaceTransport` is what production code
//   uses; the test bundle uses a `StubMarketplaceTransport`
//   keyed by a per-test UUID.
//
// Wire format:
//   GET {endpoint}/v1/catalogue.json   → [MarketplaceEntry] JSON
//   GET {endpoint}/v1/packages/{id}.json → MarketplacePackage JSON
//
// Security:
//   * No auth in v1 — the client sends no `Authorization`
//     header, no API key, no signed URL. v2 will add bearer
//     auth mirroring `RemoteAIPluginGenerator` once the
//     marketplace Preferences pane is designed.
//   * No plain-text credential logging.
//
// M4 / M5 milestone references:
//   * M4 ships the data layer + the stub client (see
//     `MarketplaceClient.swift`).
//   * M5 ships the browser UI sheet
//     (`MarketplaceBrowserSheet`) and the install flow
//     (`MarketplaceInstallPromptSheet`).
//   * This file is the M2 / M5 follow-up that replaces the
//     stub at the call site once the real marketplace
//     endpoint is online. The factory at
//     `MarketplaceClientFactory.makeRemote(endpoint:transport:)`
//     is the supported switch point.

import Foundation
import os

// MARK: - MarketplaceTransport

/// Sends a `URLRequest` and returns the `(Data, URLResponse)`
/// pair. Production uses `URLSessionMarketplaceTransport`
/// (wrapping `URLSession`); tests use a stub implementation
/// that captures the request and returns a canned response
/// without touching the network.
///
/// Splitting the HTTP call behind a protocol keeps the client
/// hermetic for unit tests: Swift Testing's parallel execution
/// does not play nicely with per-session
/// `URLSessionConfiguration.protocolClasses` on macOS, and
/// `URLSession.shared` ignores globally-registered
/// `URLProtocol` subclasses for HTTPS. Routing through a
/// protocol sidesteps both issues — the same trick the
/// `RemoteTransport` / `RemoteAIPluginGenerator` pair uses.
public protocol MarketplaceTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production `MarketplaceTransport` that wraps `URLSession`.
public final class URLSessionMarketplaceTransport: MarketplaceTransport, @unchecked Sendable {
    public let urlSession: URLSession
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await urlSession.data(for: request)
    }
}

// MARK: - RemoteMarketplaceClient

/// Real remote-provider `MarketplaceClient` that fetches the
/// catalogue and per-id packages from the user-configured
/// endpoint and decodes the JSON bodies into the M4 data
/// types.
///
/// The endpoint is treated as a bare origin like
/// `https://marketplace.example.com` — the client appends
/// `/v1/catalogue.json` for the catalogue fetch and
/// `/v1/packages/{id}.json` for the package fetch. Endpoints
/// that already include a path are used as-is; trailing
/// slashes are normalised away so the appended paths land on
/// the origin root.
///
/// HTTP status codes map to `MarketplaceError` cases:
///   * 200…299 → continue to JSON decode.
///   * 404 → `.notFound(id: <id>)` (catalogue fetch: id is
///     empty).
///   * 401 / 403 → `.unauthorized`.
///   * 429 → `.rateLimited`.
///   * 500…599 → `.transportError(reason: "<status> <body>")`.
///   * other 4xx → `.providerFailure(reason: "<status> <body>")`.
///   * `URLError` thrown by `transport.send(_:)` →
///     `.transportError(reason: <localizedDescription>)`.
///   * decode failures → `.malformedResponse(reason: <…>)`.
public final class RemoteMarketplaceClient: MarketplaceClient {
    /// The remote endpoint URL the user picked in the future
    /// marketplace Preferences pane. Stored verbatim so tests
    /// can assert on the exact URL the client dials.
    public let endpoint: URL

    /// The transport used to perform the request. Defaults to
    /// `URLSessionMarketplaceTransport()` (which wraps
    /// `URLSession.shared`); tests inject a stub that returns
    /// a canned `(Data, URLResponse)` without touching the
    /// network.
    public let transport: MarketplaceTransport

    private static let log = OSLog(
        subsystem: "com.lingyi.menubar01",
        category: "Marketplace"
    )

    /// Build a real remote-provider marketplace client.
    ///
    /// - Parameters:
    ///   - endpoint: The user-configured endpoint URL. May be
    ///     a bare origin like
    ///     `https://marketplace.example.com` — the client
    ///     appends `/v1/catalogue.json` or
    ///     `/v1/packages/{id}.json` — or a fully-qualified
    ///     origin whose path ends in `/v1`, in which case the
    ///     client appends `catalogue.json` or
    ///     `packages/{id}.json`.
    ///   - transport: The transport used to perform the HTTP
    ///     call. Defaults to `URLSessionMarketplaceTransport()`.
    ///     Tests inject a stub transport that captures the
    ///     request and returns a canned response.
    public init(
        endpoint: URL,
        transport: MarketplaceTransport = URLSessionMarketplaceTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
        let host = endpoint.host ?? "<no-host>"
        os_log(
            "MarketplaceClient: RemoteMarketplace picked endpoint host=%{public}@",
            log: Self.log, type: .info, host
        )
    }

    public func fetchCatalogue() async throws -> [MarketplaceEntry] {
        let url = Self.catalogueURL(for: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw MarketplaceError.transportError(
                reason: error.localizedDescription
            )
        }
        try Self.assertSuccess(
            response: response,
            data: data,
            id: ""
            // 404 from a catalogue fetch is unusual but we
            // still surface it as `.notFound(id: "")` rather
            // than `.transportError` so the M5 browser can
            // distinguish "endpoint not configured yet" from
            // "endpoint is up but misbehaving".
        )

        let entries: [MarketplaceEntry]
        do {
            entries = try JSONDecoder().decode(
                [MarketplaceEntry].self,
                from: data
            )
        } catch {
            throw MarketplaceError.malformedResponse(
                reason: error.localizedDescription
            )
        }
        return entries
    }

    public func fetchPackage(id: String) async throws -> MarketplacePackage {
        let url = Self.packageURL(for: endpoint, id: id)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw MarketplaceError.transportError(
                reason: error.localizedDescription
            )
        }
        try Self.assertSuccess(
            response: response,
            data: data,
            id: id
        )

        let package: MarketplacePackage
        do {
            package = try JSONDecoder().decode(
                MarketplacePackage.self,
                from: data
            )
        } catch {
            throw MarketplaceError.malformedResponse(
                reason: error.localizedDescription
            )
        }
        return package
    }

    // MARK: - Helpers

    /// Maps an `HTTPURLResponse` to either a no-op (2xx) or a
    /// thrown `MarketplaceError`. The body is included in the
    /// error reason for 4xx / 5xx so the diagnostic dump shows
    /// the upstream server's own message verbatim; 2xx bodies
    /// are parsed by the caller, not here.
    private static func assertSuccess(
        response: URLResponse,
        data: Data,
        id: String
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceError.transportError(
                reason: "non-HTTP response"
            )
        }
        switch http.statusCode {
        case 200...299:
            return
        case 404:
            throw MarketplaceError.notFound(id: id)
        case 401, 403:
            throw MarketplaceError.unauthorized
        case 429:
            throw MarketplaceError.rateLimited
        case 500...599:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MarketplaceError.transportError(
                reason: "\(http.statusCode) \(body)"
            )
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MarketplaceError.providerFailure(
                reason: "\(http.statusCode) \(body)"
            )
        }
    }

    /// Resolves the catalogue URL. If the endpoint's path
    /// already ends in `/v1/catalogue.json`, the endpoint is
    /// used verbatim; otherwise `/v1/catalogue.json` is
    /// appended under the `v1/` segment. Exposed internally so
    /// the test can assert the same resolution the runtime
    /// uses without duplicating the rule.
    static func catalogueURL(for endpoint: URL) -> URL {
        let path = endpoint.path
        if path.hasSuffix("/v1/catalogue.json") {
            return endpoint
        }
        if path.isEmpty || path == "/" {
            return endpoint.appendingPathComponent("v1/catalogue.json")
        }
        if path.hasSuffix("/v1") {
            return endpoint.appendingPathComponent("catalogue.json")
        }
        return endpoint.appendingPathComponent("v1/catalogue.json")
    }

    /// Resolves the per-id package URL. Same rule as
    /// `catalogueURL(for:)`, with the appended path being
    /// `/v1/packages/{id}.json` (or `packages/{id}.json` when
    /// the endpoint already ends in `/v1`).
    static func packageURL(for endpoint: URL, id: String) -> URL {
        let path = endpoint.path
        if path.hasSuffix("/v1/packages") || path.hasSuffix("/v1/packages/") {
            return endpoint.appendingPathComponent("\(id).json")
        }
        if path.isEmpty || path == "/" {
            return endpoint.appendingPathComponent("v1/packages/\(id).json")
        }
        if path.hasSuffix("/v1") {
            return endpoint.appendingPathComponent("packages/\(id).json")
        }
        return endpoint.appendingPathComponent("v1/packages/\(id).json")
    }
}

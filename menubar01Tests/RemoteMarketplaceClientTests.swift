// RemoteMarketplaceClientTests.swift
// menubar01 — PluginMarketplace (M2 / M5 follow-up)
//
// Swift Testing coverage for the `MarketplaceTransport`-backed
// `RemoteMarketplaceClient`. The client's HTTP call goes
// through a `MarketplaceTransport` protocol (see
// `RemoteMarketplaceClient.swift`); the test bundle uses a
// `StubMarketplaceTransport` keyed by a per-test UUID, so:
//   * tests do not touch the network,
//   * tests are immune to Swift Testing's parallel execution
//     racing `URLSession` worker threads,
//   * the test surface is independent of the
//     `URLSessionConfiguration.protocolClasses` /
//     `URLProtocol.registerClass` quirks that the macOS
//     `URLSession` stack has had for HTTPS.
//
// Mirrors the test design used for
// `RemoteAIPluginGeneratorTests` (the AI module's
// URLSession-backed generator uses the same protocol route).

import Foundation
import Testing

@testable import menubar01

// MARK: - Stub transport

/// `MarketplaceTransport` that returns a pre-registered canned
/// response for a single request. Tests construct a fresh stub
/// per test and configure it with a single `(Data,
/// HTTPURLResponse)` pair. The stub is `@unchecked Sendable`
/// because the test framework creates the stub on the test's
/// thread and the client reads it on the URLSession worker
/// thread.
private final class StubMarketplaceTransport: MarketplaceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var response: (Data, URLResponse)?
    private var capturedRequest: URLRequest?

    init() {}

    /// Register the canned response.
    func register(data: Data, response: URLResponse) {
        lock.lock(); defer { lock.unlock() }
        self.response = (data, response)
    }

    /// The most recent `URLRequest` the client sent. Tests
    /// assert on URL, method, and headers without threading
    /// the value through the client's public API.
    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequest
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        self.capturedRequest = request
        let canned = self.response
        lock.unlock()
        guard let (data, response) = canned else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

// MARK: - Helpers

/// A canned `[MarketplaceEntry]` JSON body used by the
/// success-path catalogue test. Two entries exercise the
/// common shape (id, name, summary, category, installCount,
/// rating) without pulling in any optional fields that the
/// remote client does not need to decode.
private let validCatalogueJSON = """
[
  {
    "id": "echo",
    "name": "Echo",
    "summary": "Prints a single menu item from the plugin stdout.",
    "category": "tools",
    "installCount": 12,
    "rating": 4.5,
    "generatorPromptId": "demo.echo.v1"
  },
  {
    "id": "battery-watch",
    "name": "Battery Watch",
    "summary": "Live battery percentage and charging state.",
    "category": "system",
    "installCount": 97,
    "rating": 4.2,
    "generatorPromptId": "demo.battery.v1"
  }
]
"""

/// A canned `MarketplacePackage` JSON body used by the
/// success-path package test. Matches the wire format: id +
/// manifest object + entryScript + entryFilename.
private let validPackageJSON = """
{
  "id": "echo",
  "manifest": {
    "name": "Echo",
    "version": "1.0.0",
    "description": "Prints a single menu item from the plugin stdout.",
    "author": "remote marketplace",
    "type": "Executable",
    "entry": "echo.sh",
    "refreshInterval": 0
  },
  "entryScript": "#!/bin/zsh\\necho Echo | size=14 color=blue\\n",
  "entryFilename": "echo.sh"
}
"""

/// Returns a fresh `URL` whose path includes a UUID, so each
/// test's stub registration is independent of every other
/// test's even when the tests run in parallel.
private func makeUniqueEndpoint(
    host: String = "marketplace.example.com"
) -> URL {
    let uuid = UUID().uuidString
    return URL(string: "https://\(host)/\(uuid)")!
}

// MARK: - Catalogue: happy path

struct RemoteMarketplaceClientCatalogueHappyPathTests {

    @Test func testFetchCatalogue_decodesValidResponse() async throws {
        let transport = StubMarketplaceTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: RemoteMarketplaceClient.catalogueURL(for: endpoint),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        transport.register(
            data: Data(validCatalogueJSON.utf8),
            response: response
        )

        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        let entries = try await client.fetchCatalogue()

        #expect(entries.count == 2)
        #expect(entries[0].id == "echo")
        #expect(entries[1].id == "battery-watch")
        #expect(entries[0].name == "Echo")
        #expect(entries[0].category == "tools")
    }
}

// MARK: - Catalogue: error mapping

struct RemoteMarketplaceClientCatalogueErrorTests {

    @Test func testFetchCatalogue_throwsTransportErrorOn5xx() async throws {
        let transport = StubMarketplaceTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: RemoteMarketplaceClient.catalogueURL(for: endpoint),
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data("internal error".utf8),
            response: response
        )

        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        do {
            _ = try await client.fetchCatalogue()
            Issue.record("expected .transportError, got success")
        } catch let error as MarketplaceError {
            guard case .transportError(let reason) = error else {
                Issue.record("expected .transportError, got \(error)")
                return
            }
            #expect(reason.contains("500"))
            #expect(reason.contains("internal error"))
        }
    }

    @Test func testFetchCatalogue_throwsMalformedResponseOnBadJSON() async throws {
        let transport = StubMarketplaceTransport()
        let endpoint = makeUniqueEndpoint()
        let response = HTTPURLResponse(
            url: RemoteMarketplaceClient.catalogueURL(for: endpoint),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data("not valid json".utf8),
            response: response
        )

        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        do {
            _ = try await client.fetchCatalogue()
            Issue.record("expected .malformedResponse, got success")
        } catch let error as MarketplaceError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }
}

// MARK: - Package: happy path

struct RemoteMarketplaceClientPackageHappyPathTests {

    @Test func testFetchPackage_decodesValidResponse() async throws {
        let transport = StubMarketplaceTransport()
        let endpoint = makeUniqueEndpoint()
        let id = "echo"
        let response = HTTPURLResponse(
            url: RemoteMarketplaceClient.packageURL(for: endpoint, id: id),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        transport.register(
            data: Data(validPackageJSON.utf8),
            response: response
        )

        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        let package = try await client.fetchPackage(id: id)

        #expect(package.id == "echo")
        #expect(package.manifest.name == "Echo")
        #expect(package.manifest.entry == "echo.sh")
        #expect(package.entryScript.contains("echo Echo"))
        #expect(package.entryFilename == "echo.sh")
    }
}

// MARK: - Package: error mapping

struct RemoteMarketplaceClientPackageErrorTests {

    @Test func testFetchPackage_throwsNotFoundOn404() async throws {
        let transport = StubMarketplaceTransport()
        let endpoint = makeUniqueEndpoint()
        let id = "missing"
        let response = HTTPURLResponse(
            url: RemoteMarketplaceClient.packageURL(for: endpoint, id: id),
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data("not found".utf8),
            response: response
        )

        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        do {
            _ = try await client.fetchPackage(id: id)
            Issue.record("expected .notFound, got success")
        } catch let error as MarketplaceError {
            #expect(error == .notFound(id: id))
        }
    }

    @Test func testFetchPackage_throwsTransportErrorOnUnderlyingURLError() async throws {
        final class AlwaysFailTransport: MarketplaceTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
                throw URLError(.notConnectedToInternet)
            }
        }
        let transport = AlwaysFailTransport()
        let endpoint = makeUniqueEndpoint()
        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        do {
            _ = try await client.fetchPackage(id: "echo")
            Issue.record("expected .transportError, got success")
        } catch let error as MarketplaceError {
            // Assert the case is correct and the reason is
            // non-empty. The exact wording of the reason
            // comes from `URLError.localizedDescription`
            // which is system-language-dependent, so we
            // deliberately do not assert on specific
            // substrings.
            guard case .transportError(let reason) = error else {
                Issue.record("expected .transportError, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
        }
    }
}

// MARK: - Request shape

struct RemoteMarketplaceClientRequestShapeTests {

    @Test func testFetchPackage_postsCorrectRequestURL() async throws {
        let transport = StubMarketplaceTransport()
        let endpoint = makeUniqueEndpoint()
        let id = "battery-watch"
        let expectedURL = RemoteMarketplaceClient.packageURL(
            for: endpoint,
            id: id
        )
        let response = HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        transport.register(
            data: Data(validPackageJSON.utf8),
            response: response
        )

        let client = RemoteMarketplaceClient(
            endpoint: endpoint,
            transport: transport
        )
        _ = try await client.fetchPackage(id: id)

        let captured = try #require(transport.lastRequest)
        let actualURL = try #require(captured.url)
        // The endpoint the client dials is
        // `{endpoint}/v1/packages/{id}.json` (the catalogue-
        // and package-URL helpers append the versioned path
        // segment, so the absolute URL ends in
        // `/v1/packages/battery-watch.json`).
        #expect(actualURL.absoluteString == expectedURL.absoluteString)
        #expect(captured.httpMethod == "GET")
        #expect(actualURL.absoluteString.hasSuffix("/v1/packages/battery-watch.json"))
    }
}

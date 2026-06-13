import Foundation
import Testing

@testable import menubar01

// MARK: - Stub catalogue

struct MarketplaceCatalogueTests {
    @Test func testStubCatalogue_hasThreeEntries() async throws {
        let client = StubMarketplaceClient()
        let catalogue = try await client.fetchCatalogue()

        #expect(catalogue.count == StubMarketplaceClient.stubCatalogueCount)
        #expect(catalogue.count == 3)
        // All ids are unique — the install flow keys off `id` so a
        // duplicate would silently shadow the first entry.
        let uniqueIDs = Set(catalogue.map(\.id))
        #expect(uniqueIDs.count == catalogue.count)
    }

    @Test func testStubCatalogue_seededIdsArePresent() async throws {
        let client = StubMarketplaceClient()
        let catalogue = try await client.fetchCatalogue()

        let ids = Set(catalogue.map(\.id))
        #expect(ids.contains("echo"))
        #expect(ids.contains("todays-date"))
        #expect(ids.contains("battery-watch"))
    }
}

// MARK: - fetchPackage

struct MarketplaceFetchPackageTests {
    @Test func testStubFetchPackage_returnsMatchingEntry() async throws {
        let client = StubMarketplaceClient()
        let package = try await client.fetchPackage(id: "echo")

        #expect(package.id == "echo")
        #expect(!package.entryScript.isEmpty)
        #expect(package.manifest.name == "Echo")
    }

    @Test func testStubFetchPackage_todaysDateHasNonEmptyScript() async throws {
        let client = StubMarketplaceClient()
        let package = try await client.fetchPackage(id: "todays-date")

        #expect(package.id == "todays-date")
        #expect(package.entryScript.contains("#!/bin/zsh"))
        #expect(!package.entryFilename.isEmpty)
    }

    @Test func testStubFetchPackage_unknownId_throwsNotFound() async throws {
        let client = StubMarketplaceClient()

        do {
            _ = try await client.fetchPackage(id: "nope")
            Issue.record("Expected fetchPackage(id: \"nope\") to throw")
        } catch let error as MarketplaceError {
            // Expected: notFound("nope")
            #expect(error == .notFound(id: "nope"))
        } catch {
            Issue.record("Expected MarketplaceError, got \(error)")
        }
    }
}

// MARK: - MarketplaceInstaller.plan

struct MarketplaceInstallerPlanTests {
    @Test func testInstaller_planProducesSubfolderAndData() async throws {
        let client = StubMarketplaceClient()
        let entry = try #require(try await client.fetchCatalogue().first { $0.id == "battery-watch" })
        let package = try await client.fetchPackage(id: "battery-watch")

        let plan = try MarketplaceInstaller.plan(entry: entry, package: package)

        #expect(plan.targetSubfolder == "_marketplace")
        #expect(plan.entryFilename.hasSuffix(".sh") || plan.entryFilename.hasSuffix(".zsh"))
        #expect(!plan.manifestData.isEmpty)
        #expect(!plan.entryData.isEmpty)
        #expect(plan.overwriteExisting == false)
    }

    @Test func testInstaller_planOverwriteFlagIsPropagated() async throws {
        let client = StubMarketplaceClient()
        let entry = try #require(try await client.fetchCatalogue().first { $0.id == "echo" })
        let package = try await client.fetchPackage(id: "echo")

        let plan = try MarketplaceInstaller.plan(entry: entry, package: package, overwriteExisting: true)

        #expect(plan.overwriteExisting == true)
    }

    @Test func testInstaller_planRejectsMismatchedIds() async throws {
        let client = StubMarketplaceClient()
        let entry = try #require(try await client.fetchCatalogue().first { $0.id == "echo" })
        // Intentionally fetch a *different* package to force the
        // id mismatch path.
        let wrongPackage = try await client.fetchPackage(id: "todays-date")

        do {
            _ = try MarketplaceInstaller.plan(entry: entry, package: wrongPackage)
            Issue.record("Expected plan(entry, wrongPackage) to throw")
        } catch let error as MarketplaceError {
            // The mismatched id is reported against the *entry*'s id
            // because the entry is what the user picked; the package
            // is treated as the missing piece.
            #expect(error == .notFound(id: "echo"))
        } catch {
            Issue.record("Expected MarketplaceError, got \(error)")
        }
    }
}

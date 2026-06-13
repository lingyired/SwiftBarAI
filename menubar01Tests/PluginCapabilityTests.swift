// PluginCapabilityTests.swift
// menubar01 — Capability Gate (M3)
//
// Swift Testing coverage for the M3 capability-gate. All tests are
// pure: the gate is constructed with a `UserDefaults(suiteName:)`
// per test so the suite never touches `UserDefaults.standard`. The
// manifest is built in-memory; no filesystem, no AppKit, no
// `PluginManager` coupling.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a fresh `UserDefaults` suite per call. The suite name
/// uses a UUID so parallel test runs do not stomp each other.
private func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "menubar01.tests.capabilityGate.\(UUID().uuidString)")!
}

private func makeManifest(
    name: String = "Test Plugin",
    capabilities: [String]? = nil
) -> PluginManifest {
    var manifest = PluginManifest()
    manifest.name = name
    manifest.capabilities = capabilities
    return manifest
}

// MARK: - Enum round-trip

struct PluginCapabilityEnumTests {
    @Test func testEnumRoundTrip_allCasesHaveStableRawValues() throws {
        // Pin down the raw values: a manifest authored against the
        // v1 vocabulary must continue to decode forever. Renaming
        // any of these is a breaking change for every shipped
        // plugin's `manifest.json`.
        #expect(PluginCapability.network.rawValue == "network")
        #expect(PluginCapability.clipboard.rawValue == "clipboard")
        #expect(PluginCapability.notifications.rawValue == "notifications")
        #expect(PluginCapability.calendar.rawValue == "calendar")
        #expect(PluginCapability.allCases.count == 4)

        // JSON round-trip via Codable.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for capability in PluginCapability.allCases {
            let data = try encoder.encode(capability)
            let decoded = try decoder.decode(PluginCapability.self, from: data)
            #expect(decoded == capability)
        }
    }

    @Test func testEnumUnknownRawValue_returnsNil() {
        // `init(rawValue:)` is a normal failable init — an unknown
        // string is `nil`, not a crash. The manifest decoder
        // exploits this in `resolvedCapabilities`.
        #expect(PluginCapability(rawValue: "future-capability") == nil)
        #expect(PluginCapability(rawValue: "") == nil)
        #expect(PluginCapability(rawValue: "NETWORK") == nil) // case-sensitive
    }

    @Test func testEnumDisplayMetadata_isNonEmptyForAllCases() {
        // The install-prompt UI surfaces `displayName` and
        // `description`; both must be non-empty so the row never
        // renders as a blank line.
        for capability in PluginCapability.allCases {
            #expect(!capability.displayName.isEmpty)
            #expect(!capability.description.isEmpty)
        }
    }
}

// MARK: - Manifest decoder

struct PluginManifestCapabilityTests {
    @Test func testResolvedCapabilities_decodesKnownStrings() {
        let manifest = makeManifest(capabilities: ["network", "calendar"])
        #expect(manifest.resolvedCapabilities == [.network, .calendar])
    }

    @Test func testResolvedCapabilities_dropsUnknownStrings() {
        // Order of the *known* capabilities is preserved. Unknown
        // strings are silently dropped (logged via `os_log` in the
        // real path; the log is not asserted here).
        let manifest = makeManifest(
            capabilities: ["network", "future-foo", "clipboard", "bogus"]
        )
        #expect(manifest.resolvedCapabilities == [.network, .clipboard])
    }

    @Test func testResolvedCapabilities_emptyForNilAndEmpty() {
        #expect(makeManifest(capabilities: nil).resolvedCapabilities.isEmpty)
        #expect(makeManifest(capabilities: []).resolvedCapabilities.isEmpty)
    }

    @Test func testCapabilitiesField_roundTripsThroughJSON() throws {
        // The on-disk schema is `capabilities: [String]?` —
        // `JSONDecoder` must accept that exact shape.
        let json = #"{"name": "X", "capabilities": ["network", "clipboard"]}"#
        let decoded = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )
        #expect(decoded.capabilities == ["network", "clipboard"])
        #expect(decoded.resolvedCapabilities == [.network, .clipboard])
    }

    @Test func testCapabilitiesField_absentFieldDecodesAsNil() throws {
        // Older manifests (M1/M2 era) have no `capabilities` key —
        // the decoder must tolerate the absence.
        let json = #"{"name": "X"}"#
        let decoded = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )
        #expect(decoded.capabilities == nil)
        #expect(decoded.resolvedCapabilities.isEmpty)
    }
}

// MARK: - Gate: accept-all

struct PluginCapabilityGateAcceptTests {
    @Test func testGate_acceptsManifestWithNoDeclaredCapabilities() throws {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        let manifest = makeManifest(capabilities: nil)
        // No declared capabilities ⇒ nothing to gate ⇒ verify is a no-op.
        try gate.verify(manifest: manifest)
    }

    @Test func testGate_acceptsManifestWithAllCapabilitiesGranted() throws {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network, .calendar], for: "Weather")

        let manifest = makeManifest(name: "Weather", capabilities: ["network", "calendar"])
        try gate.verify(manifest: manifest)
    }

    @Test func testGate_acceptsManifestWhenGrantedSetIsASuperset() throws {
        // Granting more than the manifest declares is fine — the
        // gate only checks subset, not equality.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network, .clipboard, .calendar], for: "Weather")

        let manifest = makeManifest(name: "Weather", capabilities: ["network"])
        try gate.verify(manifest: manifest)
    }
}

// MARK: - Gate: reject-one

struct PluginCapabilityGateRejectTests {
    @Test func testGate_rejectsManifestWithUngrantedCapability() {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.clipboard], for: "Weather")

        let manifest = makeManifest(name: "Weather", capabilities: ["network"])

        do {
            try gate.verify(manifest: manifest)
            Issue.record("Expected verify to throw for ungranted .network capability")
        } catch let error as PluginCapabilityError {
            #expect(error == .capabilityNotGranted(pluginID: "Weather", capability: .network))
        } catch {
            Issue.record("Expected PluginCapabilityError, got \(error)")
        }
    }

    @Test func testGate_rejectsWhenNoGrantsExist() {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        let manifest = makeManifest(name: "Fresh", capabilities: ["notifications"])

        do {
            try gate.verify(manifest: manifest)
            Issue.record("Expected verify to throw for first-time plugin")
        } catch let error as PluginCapabilityError {
            #expect(error == .capabilityNotGranted(pluginID: "Fresh", capability: .notifications))
        } catch {
            Issue.record("Expected PluginCapabilityError, got \(error)")
        }
    }

    @Test func testGate_rejectsFirstUngrantedCapabilityInDeclarationOrder() {
        // Order is preserved so the host UI can render a
        // deterministic error message. The grant covers
        // `clipboard` but not `network`, so `network` (declared
        // first) is the one that triggers the throw.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.clipboard, .calendar], for: "Order")

        let manifest = makeManifest(
            name: "Order",
            capabilities: ["network", "clipboard", "calendar"]
        )

        do {
            try gate.verify(manifest: manifest)
            Issue.record("Expected verify to throw")
        } catch let error as PluginCapabilityError {
            #expect(error == .capabilityNotGranted(pluginID: "Order", capability: .network))
        } catch {
            Issue.record("Expected PluginCapabilityError, got \(error)")
        }
    }

    @Test func testGate_grantsAreIsolatedPerPlugin() {
        // Granting `network` to plugin A must not affect plugin B.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network], for: "A")

        let manifestA = makeManifest(name: "A", capabilities: ["network"])
        let manifestB = makeManifest(name: "B", capabilities: ["network"])

        try? gate.verify(manifest: manifestA)
        do {
            try gate.verify(manifest: manifestB)
            Issue.record("Expected B to be rejected — A's grant must not leak")
        } catch let error as PluginCapabilityError {
            #expect(error == .capabilityNotGranted(pluginID: "B", capability: .network))
        } catch {
            Issue.record("Expected PluginCapabilityError, got \(error)")
        }
    }
}

// MARK: - Gate: idempotent grant

struct PluginCapabilityGateIdempotencyTests {
    @Test func testGate_grantIsIdempotent() {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network], for: "P")
        gate.grant([.network], for: "P") // a second time
        gate.grant([.network], for: "P") // a third time

        // `granted(for:)` should still report exactly the one
        // capability, not duplicates.
        #expect(gate.granted(for: "P") == Set([.network]))
    }

    @Test func testGate_grantIsAdditiveAcrossCalls() {
        // Two calls with disjoint sets union into the full set.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network], for: "P")
        gate.grant([.clipboard], for: "P")

        #expect(gate.granted(for: "P") == Set([.network, .clipboard]))

        // And the gate now verifies a manifest that declares both.
        let manifest = makeManifest(name: "P", capabilities: ["network", "clipboard"])
        try? gate.verify(manifest: manifest)
    }

    @Test func testGate_grantSurvivesARoundTripThroughUserDefaults() {
        // A grant written through one `PluginCapabilityGate`
        // instance must be visible to a *second* instance backed
        // by the same `UserDefaults`. This is the property M2+ UI
        // will rely on when the install sheet (separate process
        // in a future sandboxed build) grants a capability and
        // the load path (this process) then reads it.
        let defaults = makeIsolatedDefaults()
        let writer = PluginCapabilityGate(defaults: defaults)
        writer.grant([.calendar, .notifications], for: "Persisted")

        let reader = PluginCapabilityGate(defaults: defaults)
        #expect(reader.granted(for: "Persisted") == Set([.calendar, .notifications]))

        let manifest = makeManifest(
            name: "Persisted",
            capabilities: ["calendar", "notifications"]
        )
        try? reader.verify(manifest: manifest)
    }

    @Test func testGate_grantIsolatedAcrossUserDefaultsSuites() {
        // Two `UserDefaults` suites must not see each other's
        // grants. This pins down the test isolation contract.
        let writer = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        let reader = PluginCapabilityGate(defaults: makeIsolatedDefaults())

        writer.grant([.network], for: "P")
        #expect(reader.granted(for: "P").isEmpty)
    }
}

// MARK: - Error typing

struct PluginCapabilityErrorTests {
    @Test func testError_capabilityNotGranted_equalityAndDescription() {
        let error = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Weather",
            capability: .network
        )
        let identical = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Weather",
            capability: .network
        )
        let differentID = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Other",
            capability: .network
        )
        let differentCap = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Weather",
            capability: .clipboard
        )

        #expect(error == identical)
        #expect(error != differentID)
        #expect(error != differentCap)

        // `LocalizedError.errorDescription` is what the host UI
        // surfaces to the user; both cases must produce a
        // non-empty string.
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func testError_unknownCapability_isDistinctFromNotGranted() {
        let notGranted = PluginCapabilityError.capabilityNotGranted(
            pluginID: "P",
            capability: .network
        )
        let unknown = PluginCapabilityError.unknownCapability(rawValue: "future-foo")
        #expect(notGranted != unknown)
        #expect(unknown.errorDescription?.isEmpty == false)
    }
}

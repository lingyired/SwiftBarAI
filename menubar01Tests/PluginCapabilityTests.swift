// PluginCapabilityTests.swift
// menubar01 — Capability Gate (M3, extended)
//
// Swift Testing coverage for the M3 capability-gate and the
// 2026-06-13 extension that adds richer capability shapes
// (`.network(hosts:)`, `.fileWrite(paths:)`, the new
// `isGrantedByDefault` accessor, and the dual-format manifest
// decoder). All tests are pure: the gate is constructed with a
// `UserDefaults(suiteName:)` per test so the suite never touches
// `UserDefaults.standard`. The manifest is built in-memory; no
// filesystem, no AppKit, no `PluginManager` coupling.

import Foundation
import Testing

@testable import menubar01

// MARK: - Helpers

/// Builds a fresh `UserDefaults` suite per call. The suite name
/// uses a UUID so parallel test runs do not stomp each other.
private func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "menubar01.tests.capabilityGate.\(UUID().uuidString)")!
}

/// Build a manifest whose `capabilities` field carries the
/// given descriptor list. The v1 wire-format shim
/// (`PluginCapabilityDescriptor`) accepts both the bare-string
/// form and the object form, so this helper is the single
/// place the v1 string-array shorthand still appears in
/// the test suite. Unknown strings are passed through as
/// `nil` descriptors (matching the on-disk decoder's
/// lenient behaviour); the helper does **not** filter
/// them so the test can verify the decoder's behaviour.
private func makeManifest(
    name: String = "Test Plugin",
    capabilities: [String]? = nil
) -> PluginManifest {
    var manifest = PluginManifest()
    manifest.name = name
    if let capabilities {
        manifest.capabilities = capabilities.map { raw in
            switch raw {
            case "network": return .init(capability: .network(hosts: []))
            case "clipboard": return .init(capability: .clipboard)
            case "notifications": return .init(capability: .notifications)
            case "calendar": return .init(capability: .calendar)
            case "fileWrite": return .init(capability: .fileWrite(paths: []))
            default:
                // Unknown string — pass through as a
                // nil-capability descriptor to mirror the
                // lenient on-disk decoder. The
                // `resolvedCapabilities` accessor filters
                // these out.
                return .init(capability: nil)
            }
        }
    }
    return manifest
}

// MARK: - Enum round-trip

struct PluginCapabilityEnumTests {
    @Test func testEnumAllCases_isExactlyFive() {
        // Pin down the v1.1 case set: the four legacy cases
        // (`network`, `clipboard`, `notifications`, `calendar`)
        // plus the new `fileWrite` capability. `network` is
        // now a case with an associated value so it still
        // counts as one case in `allCases`.
        #expect(PluginCapability.allCases.count == 5)
        #expect(PluginCapability.allCases.contains(.clipboard))
        #expect(PluginCapability.allCases.contains(.notifications))
        #expect(PluginCapability.allCases.contains(.calendar))
        #expect(PluginCapability.allCases.contains(.fileWrite(paths: [])))
        #expect(PluginCapability.allCases.contains(.network(hosts: [])))
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

    @Test func testEnumIsGrantedByDefault_clipboardIsTrueOthersAreFalse() {
        // v1.1 (2026-06-13 install-gate follow-up) refines
        // the `isGrantedByDefault` policy: `clipboard` is
        // treated as implicitly granted because any foreground
        // macOS app can read `NSPasteboard.general` without an
        // entitlement, so showing a prompt row would just be
        // noise. The other four cases (network, notifications,
        // calendar, fileWrite) all require explicit consent —
        // the install-prompt sheet must surface them so the
        // user can opt in per plugin.
        #expect(PluginCapability.clipboard.isGrantedByDefault == true)
        #expect(PluginCapability.network(hosts: []).isGrantedByDefault == false)
        #expect(PluginCapability.notifications.isGrantedByDefault == false)
        #expect(PluginCapability.calendar.isGrantedByDefault == false)
        #expect(PluginCapability.fileWrite(paths: []).isGrantedByDefault == false)
    }

    @Test func testEnumCodable_objectFormRoundTrips() throws {
        // The wire format for an enum with associated values
        // is a keyed object: `{"type": "network", "hosts":
        // [...]}`. Round-trip each case to pin down the shape
        // — a future refactor that flips the encoder to the
        // string form would break the gate's store.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let cases: [PluginCapability] = [
            .network(hosts: ["api.openai.com", "api.anthropic.com"]),
            .clipboard,
            .notifications,
            .calendar,
            .fileWrite(paths: ["~/Library/Logs/plugin.log"])
        ]
        for capability in cases {
            let data = try encoder.encode(capability)
            let decoded = try decoder.decode(PluginCapability.self, from: data)
            #expect(decoded == capability)
        }
    }
}

// MARK: - Manifest decoder

struct PluginManifestCapabilityTests {
    @Test func testResolvedCapabilities_decodesKnownStrings() {
        // V1 form: `["network", "calendar"]` (bare strings).
        // Each string decodes to the modern case with empty
        // associated values.
        let manifest = makeManifest(capabilities: ["network", "calendar"])
        #expect(manifest.resolvedCapabilities == [
            .network(hosts: []),
            .calendar
        ])
    }

    @Test func testResolvedCapabilities_decodesObjectForm() {
        // V1.1 form: array of `{type, ...}` objects. The
        // `hosts` list flows through into the enum's
        // associated value.
        let json = #"""
        {
          "name": "Weather",
          "capabilities": [
            {"type": "network", "hosts": ["api.openai.com"]},
            {"type": "calendar"}
          ]
        }
        """#
        let manifest = try! JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.resolvedCapabilities == [
            .network(hosts: ["api.openai.com"]),
            .calendar
        ])
    }

    @Test func testResolvedCapabilities_decodesMixedForms() {
        // A manifest may mix the two forms (the descriptor
        // is per-element, not per-array). The v1 string form
        // and the v1.1 object form must both be accepted in
        // the same `capabilities` array.
        let json = #"""
        {
          "name": "Mixed",
          "capabilities": [
            "notifications",
            {"type": "fileWrite", "paths": ["~/Library/Logs/x.log"]}
          ]
        }
        """#
        let manifest = try! JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.resolvedCapabilities == [
            .notifications,
            .fileWrite(paths: ["~/Library/Logs/x.log"])
        ])
    }

    @Test func testResolvedCapabilities_dropsUnknownStrings() {
        // The v1 decoder silently dropped unknown strings;
        // the v1.1 descriptor decoder preserves that
        // behaviour so a manifest authored by a future
        // build of menubar01 (with new capabilities the
        // current build does not know about) still loads.
        // The `os_log` warning is the observable signal;
        // here we just verify the resolved list contains
        // the known entries.
        let manifest = makeManifest(capabilities: ["network", "future-foo", "clipboard"])
        #expect(manifest.resolvedCapabilities == [
            .network(hosts: []),
            .clipboard
        ])
    }

    @Test func testResolvedCapabilities_emptyForNilAndEmpty() {
        #expect(makeManifest(capabilities: nil).resolvedCapabilities.isEmpty)
        #expect(makeManifest(capabilities: []).resolvedCapabilities.isEmpty)
    }

    @Test func testCapabilitiesField_roundTripsThroughJSON() throws {
        // The v1 string-array form (`["network", "clipboard"]`)
        // must continue to decode — every shipped manifest
        // uses this form, so the v1.1 extension is additive,
        // not breaking, on the input side.
        let json = #"{"name": "X", "capabilities": ["network", "clipboard"]}"#
        let decoded = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )
        // The descriptor wrapper owns the value; the
        // resolved list is the observable surface.
        #expect(decoded.resolvedCapabilities == [
            .network(hosts: []),
            .clipboard
        ])
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
        gate.grant([.network(hosts: []), .calendar], for: "Weather")

        let manifest = makeManifest(name: "Weather", capabilities: ["network", "calendar"])
        try gate.verify(manifest: manifest)
    }

    @Test func testGate_acceptsManifestWhenGrantedSetIsASuperset() throws {
        // Granting more than the manifest declares is fine — the
        // gate only checks subset, not equality.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network(hosts: []), .clipboard, .calendar], for: "Weather")

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
            #expect(error == .capabilityNotGranted(
                pluginID: "Weather",
                capability: .network(hosts: [])
            ))
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
            #expect(error == .capabilityNotGranted(
                pluginID: "Fresh",
                capability: .notifications
            ))
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
            #expect(error == .capabilityNotGranted(
                pluginID: "Order",
                capability: .network(hosts: [])
            ))
        } catch {
            Issue.record("Expected PluginCapabilityError, got \(error)")
        }
    }

    @Test func testGate_grantsAreIsolatedPerPlugin() {
        // Granting `network` to plugin A must not affect plugin B.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network(hosts: [])], for: "A")

        let manifestA = makeManifest(name: "A", capabilities: ["network"])
        let manifestB = makeManifest(name: "B", capabilities: ["network"])

        try? gate.verify(manifest: manifestA)
        do {
            try gate.verify(manifest: manifestB)
            Issue.record("Expected B to be rejected — A's grant must not leak")
        } catch let error as PluginCapabilityError {
            #expect(error == .capabilityNotGranted(
                pluginID: "B",
                capability: .network(hosts: [])
            ))
        } catch {
            Issue.record("Expected PluginCapabilityError, got \(error)")
        }
    }
}

// MARK: - Gate: idempotent grant

struct PluginCapabilityGateIdempotencyTests {
    @Test func testGate_grantIsIdempotent() {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network(hosts: [])], for: "P")
        gate.grant([.network(hosts: [])], for: "P") // a second time
        gate.grant([.network(hosts: [])], for: "P") // a third time

        // `granted(for:)` should still report exactly the one
        // capability, not duplicates.
        #expect(gate.granted(for: "P") == Set([.network(hosts: [])]))
    }

    @Test func testGate_grantIsAdditiveAcrossCalls() {
        // Two calls with disjoint sets union into the full set.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network(hosts: [])], for: "P")
        gate.grant([.clipboard], for: "P")

        #expect(gate.granted(for: "P") == Set([.network(hosts: []), .clipboard]))

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

        writer.grant([.network(hosts: [])], for: "P")
        #expect(reader.granted(for: "P").isEmpty)
    }
}

// MARK: - New (2026-06-13) capabilities

struct PluginCapabilityNetworkTests {
    @Test func testNetwork_capabilityHasDisplayName() {
        // The display name surfaces the host list so the
        // install-prompt sheet can show the user exactly
        // which domains the plugin is going to talk to.
        let cap = PluginCapability.network(hosts: ["api.openai.com"])
        #expect(cap.displayName.contains("api.openai.com") || cap.displayName.contains("Network"))
    }

    @Test func testNetwork_capabilityIsNotGrantedByDefault() {
        // Network access must always require explicit user
        // consent — there's no entitlement / Info.plist
        // string that implicitly grants it.
        #expect(PluginCapability.network(hosts: []).isGrantedByDefault == false)
        #expect(PluginCapability.network(hosts: ["a.com"]).isGrantedByDefault == false)
    }
}

struct PluginCapabilityFileWriteTests {
    @Test func testFileWrite_capabilityHasDisplayName() {
        let cap = PluginCapability.fileWrite(paths: ["~/Library/Logs/plugin.log"])
        #expect(cap.displayName.contains("plugin.log") || cap.displayName.contains("Write"))
    }

    @Test func testFileWrite_capabilityIsNotGrantedByDefault() {
        #expect(PluginCapability.fileWrite(paths: []).isGrantedByDefault == false)
        #expect(PluginCapability.fileWrite(paths: ["a.log"]).isGrantedByDefault == false)
    }
}

struct PluginCapabilityNotificationsTests {
    @Test func testNotifications_capabilityHasDisplayName() {
        #expect(PluginCapability.notifications.displayName == "Notifications")
    }

    @Test func testNotifications_capabilityIsNotGrantedByDefault() {
        // Even though macOS has the system-level Notifications
        // preference, the per-plugin grant is still recorded
        // in the gate — the user must opt in per plugin.
        #expect(PluginCapability.notifications.isGrantedByDefault == false)
    }
}

struct PluginCapabilityGateGrantTests {
    @Test func testGate_grantNetwork_addsToGrantedSet() {
        // The grant is keyed on the *whole* capability value
        // — granting `network(hosts: ["a.com"])` does NOT
        // automatically grant `network(hosts: ["b.com"])`.
        // The install-prompt sheet is responsible for asking
        // for each declared shape explicitly.
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.network(hosts: ["api.openai.com"])], for: "plugin-name")
        #expect(gate.isGranted(.network(hosts: ["api.openai.com"]), for: "plugin-name"))
    }

    @Test func testGate_grantFileWrite_addsToGrantedSet() {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.fileWrite(paths: ["~/Library/Logs/plugin.log"])], for: "plugin-name")
        #expect(gate.isGranted(
            .fileWrite(paths: ["~/Library/Logs/plugin.log"]),
            for: "plugin-name"
        ))
    }

    @Test func testGate_grantNotifications_addsToGrantedSet() {
        let gate = PluginCapabilityGate(defaults: makeIsolatedDefaults())
        gate.grant([.notifications], for: "plugin-name")
        #expect(gate.isGranted(.notifications, for: "plugin-name"))
    }
}

// MARK: - Error typing

struct PluginCapabilityErrorTests {
    @Test func testError_capabilityNotGranted_equalityAndDescription() {
        let error = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Weather",
            capability: .network(hosts: [])
        )
        let identical = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Weather",
            capability: .network(hosts: [])
        )
        let differentID = PluginCapabilityError.capabilityNotGranted(
            pluginID: "Other",
            capability: .network(hosts: [])
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
            capability: .network(hosts: [])
        )
        let unknown = PluginCapabilityError.unknownCapability(rawValue: "future-foo")
        #expect(notGranted != unknown)
        #expect(unknown.errorDescription?.isEmpty == false)
    }
}

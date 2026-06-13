# 2026-06-13: M3 capability-gate install flow

- **Type:** feat
- **Scope:** `menubar01/Plugin/`, `menubar01Tests/`, `docs/`
- **Author(s):** Trae AI
- **Commit(s):** TBD
- **Status:** in-progress

## Summary

Implements M3 of [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §6: the
capability-gate install flow. A new `PluginCapability` enum is the
canonical vocabulary (§3), a `PluginCapabilityGate` enforces it at the
load boundary, and a new `capabilities` field on `PluginManifest` carries
the plugin's declaration. No UI lands in M3; M2 owns the install-prompt
sheet and calls `gate.grant(_:for:)` once the user accepts.

## Motivation

`AI_PLUGIN_ARCHITECTURE.md` §6 lists M3 as *"Capability-gate install
flow"* with `PluginManager.importPlugin` as the existing dependency.
The gate must exist before the M2 install-prompt sheet can wire
`gate.grant(...)` into the user-acceptance step, and the manifest
field must exist before the gate has anything to verify.

The design note [`docs/M3-capability-gate.md`](../docs/M3-capability-gate.md)
captures the full motivation, the v1 capability set, and the
*"drop unknown with log"* vs. *"throw"* decision.

## Changes

- `menubar01/Plugin/PluginCapabilities.swift`: new.
  - `public enum PluginCapability: String, Codable, CaseIterable, Equatable, Sendable`
    with the v1 vocabulary: `.network`, `.clipboard`, `.notifications`,
    `.calendar`.
  - `displayName: String` and `description: String` for the
    install-prompt UI.
- `menubar01/Plugin/PluginCapabilityError.swift`: new.
  - `public enum PluginCapabilityError: Error, Equatable, Sendable`
    with `.capabilityNotGranted(pluginID:capability:)` and
    `.unknownCapability(rawValue:)`.
  - `LocalizedError` conformance for the host UI.
- `menubar01/Plugin/PluginCapabilityGate.swift`: new.
  - `public struct PluginCapabilityGate` — `init(defaults: UserDefaults = .standard)`,
    `grant(_:for:)`, `granted(for:)`, `verify(manifest:) throws`.
    Intentionally **not** `Sendable`: `UserDefaults` is not
    `Sendable` in Swift 6, and `PreferencesStore` (the closest
    precedent) is also a non-`Sendable` class for the same reason.
  - `UserDefaults`-backed `[PluginID: Set<PluginCapability>]` store
    under key `PluginCapabilityGate.grants.v1`. The init accepts an
    injected `UserDefaults` so tests can pass a
    `UserDefaults(suiteName:)` for isolation (same DI pattern as
    `PreferencesStore` in commit 4e1fc52).
- `menubar01/Plugin/PluginManifest.swift:78-82,92,118,144,203-223`:
  - Added `var capabilities: [String]?` field with
    `CodingKeys` / `init(from:)` / `encode(to:)` wiring.
  - Added `var resolvedCapabilities: [PluginCapability]` computed
    property in the existing `PluginManifest` extension.
    Each raw string is mapped through `PluginCapability(rawValue:)`
    and unknown values are **dropped with an `os_log` warning** (not
    thrown), so manifests from future builds of menubar01 still load.
- `menubar01/Plugin/PluginManger.swift:335-339,806-837`:
  - Added `let pluginCapabilityGate = PluginCapabilityGate()` stored
    property on `PluginManager` (matches the `prefs` injection
    pattern from commit 4e1fc52).
  - Updated `loadPlugin(fileURL:)` to load the manifest, call
    `try pluginCapabilityGate.verify(manifest:)`, and only then
    hand the manifest to `FolderPlugin.init(manifestDirectory:manifest:)`.
    A throw is caught and logged, returning `nil` so the
    `syncFilePlugins` pipeline filters the plugin out — the existing
    error path in `getLoadablePluginList` then ensures it never
    appears in the status bar.
- `menubar01Tests/PluginCapabilityTests.swift`: new. 22 Swift
  Testing tests in 5 suites covering enum round-trip, manifest
  decoder drop-unknown semantics, gate accept-all / reject-one /
  per-plugin isolation, idempotent grant, cross-instance round-trip
  through `UserDefaults`, and `PluginCapabilityError` equality +
  `LocalizedError` surface.
- `docs/M3-capability-gate.md`: new design note (≤80 LoC)
  quoting the §3 / §6 references, listing the v1 capability set and
  the gate's policy, and explaining the *"drop unknown with log"*
  vs. *"throw"* decision.
- `changes/2026-06-13-m3-capability-gate.md`: this record.

## Impact

- **New public types:** `PluginCapability`, `PluginCapabilityError`,
  `PluginCapabilityGate`. All live in `menubar01/Plugin/` and follow
  the existing module-naming convention (no `package` keyword, bare
  `Foundation` / `os` imports).
- **New manifest field:** `capabilities: [String]?` — optional, so
  every pre-M3 manifest continues to decode unchanged. The decoder
  is permissive on input and the encoder omits `nil`/empty arrays
  via `encodeIfPresent`.
- **No user-visible behaviour change** at the v1 surface (the UI
  sheet for granting does not exist yet — that's M2). The change
  is observable to plugins whose `manifest.json` declares a
  capability without the user having accepted it: they are silently
  filtered out of the menu bar. This is the "missing permission"
  behaviour §3 promises and matches the existing `loadPlugins`
  contract.
- **No new entitlements, no new dependencies, no new URL scheme
  handlers.** The `menubar01.entitlements` file already grants
  `com.apple.security.network.client`; `NSCalendarsUsageDescription`
  is already in `Info.plist`. The clipboard and notifications gates
  record the grant but do not yet call into `NSPasteboard` /
  `UNUserNotificationCenter` — those calls live in the future
  install-prompt sheet.

## Testing

- 22 new unit tests in `menubar01Tests/PluginCapabilityTests.swift`,
  pure (no filesystem, no networking, no `PluginManager` coupling).
  Every test that touches `UserDefaults` constructs a fresh
  `UserDefaults(suiteName: "menubar01.tests.capabilityGate.<UUID>")`
  so the suite cannot contaminate `UserDefaults.standard` or
  other tests in the run.
- Verification: `xcodebuild … build-for-testing` reports 0 errors
  after the M3 sources are registered. Full `xcodebuild test` will
  be run by the main agent after the pbxproj is updated.
- Compile-time notes that informed the implementation:
  - `PluginCapabilityGate.verify(manifest:)` derives the per-plugin
    key from `manifest.name` (with `"<unnamed>"` as a fallback for
    tests). The on-disk `id` lives on `FolderPlugin`, not
    `PluginManifest`, so the gate cannot use it without expanding
    the manifest's data model. M2's install sheet can call
    `gate.grant(_:for: manifest.name ?? ...)` using the same name the
    loader sees, keeping the keys consistent end-to-end.
  - `PluginCapabilityGate` is a `struct` (not a `class`) because it
    holds no mutable state — the `UserDefaults` instance is the
    source of truth.
- `PluginManifest.resolvedCapabilities` returns a `[PluginCapability]`
    (not a `Set`) so the gate's *"first ungranted capability wins"*
    rule is deterministic in declaration order. The unit test
    `testGate_rejectsFirstUngrantedCapabilityInDeclarationOrder`
    pins the order down.
- `Sendable` conformance is granted only where the compiler allows
    it: `PluginCapability` and `PluginCapabilityError` are
    `Sendable` (value-only types); the gate and the manifest are not
    (both transitively hold a non-`Sendable` `UserDefaults`).

## Related

- [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md) §3
  (the permission model this M3 implements) and §6 (the M3
  roadmap entry).
- Follow-up: M2 (the install-prompt sheet that calls
  `gate.grant(_:for:)`) and the marketplace install path (M4+).

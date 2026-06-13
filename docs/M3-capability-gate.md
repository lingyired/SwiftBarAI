# M3 — Capability-gate install flow

- **Type:** feat
- **Status:** in-progress
- **Commit(s):** TBD

## Summary

Implements the manifest → install-time capability gate for AI-generated
plugins. A `PluginCapability` enum is the canonical vocabulary, a
`PluginCapabilityGate` enforces it at the load boundary, and a new
`capabilities` field on `PluginManifest` carries the plugin's
declaration. No UI lands in M3.

## Motivation

Quotes from [`AI_PLUGIN_ARCHITECTURE.md`](../AI_PLUGIN_ARCHITECTURE.md):

> ### §3 — *"If a generated plugin requests more capabilities than the
> user approves at install time, the runtime refuses to spawn it and
> shows a clear 'missing permission' error in the status bar fallback."*

> ### §6 M3 — *"Capability-gate install flow. Existing dependency:
> `PluginManager.importPlugin`."*

## v1 vocabulary

| Raw value | Gate policy | Backing |
| --- | --- | --- |
| `network` | ask once at install, persist grant | `menubar01.entitlements` (present) |
| `clipboard` | ask once at install, persist grant | (new) |
| `notifications` | `UNUserNotificationCenter.requestAuthorization` at install | (new) |
| `calendar` | ask once at install, persist grant | `NSCalendarsUsageDescription` (present) |

## Manifest field

```swift
var capabilities: [String]?
```

Raw strings match the on-disk schema verbatim. Resolution goes through
`PluginCapability(rawValue:)`; **unknown strings are dropped with an
`os_log` warning**, *not* thrown — manifests from future builds (or
typo'd ones) must still load. The test
`testResolvedCapabilities_dropsUnknownStrings` pins the contract.

This is the inverse of the gate's **runtime** stance: a missing
capability at load time is a hard `throw .capabilityNotGranted`; an
*unknown* string in the manifest is a soft drop because the contract
is *"this build understands these strings"*, not *"no other strings
are allowed"*.

## Gate policy

`PluginCapabilityGate.verify(manifest:)` runs at the manifest-parsing
boundary in `PluginManager.loadPlugin(fileURL:)` (per the task spec's
escape clause — `importPlugin` itself does not load manifests).
Throwing propagates as `nil`, which `syncFilePlugins` already filters.
M2's install-prompt sheet will call `gate.grant(_:for:)` once per
accepted prompt using the plugin's `name` as the per-plugin key.

The store is a `UserDefaults`-backed
`[PluginID: Set<PluginCapability>]` map. Tests pass
`UserDefaults(suiteName:)` for isolation — the same DI pattern
`PreferencesStore` adopted in commit 4e1fc52.

## Out of scope for M3

- The install-prompt UI sheet (M2 owns it).
- `UNUserNotificationCenter.requestAuthorization` after a
  `.notifications` grant.
- Per-platform expansion (`location`, `accessibility`, …).

## Testing

22 Swift Testing tests in `menubar01Tests/PluginCapabilityTests.swift`
covering enum round-trip, decoder drop-unknown semantics, gate
accept-all / reject-one / per-plugin isolation, idempotent grant,
cross-instance round-trip, and `PluginCapabilityError` equality. All
tests are pure: no filesystem, no `PluginManager`, no
`UserDefaults.standard` contamination.
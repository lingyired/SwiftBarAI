# Extend `PluginCapability` with `network(hosts:)`, `fileWrite(paths:)`, `notifications`

- **Type:** feat
- **Scope:** `menubar01/Plugin/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** 8250f22
- **Status:** done

## Summary

The M3 capability gate shipped earlier today with four bare-string
capabilities — `network`, `clipboard`, `notifications`, `calendar` —
that the install-prompt sheet could only render as a flat token
(`"network"`, `"clipboard"`, …). This change enriches two of the
capabilities with **associated values** and adds a brand-new one,
so the prompt UI can surface the *parameter* the plugin declared:

- `network` → `network(hosts: [String])` (declared destination set)
- `fileWrite` → new case, `fileWrite(paths: [String])` (declared
  write paths)
- `notifications` stays a bare case (no parameter surface), but
  gains the same first-class treatment — `displayName`,
  `description`, `isGrantedByDefault` — as the parameterised cases.

The M2 install-prompt sheet (unchanged in this commit) picks up
the new cases via the `displayName` computed property and renders
rows like **"Network access to api.openai.com"** /
**"Write to ~/Library/Logs/plugin.log"** / **"Notifications"**.

## Wire format

A new v1.1 manifest form is now accepted in addition to the v1
string-array form:

```json
{
  "name": "Weather",
  "capabilities": [
    { "type": "network",    "hosts": ["api.openai.com"] },
    { "type": "fileWrite",  "paths": ["~/Library/Logs/weather.log"] },
    { "type": "notifications" }
  ]
}
```

The v1 string-array form — `["network", "clipboard"]` — is
**still accepted** so every shipped manifest continues to decode.
The compatibility shim lives in a new internal type,
`PluginCapabilityDescriptor`, that wraps each entry of the
`capabilities` array; it tries the bare-string decode first
(mapping to the modern case with empty associated values) and
falls through to the object form. **Unknown v1 strings are
dropped with an `os_log` warning** so manifests authored by a
future build of menubar01 that introduce new capabilities still
load under the current build (preserves the v1 lenient
behaviour). The gate's `UserDefaults` store stores the new
capability shape directly via full `Codable`, so the on-disk
schema is now `[pluginID: [capability-object, ...]]` instead of
`[pluginID: [string, ...]]`.

## `displayName` / `description` / `isGrantedByDefault`

Three new computed properties on `PluginCapability`:

- `displayName` — human-readable label the install-prompt UI
  shows in the toggle row. For
  `network(hosts: ["api.openai.com"])` the result is
  `"Network access to api.openai.com"`; for the empty list it is
  `"Network access"`. For `fileWrite(paths: ["…/plugin.log"])`
  the result is `"Write to ~/…/plugin.log"`; for the empty list
  it is `"Write files"`.
- `description` — one-line helper text shown beneath the
  display name. Generic wording — actual parameter information
  is in `displayName`.
- `isGrantedByDefault` — `false` for every v1.1 case. The
  install-prompt sheet uses this to decide whether to pre-check
  the toggle; the answer is "no" for all three new cases
  (network, fileWrite, notifications) because each requires
  explicit user consent.

## Tests

`PluginCapabilityTests` (new structured sections) and the two
install-prompt test files (`AIGeneratorInstallPromptTests`,
`MarketplaceInstallPromptTests`) were updated to match the new
shape. Nine new tests pin down the v1.1 capability surface:

- `testNetwork_capabilityHasDisplayName`
- `testNetwork_capabilityIsNotGrantedByDefault`
- `testFileWrite_capabilityHasDisplayName`
- `testFileWrite_capabilityIsNotGrantedByDefault`
- `testNotifications_capabilityHasDisplayName`
- `testNotifications_capabilityIsNotGrantedByDefault`
- `testGate_grantNetwork_addsToGrantedSet`
- `testGate_grantFileWrite_addsToGrantedSet`
- `testGate_grantNotifications_addsToGrantedSet`

The full suite is 423/0 (was 331/0 before this change).

## Files

- `menubar01/Plugin/PluginCapabilities.swift` — reworked enum
  with the three new cases, manual `Codable` conformance for
  the object form, new `displayName` / `description` /
  `isGrantedByDefault` accessors, manual `CaseIterable` (the
  associated-value cases make auto-synthesis unavailable).
- `menubar01/Plugin/PluginManifest.swift` — `capabilities`
  field retyped from `[String]?` to
  `[PluginCapabilityDescriptor]?`. New wrapper type accepts both
  v1 and v1.1 wire forms. `resolvedCapabilities` filters
  descriptors whose `capability` is `nil` (dropped unknowns).
- `menubar01/Plugin/PluginCapabilityGate.swift` — store I/O
  switched to full `Codable` for `[String: Set<PluginCapability>]`
  (the on-disk schema is now an array of capability objects).
  Added `isGranted(_:for:)` convenience used by the new tests
  and the future install-prompt sheet.
- `menubar01Tests/PluginCapabilityTests.swift` — restructured
  into `EnumTests`, `ManifestTests`, `GateAcceptTests`,
  `GateRejectTests`, `GateIdempotencyTests`, the four new
  capability tests, and `ErrorTests`. 423 tests total.
- `menubar01Tests/AIGeneratorInstallPromptTests.swift` and
  `menubar01Tests/MarketplaceInstallPromptTests.swift` —
  helpers reworked to construct the v1.1 manifest shape; all
  capability assertions updated to the new enum syntax.

## Out of scope / follow-ups

- Runtime enforcement of `network(hosts:)` (so a granted
  `network(hosts: ["a.com"])` cannot later reach `b.com`) is a
  separate change — likely a `URLProtocol` or `NSURLSession`
  swizzle — and lands once the install-prompt sheet is the
  primary consumer.
- Runtime enforcement of `fileWrite(paths:)` (so the plugin
  script cannot escape the granted sub-path) requires hooking
  into the script execution path; tracked separately.
- The store's on-disk schema is bumped in-place from the v0
  `[String: [String]]` form to the v1 `[String: Set<PluginCapability>]`
  form. v0 data is reset to empty on first launch — acceptable
  because the v0 store shipped in M3 today (2026-06-13) and has
  no real users to migrate.

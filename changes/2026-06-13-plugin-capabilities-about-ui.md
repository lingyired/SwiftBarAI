# Surface granted capabilities in the plugin About view with optional revoke

- **Type:** feat
- **Scope:** `menubar01/Plugin/`, `menubar01/UI/Preferences/`, `menubar01Tests/`
- **Author(s):** Trae AI
- **Commit(s):** 169f26a
- **Status:** done

## Summary

The plugin About / Details view (`PluginDetailsView`) gains a
**"Permissions"** section that lists every capability the plugin
declares in its `manifest.json`, shows a **Granted** (green) or
**Not granted** (red) badge for each, and offers an inline
**Revoke** button on the granted rows. Revoking is a soft action:
the plugin keeps running with its currently loaded capability set
until the next refresh, at which point
`PluginCapabilityGate.verify(...)` throws
`PluginCapabilityError.capabilityNotGranted` and the install-prompt
sheet will surface again.

The capability gate is extended with a new idempotent
`revoke(_:for:)` method. The v1 design explicitly deferred
revoke ("there is no `revoke(_:for:)` in v1 because the install
flow is the only writer"); this change reverses that — the
Permissions section is a second writer, so the gate needs a
matching operation.

## Motivation

M3's `PluginCapabilityGate` shipped earlier today with only
`grant` and `verify`. The install-prompt sheet is the only caller
in v1, so the absence of a revoke is defensible — *until* the
user asks to see what they have granted. Once the About view
exposes the grant set, the user has every right to undo a
mistaken grant, and the gate needs an operation to back that
UI affordance. Doing it now (while the M3 surface is still
small) keeps the gate's API symmetric: any operation visible in
the UI has a matching gate method.

## Changes

### `menubar01/Plugin/PluginCapabilityGate.swift`

- New `public func revoke(_ capability: PluginCapability, for pluginID: String)`
  method. Idempotent — revoking a capability the plugin does
  not currently hold is a no-op. When the revoke empties the
  plugin's grant set, the plugin's entry in the store is
  removed entirely (matches the "never granted" path).
- The top-of-file design comment now lists four operations
  (grant, revoke, granted, verify) instead of three, and the
  `grant(_:for:)` doc comment points callers that want to
  pull a capability back at `revoke(_:for:)`.

### `menubar01/Plugin/Plugin.swift`

- New protocol-extension computed property
  `Plugin.resolvedCapabilities: [PluginCapability]`. Returns
  the `FolderPlugin`'s manifest's resolved capabilities
  (`FolderPlugin.manifest?.resolvedCapabilities ?? []`),
  and `[]` for plugin types that do not carry a manifest
  (`ShortcutPlugin`, `EphemeralPlugin`). The About view uses
  this accessor to render the Permissions section without
  downcasting the protocol value to a concrete type.

### `menubar01/UI/Preferences/PluginDetailsView.swift`

- New `let pluginCapabilityGate: PluginCapabilityGate` parameter
  on `PluginDetailsView`, defaulting to
  `PluginManager.shared.pluginCapabilityGate` (matches the
  injection pattern used by `AIGeneratorViewModel` and
  `MarketplaceBrowserViewModel`). Tests can pass a gate backed
  by an isolated `UserDefaults(suiteName:)` instance to
  assert the section's behavior without touching the real
  store.
- New `@State capabilitiesRevision: Int` counter that the
  parent view bumps after every revoke, plus a matching
  `revision: Int` parameter on `PermissionsSection` — the
  section reads it inside its `declaredCapabilities` getter
  to force a re-evaluation of the gate lookups on the next
  render. `PluginCapabilityGate` is a value type stored in
  `UserDefaults`, so SwiftUI cannot observe its underlying
  mutations on its own.
- New `@State pendingRevoke: PluginCapability?` tracking the
  capability the user is currently confirming in the alert,
  and a `.alert` modifier on the parent that shows a
  "Revoke <displayName> for <pluginName>?" confirmation with
  a destructive **Revoke** button and a **Cancel** button.
- New `PermissionsSection` view: a `Preferences.Section` with
  a **Permissions** headline, an empty-state line ("This
  plugin does not request any special capabilities." in
  `.secondary`) for plugins with no declared capabilities,
  and a `ForEach` of `PluginCapabilityRowView` rows for the
  rest. Extracted into its own view so the section can be
  reused (the marketplace install-prompt sheet has a similar
  row layout) and so the parent view stays readable.
- New `PluginCapabilityRowView`: a single capability row
  with a bold `displayName`, a small `.secondary`
  `description`, a **Granted** / **Not granted** badge in
  green / red, and a small `.borderless` button with a red
  `Image(systemName: "xmark.circle.fill")` on granted rows.
  The button's `.help(...)` tooltip explains the soft-revoke
  semantics.

### `menubar01Tests/PluginCapabilityTests.swift`

- New `PluginCapabilityGateRevokeTests` struct with 5 tests:
  - `testRevoke_removesCapabilityFromGrantSet` — happy
    path: revoking one capability leaves the others
    intact.
  - `testRevoke_ungrantedCapabilityIsNoOp` — revoking a
    capability the plugin never had does not throw, does
    not add the capability, and does not evict existing
    grants.
  - `testRevoke_lastCapabilityRemovesPluginKey` — when the
    revoke empties the set, the entry is removed and the
    plugin can be re-granted from scratch.
  - `testRevoke_unknownPluginIsNoOp` — revoking for a
    pluginID with no store entry is a no-op.
  - `testRevoke_idempotent` — revoking the same capability
    three times in a row has the same effect as once.

## Out of scope

- **View tests.** The repo does not currently use a SwiftUI
  view-inspection library (e.g. ViewInspector / SwiftUI
  snapshot testing), and the task description allows skipping
  view tests if no snapshot testing is in place. The
  Permissions section's wiring is exercised manually via the
  Preferences → Plugins pane; the 5 new gate tests pin down
  the underlying state machine the view renders.
- **Unload-after-revoke.** The revoke is "soft" — the
  plugin keeps running with its currently loaded
  capabilities until the next refresh, at which point
  `gate.verify(...)` throws. A future change could
  explicitly unload the plugin on revoke (and prompt the
  user to re-grant via the install-prompt sheet) — out of
  scope here.

## Impact

- **User-visible.** The plugin About pane now shows what
  capabilities a plugin declared and which of them are
  currently granted, with a per-row Revoke control.
- **Public API surface.** One new public method on
  `PluginCapabilityGate` (`revoke(_:for:)`), one new
  public computed property on `Plugin`
  (`resolvedCapabilities`), one new public type
  (`PermissionsSection`), one new public type
  (`PluginCapabilityRowView`).
- **No new dependencies.** No SwiftPM additions. The view
  is plain SwiftUI on top of the existing
  `Preferences.framework` import.

## Testing

- 5 new tests in `PluginCapabilityTests.swift`
  (`PluginCapabilityGateRevokeTests`).
- Full suite: previous 423 + 5 new = 428 tests, 0
  regressions.

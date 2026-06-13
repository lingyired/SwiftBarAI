# M3 — Plugin capabilities

> **Status:** done (extended through M3 + M5)
> **Date:** 2026-06-13
> **Related records:**
> [`../changes/2026-06-13-m3-capability-gate.md`](../changes/2026-06-13-m3-capability-gate.md),
> [`../changes/2026-06-13-capability-gate-extension.md`](../changes/2026-06-13-capability-gate-extension.md),
> [`../changes/2026-06-13-m2-install-prompt-sheet.md`](../changes/2026-06-13-m2-install-prompt-sheet.md),
> [`../changes/2026-06-13-m5-marketplace-install-prompt.md`](../changes/2026-06-13-m5-marketplace-install-prompt.md),
> [`../changes/2026-06-13-marketplace-install-capability-gate.md`](../changes/2026-06-13-marketplace-install-capability-gate.md),
> [`../changes/2026-06-13-plugin-capabilities-about-ui.md`](../changes/2026-06-13-plugin-capabilities-about-ui.md).

## What this milestone delivers

A consistent **capability** layer that every install path in
menubar01 funnels through:

1. A canonical **vocabulary** of capabilities a plugin can
   declare in its `manifest.json` (`PluginCapability`).
2. A **gate** (`PluginCapabilityGate`) that records the
   user's per-plugin grant set in `UserDefaults` and refuses
   to load a plugin whose declared capabilities it has not
   yet approved.
3. A **prompt sheet** in the M2+ AI generator install flow
   and the M5 marketplace browser — both call
   `gate.grant(_:for:)` before installing so the loader
   never sees an ungranted plugin.
4. A **marketplace install-gate overload** that auto-grants
   implicit capabilities (`clipboard`) and prompts for the
   rest in a single Grant / Decline choice.
5. A **Permissions** section on the plugin About / Details
   view that shows the user what they have granted and lets
   them revoke.

The v1 capability set is small (five cases); new
capabilities land in a follow-up without changing the gate
or the install-prompt contracts.

## The capability vocabulary

`PluginCapability` is a `Equatable, Hashable, Sendable`
enum with five cases. The wire format is a keyed object —
`{ "type": "<case-name>", "<param>": <value>, ... }` — so
the install-prompt sheet can render *"Network access to
api.openai.com"* / *"Write to ~/Library/Logs/plugin.log"*
instead of a bare word.

| Case                       | Meaning / backing entitlement                                                                                                                                | Gate policy                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `network(hosts: [String])` | Outbound HTTP/TCP via the app's `com.apple.security.network.client`. `hosts` is the declared destination set; empty means *any host*.                          | Ask once at install, persist grant.               |
| `clipboard`                | Read/write of `NSPasteboard.general`.                                                                                                                         | Granted by default — no prompt row.               |
| `notifications`            | Posting of `UNUserNotification` alerts. Triggers `UNUserNotificationCenter.requestAuthorization` at install.                                                  | Ask once at install, persist grant.               |
| `calendar`                 | Reading events from `EventKit` / `EKEventStore`. Backed by `NSCalendarsUsageDescription`.                                                                    | Ask once at install, persist grant.               |
| `fileWrite(paths: [String])` | Writing files under the user's home directory at the declared `paths`. Empty means *any path*. Runtime path enforcement is a follow-up; v1 just records the declaration. | Ask once at install, persist grant.               |

`isGrantedByDefault` returns `true` for `clipboard` (any
foreground macOS app can read `NSPasteboard.general`
without an entitlement, so surfacing a prompt row would
just be noise) and `false` for the other four — those all
require explicit consent.

### The v1.1 object form

The M3 extension enriched two of the original bare-string
cases and added `fileWrite`. The v1.1 manifest form is:

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

The v1 string-array form (`["network", "clipboard"]`) is
**still accepted** for backward compatibility. A
`PluginCapabilityDescriptor` shim tries the bare-string
decode first and falls through to the object form.
**Unknown v1 strings are dropped with an `os_log` warning**,
not thrown, so manifests authored by a future build of
menubar01 still load.

`CaseIterable` is hand-rolled (auto-synthesis is unavailable
for enums with associated values); the
`menubar01/Plugin/PluginCapabilities.swift` file lists each
case with empty associated values as the "canonical empty"
representation. The sheet's `allCases` loop is only used to
verify that every case has a non-empty `displayName` /
`description` / `isGrantedByDefault`, so the associated-value
payloads do not matter for the observable behaviour.

## The `PluginCapabilityGate`

`PluginCapabilityGate` is a `UserDefaults`-backed store of
`(pluginID, grantedCapabilities)` pairs. The four
operations the install + About flows need:

### `grant(_:for:)`

```swift
public func grant(_ caps: Set<PluginCapability>, for pluginID: String)
```

Records that `pluginID` has been granted `caps`.
**Idempotent** — granting the same set twice is a no-op.
Subsequent calls with a strict subset do **not** revoke;
callers that want to pull a capability back must use
`revoke(_:for:)`. The `pluginID` is typed as `String`
(rather than the internal `PluginID` typealias) so the
public method does not leak an internal type.

### `revoke(_:for:)`

```swift
public func revoke(_ capability: PluginCapability, for pluginID: String)
```

The About view's Permissions section is a second writer of
the gate, so the operation lands alongside `grant(...)`.
**Idempotent** — revoking a capability the plugin does not
currently hold is a no-op. When the revoke empties the
plugin's grant set, the plugin's entry in the store is
removed entirely (so `granted(for:)` continues to return
`[]`, matching the "never granted" path).

Revoke is **soft** — the plugin keeps running with its
currently loaded capability set until the next refresh, at
which point `verify(...)` throws
`PluginCapabilityError.capabilityNotGranted` and the
install-prompt sheet surfaces again on the next install
attempt.

### `granted(for:)`

```swift
public func granted(for pluginID: String) -> Set<PluginCapability>
```

Returns the set of capabilities the user has granted to
`pluginID`. Empty when the plugin has never been granted
anything (or no such plugin exists in the store). The
About view's Permissions section reads this to render the
granted set.

### `isGranted(_:for:)`

```swift
public func isGranted(_ capability: PluginCapability, for pluginID: String) -> Bool
```

`true` when `pluginID` has been granted `capability`. The
whole-capability value (including associated values) must
match — `.network(hosts: ["a.com"])` is **not** satisfied
by a grant of `.network(hosts: ["b.com"])`. The
install-prompt sheet is responsible for asking the user to
grant each declared shape explicitly.

### `verify(pluginID:requiredCapabilities:)`

```swift
public func verify(
    pluginID: String,
    requiredCapabilities: [PluginCapability]
) throws
```

The **gate itself**. Throws
`PluginCapabilityError.capabilityNotGranted` if any
element of `requiredCapabilities` is missing from
`granted(for:)`. An empty `requiredCapabilities` always
verifies — there is nothing to gate. Declaration order is
preserved so the host UI can show a deterministic error.

A convenience overload `verify(manifest:)` derives the
`pluginID` from `manifest.name` (with `"<unnamed>"` as a
defensive fallback for tests). The manifest overload is
`internal` because `PluginManifest` is `internal`; external
callers use the `String` + list overload above.

## The on-disk schema

The store is a `[String: Set<PluginCapability>]` map
persisted as a `Data` blob via `JSONEncoder`; the
on-disk schema is `[pluginID: [capability-object, ...]]`
where each capability-object is the manual `Codable` form
from `PluginCapabilities.swift` (e.g. `{"type": "network",
"hosts": ["api.openai.com"]}`). The
`UserDefaults` key is
`PluginCapabilityGate.grants.v1` (versioned via the `v1`
suffix so the schema can evolve without colliding with
future revisions of the store).

The v0 schema (`[String: [String]]` of raw values) is no
longer produced by the gate, so reading v0 data falls
through the catch and resets to empty — acceptable because
the v0 store shipped in M3 today (2026-06-13) and has no
real users to migrate.

## Install flow integration

### The M2+ AI generator install flow

`AIGeneratorViewModel` exposes two accessors the
`AIGeneratorInstallPromptSheet` sub-sheet uses:

- `installPromptCapabilities: [PluginCapability]` —
  mirrors `latestPlugin?.manifest.resolvedCapabilities ?? []`.
- `installPromptIsPreApproved: Bool` — `true` when every
  declared capability is already in the gate's grant set.
  Reserved for a future short-circuit; v1 always shows the
  prompt when there is at least one capability.

The prompt sheet's grant loop is the only place
`PluginCapabilityGate.grant(_:for:)` is called from the AI
generator flow:

```swift
let pluginName = plugin.manifest.name ?? "unnamed"
if !enabledCapabilities.isEmpty {
    viewModel.pluginCapabilityGate.grant(enabledCapabilities, for: pluginName)
}
```

Two design choices:

1. **The grant is independent of the install.** If the
   `installGeneratedPlugin` call fails, the grants stay in
   place — the user can retry the install without
   re-toggling every capability. The gate is idempotent, so
   re-granting the same capability for the same name is a
   no-op.
2. **The grant uses `manifest.name` as the key.** This
   matches the loader's read path: the gate is consulted by
   `PluginManifest.name`, so an AI-generated plugin named
   "Weather" will read the same grant set whether the
   prompt came from the AI generator or a future
   marketplace install.

### The M5 marketplace install flow

`MarketplaceBrowserViewModel` mirrors the same two
accessors (`installPromptCapabilities`,
`installPromptIsPreApproved`) and the
`MarketplaceInstallPromptSheet` sub-sheet calls
`pluginCapabilityGate.grant(enabledCapabilities, for:
context.pluginName)` before calling
`_installSelectedAfterGrants(overwriteExisting:)`. The
grants and the install are independent, matching the M2+
pattern.

### The marketplace install-gate overload

`PluginManager.installMarketplacePluginWithCapabilityGate(plan:overwriteExisting:gate:prompt:)`
is a new entry point that threads the gate through the
marketplace install path. It:

1. Walks `plan.manifest?.resolvedCapabilities` and
   partitions the list into "already granted", "granted by
   default" (e.g. `clipboard`), and "needs user prompt".
2. Silently `gate.grant(...)`s the auto-grant set in one
   batched call so the user sees one log line per plugin
   install, not one per capability.
3. Hands the prompt set to the caller-supplied `prompt`
   closure and `await`s the result. The M5 caller is
   `MarketplaceCapabilityPrompter.present(...)`, a
   SwiftUI sheet that renders an all-or-nothing
   **Grant** / **Decline** choice (the install-gate
   overload has already filtered out the
   `isGrantedByDefault == true` capabilities, so a
   per-row checkbox UI would all default to "on" — a
   single Grant button is the more honest representation
   of the choice).
4. On grant, `gate.grant(...)`s the prompt set and
   delegates to the existing
   `installMarketplacePlugin(plan:overwriteExisting:)`
   I/O helper; on decline, returns
   `.capabilityDeclined(pluginID:capabilities:)` without
   touching the disk.

The M5 browser wires this overload through
`installSelectedWithCapabilityGate(overwriteExisting:)`,
which rolls the view-model state back to `.loaded` on a
`.capabilityDeclined` failure so the install button
re-enables without showing the error banner.

The legacy `installMarketplacePlugin(plan:overwriteExisting:)`
signature is preserved unchanged for callers that want to
pre-approve capabilities themselves (the M5-first-cut
checkbox flow still uses it).

## The About view's Permissions section

The plugin About / Details view (`PluginDetailsView`) gains
a **Permissions** section that lists every capability the
plugin declares in its `manifest.json`, shows a
**Granted** (green) or **Not granted** (red) badge for
each, and offers an inline **Revoke** button on the
granted rows. The section is built on top of:

- A new `Plugin.resolvedCapabilities` protocol-extension
  computed property. Returns the `FolderPlugin`'s manifest's
  resolved capabilities
  (`FolderPlugin.manifest?.resolvedCapabilities ?? []`),
  and `[]` for plugin types that do not carry a manifest
  (`ShortcutPlugin`, `EphemeralPlugin`).
- A new `pluginCapabilityGate: PluginCapabilityGate`
  parameter on `PluginDetailsView` (defaulting to
  `PluginManager.shared.pluginCapabilityGate`) — same DI
  pattern as `AIGeneratorViewModel` and
  `MarketplaceBrowserViewModel`.
- A `@State capabilitiesRevision: Int` counter that the
  parent view bumps after every revoke, plus a matching
  `revision: Int` parameter on `PermissionsSection`. The
  `PluginCapabilityGate` is a value type stored in
  `UserDefaults`, so SwiftUI cannot observe its underlying
  mutations on its own.
- A `PermissionsSection` SwiftUI view (a
  `Preferences.Section` with a **Permissions** headline,
  an empty-state line, and a `ForEach` of
  `PluginCapabilityRowView` rows). Extracted into its own
  view so the section can be reused (the marketplace
  install-prompt sheet has a similar row layout).
- A `PluginCapabilityRowView` for a single capability row:
  a bold `displayName`, a small `.secondary` `description`,
  a **Granted** / **Not granted** badge in green / red, and
  a small `.borderless` button with a red
  `Image(systemName: "xmark.circle.fill")` on granted
  rows. The button's `.help(...)` tooltip explains the
  soft-revoke semantics.

The Permissions section is the second writer of the gate
(in addition to the install-prompt sheets), which is why
the v1 "no revoke" deferral was reversed.

## Tests

The capability surface is exercised across several test
suites:

- `menubar01Tests/PluginCapabilityTests.swift` — 7 suites
  covering enum round-trip, manifest decoder drop-unknown
  semantics, gate accept-all / reject-one / per-plugin
  isolation, idempotent grant / revoke, cross-instance
  round-trip, the v1.1 capability surface, the new revoke
  path (5 dedicated tests), and `PluginCapabilityError`
  equality + `LocalizedError` surface.
- `menubar01Tests/AIGeneratorInstallPromptTests.swift` — 8
  tests pinning the M2+ install-prompt view-model
  contract: `installPromptCapabilities`,
  `installPromptIsPreApproved`, `didCompleteInstall(at:)`,
  `didFailInstall(reason:)`.
- `menubar01Tests/MarketplaceInstallPromptTests.swift` —
  10 tests mirroring the M2+ contract for the marketplace
  install-prompt sheet.
- `menubar01Tests/PluginManagerMarketplaceInstallGateTests.swift`
  — 8 tests for the new
  `installMarketplacePluginWithCapabilityGate(...)` overload
  (auto-grant default capabilities, prompt-then-grant,
  prompt-decline-rolls-back, prompt-then-reinstall-skips-prompt,
  error equality).

All tests use per-test
`UserDefaults(suiteName: "menubar01.tests.<...>.<UUID>")`
isolation so the suite cannot contaminate
`UserDefaults.standard` or other tests in the run.

## Out of scope (follow-ups)

- **Runtime enforcement of `network(hosts:)` and
  `fileWrite(paths:)`.** A granted
  `network(hosts: ["a.com"])` can currently reach `b.com`; a
  granted `fileWrite(paths: ["…/plugin.log"])` can currently
  escape the granted sub-path. The fix is a
  `URLProtocol`- or `NSURLSession`-based swizzle for
  network and a script-execution hook for file writes —
  tracked separately, not in this milestone.
- **Unload-after-revoke.** The revoke is "soft" — the
  plugin keeps running with its currently loaded
  capabilities until the next refresh. A future change
  could explicitly unload the plugin on revoke (and prompt
  the user to re-grant via the install-prompt sheet).
- **A unified install-prompt sheet.** The two
  install-prompt sheets (`AIGeneratorInstallPromptSheet`
  and `MarketplaceInstallPromptSheet`) are nearly
  identical. A future refactor could collapse them into a
  single `CapabilityInstallPromptSheet<Context>` generic
  view; the file headers in both sheets note the future
  unification.

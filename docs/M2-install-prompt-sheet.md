# M2 install-prompt sheet — design note

Companion document to
[`changes/2026-06-13-m2-install-prompt-sheet.md`](../changes/2026-06-13-m2-install-prompt-sheet.md).
Captures the sheet shape, the gate integration, the success
and cancel paths, and the marketplace-install follow-up that
will reuse the same `gate.grant(_:for:)` pattern.

## 1. The flow

```
AIGeneratorSheet  (parent sheet, "Generate" workflow)
   │
   │  user clicks "Save to Plugin Folder"
   ▼
AIGeneratorInstallPromptSheet  (sub-sheet, capability grant)
   │
   │  user toggles capabilities, clicks "Install"
   ▼
gate.grant(enabled, for: latestPlugin.manifest.name)   ←── M3
   │
   ▼
PluginManager.shared.installGeneratedPlugin(plugin)   ←── M2 install-flow
   │
   ▼
.onComplete(.success(url))
   │
   ▼
AIGeneratorSheet.dismissed → viewModel.didCompleteInstall(at: url)
                             → didRequestSave = true
                             → installedPluginURL = url
   │
   ▼
"Installed!" green banner shown in parent sheet
```

The cancel path is the same chain with
`.failure(.noLatestPlugin)` (or
`.installFailed(reason:)` for a non-cancel failure); the parent
sheet then calls `viewModel.didFailInstall(reason:)` which
resets both `didRequestSave` and `installedPluginURL`.

## 2. The sheet shape

`AIGeneratorInstallPromptSheet` is a `MainActor`-isolated
`View` driven by `@State` for the local toggle set and an
`@ObservedObject` reference to the parent's
`AIGeneratorViewModel`. It deliberately does **not** own any
view-model state — the `onComplete: (Result<URL, InstallPromptError>) -> Void`
callback is the only path back into the parent's state.

Layout (left-to-right, top-to-bottom):

1. `Text("Install \"<pluginName>\"")` — headline.
2. `Text(...)` — one-sentence explanation of the prompt.
3. `ForEach(viewModel.installPromptCapabilities, id: \.self)`:
   - A `Toggle` (`displayName` is the row label, checkbox
     style for native macOS feel).
   - A `Text(capability.description)` (caption, secondary).
4. An optional red `Text(installError)` (only after a failed
   install attempt).
5. An `HStack` with `Button("Cancel", role: .cancel)` and
   `Button(isInstalling ? "Installing…" : "Install")`.

The Cancel button is wired to `.keyboardShortcut(.cancelAction)`
(ESC) and the Install button to `.keyboardShortcut(.defaultAction)`
(Return) so the prompt behaves like a real macOS sheet.

`onAppear` pre-checks every capability the gate has already
granted for `latestPlugin.manifest.name`. The user can still
uncheck a row before clicking Install.

## 3. Gate integration

The sheet's grant loop is the only place
`PluginCapabilityGate.grant(_:for:)` is called from the AI
generator flow:

```swift
let pluginName = plugin.manifest.name ?? "unnamed"
if !enabledCapabilities.isEmpty {
    viewModel.pluginCapabilityGate.grant(enabledCapabilities, for: pluginName)
}
```

Two design choices worth calling out:

1. **The grant is independent of the install.** If the
   `installGeneratedPlugin` call fails, the grants stay in
   place — the user can retry the install without re-toggling
   every capability. The gate is idempotent, so re-granting the
   same capability for the same name is a no-op.
2. **The grant uses `manifest.name` as the key.** This matches
   the loader's read path: the gate is consulted by
   `PluginManifest.name`, so an AI-generated plugin named
   "Weather" will read the same grant set whether the prompt
   came from the AI generator or a future marketplace install.

The `viewModel.pluginCapabilityGate` property defaults to
`PluginManager.shared.pluginCapabilityGate` so the production
sheet uses the same store the loader reads from. Tests
overwrite the property with a fresh instance backed by an
isolated `UserDefaults(suiteName:)` — same DI pattern as the
`generator: AIPluginGenerator` injection already in place.

## 4. Success / cancel / fail paths

| User action     | `onComplete`                  | View-model state                              |
|-----------------|-------------------------------|-----------------------------------------------|
| Click Install   | `.success(url)`               | `didCompleteInstall(at: url)`                 |
|                 |                               | → `didRequestSave = true`                     |
|                 |                               | → `installedPluginURL = url`                  |
|                 |                               | → parent sheet shows "Installed!" banner      |
| Click Cancel    | `.failure(.noLatestPlugin)`   | `didFailInstall(reason: "cancelled")`         |
|                 |                               | → `didRequestSave = false`                    |
|                 |                               | → `installedPluginURL = nil`                  |
|                 |                               | → parent sheet shows no banner                |
| Install fails   | `.failure(.installFailed(r))` | `didFailInstall(reason: r)`                   |
|                 |                               | → same as Cancel, plus the sub-sheet shows    |
|                 |                               |   the red `installError` text in place        |

The `InstallPromptError` cases are deliberately small: a Cancel
and a "lost `latestPlugin` while the sheet was visible" both
collapse to `.noLatestPlugin` because the parent sheet
no-ops either way. A genuine install failure carries the
underlying error string so the parent sheet can log it
(`.os_log` from `didFailInstall(reason:)`) without surfacing
it to the user.

## 5. View-model contract

The view model grew four pieces of state and one
behaviour change. The state is intentionally minimal so
the sheet can drive it through the completion callback:

- `@Published var installedPluginURL: URL?` — the on-disk
  path. Read by `AIGeneratorSheet` to render the success
  banner; set by `didCompleteInstall(at:)`; cleared by
  `didFailInstall(reason:)`, `reset()`, and `generate()`.
- `var pluginCapabilityGate: PluginCapabilityGate` —
  defaults to `PluginManager.shared.pluginCapabilityGate`;
  `internal(set)` (i.e. var with default setter) so tests
  can inject an isolated instance.
- `var installPromptCapabilities: [PluginCapability]` —
  `latestPlugin?.manifest.resolvedCapabilities ?? []`. The
  parent sheet checks this to decide whether to even open
  the prompt (an empty list is a no-op prompt).
- `var installPromptIsPreApproved: Bool` — true when the
  gate has every declared capability. Reserved for a future
  v1.1 short-circuit ("skip the prompt when the user has
  already accepted everything in a previous round-trip");
  v1 always shows the prompt when there is at least one
  capability.

The behaviour change: `requestSaveToPluginFolder()` is now
a documented no-op. It is kept on the public API so older
call sites still compile, but the active participant is the
sheet. The comment block in the source explains the new
contract and points at the sheet for the active flow.

## 6. Tests

Three Swift Testing suites, eight tests, no fixtures that
depend on `PluginManager.shared` or `UserDefaults.standard`:

- `AIGeneratorInstallPromptCapabilitiesTests` (3) —
  `installPromptCapabilities` mirrors
  `latestPlugin.manifest.resolvedCapabilities`, returns
  `[]` when there is no `latestPlugin`, and drops unknown
  capability strings.
- `AIGeneratorInstallPromptPreApprovalTests` (3) —
  `installPromptIsPreApproved` is `true` when every
  declared capability is already granted, `false` when at
  least one is missing, and `true` when the manifest
  declares no capabilities.
- `AIGeneratorInstallCompletionTests` (2) —
  `didCompleteInstall(at:)` flips `didRequestSave` and
  stores the URL; `didFailInstall(reason:)` clears both.

The end-to-end install path (grant + write to disk) is
exercised by the existing
`PluginManagerInstallGeneratedPluginTests` suite — those
tests already cover the install helper the sheet delegates
to. The new tests here pin down the *view-model contract*
that the sheet relies on, which is the layer the sheet
introduces.

Per-test isolation uses
`UserDefaults(suiteName: "menubar01.tests.installPrompt.<UUID>")`,
matching the `PluginCapabilityTests` pattern. Each test
removes its suite's persistent domain on setup so a stale
run cannot leak into the next test.

## 7. Marketplace install follow-up

The marketplace install path will need the same
"show the user the declared capabilities, let them toggle,
then grant" UX. Two reuse paths are available:

- **Reuse the sheet wholesale** —
  `AIGeneratorInstallPromptSheet(viewModel: someViewModel)`
  with a different `onComplete` mapping. This works as
  long as the marketplace install path also publishes a
  view model with `latestPlugin`, `installPromptCapabilities`,
  and `installedPluginURL`. The downside is the
  "AI Generator" name in the doc comments; we'd want to
  rename the type to `CapabilityInstallPromptSheet` if we
  go this route.
- **Copy the gate-grant call into the marketplace installer.**
  `PluginManager+MarketplaceInstall.swift` can call
  `pluginCapabilityGate.grant(enabled, for: manifest.name)`
  inline after the user picks the capabilities in the
  marketplace sheet. This keeps each sheet focused on its
  own flow and avoids a cross-flow rename, at the cost of
  duplicating the grant loop.

For v1 the plan is option 2: copy the grant loop, since
the marketplace sheet will have a different layout
(possibly with a per-capability risk rating) and a
different completion handler (it needs to wire the
downloaded entry-script into the manifest, not just write
the manifest to disk). The shared piece is the
`PluginCapabilityGate` API itself, which is already
M3-stable.

## 8. Open questions

- **Should the prompt be skippable for an "always allow"
  toggle?** The architecture doc's §3 says every grant
  must be recorded, but doesn't forbid an "always allow
  for this kind of plugin" preference. v1 leaves this
  alone; the marketplace follow-up is the right place to
  decide.
- **Should the sheet fire a `UNUserNotificationCenter`
  notification on success?** v1 just updates the
  `installedPluginURL` banner. The `didCompleteInstall(at:)`
  method is the natural place to add a notification; a
  follow-up can add it without changing the contract.
- **What happens if the user closes the parent sheet
  while the install is in flight?** SwiftUI tears down
  the `@StateObject` view model, but the install is
  happening on the main actor via
  `PluginManager.shared.installGeneratedPlugin(_:)`. The
  grant is already persisted by then, so a re-open of
  the parent sheet would see the granted capabilities
  and a fresh `latestPlugin == nil`. Not a correctness
  bug, but worth noting for the
  `PluginManager+MarketplaceInstall.swift` reviewer.

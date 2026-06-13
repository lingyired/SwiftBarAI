# Intents and URL Scheme

menubar01 exposes its control surface through **two** parallel entry points: the legacy `menubar01://` URL scheme (documented in [README.md](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/README.md)) and a set of `INIntent` subclasses (for Siri/Shortcuts).

## URL scheme — `menubar01://`

Declared in [Resources/Info.plist](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Info.plist) under `CFBundleURLTypes`. The handler is `AppDelegate.application(_:open:)`.

### Hosts

| Host | Query parameters | Behavior |
| --- | --- | --- |
| `refreshallplugins` | — | `pluginManager.refreshAllPlugins(reason: .RefreshAllURLScheme)` |
| `refreshplugin` | `name=` / `plugin=`, optional `interval=`, `env.k=v`, `index=` | Refresh a single plugin by name or by 1-based index. |
| `enableplugin` | `name=` | Removes `name` from `prefs.disabledPlugins`. |
| `disableplugin` | `name=` | Adds `name` to `prefs.disabledPlugins`. |
| `toggleplugin` | `name=` | Toggles. |
| `addplugin` | `src=` (URL or local path) | Imports the plugin. |
| `setephemeralplugin` | `name=`, `content=`, `href=`, `image=`, `exitafter=`, `reset=true` | Creates/updates the `EphemeralPlugin`. |
| `notify` | `name=`, `title=`, `subtitle=`, `body=`, `href=`, `silent=true` | Posts a user notification. |
| `copysystemreport` | — | Copies the latest report to the pasteboard. |
| `opensystemreport` | — | Opens the latest report in the default app. |
| `refreshtranslations` | — | Re-reads `Localizable.strings`. |
| `refreshrepositorydata` | — | Refreshes the plugin repository cache. |
| `showwindow` | `name=` (optional: `preferences` or `repository`) | Brings a window to the front. |
| `enableallplugins` | — | Resets `disabledPlugins` to empty. |
| `disableallplugins` | — | Sets `disabledPlugins` to all current plugins. |
| `showdebugforplugin` | `name=` | Opens the debug popover for a single plugin. |
| `quit` | — | Quits the app. |

If the URL is a `file:///` (or local path) and the file's extension matches a known plugin, the delegate imports it before handling the host (e.g. `menubar01://disableplugin` called on a `file://…/foo.10s.sh` is interpreted as "disable foo").

### Refresh env

The `refreshplugin` URL also accepts any number of `env.*=value` query parameters. These are added to the plugin's env during that single refresh (e.g. `menubar01://refreshplugin?name=battery&env.DEBUG=1`).

## Intents — Siri / Shortcuts

Defined in [Resources/Intents.intentdefinition](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Intents.intentdefinition). Implemented in [menubar01/Intents/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents).

### `GetPluginsIntent`

- Parameter: `enabledOnly: Bool?`
- Returns: `[String]` (list of plugin names)
- Handler: [GetPluginsIntentHandler.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents/GetPluginsIntentHandler.swift)
- Logic: returns `pluginManager.plugins.map(\.metadata.name)` filtered by `enabledOnly` if set.

### `EnablePluginIntent` / `DisablePluginIntent`

- Parameter: `name: String`
- Handler: [EnablePluginIntentHandler.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents/EnablePluginIntentHandler.swift) and [DisablePluginIntentHandler.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents/DisablePluginIntentHandler.swift)
- Logic: mutate `prefs.disabledPlugins`; trigger `pluginManager.pluginsDidChange()`.

### `ReloadPluginIntent`

- Parameter: `name: String`
- Handler: [ReloadPluginIntentHandler.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents/ReloadPluginIntentHandler.swift)
- Logic: find the plugin and call `plugin.run()`.

### `SetEphemeralPluginIntent`

- Parameter: `name: String`, `content: String?`
- Handler: [SetEphemeralPluginIntentHandler.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents/SetEphemeralPluginIntentHandler.swift)
- Logic: calls `pluginManager.setEphemeralPlugin(...)` with the provided name/content/href/etc.

### Routing

`AppDelegate.application(_:handlerFor:)` returns a closure that resolves the intent type to its handler:

```swift
if intent is GetPluginsIntent      { return GetPluginsIntentHandler() }
if intent is EnablePluginIntent     { return EnablePluginIntentHandler() }
if intent is DisablePluginIntent    { return DisablePluginIntentHandler() }
if intent is ReloadPluginIntent     { return ReloadPluginIntentHandler() }
if intent is SetEphemeralPluginIntent { return SetEphemeralPluginIntentHandler() }
```

The MAS build replaces `SPUStandardUserDriverDelegate` etc. with empty protocols in [Resources/Intents/EmptyAdoption.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Intents/EmptyAdoption.swift) (the actual `Intents.intentdefinition` generates the `GetPluginsIntent`, etc. types at build time).

## User notifications

Posted by `PluginManager.showNotification(plugin: SystemNotification)` (and the equivalent for `showAlert`):

- The system notification's `userInfo` carries:
  - `SystemNotificationName.pluginID: String` — the originating plugin's `metadata.name`.
  - `SystemNotificationName.url: String?` — the `href` to open on click.
  - `SystemNotificationName.command: String?` — a `MenuLineParameters`-encoded JSON describing what to do on click (terminal or background script).

When the user clicks the notification, the delegate (in `AppDelegate`) decodes the userInfo and acts on it.

## Diagnostics

- `menubar01://copysystemreport` and `menubar01://opensystemreport` use the latest system report persisted by `PluginManager.persistLatestSystemReport(reason:)`.
- A non-existent host logs an error at `.error` level in `Log.plugin` and surfaces in the system report.

## Tests

A few URL-scheme scenarios are exercised by hand; there is no automated test for them in [menubar01Tests/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01Tests), but a new test is straightforward via the URL parser in `AppDelegate` (it would need to be lifted into a helper for direct testing).

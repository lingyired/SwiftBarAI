# Architecture

SwiftBar is structured around **three coordinated layers**: the **App layer** (NSApplication lifecycle, URL routing, intents, repository browser), the **Plugin layer** (model + execution), and the **MenuBar layer** (NSStatusItem rendering and incremental updates). All three layers share a single source of truth — `PreferencesStore` — which is also the only `ObservableObject` that the SwiftUI panes observe.

## Layered diagram

```
                            ┌──────────────────────────────────┐
                            │           NSApplication          │
                            │  main.swift → NSApplicationMain  │
                            └──────────────┬───────────────────┘
                                           │
                                           ▼
              ┌──────────────────────────────────────────────────┐
              │                   AppDelegate                     │
              │  • applicationDidFinishLaunching                  │
              │  • application(_, open:) — swiftbar:// URL scheme │
              │  • userNotificationCenter(_:didReceive:)          │
              │  • Sparkle / AppDelegate+Intents / +Toolbar / +Menu│
              └──────┬─────────────────┬──────────────────┬───────┘
                     │                 │                  │
                     ▼                 ▼                  ▼
       ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
       │   PluginManager  │  │  AppShared       │  │  PreferencesStore│
       │  (singleton)     │  │  (static facade) │  │  (UserDefaults)  │
       └────────┬─────────┘  └─────────┬────────┘  └────────┬─────────┘
                │                      │                     │
                ▼                      ▼                     ▼
  ┌──────────────────────────┐  ┌──────────────────┐  ┌──────────────────┐
  │  [Plugin] (protocol)     │  │  Terminal / TTY  │  │  @Published      │
  │  ├ ExecutablePlugin     │  │  AppleScript     │  │  values observed │
  │  ├ StreamablePlugin     │  │  Kitty process   │  │  by SwiftUI      │
  │  ├ ShortcutPlugin       │  │  Shortcuts.app   │  └──────────────────┘
  │  ├ EphemeralPlugin      │  └──────────────────┘
  │  └ PackagedPlugin       │
  │     (.swiftbar bundles) │
  └────────┬─────────────────┘
           │ content (String?) published via Combine
           ▼
  ┌──────────────────────────┐         ┌────────────────────────────┐
  │      MenubarItem         │◀────────│  MenuItemNode (tree)       │
  │  per-plugin NSStatusItem │         │  + MenuDiff (shape-based)  │
  │  + NSMenu + popovers     │         │  + FoldableMenuItemView    │
  └──────────────────────────┘         └────────────────────────────┘
```

## Bootstrapping flow

1. [main.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/main.swift) creates an `AppDelegate` and calls `NSApplicationMain`. There is no `@main` attribute; the `main.swift` file is the entry.
2. `AppDelegate.applicationDidFinishLaunching`:
   1. Configures the preferences window and toolbar.
   2. Removes stray `NSStatusItem Visible` keys from `UserDefaults` (these can hide items incorrectly when plugins emit no output).
   3. Starts the Sparkle updater (non-MAS only).
   4. Determines the user's login shell (env `SHELL`, fallback to `dscl`).
   5. Prompts for a plugin folder on first launch.
   6. Constructs [`PluginManager.shared`](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Plugin/PluginManger.swift) and calls `loadPlugins()`.
   7. Subscribes to `NSWorkspace.willSleep` / `didWake` to terminate / start plugins and refresh the env time stamps.
3. Each discovered file becomes an `ExecutablePlugin` or `StreamablePlugin`; each persisted Shortcut becomes a `ShortcutPlugin`; each `.swiftbar` directory becomes a `PackagedPlugin`. URL-scheme-driven plugins become `EphemeralPlugin` on demand.
4. For every enabled plugin, a `MenubarItem` is created (`PluginManager.pluginsDidChange`).

## Threading model

| Concern | Queue / mechanism |
| --- | --- |
| UI rendering, NSStatusItem mutations, NSMenu diffing | Main thread (asserted via `dispatchPrecondition(condition: .onQueue(.main))`) |
| Plugin script invocation | `PluginManager.pluginInvokeQueue` (`OperationQueue`, QoS `.userInitiated`, max 20 concurrent) |
| Menu incremental updates | `PluginManager.menuUpdateQueue` (`OperationQueue`, QoS `.userInteractive`, max 10 concurrent) |
| File-system watch | `DirectoryObserver` uses `DispatchSource.makeFileSystemObjectSource` on a global queue; result is debounced on main |
| Sleep/wake observation | `NSWorkspace` notifications on main queue |
| Streamable plugin reads | `Pipe` reader `readabilityHandler` on a private serial dispatch queue, then `onOutputUpdate` callback (per plugin) |
| Cron timers | `RunLoop.main` (`mode: .common`) |
| Preferences mutations | `@Published` triggers SwiftUI re-render on main |
| Combine | `PassthroughSubject` on `Plugin.contentUpdatePublisher` → subscribed on `menuUpdateQueue` |

## Core invariants

1. **`PluginManager.plugins` is the single source of truth.** Mutating it (`didSet` → `pluginsDidChange`) reconciles the `menuBarItems` dictionary: a `MenubarItem` is added/removed/replaced for every enabled/disabled plugin, then `updateDefaultBarItemVisibility` runs and a system report is persisted.
2. **A `Plugin` reports its output through `content: String?`.** Every concrete type uses a `didSet` to publish the new value via a Combine `PassthroughSubject`, so all `MenubarItem` instances receive updates without polling.
3. **Plugin execution is wrapped in `RunPluginOperation<T>`.** This `Operation` subclass invokes the plugin, assigns the result to `plugin.content`, and re-arms the timer (`TimerArmingPlugin.enableTimer()`). Cancellation is honored both before and after `invoke()`.
4. **The script-output grammar is centralized in `MenuLineParameters`** (parsing) and `MenuItemNode` (tree building). The NSMenu is rendered from this tree, never from raw strings.
5. **All cross-cutting mutable state goes through `PreferencesStore.shared`.** There is no second source of user preferences; SwiftUI views observe it via `@EnvironmentObject`.
6. **Hidden settings are surfaced via `PreferencesStore` (with default values) or read directly from `UserDefaults` in `AppDelegate`.** They are intentionally not exposed in the UI.
7. **`MAC_APP_STORE` flag switches off Sparkle and the FSEvents `DirectoryObserver`**, and changes which entitlements file is used. Most non-MAS code paths use `#if !MAC_APP_STORE`.

## Cross-component communication

| Producer | Channel | Consumer |
| --- | --- | --- |
| `Plugin.content` setter | `PassthroughSubject<String?, Never>` | `MenubarItem` (subscribed on `menuUpdateQueue`) |
| `PreferencesStore.disabledPlugins` | `PassthroughSubject<Any, Never>` | `PluginManager` → `pluginsDidChange()` |
| `PreferencesStore.swiftBarIconIsHidden` | `@Published` | `AppShared.rebuildAllMenus()` via `didSet` |
| `NSWorkspace` sleep/wake | `NotificationCenter` (main queue) | `AppDelegate` → `Environment` & `PluginManager` |
| `DirectoryObserver` | Dispatch source event | `PluginManager.directoryChanged` → debounced `loadPlugins` |
| `swiftbar://…` URL | `application(_:open:)` | `AppDelegate` switch by host |
| `AppDelegate.repositoryToolbarSearchItem` text change | `NotificationCenter` → `.repositoirySearchUpdate` | `PluginRepository` → debounced search |

## URL / Intent / Notification surfaces

SwiftBar exposes three external entry points:

1. **`menubar01://` URL scheme** — see [10-Intents-and-URL-Scheme.md](./10-Intents-and-URL-Scheme.md). Hosts include `refreshplugin`, `enableplugin`, `addplugin`, `setephemeralplugin`, `notify`, `copysystemreport`, etc.
2. **Siri/Shortcuts Intents** — `GetPluginsIntent`, `EnablePluginIntent`, `DisablePluginIntent`, `ReloadPluginIntent`, `SetEphemeralPluginIntent`. Routed via `AppDelegate.application(_:handlerFor:)` to handlers in [menubar01/Intents/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Intents).
3. **Plugin-driven notifications** — plugins can post `UNNotificationRequest` through `PluginManager.showNotification(...)`; the delegate re-acts on click via `userNotificationCenter(_:didReceive:withCompletionHandler:)`.

## Diagnostics

`PluginManager` produces a human-readable system report at any time:

- `currentSystemReport(reason:)` — formatted text
- `persistLatestSystemReport(reason:)` — written to `Application Support/<AppName>/Diagnostics/latest-system-report.txt`
- `copyLatestSystemReportToPasteboard()` — copies to clipboard
- `openLatestSystemReport()` — opens the file with default app

This is reachable from the menu bar via the `CopySystemReport` / `OpenSystemReport` items and from the URL scheme (`swiftbar://copysystemreport`, `swiftbar://opensystemreport`).

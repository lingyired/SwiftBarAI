# menubar01 Code Wiki

> Structured technical documentation for the menubar01 macOS application.

menubar01 is a macOS menu-bar app that lets users add custom menu bar items by writing small executable scripts packaged as a folder containing a `manifest.json` and an entry script. It is an independent fork of [SwiftBar](https://github.com/swiftbar/SwiftBar) with the legacy SwiftBar plugin format removed; only the folder-based `manifest.json` format is supported (see [`README-MANIFEST-PLUGINS.md`](../README-MANIFEST-PLUGINS.md)).

## Table of Contents

### Foundations
1. [Project Overview](./01-Project-Overview.md) — purpose, tech stack, deployment targets, build flavors
2. [Architecture](./02-Architecture.md) — module map, runtime data flow, threading model
3. [Application Lifecycle](./03-Application-Lifecycle.md) — `main`, `AppDelegate`, URL scheme, sleep/wake
4. [Build and Run](./13-Build-and-Run.md) — how to build, dependencies, configuration flags

### Core Subsystems
5. [Plugin System](./04-Plugin-System.md) — `Plugin` protocol, the five concrete plugin types, `PluginManager`
6. [MenuBar System](./05-MenuBar-System.md) — `MenubarItem`, `MenuItemNode`, `MenuDiff`, incremental updates
7. [Plugin Output Parsing](./06-Plugin-Output-Parsing.md) — `MenuLineParameters`, parameter grammar, formatting
8. [Script Execution](./07-Script-Execution.md) — `runScript`, shell wrapping, terminals, `Environment`, `ShortcutsManager`
9. [Preferences and Storage](./08-Preferences-and-Storage.md) — `PreferencesStore`, `UserDefaults`, hidden settings

### Extensions and Surfaces
10. [Plugin Repository](./09-Plugin-Repository.md) — in-app plugin browsing, `PluginRepository`, `Agent`
11. [Intents and URL Scheme](./10-Intents-and-URL-Scheme.md) — Siri/Shortcuts intents, `menubar01://` URLs
12. [User Interface](./11-User-Interface.md) — preferences panes, plugin repository window, popovers
13. [Utilities](./12-Utilities.md) — helpers, extensions, observability

## Repository Layout (at a glance)

```
menubar01/
├── main.swift                     # App entry point
├── AppDelegate.swift              # Top-level NSApplicationDelegate
├── AppShared.swift                # Cross-window utility actions
├── AppDelegate+Menu.swift         # Dock-style menu
├── AppDelegate+Toolbar.swift      # Plugin repository toolbar
├── AppDelegate+Intents.swift      # Siri/Shortcuts intent routing
├── PreferencesStore.swift         # UserDefaults-backed settings
├── Log.swift                      # os.Logger categories
│
├── Plugin/                        # The plugin model (3 active concrete types after 1ccd8ef)
│   ├── Plugin.swift               # Protocol + base behavior
│   ├── (ExecutablePlugin.swift removed in 1ccd8ef)
│   ├── (StreamablePlugin.swift removed in 1ccd8ef)
│   ├── ShortcutPlugin.swift       # Apple Shortcuts-backed plugins
│   ├── EphemeralPlugin.swift      # URL-scheme driven short-lived items
│   ├── (PackagedPlugin.swift / .swiftbar bundle support removed in 1ccd8ef)
│   ├── PluginMetadata.swift       # ObservableObject data class populated by FolderPlugin
│   ├── PluginManger.swift         # Manager (typo preserved; contains FolderPlugin loader)
│   ├── PluginDebugInfo.swift      # Debug event log
│   └── FolderPlugin.swift         # Folder-based manifest.json plugin loader (the only active plugin class)
│
├── MenuBar/                       # NSStatusItem & NSMenu plumbing
│   ├── MenuBarItem.swift          # The big one
│   ├── MenuItemNode.swift         # Tree representation of menu
│   ├── MenuDiff.swift             # Shape-based diffing
│   └── FoldableMenuItemView.swift # Custom accordion view
│
├── Intents/                       # Siri / Shortcuts intent handlers
│
├── Utility/                       # Cross-cutting helpers
│   ├── RunScript.swift            # Process + pipe plumbing
│   ├── Environment.swift          # Plugin env-var provider
│   ├── PluginUtilities.swift      # parseRefreshInterval, RunPluginOperation
│   ├── DirectoryObserver.swift    # FSEvents-backed watcher
│   ├── ShortcutsManager.swift     # AppleScript-bridge to Shortcuts.app
│   ├── LaunchAtLogin.swift        # ServiceManagement wrapper
│   └── ...                        # String/NSColor/NSImage/URL extensions
│
├── UI/                            # SwiftUI windows / panes
│   ├── Preferences/               # Settings window panes
│   ├── Plugin Repository/         # Get Plugins... window
│   ├── Helpers/                   # AnimatableWindow, ImageView, etc.
│   ├── Debug/                     # Plugin debug inspector
│   ├── AboutPluginView.swift
│   ├── PluginErrorView.swift
│   └── WebView.swift              # WKWebView wrapper
│
└── Resources/                     # Info.plist, Assets, Localizable.strings
```

## Naming notes

- The file `PluginManger.swift` keeps its original typo for git-blame stability; the type it defines is `PluginManager`.
- Build flavors: the same source tree compiles to **menubar01** (Sparkle-enabled) and **menubar01 MAS** (Mac App Store, no Sparkle, sandbox-friendly). The two are switched via the `MAC_APP_STORE` compile flag.

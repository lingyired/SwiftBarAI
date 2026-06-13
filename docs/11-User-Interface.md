# User Interface

SwiftBar's UI is a hybrid: AppKit for the menu bar, SwiftUI for the preferences and repository windows, SwiftUI-via-`NSHostingController` for popovers and the plugin detail.

## Preferences window

[PreferencesView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Preferences/PreferencesView.swift) is the host. It is wrapped in `PreferencesWindowController` (from the `sindresorhus/Preferences` SwiftPM package) and exposes a sidebar with the following tabs:

| Tab | View | Notes |
| --- | --- | --- |
| **General** | `GeneralPreferencesView` | Refresh-on-launch toggle, default plugin folder, default run scripts. |
| **Plugin Folder** | `PluginFolderPreferencesView` | Pick a plugin folder. |
| **Plugins** | `PluginsPreferencesView` | Master/detail list, enable/disable, drag-to-reorder. |
| **Shortcut Plugins** | `ShortcutPluginsPreferencesView` | List of `ShortcutPlugin` instances, run type, schedule. |
| **Terminal** | `TerminalPreferencesView` | Default terminal app (.terminal, .iterm, .ghostty, .kitty). |
| **Plugin Repository** | `PluginRepositoryPreferencesView` | Toggle, beta updates. |
| **Advanced** | `AdvancedPreferencesView` | Hidden settings toggles (debug logging, data dir overrides, etc.). |

### `GeneralPreferencesView`

[GeneralPreferencesView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Preferences/GeneralPreferencesView.swift) implements:

- **Show SwiftBar on all desktops** (`prefs.showDefaultMenuBar`).
- **Hide SwiftBar menu bar icon** (`prefs.hideIcon`).
- **Launch SwiftBar at login** (uses `LaunchAtLogin`).
- **Refresh on system wake** (`prefs.refreshAllPluginsOnWake`).
- **Show plugin repository** (`prefs.showPluginRepository`).
- **Custom shell scripts**: a text-editor for `userBashScript`, `userZshScript`, `userFishScript`, `userScriptOverride`. These run before each plugin.
- **Open the plugin folder** button (calls `AppShared.openPluginFolder`).
- **Check for updates** button (calls `AppShared.checkForUpdates`, MAS-disabled).

### `PluginsPreferencesView`

[PluginsPreferencesView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Preferences/PluginsPreferencesView.swift) is a master/detail list bound to `PluginManager.plugins`. Drag-to-reorder is supported (it re-orders by re-numbering the `Plugin` order, which the manager respects). A toggle per row writes to `prefs.disabledPlugins`.

### `ShortcutPluginsPreferencesView`

[ShortcutPluginsPreferencesView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Preferences/ShortcutPluginsPreferencesView.swift) lists every Apple Shortcut configured as a plugin. Each row shows the shortcut name, the run type (`.instant` / `.silent` / `.foreground` / `.pinnedMenuBar`), and an optional schedule. Edits persist to `prefs.shortcutsList`.

### `AdvancedPreferencesView`

[AdvancedPreferencesView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Preferences/AdvancedPreferencesView.swift) surfaces the less-commonly-used settings: enable verbose logging, debug cache dir, default data dir, default refresh plugin, etc.

## Plugin repository window

[PluginRepositoryView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Plugin%20Repository/PluginRepositoryView.swift) is a SwiftUI `Window` (`WindowGroup`-style, opened by `AppDelegate.repositoryWindowController`). It uses a `NavigationSplitView` with a category sidebar and a `PluginListView` detail.

The window's toolbar is configured in `AppDelegate+Toolbar.swift` and posts `.repositoirySearchUpdate` to the `NotificationCenter` on search field changes.

`PluginListView` is a scrollable list of `PluginEntryView` cells. Tapping a cell presents `PluginEntryModalView` as a sheet.

## Popovers and modals

- `PluginEntryModalView` — sheet for installing/uninstalling a plugin.
- `AboutPluginView` — sheet showing the plugin's README (rendered as Markdown via `WebView`).
- `PluginErrorView` — sheet that surfaces a plugin's last error with a "Copy" action.
- `FoldableMenuItemView` — the SwiftUI accordion shown when a menu item has `dropdown=true`.
- `PluginDebugInfo` — popover shown via `AppShared.showPluginDebug(plugin:)`.

### `WebView`

[UI/WebView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/WebView.swift) wraps `WKWebView` for displaying README and the WebView plugin type.

### `ImageView`

[UI/Helpers/ImageView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Helpers/ImageView.swift) is a small SwiftUI view that loads an image by URL with a fallback view.

## Animatable window

[UI/Helpers/AnimatableWindow.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Helpers/AnimatableWindow.swift) is an `NSWindow` subclass that supports an `animator.alphaValue` property. Used for fade in/out of the plugin detail / repository windows.

## Localization

`Localizable.strings` is provided for several languages (English, German, Russian, simplified/traditional Chinese, Portuguese, Spanish, French, etc.). Strings are accessed through a typed `Localizable` enum (in [Resources/Localization/Localizable.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Localization/Localizable.swift)) which has nested types for each top-level UI region (e.g. `Localizable.PluginRepository`, `Localizable.Preferences`).

`Localizable` exposes `.localized` for every key. This generates compile-time guarantees that all key paths exist; if a key is missing, the build fails.

## Build-time generated types

- `Localizable` — generated by a Swift script in [Localization/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Localization). The script is not part of the Xcode build; the generated file is checked in.
- The `INIntent` subclasses (e.g. `GetPluginsIntent`) are generated by Xcode from [Intents.intentdefinition](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Intents.intentdefinition).

## Asset catalog

`Resources/Assets.xcassets` contains:

- `AppIcon` — the SwiftBar menu bar app icon.
- `Background` and other backgrounds for the repository window.
- `Icon` — the SwiftBar status-bar logo.

A few custom `NSImage` assets are also used in toolbar buttons.

## Build-time UI toggles

`#if !MAC_APP_STORE` guards the **Check for Updates** menu item and the **Use beta updates** switch in the repository preferences. The MAS build does not surface them.

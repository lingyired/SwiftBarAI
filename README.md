# menubar01

menubar01 is an independent macOS menu-bar platform. It lets you turn any
executable script (bash, python, node, swift, …) into a menu-bar app and
keep the macOS menu bar fully under your control.

This project is a fork of [SwiftBar](https://github.com/swiftbar/SwiftBar),
rebranded and re-platformed for new product directions:

- AI-generated plugins
- AI-assisted plugin development
- Plugin ecosystem
- Automation tool runtime

## Highlights

- **Folder-based plugins** — drop a folder containing a `manifest.json`
  plus an entry script and menubar01 picks it up. See
  [Plugin Manifest Schema](#plugin-manifest-schema) below.
- **Five plugin types** — `Executable`, `Streamable`, `Shortcut` (Apple
  Shortcuts), `Ephemeral`, and `Packaged` (`.swiftbar` bundle).
- **Rich menu parameters** — `href=`, `bash=`, `terminal=`, `color=`,
  `font=`, `size=`, `refresh=`, `dropdown=`, `notify=`, `webview=`, …
- **Plugin metadata** — inline `<swiftbar.*>` / `<xbar.*>` comments or
  `manifest.json` fields.
- **Terminal integration** — Terminal.app, iTerm2, Ghostty, Kitty.
- **Notifications, Shortcuts intents, URL scheme** — `menubar01://`
  plus the legacy `swiftbar://` is preserved for compatibility.

## Build & run

```bash
open SwiftBar/SwiftBar.xcodeproj
# pick the menubar01 scheme → "My Mac" → Run (⌘R)
```

> The Xcode project file is still named `SwiftBar.xcodeproj` for git
> history continuity. Renaming it is a follow-up step tracked in
> `MENUBAR01_MIGRATION_REPORT.md`.

## Plugin Manifest Schema

```
my-plugin/
├── manifest.json    # plugin metadata (required)
└── my-plugin.sh     # entry script (referenced from manifest)
```

```json
{
  "name": "Battery",
  "version": "1.0.0",
  "entry": "plugin.sh",
  "refreshInterval": 30,
  "environment": { "API_KEY": "" },
  "parameters": [
    { "name": "CITY", "type": "string", "default": "Cupertino" }
  ]
}
```

## Environment variables exposed to plugins

| Variable | Value |
| --- | --- |
| `MENUBAR01_VERSION` | menubar01 version (`x.y.z`) |
| `MENUBAR01_BUILD` | build number (`CFBundleVersion`) |
| `MENUBAR01_PLUGINS_PATH` | path to the Plugin Folder |
| `MENUBAR01_PLUGIN_PATH` | path to the running plugin |
| `MENUBAR01_PLUGIN_CACHE_PATH` | per-plugin cache directory |
| `MENUBAR01_PLUGIN_DATA_PATH` | per-plugin data directory |
| `MENUBAR01_PLUGIN_REFRESH_REASON` | refresh trigger name |
| `MENUBAR01_LAUNCH_TIME` | menubar01 launch time (ISO8601) |
| `SWIFTBAR_*` | legacy aliases — old plugins continue to read these |

## URL scheme

`menubar01://` and `swiftbar://` both resolve to the same handlers.

| Endpoint | Description | Example |
| --- | --- | --- |
| `refreshallplugins` | Force-refresh every loaded plugin | `menubar01://refreshallplugins` |
| `refreshplugin?name=…` | Force-refresh a single plugin | `menubar01://refreshplugin?name=weather` |
| `enableplugin?name=…` | Enable a plugin by name | `menubar01://enableplugin?name=weather` |
| `disableplugin?name=…` | Disable a plugin by name | `menubar01://disableplugin?name=weather` |
| `setephemeralplugin` | Show a temporary menu item | `menubar01://setephemeralplugin?name=eph&content=hi` |
| `notify` | Post a notification | `menubar01://notify?plugin=…&title=…` |
| `copysystemreport` | Copy the system report to the clipboard | `menubar01://copysystemreport` |

## Acknowledgements

menubar01 is built on top of the SwiftBar code base. The bundled SwiftBar
dependencies (`HotKey`, `LaunchAtLogin`, `Preferences`, `Sparkle`,
`SwiftCron`) are reused unmodified.

## License

See `LICENSE`. menubar01 carries the same license as the upstream
SwiftBar project.
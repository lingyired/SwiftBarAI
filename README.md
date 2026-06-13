# menubar01

menubar01 is an independent macOS menu-bar platform. It lets you turn
any folder containing a `manifest.json` + an executable script (bash,
python, node, swift, …) into a menu-bar app and keep the macOS menu
bar fully under your control.

This project is a fork of [SwiftBar](https://github.com/swiftbar/SwiftBar),
rebranded and re-platformed for new product directions:

- AI-generated plugins
- AI-assisted plugin development
- Plugin ecosystem
- Automation tool runtime

## Highlights

- **Folder-based plugins** — drop a folder containing a `manifest.json`
  plus an entry script and menubar01 picks it up. See
  [Plugin Manifest Schema](#plugin-manifest-schema) below and the full
  spec in [`README-MANIFEST-PLUGINS.md`](README-MANIFEST-PLUGINS.md).
- **Three plugin types** — `Executable` (default), `Shortcut` (Apple
  Shortcuts), and `Ephemeral` (URL-driven). All three are loaded via
  `FolderPlugin`, which is the only active plugin class in the
  discovery pipeline.
- **Rich menu parameters** — `href=`, `bash=`, `terminal=`, `color=`,
  `font=`, `size=`, `refresh=`, `dropdown=`, `notify=`, `webview=`, …
- **Manifest-only metadata** — plugin metadata lives entirely in
  `manifest.json`. menubar01 does **not** parse inline `<swiftbar.*>` /
  `<xbar.*>` / `<bitbar.*>` comments from script bodies.
- **Declarative parameters** — strings, numbers, booleans, and
  enums declared in `manifest.json` are surfaced to the entry script
  as `MENUBAR01_PARAM_<NAME>` env vars and persisted to
  `<plugin-folder>/vars.json`.
- **Terminal integration** — Terminal.app, iTerm2, Ghostty, Kitty.
- **Notifications, Shortcuts intents, URL scheme** — `menubar01://`.

## Build & run

```bash
open SwiftBar/SwiftBar.xcodeproj
# pick the menubar01 scheme → "My Mac" → Run (⌘R)
```

> The Xcode project file is still named `SwiftBar.xcodeproj` for git
> history continuity. Renaming it is a follow-up step tracked in
> [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) § 4.

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
  "author": "Alice",
  "entry": "plugin.sh",
  "refreshInterval": 30,
  "environment": { "API_KEY": "" },
  "parameters": [
    { "name": "CITY", "type": "string", "default": "Cupertino" }
  ]
}
```

See [`README-MANIFEST-PLUGINS.md`](README-MANIFEST-PLUGINS.md) for the
full schema, every field, and a worked example.

## Environment variables exposed to plugins

| Variable | Value |
| --- | --- |
| `MENUBAR01_VERSION` | menubar01 version (`x.y.z`) |
| `MENUBAR01_BUILD` | build number (`CFBundleVersion`) |
| `MENUBAR01_PLUGINS_PATH` | path to the Plugin Folder |
| `MENUBAR01_PLUGIN_PATH` | path to the running entry script |
| `MENUBAR01_PLUGIN_PACKAGE_PATH` | path to the plugin's directory |
| `MENUBAR01_PLUGIN_CACHE_PATH` | per-plugin cache directory |
| `MENUBAR01_PLUGIN_DATA_PATH` | per-plugin data directory |
| `MENUBAR01_PLUGIN_REFRESH_REASON` | refresh trigger name |
| `MENUBAR01_LAUNCH_TIME` | menubar01 launch time (ISO8601) |
| `MENUBAR01_PARAM_<NAME>` | value of a parameter declared in `manifest.json` |

> The historical `SWIFTBAR_*` env vars are **not** exposed. SwiftBar
> plugins that read them will see nothing and must be ported to
> `manifest.json`.

## URL scheme

| Endpoint | Description | Example |
| --- | --- | --- |
| `refreshallplugins` | Force-refresh every loaded plugin | `menubar01://refreshallplugins` |
| `refreshplugin?name=…` | Force-refresh a single plugin | `menubar01://refreshplugin?name=weather` |
| `enableplugin?name=…` | Enable a plugin by name | `menubar01://enableplugin?name=weather` |
| `disableplugin?name=…` | Disable a plugin by name | `menubar01://disableplugin?name=weather` |
| `setephemeralplugin` | Show a temporary menu item | `menubar01://setephemeralplugin?name=eph&content=hi` |
| `notify` | Post a notification | `menubar01://notify?plugin=…&title=…` |
| `copysystemreport` | Copy the system report to the clipboard | `menubar01://copysystemreport` |

> The previous `swiftbar://` URL scheme is **not** recognised. menubar01
> is a hard fork with no backward compatibility; existing
> `swiftbar://` callers must be updated to `menubar01://`.

## Acknowledgements

menubar01 is built on top of the SwiftBar code base. The bundled
dependencies (`HotKey`, `LaunchAtLogin`, `Preferences`, `Sparkle`,
`SwifCron`) are reused unmodified.

## License

See `LICENSE`. menubar01 carries the same license as the upstream
SwiftBar project.

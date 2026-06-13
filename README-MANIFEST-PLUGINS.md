# menubar01 Plugin Manifest Schema

> The full specification of the `manifest.json` format that drives
> every active menubar01 plugin. menubar01 is a hard fork of SwiftBar
> and **does not** recognise the older `.swiftbar` directory format,
> script-header tags (`<swiftbar.*>`, `<xbar.*>`, `<bitbar.*>`),
> `.swiftbarignore` files, or `SWIFTBAR_*` environment variables. If
> you are porting an existing SwiftBar plugin, see
> [Migrating from SwiftBar](#7-migrating-from-swiftbar) at the bottom.

## 1. Directory layout

A plugin is a folder:

```
my-plugin/
├── manifest.json     # required — source of truth for metadata
├── my-plugin.sh      # entry script (path declared in manifest.entry)
├── icon.png          # optional — used as the status-bar icon
├── vars.json         # optional — written by menubar01 to persist parameter values
└── …                 # any other files referenced by the entry script
```

`manifest.json` is the only required file. The folder is picked up by
`PluginManager` the next time it rescans the Plugin Folder, and is
identified by its **resolved path** (symlinks resolved).

## 2. `manifest.json` schema

The schema is a `Codable` struct (`SwiftBar/Plugin/PluginManifest.swift`).
All fields are optional unless marked otherwise.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string | folder basename | Display name. |
| `version` | string | `""` | Semver string. |
| `description` | string | `""` | Long-form description shown in the About panel. |
| `author` | string | `""` | Plugin author. |
| `aboutUrl` | string | `""` | URL surfaced in the About panel. |
| `image` | string | `""` | URL to a preview image shown in the About panel. |
| `type` | string | `"executable"` | One of `executable` / `shortcut` / `ephemeral` (case-insensitive; the loader maps to `PluginType`). |
| `entry` | string | first `plugin.*` file in the folder | Path (relative to the plugin folder) of the entry script. |
| `refreshInterval` | number | — | Refresh interval in seconds. Falls back to the interval encoded in the entry script's filename (e.g. `plugin.30s.sh` → 30s). |
| `schedule` | string | `""` | `\|`-separated list of cron expressions. When set, takes precedence over `refreshInterval`. |
| `runInBash` | boolean | `true` | Run the entry script under `/bin/bash` instead of the user's shell. |
| `environment` | object | `{}` | Extra env vars injected into the entry script, merged on top of the `MENUBAR01_*` defaults. |
| `dependencies` | string | `""` | Comma- or whitespace-separated tool/runtime dependencies. Shown in the About panel; informational only. |
| `parameters` | array | `[]` | User-configurable parameters (see [§ 3 Parameters](#3-parameters)). |
| `hideAbout` | boolean | `false` | Hide the default "About Plugin" menu item. |
| `hideRunInTerminal` | boolean | `false` | Hide the "Run in Terminal" menu item. |
| `hideLastUpdated` | boolean | `false` | Hide the "Last Updated" indicator. |
| `hideDisablePlugin` | boolean | `false` | Hide the "Disable Plugin" menu item. |
| `hideMenubar01` | boolean | `false` | Hide the "menubar01" submenu (the parent menu of plugin-specific entries). |

Unknown fields are ignored — forward compatibility is additive.

## 3. Parameters

A parameter declared in `parameters[]` is surfaced to the entry script
as `MENUBAR01_PARAM_<NAME>` and persisted by menubar01 in
`<plugin-folder>/vars.json` after the user edits it from the
preferences pane.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Parameter name. Becomes the env-var suffix. |
| `type` | string | yes | One of `string` / `number` / `boolean` / `select`. |
| `default` | string | yes | Default value (string-encoded; `number` and `boolean` are parsed from the string at access time). |
| `description` | string | yes | Shown next to the field in the preferences UI. |
| `options` | string[] | for `select` only | Allowed values for the `select` type. |

Example:

```json
"parameters": [
  {
    "name": "CITY",
    "type": "string",
    "default": "Cupertino",
    "description": "City to display weather for."
  },
  {
    "name": "TEMP_UNIT",
    "type": "select",
    "default": "C",
    "description": "Temperature unit.",
    "options": ["C", "F"]
  },
  {
    "name": "REFRESH_MIN",
    "type": "number",
    "default": "30",
    "description": "Refresh interval in minutes."
  }
]
```

## 4. Environment variables exposed to the entry script

| Variable | Source | Notes |
| --- | --- | --- |
| `MENUBAR01_VERSION` | menubar01 | `x.y.z`. |
| `MENUBAR01_BUILD` | menubar01 | `CFBundleVersion`. |
| `MENUBAR01_PLUGINS_PATH` | menubar01 | Path to the Plugin Folder. |
| `MENUBAR01_PLUGIN_PATH` | menubar01 | Path to the running entry script. |
| `MENUBAR01_PLUGIN_PACKAGE_PATH` | menubar01 | Path to the plugin folder. |
| `MENUBAR01_PLUGIN_CACHE_PATH` | menubar01 | Per-plugin cache directory (already created). |
| `MENUBAR01_PLUGIN_DATA_PATH` | menubar01 | Per-plugin data directory (already created). |
| `MENUBAR01_PLUGIN_REFRESH_REASON` | menubar01 | `FirstLaunch` / `Schedule` / `WakeFromSleep` / `Manual` / etc. |
| `MENUBAR01_LAUNCH_TIME` | menubar01 | menubar01 launch time in ISO8601. |
| `MENUBAR01_PARAM_<NAME>` | `parameters[]` | One env var per declared parameter. |
| `OS_APPEARANCE` | system | `Dark` / `Light`. |
| `OS_VERSION_MAJOR` / `_MINOR` / `_PATCH` | system | |
| `OS_LAST_SLEEP_TIME` / `OS_LAST_WAKE_TIME` | menubar01 | Sleep/wake timestamps. |

> The historical `SWIFTBAR_*` env vars are **not** exposed.

## 5. Output format

The entry script's stdout is parsed line by line into a menu tree
(see [`docs/06-Plugin-Output-Parsing.md`](docs/06-Plugin-Output-Parsing.md)).
Per-line parameters (`href=`, `bash=`, `terminal=`, `color=`, `font=`,
`size=`, `refresh=`, `dropdown=`, `notify=`, `webview=`, `…`) are
parsed from the same line. A `---` line is a section break.

The first line is rendered as the status-bar title; subsequent lines
become the dropdown menu.

## 6. Worked example

`weather/manifest.json`:

```json
{
  "name": "Weather",
  "version": "1.0.0",
  "author": "Alice",
  "description": "Shows today's weather for the configured city.",
  "entry": "weather.sh",
  "refreshInterval": 1800,
  "environment": { "API_KEY": "" },
  "parameters": [
    {
      "name": "CITY",
      "type": "string",
      "default": "Cupertino",
      "description": "City to display weather for."
    },
    {
      "name": "UNIT",
      "type": "select",
      "default": "C",
      "description": "Temperature unit.",
      "options": ["C", "F"]
    }
  ]
}
```

`weather/weather.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

CITY="${MENUBAR01_PARAM_CITY:-Cupertino}"
UNIT="${MENUBAR01_PARAM_UNIT:-C}"

RESP=$(curl -sf "https://wttr.in/${CITY}?format=j1" | jq '.current_condition[0]')

TEMP_C=$(echo "$RESP" | jq -r '.temp_C')
TEMP_F=$(echo "$RESP" | jq -r '.temp_F')
DESC=$(echo "$RESP" | jq -r '.weatherDesc[0].value')

case "$UNIT" in
  F) TEMP="$TEMP_F °F" ;;
  *) TEMP="$TEMP_C °C" ;;
esac

echo "${CITY}: ${TEMP}, ${DESC} | size=14"
echo "---"
echo "Refresh now | refresh=true"
echo "Open wttr.in | href=https://wttr.in/${CITY}"
echo "---"
echo "About | href=https://github.com/example/weather-menubar01"
```

## 7. Migrating from SwiftBar

A SwiftBar plugin can be ported in three steps:

1. **Move the script into a folder.** Create a new folder, drop the
   script inside, and add a `manifest.json` next to it with at least
   `name`, `entry`, and any user-facing metadata.
2. **Convert script-header tags to manifest fields.** Every
   `<swiftbar.refresh>`, `<swiftbar.image>`, `<swiftbar.hideAbout>`,
   etc. moves to the matching field in `manifest.json`. `<xbar.var>`
   blocks move to `parameters[]`.
3. **Read `MENUBAR01_*` env vars instead of `SWIFTBAR_*`.** Replace
   every `SWIFTBAR_PLUGIN_PATH` etc. with the matching
   `MENUBAR01_*` name.

There is no compatibility shim. Old SwiftBar plugins that are dropped
into the Plugin Folder unchanged will be silently ignored.

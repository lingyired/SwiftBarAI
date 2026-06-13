# menubar01 AI Plugin Architecture

> Forward-looking architecture notes for the AI-assisted plugin system
> that will ship on top of the migrated menubar01 core. This document
> does **not** rewrite the plugin system — it plans future modules on
> top of the existing `FolderPlugin` / `PluginManager` /
> `PluginManifest` scaffolding.

## 0. Current plugin system recap

menubar01's plugin runtime is a folder-based, manifest-driven model:

- **Single plugin shape** — every active plugin is a directory
  containing a `manifest.json` (the source of truth for all metadata)
  and an entry-point script. The discovery pipeline in
  `PluginManager.getPluginList()` matches folders that contain a
  `manifest.json`; single-file scripts and `.swiftbar` directory
  bundles are no longer recognised.
- **Plugin loading** — `FolderPlugin.init(manifestDirectory:manifest:)`
  parses the manifest, infers the entry script, and hands the
  resulting `FolderPlugin` instance to the existing
  `PluginManager.loadPlugins()` pipeline (`enable()` → `start()` →
  `refresh()` → `terminate()`).
- **Plugin types** — `PluginType` enum has three cases:
  `Executable` (default; one-shot script), `Shortcut` (Apple
  Shortcuts wrapper), `Ephemeral` (URL-driven menu item). The
  historical `Streamable` and `Packaged` cases are gone (see
  [`changes/2026-06-13-drop-legacy-compat.md`](changes/2026-06-13-drop-legacy-compat.md)).
- **Output rendering** — `MenubarItem` parses the plugin's stdout
  into a `MenuItemNode` tree, diffs against the previous tree, and
  patches the live `NSMenu` in place.
- **Plugin metadata** — `PluginMetadata` is a plain data class
  populated entirely from `manifest.json` by
  `FolderPlugin.buildMetadata(from:)`. There is no script-header
  parser and no extended-attribute cache.
- **Plugin repository** — `PluginRepository.shared.refreshRepositoryData()`
  fetches a remote catalogue (today: the upstream SwiftBar
  `swiftbar/swiftbar-plugins` repo — re-mirroring under a new owner
  is a follow-up) and lets the user install/uninstall plugins
  in-app.

The runtime is **plugin-agnostic**: it does not care whether the entry
script was hand-written, generated, or served from a marketplace. That
is the leverage we will build on.

## 1. Future modules

```
                ┌───────────────────────────────────────────┐
                │            menubar01 app                 │
                ├───────────────────────────────────────────┤
                │  PluginManager     MenubarItem renderer  │
                │  PluginMetadata    MenuLineParameters    │
                │  PluginRepository  PreferencesStore      │
                └──────┬───────────────────┬───────────────┘
                       │                   │
        ┌──────────────┴──────┐    ┌───────┴────────────┐
        │  PluginManifest    │    │  PluginMarketplace │
        │  (existing)        │    │  (new)              │
        └──────────────┬──────┘    └───────┬────────────┘
                       │                   │
            ┌──────────┴──────────┐  ┌─────┴──────────┐
            │  FolderPlugin       │  │  PluginSandbox │
            │  (existing loader)  │  │  (new)         │
            └──────────┬──────────┘  └─────────────────┘
                       │
              ┌────────┴─────────┐
              │ AIPluginGenerator│  ← new
              │  (new)           │
              └──────────────────┘
```

### 1.1 `PluginManifest` (existing — `SwiftBar/Plugin/PluginManifest.swift`)

Already covers the public schema. Future extension points:

| Field | Status | Future |
| --- | --- | --- |
| `name`, `version`, `author`, `entry` | exists | unchanged |
| `parameters[]` | exists | add `prompt` field for AI-assisted parameter entry |
| `dependencies` | exists | add `requires[]` with version pinning (npm-style semver) |
| `generated: { by: "menubar01.ai", promptId, promptVersion }` | **new** | provenance tracking for AI-generated plugins |
| `intent: "weather" \| "timer" \| "..."` | **new** | typed intent vocabulary the generator uses to seed the model |
| `capabilities: ["network", "clipboard", "notifications"]` | **new** | explicit capability declaration for the permission UI |

### 1.2 `FolderPlugin` (existing — `SwiftBar/Plugin/FolderPlugin.swift`)

No rewrite. Future enhancement is a **declared-capability gate**: the
loader refuses to spawn a plugin whose `manifest.json` requests
`network` access without the user granting it once at install time.

### 1.3 `MenubarItem` renderer (existing — `SwiftBar/MenuBar/MenuBarItem.swift`)

The renderer is already a tree-diff engine. AI plugins benefit from the
fact that they can output any well-formed menu text — the renderer
doesn't care whether the script was AI-written or hand-written. The
only planned addition is **live preview**: when the AI generator runs
the script in a sandbox, the resulting menu tree is shown inline in
the generator UI before the user accepts the plugin.

### 1.4 `PluginManager` (existing singleton)

Future: expose a public Combine `Publisher<PluginEvent>` so the AI
generator can subscribe to plugin lifecycle events without subclassing.

### 1.5 `AIPluginGenerator` (new)

The headline module. Design principles:

1. **Tooling first, autonomy later.** V1 returns a `manifest.json` +
   an entry script for the user to review and tweak. V2 may ask the
   user to confirm before saving into the Plugin Folder.
2. **Deterministic prompts.** Each generator run is keyed by a stable
   `promptId` so the user can reproduce, audit, or downgrade a plugin.
3. **Sandboxed execution.** Generated scripts run inside the existing
   `FolderPlugin` runtime with the manifest's declared capabilities
   only.

Sketch:

```swift
public protocol AIPluginGenerator {
    /// Build a plugin from a natural-language request.
    /// `request` is free-form text ("show today's weather in the menu bar").
    /// `context` carries any pre-filled parameters (the user's city,
    /// chosen refresh interval, …).
    func generate(
        request: String,
        context: AIGeneratorContext = .empty
    ) async throws -> GeneratedPlugin
}

public struct GeneratedPlugin {
    let manifest: PluginManifest         // fully populated
    let entryScript: String              // shebang + body
    let explanation: String              // human-readable rationale
    let promptId: String                 // stable hash for reproducibility
    let promptVersion: String            // bumped when the generator changes
}

public enum AIGeneratorError: Error {
    case unsafeRequest                  // the model produced a manifest that
                                        // declares capabilities it does not have
    case unrenderableMenu                // the model produced no parseable
                                        // menu output during sandboxed dry-run
    case rateLimited
    case providerFailure(reason: String)
}
```

### 1.6 `PluginMarketplace` (new)

A built-in catalogue of AI-generated plugins that the user can browse,
preview, and install with one click. Distinct from the existing
`PluginRepository` (which today points at the SwiftBar plugin repo).

```swift
public struct MarketplaceEntry: Codable, Identifiable {
    public let id: String                 // stable slug
    public let name: String
    public let summary: String
    public let category: String
    public let previewImageURL: URL?
    public let installCount: Int
    public let rating: Double
    public let generatorPromptId: String  // provenance
    public let signedBy: String?          // publisher signature
}
```

Marketplace data is fetched from a remote catalogue (separate from the
plugin repository). Install flow:

1. User picks a marketplace entry.
2. `MarketplaceClient.fetchPackage(id)` returns the
   `manifest.json` + entry script bundle.
3. The `PluginManager.importPlugin(from:)` pipeline writes the bundle
   into the user's Plugin Folder (under a `_marketplace/` subfolder so
   it can be uninstalled cleanly).

## 2. End-to-end user flow

> "帮我生成一个显示天气的插件"

1. User clicks **"Generate plugin with AI…"** in the Plugin Repository
   window.
2. A modal sheet captures the request ("show today's weather in the
   menu bar"), optional context (city, refresh interval), and shows
   a privacy notice: the request is sent to the model provider; the
   user can opt out and switch to a local model.
3. `AIPluginGenerator.generate(request:context:)` runs.
4. The generator returns a `GeneratedPlugin`. The UI shows the
   manifest, the entry script, the explanation, and a **live preview**
   of the rendered menu items (sandboxed execution against
   `Environment.shared`).
5. The user can iterate ("use Fahrenheit", "refresh every 30 minutes",
   "include wind speed"). Each iteration bumps `promptVersion`.
6. On accept, the plugin is written into the Plugin Folder via the
   existing `PluginManager.importPlugin(from:)`.
7. The user can re-edit any field directly in Preferences → Plugins →
   the existing `PluginDetailsView`.

## 3. Permission model

AI-generated plugins may need capabilities that hand-written plugins
also need (network, calendar, clipboard). To prevent scope creep we
adopt an explicit manifest field:

```json
{
  "name": "Weather",
  "capabilities": ["network"],
  "entry": "weather.sh"
}
```

The `PluginManager` enforces:

- `network` → app sandbox hole punch (already supported via
  `menubar01.entitlements`).
- `calendar` → requires `NSCalendarsUsageDescription` (already in
  `Info.plist`).
- `clipboard` → new; gated behind a confirmation dialog.
- `notifications` → new; gated behind `UNUserNotificationCenter`
  request.

If a generated plugin requests more capabilities than the user
approves at install time, the runtime refuses to spawn it and shows a
clear "missing permission" error in the status bar fallback.

## 4. Storage and privacy

- The generator's prompt body, the model's response, and the rendered
  menu tree are stored locally at
  `~/Library/Application Support/menubar01/AIGenerator/{promptId}/`.
- The user can wipe all generator history from a single menu item in
  Preferences → Advanced.
- No prompt data is sent to a remote service unless the user has
  explicitly enabled a remote provider in Preferences → AI. The
  default install ships with a local model toggle that does no
  network I/O for generation.

## 5. Non-goals (v1)

- **Code review by AI** — out of scope for the v1 generator. Plugins
  are returned to the user as text; review happens in the host's
  editor.
- **Live re-prompt** — v1 does not auto-repair failing plugins by
  asking the model again. Failure paths land in the existing plugin
  error UI.
- **Marketplace publishing from the app** — v1 reads from the
  catalogue; the user cannot publish to it from inside the app.
- **Plugin signing / notarisation** — out of scope for v1. The
  marketplace assumes HTTPS delivery and trusts the catalogue
  publisher.

## 6. Implementation roadmap

| Milestone | Scope | Existing dependency |
| --- | --- | --- |
| **M1** | `AIPluginGenerator` skeleton + sandboxed dry-run against `FolderPlugin`. | `PluginManifest`, `Environment.swift` |
| **M2** | Live preview UI in the Plugin Repository window. | `PluginRepositoryView`, `PluginEntryView` |
| **M3** | Capability-gate install flow. | `PluginManager.importPlugin` |
| **M4** | `PluginMarketplace` catalogue + install flow. | `PluginRepositoryAPI` |
| **M5** | Persistence layer for generator history. | `~/Library/Application Support/menubar01/` |

## 7. Public API sketch (v1)

The goal of v1 is to keep the API surface additive — existing plugins
must continue to work without recompilation.

```swift
// New file: SwiftBar/AI/AIGenerator.swift

public struct AIGeneratorContext {
    public var model: String               // "gpt-4o-mini" / "local-7b-q4"
    public var city: String?
    public var refreshIntervalSeconds: Int?
    public var language: String            // for the script's comments

    public static let empty = AIGeneratorContext(
        model: "gpt-4o-mini", city: nil, refreshIntervalSeconds: nil, language: "en"
    )
}

public protocol AIPluginGenerator {
    func generate(
        request: String,
        context: AIGeneratorContext
    ) async throws -> GeneratedPlugin
}

public enum AIPluginGeneratorFactory {
    public static func makeDefault() -> AIPluginGenerator
    public static func makeLocal(modelPath: URL) -> AIPluginGenerator
    public static func makeRemote(
        endpoint: URL, apiKey: String
    ) -> AIPluginGenerator
}
```

The factory is wired into the existing Plugin Repository window via a
single "Generate plugin…" button. The factory's defaults come from
`PreferencesStore` (new key `AIProvider`).

## 8. Why we are not rewriting the plugin system

The existing plugin system is already:

- **Sandbox-aware** — plugin output is parsed, not `eval`'d. Generated
  scripts cannot escape the menu bar renderer.
- **Diff-friendly** — incremental updates mean a flaky AI plugin does
  not thrash the menu bar.
- **Observable** — `PluginDebugInfo` + system report give us a hook
  to surface generator failures back to the model in a future version.
- **Multi-runtime** — the same protocol is used for shell, Python,
  and Shortcut plugins. The AI generator returns the same
  `manifest.json` regardless of the entry-script language.

The right move is to **layer** the AI features on top of the existing
protocol, not replace it.

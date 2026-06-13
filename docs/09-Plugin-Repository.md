# Plugin Repository

The "Get Plugins…" window is a SwiftUI in-app browser for community-contributed plugins. The backing data is the [swiftbar/swiftbar-plugins](https://github.com/swiftbar/swiftbar-plugins) repository. SwiftBar fetches the list, then downloads individual plugin files into the user's plugin folder on install.

## `PluginRepository` — the data layer

[PluginRepository.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Plugin%20Repository/PluginRepository.swift) is a `NSObject` that acts as the source of truth for the plugin browser.

### Singleton + persistence

- `static let shared = PluginRepository()`.
- On `init`, the manager reads `pluginRepositoryJSONPath` and loads any cached `JSON`-encoded `RepositoryPlugin` list. This is what the user sees immediately on launch.
- The file is at `~/Library/Application Support/SwiftBar/PluginRepository.json`.

### Git checkouts for the plugin repository

The repository can also be checked out to `dataDirectory/PluginRepositoryData/`. This is the only way SwiftBar can read the README/description of each plugin without bundling the data. The data folder is used by:

- `PluginRepositoryView` — to display README excerpts (markdown).
- `PluginEntryModalView` — to display long descriptions.

A `git fetch` happens on `refresh()` if the data folder exists; otherwise SwiftBar creates it with a shallow clone. The status of the clone is exposed via `isCloned` and `cloningStatus`.

### Refreshing

`refresh(_:)` is called from:

- `AppShared.getPlugins()` — the user clicks "Get Plugins…".
- `AppDelegate.repositoryToolbar` refresh button.
- `AppDelegate.application(_:open:)` for `swiftbar://refreshrepositorydata`.

Steps:

1. POST to the repository `update` endpoint (see `PluginRepositoryAPI.update`).
2. Download the latest `plugins.json` snapshot if the API returns one.
3. `git fetch` + `git reset` in the data folder (if present).
4. Re-read the JSON and notify observers.

### Searching / filtering

`filteredRepositoryPlugins(query:)` is called on every keystroke of the repository search field (debounced via `NotificationCenter`). The search matches:

- The plugin `title` (case-insensitive).
- The plugin `author` (case-insensitive).
- The plugin `desc` (case-insensitive).
- The plugin tags (case-insensitive).
- The `category` (case-insensitive).

The result is `repositoryPlugins.filter { … }`.

### Install / uninstall

`install(plugin:)` calls `delegate.pluginManager.importPlugin(from: sourceFileURL) { … }` and lets the PluginManager copy the file to the user's plugin folder.

`uninstall(plugin:)` removes the file using the `xattr`-encoded source URL (`.SwiftBar.SourceURL`); it is a no-op if the file wasn't installed from the repository.

## `PluginRepositoryAPI` — the request layer

[PluginRepositoryAPI.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Plugin%20Repository/PluginRepositoryAPI.swift) is a `NSObject` that performs HTTP requests. It uses `URLSession` and a `Result`-based completion style. All endpoints are POSTs to `https://api.github.com/repos/swiftbar/swiftbar-plugins/...`.

### Endpoints

- `RepositoryPluginList` — `GET` `/contents/plugins.json?ref=main`, `Accept: application/vnd.github.v3.raw`. Returns `[RepositoryPlugin]`.
- `plugin(id:)` — GET `/contents/plugins/{id}/{id}.json?ref=main`, returns a single plugin.
- `PluginSourceFile` — `GET` `/contents/plugins/{id}/{id}.{ext}?ref=main`, raw file bytes. (Used to install.)
- `Image` — `GET` `/contents/plugins/{id}/image?ref=main`, raw image bytes.

The model `RepositoryPlugin` mirrors the JSON:

```json
{
  "id": "1password",
  "title": "1Password Status",
  "author": "Prajwal Rao",
  "github": null,
  "desc": "Display 1Password subscription status",
  "image": "https://raw.githubusercontent.com/swiftbar/swiftbar-plugins/main/Plugins/1password/image.png",
  "dependencies": ["1password-cli"],
  "aboutURL": "https://github.com/swiftbar/swiftbar-plugins/blob/main/Plugins/1password/README.md",
  "source": "./1password.10s.sh",
  "version": "v1.0.0",
  "gitHubURL": "https://github.com/swiftbar/swiftbar-plugins/tree/main/Plugins/1password"
}
```

`RepositoryPlugin.Plugin` is a `Codable` struct with computed `gitHubURL` and `sourceFileURL` properties.

## `PluginRepositoryView` — the SwiftUI pane

[PluginRepositoryView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Plugin%20Repository/PluginRepositoryView.swift) wraps the data in a `NavigationSplitView` (sidebar with categories, detail with the plugin list). It uses:

- `PluginListView` — main list with `PluginEntryView` cells.
- `PluginEntryModalView` — the install modal.
- `PluginListEntryView` — alternative compact list cell.
- `ImageView` — async image loader with placeholder fallback.

The view listens for `.repositoirySearchUpdate` notifications and updates the search query. The search field itself is wired up in `AppDelegate+Toolbar.swift`.

## `PluginEntryView` — the cell

[PluginEntryView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Plugin%20Repository/PluginEntryView.swift) is a rounded-rectangle card with title, author (linking to GitHub if available), image, description, and footer with links to "Plugin Source" and "About Plugin". Tapping the card opens `PluginEntryModalView`.

## `PluginEntryModalView` — the install modal

Also in [PluginEntryView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/UI/Plugin%20Repository/PluginEntryView.swift). The modal shows:

- Title and author.
- Image.
- Description (longer line limit).
- "Dependencies" list.
- "About" / "Source" links.
- An install button that flips through `InstallStatus` (`.Install` → `.Downloading` → `.Installed` / `.Failed`).

The install uses `delegate.pluginManager.importPlugin(from: sourceFileURL) { result in … }`. The status is reflected in the button color and icon.

import Foundation
import os

/// File name menubar01 looks for inside a folder-based plugin.
let pluginManifestFileName = "manifest.json"

/// Schema of `manifest.json` for folder-based plugins.
///
/// Example:
/// ```
/// {
///   "name": "Battery",
///   "version": "1.0.0",
///   "description": "Shows battery info",
///   "author": "Me",
///   "aboutUrl": "https://github.com/you/battery",
///   "dependencies": "bash, curl",
///   "type": "executable",
///   "entry": "plugin.sh",
///   "refreshInterval": 30,
///   "schedule": "*/5 * * * *",
///   "runInBash": true,
///   "environment": {
///     "API_BASE_URL": "https://example.com"
///   },
///   "parameters": [
///     { "name": "API_KEY", "type": "string", "default": "", "description": "API key" }
///   ],
///   "hideAbout": false,
///   "hideRunInTerminal": false,
///   "hideLastUpdated": false
/// }
/// ```
struct PluginManifest: Codable {
    /// The display name shown in the menu. Defaults to the directory name.
    var name: String?
    /// The plugin's semantic version.
    var version: String?
    /// Short one-line description.
    var description: String?
    /// Author / owner.
    var author: String?
    /// "executable" (default) or "streamable".
    var type: PluginType?
    /// Relative path of the script to run, resolved against the manifest directory.
    var entry: String?
    /// Refresh interval in seconds. `0` or negative disables timed refresh.
    var refreshInterval: Double?
    /// Cron expression. Overrides `refreshInterval` when set.
    var schedule: String?
    /// Whether the script should be invoked via `/bin/bash -c`.
    var runInBash: Bool?
    /// Extra environment variables to inject when running the entry script.
    var environment: [String: String]?
    /// User-configurable parameters. Persisted via the existing `xbar.var`
    /// storage so the values flow into the script as `SWIFTBAR_PLUGIN_PARAM_*`
    /// environment variables.
    var parameters: [PluginManifestParameter]?
    /// Comma-separated tool/runtime dependencies shown in the About panel
    /// (e.g. `bash, python3, curl`). Informational only — menubar01 does not
    /// install these for you.
    var dependencies: String?
    /// URL surfaced in the About panel / `AboutPlugin` UI.
    var aboutUrl: String?
    /// Optional preview image shown in the About panel.
    var image: String?
    /// Hide the default "About Plugin" menu item.
    var hideAbout: Bool?
    /// Hide the "Run in Terminal" menu item.
    var hideRunInTerminal: Bool?
    /// Hide the "Last Updated" indicator.
    var hideLastUpdated: Bool?
    /// Hide the "Disable Plugin" menu item.
    var hideDisablePlugin: Bool?
    /// Hide the "menubar01" menu item (parent menu of plugin-specific entries).
    var hideMenubar01: Bool?

    /// Permissions the plugin needs at install time. Mapped 1-to-1
    /// to `PluginCapability` raw values by `resolvedCapabilities`;
    /// unknown strings are dropped with an `os_log` warning so
    /// manifests produced by future builds still decode.
    var capabilities: [String]?

    /// The manifest format version this struct understands.
    static let currentVersion = 1

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, type, entry
        case refreshInterval, schedule, runInBash, environment, parameters
        case dependencies, aboutUrl, image
        case hideAbout, hideRunInTerminal, hideLastUpdated
        case hideDisablePlugin, hideMenubar01, capabilities
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        type = try container.decodeIfPresent(PluginType.self, forKey: .type)
        entry = try container.decodeIfPresent(String.self, forKey: .entry)
        refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        runInBash = try container.decodeIfPresent(Bool.self, forKey: .runInBash)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
        parameters = try container.decodeIfPresent([PluginManifestParameter].self, forKey: .parameters)
        dependencies = try container.decodeIfPresent(String.self, forKey: .dependencies)
        aboutUrl = try container.decodeIfPresent(String.self, forKey: .aboutUrl)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        hideAbout = try container.decodeIfPresent(Bool.self, forKey: .hideAbout)
        hideRunInTerminal = try container.decodeIfPresent(Bool.self, forKey: .hideRunInTerminal)
        hideLastUpdated = try container.decodeIfPresent(Bool.self, forKey: .hideLastUpdated)
        hideDisablePlugin = try container.decodeIfPresent(Bool.self, forKey: .hideDisablePlugin)
        hideMenubar01 = try container.decodeIfPresent(Bool.self, forKey: .hideMenubar01)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
    }

    /// Encodes the manifest, omitting fields that are at their default value so
    /// the resulting JSON stays minimal.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(entry, forKey: .entry)
        try container.encodeIfPresent(refreshInterval, forKey: .refreshInterval)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(runInBash, forKey: .runInBash)
        try container.encodeIfPresent(environment, forKey: .environment)
        try container.encodeIfPresent(parameters, forKey: .parameters)
        try container.encodeIfPresent(dependencies, forKey: .dependencies)
        try container.encodeIfPresent(aboutUrl, forKey: .aboutUrl)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(hideAbout, forKey: .hideAbout)
        try container.encodeIfPresent(hideRunInTerminal, forKey: .hideRunInTerminal)
        try container.encodeIfPresent(hideLastUpdated, forKey: .hideLastUpdated)
        try container.encodeIfPresent(hideDisablePlugin, forKey: .hideDisablePlugin)
        try container.encodeIfPresent(hideMenubar01, forKey: .hideMenubar01)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
    }
}

/// User-facing shape of a parameter inside `manifest.json`.
///
/// This is a thin wrapper over `PluginVariable` so the JSON field names
/// (`default`, `description`) can stay in the more common / gitignore-style
/// camelCase form rather than the `defaultValue` / `description` keys the
/// internal `PluginVariable` Codable expects.
struct PluginManifestParameter: Codable, Equatable {
    /// Variable name — also used as the on-disk `vars.json` key and the
    /// `SWIFTBAR_PLUGIN_PARAM_<NAME>` environment variable.
    let name: String
    /// One of `string`, `number`, `boolean`, `select`.
    let type: PluginVariableType
    /// Default value the parameter takes before the user customises it.
    let `default`: String?
    /// Human-readable description shown in the prefs UI.
    let description: String?
    /// Options for `select` type parameters.
    let options: [String]?

    enum CodingKeys: String, CodingKey {
        case name, type, `default`, description, options
    }

    /// Converts this manifest-level description into the runtime
    /// `PluginVariable` that the rest of menubar01's metadata pipeline expects.
    func toPluginVariable() -> PluginVariable {
        PluginVariable(
            type: type,
            name: name,
            defaultValue: `default` ?? "",
            description: description ?? "",
            options: options ?? []
        )
    }
}

extension PluginManifest {
    /// Resolved entry script URL relative to the manifest directory.
    func resolvedEntryURL(in manifestDirectory: URL) -> URL? {
        guard let entry, !entry.isEmpty else { return nil }
        return manifestDirectory.appendingPathComponent(entry).standardizedFileURL
    }

    /// Resolved plugin type, defaulting to `Executable`.
    var resolvedType: PluginType {
        type ?? .Executable
    }

    /// Resolved refresh interval in seconds, defaulting to "never".
    var resolvedRefreshInterval: Double {
        let value = refreshInterval ?? Double(pluginNeverUpdateInterval)
        if value <= 0 { return Double(pluginNeverUpdateInterval) }
        return value
    }

    /// Decoded capability list. Each raw string in `capabilities` is
    /// mapped through `PluginCapability.init(rawValue:)`; strings
    /// the v1 enum does not recognise are **dropped** (with a
    /// warning) rather than throwing, so manifests authored by a
    /// future build of menubar01 still load. The order of declared
    /// strings is preserved so the gate's "first ungranted
    /// capability wins" error is deterministic.
    var resolvedCapabilities: [PluginCapability] {
        guard let rawValues = capabilities else { return [] }
        var resolved: [PluginCapability] = []
        resolved.reserveCapacity(rawValues.count)
        for raw in rawValues {
            if let capability = PluginCapability(rawValue: raw) {
                resolved.append(capability)
            } else {
                os_log("PluginManifest: dropping unknown capability %{public}@ declared in manifest",
                       log: Log.plugin, type: .info, raw)
            }
        }
        return resolved
    }
}

enum PluginManifestLoader {
    /// Loads a `PluginManifest` from a directory. Returns `nil` if the
    /// directory does not contain a `manifest.json`.
    static func loadManifest(from directory: URL) -> PluginManifest? {
        let manifestURL = directory.appendingPathComponent(pluginManifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL)
        else { return nil }
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            os_log("Failed to parse manifest.json at %{public}@: %{public}@",
                   log: Log.plugin, type: .error, manifestURL.path, error.localizedDescription)
            return nil
        }
    }

    /// Loads the manifest, validates the entry script, and returns the
    /// resolved `PluginManifest` and absolute entry script URL.
    static func loadAndValidate(from directory: URL) -> (manifest: PluginManifest, entryURL: URL)? {
        let manifestURL = directory.appendingPathComponent(pluginManifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL)
        else { return nil }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            os_log("Failed to parse manifest.json at %{public}@: %{public}@",
                   log: Log.plugin, type: .error, manifestURL.path, error.localizedDescription)
            return nil
        }

        // If the manifest omits `entry`, fall back to `plugin.*` discovery
        // so users can author a folder plugin without declaring the entry
        // explicitly.
        let entryPath = manifest.entry ?? FolderPlugin.inferEntryFilename(in: directory)
        guard let entryPath, !entryPath.isEmpty else {
            os_log("manifest.json at %{public}@ is missing the required 'entry' field and no plugin.* file was found",
                   log: Log.plugin, type: .error, manifestURL.path)
            return nil
        }

        let entryURL = directory.appendingPathComponent(entryPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            os_log("Entry script '%{public}@' declared in %{public}@ does not exist",
                   log: Log.plugin, type: .error, entryPath, manifestURL.path)
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: entryURL.path) else {
            os_log("Entry script '%{public}@' declared in %{public}@ is not executable",
                   log: Log.plugin, type: .error, entryPath, manifestURL.path)
            return nil
        }

        return (manifest, entryURL)
    }
}

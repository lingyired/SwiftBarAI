import Cocoa
import Foundation
import SwifCron

// MARK: - Plugin Variable Support (manifest.json parameters)

/// Type of a user-configurable parameter declared in `manifest.json`.
enum PluginVariableType: String, Codable {
    case string
    case number
    case boolean
    case select
}

/// A user-configurable parameter declared in `manifest.json` under
/// `parameters: [...]`. Values are persisted by `PluginVariableStorage`
/// in `<plugin-folder>/vars.json` and surface to the entry script as
/// `MENUBAR01_PARAM_<NAME>` environment variables.
struct PluginVariable: Codable, Identifiable, Hashable {
    var id: String { name }
    let type: PluginVariableType
    let name: String
    let defaultValue: String
    let description: String
    let options: [String]  // For select type

    init(type: PluginVariableType, name: String, defaultValue: String, description: String, options: [String] = []) {
        self.type = type
        self.name = name
        self.defaultValue = defaultValue
        self.description = description
        self.options = options
    }
}

// MARK: - PluginMetadata

/// Runtime model holding a plugin's metadata.
///
/// All fields are populated from `manifest.json` at plugin load time by
/// `FolderPlugin.applyManifestOverrides(_:)`. There is no tag-based
/// script-header parser and no extended-attribute (xattr) cache: the
/// `manifest.json` file is the single source of truth, so this class is
/// a plain data holder used by the menu, preferences, and debug layers.
class PluginMetadata: ObservableObject {
    @Published var name: String
    @Published var version: String
    @Published var author: String
    @Published var github: String
    @Published var desc: String
    @Published var previewImageURL: URL?
    @Published var dependencies: [String]
    @Published var aboutURL: URL?
    @Published var dropTypes: [String]
    @Published var schedule: String
    @Published var type: PluginType
    @Published var hideAbout: Bool
    @Published var hideRunInTerminal: Bool
    @Published var hideLastUpdated: Bool
    @Published var hideDisablePlugin: Bool
    @Published var hideMenubar01: Bool
    @Published var environment: [String: String]
    @Published var runInBash: Bool
    @Published var refreshOnOpen: Bool
    @Published var persistentWebView: Bool
    @Published var useTrailingStreamSeparator: Bool
    @Published var alwaysVisible: Bool
    @Published var variables: [PluginVariable]

    var isEmpty: Bool {
        name.isEmpty
            && version.isEmpty
            && author.isEmpty
            && github.isEmpty
            && desc.isEmpty
            && previewImageURL == nil
            && dependencies.isEmpty
            && aboutURL == nil
    }

    /// Earliest upcoming fire time across the `|`-separated cron expressions
    /// in `schedule`, or `nil` when no schedule is set or none of the
    /// expressions parse.
    var nextDate: Date? {
        let date = schedule.components(separatedBy: "|").compactMap { try? SwifCron($0).next() }.reduce(Date.distantFuture, min)
        return date == Date.distantFuture ? nil : date
    }

    var shouldRunInBash: Bool {
        if PreferencesStore.shared.disableBashWrapper {
            return false
        }
        return runInBash
    }

    init(name: String = "", version: String = "", author: String = "", github: String = "", desc: String = "", previewImageURL: URL? = nil, dependencies: [String] = [], aboutURL: URL? = nil, dropTypes: [String] = [], schedule: String = "", type: PluginType = .Executable, hideAbout: Bool = false, hideRunInTerminal: Bool = false, hideLastUpdated: Bool = false, hideDisablePlugin: Bool = false, hideMenubar01: Bool = false, environment: [String: String] = [:], runInBash: Bool = true, refreshOnOpen: Bool = false, persistentWebView: Bool = false, useTrailingStreamSeparator: Bool = false, alwaysVisible: Bool = false, variables: [PluginVariable] = []) {
        self.name = name
        self.version = version
        self.author = author
        self.github = github
        self.desc = desc
        self.previewImageURL = previewImageURL
        self.dependencies = dependencies
        self.dropTypes = dropTypes
        self.schedule = schedule
        self.aboutURL = aboutURL
        self.type = type
        self.hideAbout = hideAbout
        self.hideRunInTerminal = hideRunInTerminal
        self.hideLastUpdated = hideLastUpdated
        self.hideDisablePlugin = hideDisablePlugin
        self.hideMenubar01 = hideMenubar01
        self.environment = environment
        self.runInBash = runInBash
        self.refreshOnOpen = refreshOnOpen
        self.persistentWebView = persistentWebView
        self.useTrailingStreamSeparator = useTrailingStreamSeparator
        self.alwaysVisible = alwaysVisible
        self.variables = variables
    }

    /// Returns a default-valued `PluginMetadata`. Used by the preferences
    /// panel as the initial state before a real plugin is bound.
    static func empty() -> PluginMetadata {
        PluginMetadata()
    }
}

// MARK: - Plugin Variable Storage

/// Persists the user-customised values of the `PluginVariable`s declared
/// in `manifest.json`. The file lives at `<plugin-folder>/vars.json`,
/// next to the entry script.
class PluginVariableStorage {
    /// File URL of the on-disk `vars.json` for a given entry script path.
    static func variablesFileURL(forPluginFile pluginFile: String) -> URL {
        let pluginURL = URL(fileURLWithPath: pluginFile)
        return pluginURL.deletingPathExtension()
            .appendingPathExtension("vars")
            .appendingPathExtension("json")
    }

    /// Loads the user's saved values for the given plugin's `vars.json`.
    /// Returns an empty dictionary if the file is missing or unparseable.
    static func loadUserValues(pluginFile: String) -> [String: String] {
        let fileURL = variablesFileURL(forPluginFile: pluginFile)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        return values
    }

    /// Persists the user-customised variable values to `vars.json`.
    static func saveUserValues(_ values: [String: String], pluginFile: String) {
        let fileURL = variablesFileURL(forPluginFile: pluginFile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        if let data = try? encoder.encode(values) {
            try? data.write(to: fileURL)
        }
    }

    /// Builds the final `key → value` map by combining the parameter
    /// schema's defaults with any user overrides.
    static func buildEnvironment(variables: [PluginVariable], userValues: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]

        for variable in variables {
            // Use user value if available, otherwise use default
            environment[variable.name] = userValues[variable.name] ?? variable.defaultValue
        }

        return environment
    }
}

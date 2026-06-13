import Cocoa
import Combine

enum TerminalOptions: String, CaseIterable {
    case Terminal
    case iTerm
    case Ghostty
    case Kitty
}

enum ShellOptions: String, CaseIterable {
    case Bash = "bash"
    case Zsh = "zsh"
    case Default = "default"

    var path: String {
        switch self {
        case .Bash:
            "/bin/bash"
        case .Zsh:
            "/bin/zsh"
        case .Default:
            "/bin/zsh"
        }
    }
}

class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    /// The `UserDefaults` instance this store reads from and writes to. Tests
    /// inject a per-suite instance (via `UserDefaults(suiteName:)`) so they do
    /// not contaminate `UserDefaults.standard` for other test cases.
    private let defaults: UserDefaults
    enum PreferencesKeys: String {
        case PluginDirectory
        case ShortcutsFolder
        case DisabledPlugins
        case Terminal
        case Shell
        case HideMenubar01Icon
        case MakePluginExecutable
        case PluginDeveloperMode
        case DisableBashWrapper
        case StreamablePluginDebugOutput
        case PluginDebugMode
        case StealthMode
        case AlwaysShowMenubar01Menu
        case IncludeBetaUpdates
        case DimOnManualRefresh
        case CollectCrashReports
        case DebugLoggingEnabled
        case ShortcutPlugins
        case PluginRepositoryURL
        case PluginSourceCodeURL
    }

    let disabledPluginsPublisher = PassthroughSubject<Any, Never>()

    @Published var pluginDirectoryPath: String? {
        didSet {
            PreferencesStore.setValue(value: pluginDirectoryPath, key: .PluginDirectory, defaults: defaults)
        }
    }

    @Published var shortcutsFolder: String {
        didSet {
            PreferencesStore.setValue(value: shortcutsFolder, key: .ShortcutsFolder, defaults: defaults)
        }
    }

    var pluginDirectoryResolvedURL: URL? {
        guard let path = pluginDirectoryPath as NSString? else { return nil }
        return URL(fileURLWithPath: path.expandingTildeInPath).resolvingSymlinksInPath()
    }

    var pluginDirectoryResolvedPath: String? {
        pluginDirectoryResolvedURL?.path
    }

    @Published var disabledPlugins: [PluginID] {
        didSet {
            let unique = Array(Set(disabledPlugins))
            PreferencesStore.setValue(value: unique, key: .DisabledPlugins, defaults: defaults)
            disabledPluginsPublisher.send("")
        }
    }

    /// Add a plugin id to `disabledPlugins`. Reads the current value, mutates
    /// the copy, and writes it back through the setter so `@Published`'s
    /// `objectWillChange` and `didSet` fire reliably. Swift's in-place
    /// `append`/`removeAll(where:)` on a `@Published`-wrapped array has been
    /// observed to skip the setter on some macOS/Swift combinations, so we
    /// centralise the mutation here.
    func disablePlugin(_ id: PluginID) {
        if disabledPlugins.contains(id) { return }
        disabledPlugins = disabledPlugins + [id]
    }

    /// Remove a plugin id from `disabledPlugins`. See `disablePlugin(_:)` for
    /// why this is a read-modify-write helper instead of a direct
    /// `removeAll(where:)`.
    func enablePlugin(_ id: PluginID) {
        guard disabledPlugins.contains(id) else { return }
        disabledPlugins = disabledPlugins.filter { $0 != id }
    }

    @Published var terminal: TerminalOptions {
        didSet {
            PreferencesStore.setValue(value: terminal.rawValue, key: .Terminal, defaults: defaults)
        }
    }

    @Published var shell: ShellOptions {
        didSet {
            PreferencesStore.setValue(value: shell.rawValue, key: .Shell, defaults: defaults)
        }
    }

    @Published var menubar01IconIsHidden: Bool {
        didSet {
            PreferencesStore.setValue(value: menubar01IconIsHidden, key: .HideMenubar01Icon, defaults: defaults)
            delegate.pluginManager.rebuildAllMenus()
        }
    }

    @Published var includeBetaUpdates: Bool {
        didSet {
            PreferencesStore.setValue(value: includeBetaUpdates, key: .IncludeBetaUpdates, defaults: defaults)
        }
    }

    @Published var collectCrashReports: Bool {
        didSet {
            PreferencesStore.setValue(value: collectCrashReports, key: .CollectCrashReports, defaults: defaults)
        }
    }

    @Published var dimOnManualRefresh: Bool {
        didSet {
            PreferencesStore.setValue(value: dimOnManualRefresh, key: .DimOnManualRefresh, defaults: defaults)
        }
    }

    @Published var shortcutsPlugins: [PersistentShortcutPlugin] {
        didSet {
            PreferencesStore.setValue(value: try? PropertyListEncoder().encode(shortcutsPlugins), key: .ShortcutPlugins, defaults: defaults)
        }
    }

    var makePluginExecutable: Bool {
        guard let out = defaults.value(forKey: PreferencesKeys.MakePluginExecutable.rawValue) as? Bool else {
            defaults.setValue(true, forKey: PreferencesKeys.MakePluginExecutable.rawValue)
            defaults.synchronize()
            return true
        }
        return out
    }

    var pluginDeveloperMode: Bool {
        defaults.value(forKey: PreferencesKeys.PluginDeveloperMode.rawValue) as? Bool ?? false
    }

    var pluginDebugMode: Bool {
        defaults.value(forKey: PreferencesKeys.PluginDebugMode.rawValue) as? Bool ?? false
    }

    var disableBashWrapper: Bool {
        defaults.value(forKey: PreferencesKeys.DisableBashWrapper.rawValue) as? Bool ?? false
    }

    @Published var stealthMode: Bool {
        didSet {
            PreferencesStore.setValue(value: stealthMode, key: .StealthMode, defaults: defaults)
        }
    }

    /// When true, the fallback menubar01 status item stays in the menu bar
    /// even if at least one plugin is currently visible. This is a safety
    /// net so the user can always reach Preferences / Quit / logs even when
    /// a misbehaving plugin (or disabling all plugins) would otherwise leave
    /// the menu bar empty.
    @Published var alwaysShowMenubar01Menu: Bool {
        didSet {
            PreferencesStore.setValue(value: alwaysShowMenubar01Menu, key: .AlwaysShowMenubar01Menu, defaults: defaults)
            delegate.pluginManager.updateDefaultBarItemVisibility()
        }
    }

    var debugLoggingEnabled: Bool {
        defaults.value(forKey: PreferencesKeys.DebugLoggingEnabled.rawValue) as? Bool ?? false
    }

    var pluginRepositoryURL: URL {
        guard let str = defaults.value(forKey: PreferencesKeys.PluginRepositoryURL.rawValue) as? String,
              let url = URL(string: str)
        else {
            return URL(string: "https://xbarapp.com/docs/plugins/")!
        }
        return url
    }

    var pluginSourceCodeURL: URL {
        guard let str = defaults.value(forKey: PreferencesKeys.PluginSourceCodeURL.rawValue) as? String,
              let url = URL(string: str)
        else {
            return URL(string: "https://github.com/matryer/xbar-plugins/blob/master/")!
        }
        return url
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pluginDirectoryPath = PreferencesStore.getValue(key: .PluginDirectory, defaults: defaults) as? String
        shortcutsFolder = PreferencesStore.getValue(key: .ShortcutsFolder, defaults: defaults) as? String ?? ""
        disabledPlugins = PreferencesStore.getValue(key: .DisabledPlugins, defaults: defaults) as? [PluginID] ?? []
        terminal = .Terminal
        shell = .Bash
        menubar01IconIsHidden = PreferencesStore.getValue(key: .HideMenubar01Icon, defaults: defaults) as? Bool ?? false
        includeBetaUpdates = PreferencesStore.getValue(key: .IncludeBetaUpdates, defaults: defaults) as? Bool ?? false
        collectCrashReports = PreferencesStore.getValue(key: .CollectCrashReports, defaults: defaults) as? Bool ?? true
        dimOnManualRefresh = PreferencesStore.getValue(key: .DimOnManualRefresh, defaults: defaults) as? Bool ?? true
        stealthMode = PreferencesStore.getValue(key: .StealthMode, defaults: defaults) as? Bool ?? false
        alwaysShowMenubar01Menu = PreferencesStore.getValue(key: .AlwaysShowMenubar01Menu, defaults: defaults) as? Bool ?? true
        shortcutsPlugins = {
            guard let data = PreferencesStore.getValue(key: .ShortcutPlugins, defaults: defaults) as? Data,
                  let plugins = try? PropertyListDecoder().decode([PersistentShortcutPlugin].self, from: data) else { return [] }
            return plugins
        }()
        if let savedTerminal = PreferencesStore.getValue(key: .Terminal, defaults: defaults) as? String,
           let value = TerminalOptions(rawValue: savedTerminal)
        {
            terminal = value
        }
        if let savedShell = PreferencesStore.getValue(key: .Shell, defaults: defaults) as? String,
           let value = ShellOptions(rawValue: savedShell)
        {
            shell = value
        }
    }

    /// Wipe the persistent domain backing this store. Operates on whichever
    /// `UserDefaults` instance was injected, so tests that pass a suite-backed
    /// instance clean up only that suite.
    func removeAll() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
    }

    private static func getValue(key: PreferencesKeys, defaults: UserDefaults) -> Any? {
        defaults.value(forKey: key.rawValue)
    }

    private static func setValue(value: Any?, key: PreferencesKeys, defaults: UserDefaults) {
        defaults.setValue(value, forKey: key.rawValue)
        defaults.synchronize()
    }
}

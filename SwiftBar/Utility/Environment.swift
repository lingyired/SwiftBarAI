import Foundation

class Environment {
    static let shared = Environment()

    /// Environment variable names exposed to plugin scripts. The
    /// `SWIFTBAR_*` aliases that used to ship alongside the `MENUBAR01_*`
    /// names are gone — there is no longer any compatibility shim, and
    /// plugin authors should read `MENUBAR01_*` exclusively.
    enum Variables: String {
        case menubar01 = "MENUBAR01"
        case menubar01Version = "MENUBAR01_VERSION"
        case menubar01Build = "MENUBAR01_BUILD"
        case menubar01PluginsPath = "MENUBAR01_PLUGINS_PATH"
        case menubar01PluginPath = "MENUBAR01_PLUGIN_PATH"
        case menubar01PluginCachePath = "MENUBAR01_PLUGIN_CACHE_PATH"
        case menubar01PluginDataPath = "MENUBAR01_PLUGIN_DATA_PATH"
        case menubar01PluginRefreshReason = "MENUBAR01_PLUGIN_REFRESH_REASON"
        case menubar01LaunchTime = "MENUBAR01_LAUNCH_TIME"
        case osVersionMajor = "OS_VERSION_MAJOR"
        case osVersionMinor = "OS_VERSION_MINOR"
        case osVersionPatch = "OS_VERSION_PATCH"
        case osAppearance = "OS_APPEARANCE"
        case menubar01PluginPackagePath = "MENUBAR01_PLUGIN_PACKAGE_PATH"
        case osLastSleepTime = "OS_LAST_SLEEP_TIME"
        case osLastWakeTime = "OS_LAST_WAKE_TIME"
    }

    private var dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    var userLoginShell = "/bin/zsh"

    private var systemEnv: [Variables: String] = [
        .menubar01: "1",
        .menubar01Version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        .menubar01Build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
        .menubar01PluginsPath: PreferencesStore.shared.pluginDirectoryPath ?? "",
        .osVersionMajor: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
        .osVersionMinor: String(ProcessInfo.processInfo.operatingSystemVersion.minorVersion),
        .osVersionPatch: String(ProcessInfo.processInfo.operatingSystemVersion.patchVersion),
    ]

    var systemEnvStr: [String: String] {
        var env = Dictionary(uniqueKeysWithValues:
            systemEnv.map { key, value in (key.rawValue, value) })
        // Always resolve plugin directory path dynamically so it reflects the current value,
        // not the potentially stale value captured at init time.
        env[Variables.menubar01PluginsPath.rawValue] = PreferencesStore.shared.pluginDirectoryPath ?? ""
        return env
    }

    init() {
        systemEnv[.menubar01LaunchTime] = dateFormatter.string(from: NSDate.now)
    }

    func updateSleepTime(date: Date) {
        systemEnv[.osLastSleepTime] = dateFormatter.string(from: date)
    }

    func updateWakeTime(date: Date) {
        systemEnv[.osLastWakeTime] = dateFormatter.string(from: date)
    }
}

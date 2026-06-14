import Combine
import Foundation
import os

/// The single runtime plugin type produced by `PluginManager`.
///
/// A folder plugin is a directory containing a `manifest.json` (the
/// source of truth for all metadata) and an entry-point script. There is
/// no legacy `.swiftbar` suffix, no binary-plugin xattr cache, and no
/// script-header tag parser — the manifest is the entire spec.
class FolderPlugin: TimerArmingPlugin {
    var id: PluginID
    var type: PluginType = .Executable
    var name: String
    var file: String
    let packageDirectory: URL
    let mainExecutable: URL
    var updateInterval: Double = pluginNeverUpdateInterval
    var refreshEnv: [String: String] = [:]

    private var _metadata: PluginMetadata?
    private let metadataQueue = DispatchQueue(label: "com.lingyi.menubar01.FolderPlugin.metadata", attributes: .concurrent)

    var metadata: PluginMetadata? {
        get {
            metadataQueue.sync { _metadata }
        }
        set {
            metadataQueue.async(flags: .barrier) { [weak self] in
                self?._metadata = newValue
            }
        }
    }

    var lastUpdated: Date?
    var lastState: PluginState
    var lastRefreshReason: PluginRefreshReason = .FirstLaunch
    var contentUpdatePublisher = PassthroughSubject<String?, Never>()
    var operation: RunPluginOperation<FolderPlugin>?

    var content: String? = "..." {
        didSet {
            guard content != oldValue || PluginRefreshReason.manualReasons().contains(lastRefreshReason) else { return }
            contentUpdatePublisher.send(content)
        }
    }

    var error: Error?
    var debugInfo = PluginDebugInfo()

    // Use PluginManager.shared instead of the undeclared top-level `delegate`
    // (matches the precedent in MenuBarItem.swift). PluginManager.shared is
    // created in PluginManager.init long before any plugin is constructed, so
    // the test bundle's missing main.swift no longer traps.
    lazy var invokeQueue: OperationQueue = PluginManager.shared.pluginInvokeQueue

    var updateTimerPublisher: Timer.TimerPublisher {
        Timer.TimerPublisher(interval: updateInterval, runLoop: .main, mode: .common)
    }

    var cronTimer: Timer?

    var cancellable: Set<AnyCancellable> = []

    let prefs = PreferencesStore.shared

    /// The on-disk manifest that backs this plugin. `nil` only when the
    /// loader fell back to a synthetic manifest (none of the production
    /// paths do that today).
    let manifest: PluginManifest?

    // MARK: - Initialization

    /// Convenience initializer for the discovery pipeline: parse the
    /// `manifest.json` from the directory, then delegate to the
    /// designated init.
    convenience init?(manifestDirectory: URL) {
        let manifestURL = manifestDirectory.appendingPathComponent(pluginManifestFileName)
        guard let manifest = PluginManifestLoader.loadManifest(from: manifestDirectory) else {
            os_log("Folder plugin %{public}@ has no readable manifest.json", log: Log.plugin, type: .error, manifestURL.path)
            return nil
        }
        self.init(manifestDirectory: manifestDirectory, manifest: manifest)
    }

    /// Designated initializer. The manifest must already have been
    /// parsed by the caller.
    init?(manifestDirectory: URL, manifest: PluginManifest) {
        guard let entryName = manifest.entry ?? Self.inferEntryFilename(in: manifestDirectory) else {
            os_log("Folder plugin %{public}@ has no entry declared in manifest and no plugin.* file to fall back on",
                   log: Log.plugin, type: .error, manifestDirectory.path)
            return nil
        }
        let entryURL = manifestDirectory.appendingPathComponent(entryName)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            os_log("Entry script %{public}@ for folder plugin %{public}@ is missing on disk",
                   log: Log.plugin, type: .error, entryURL.path, manifestDirectory.path)
            return nil
        }
        self.packageDirectory = manifestDirectory
        self.mainExecutable = entryURL
        self.manifest = manifest
        name = manifest.name ?? manifestDirectory.lastPathComponent
        id = manifestDirectory.resolvingSymlinksInPath().path
        file = entryURL.path
        lastState = .Loading

        makeScriptExecutable(file: file)

        // Build the metadata model from the manifest directly. The
        // legacy xattr / script-header parser is gone; the manifest is
        // authoritative.
        _metadata = Self.buildMetadata(from: manifest)

        let nameComponents = entryURL.lastPathComponent.components(separatedBy: ".")
        if _metadata?.nextDate == nil, nameComponents.count > 2 {
            updateInterval = nameComponents.dropFirst()
                .compactMap { parseRefreshInterval(intervalStr: $0, baseUpdateinterval: updateInterval) }
                .reduce(updateInterval, min)
        }

        createSupportDirs()
        os_log("Initialized folder plugin\n%{public}@", log: Log.plugin, description)
        refresh(reason: .FirstLaunch)
    }

    // MARK: - Entry-point Discovery (Manifest Fallback)

    /// Looks for a `plugin.*` file inside a plugin directory when the
    /// manifest does not declare an `entry` field. Sorted so that
    /// already-executable files win ties, then alphabetically for
    /// determinism.
    static func inferEntryFilename(in directory: URL) -> String? {
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            os_log("Failed to read plugin directory %{public}@: %{public}@",
                   log: Log.plugin, type: .error, directory.path, error.localizedDescription)
            return nil
        }
        var candidates = contents.filter { url in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                return false
            }
            return url.lastPathComponent.hasPrefix("plugin.")
        }
        candidates.sort {
            let exec0 = fileManager.isExecutableFile(atPath: $0.path)
            let exec1 = fileManager.isExecutableFile(atPath: $1.path)
            if exec0 != exec1 { return exec0 && !exec1 }
            return $0.lastPathComponent < $1.lastPathComponent
        }
        return candidates.first?.lastPathComponent
    }

    /// Builds a `PluginMetadata` instance from a manifest. Only the
    /// fields the manifest actually declares are populated; the rest
    /// stay at their defaults.
    static func buildMetadata(from manifest: PluginManifest) -> PluginMetadata {
        var metadata = PluginMetadata()
        if let name = manifest.name, !name.isEmpty { metadata.name = name }
        if let version = manifest.version, !version.isEmpty { metadata.version = version }
        if let desc = manifest.description, !desc.isEmpty { metadata.desc = desc }
        if let author = manifest.author, !author.isEmpty { metadata.author = author }
        if let aboutUrl = manifest.aboutUrl, !aboutUrl.isEmpty,
           let parsed = URL(string: aboutUrl) { metadata.aboutURL = parsed }
        if let image = manifest.image, !image.isEmpty,
           let parsed = URL(string: image) { metadata.previewImageURL = parsed }
        if let deps = manifest.dependencies {
            let parts = deps
                .split(whereSeparator: { ",;\n\t".contains($0) || $0.isWhitespace })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { metadata.dependencies = parts }
        }
        if let schedule = manifest.schedule, !schedule.isEmpty { metadata.schedule = schedule }
        if let env = manifest.environment, !env.isEmpty { metadata.environment = env }
        if let parameters = manifest.parameters, !parameters.isEmpty {
            metadata.variables = parameters.map { $0.toPluginVariable() }
        }
        if let type = manifest.type { metadata.type = type }
        if manifest.hideAbout == true { metadata.hideAbout = true }
        if manifest.hideRunInTerminal == true { metadata.hideRunInTerminal = true }
        if manifest.hideLastUpdated == true { metadata.hideLastUpdated = true }
        if manifest.hideDisablePlugin == true { metadata.hideDisablePlugin = true }
        if manifest.hideMenubar01 == true { metadata.hideMenubar01 = true }
        if let runInBash = manifest.runInBash { metadata.runInBash = runInBash }
        return metadata
    }

    // MARK: - Plugin Protocol

    func enableTimer() {
        if let nextDate = metadata?.nextDate {
            cronTimer?.invalidate()
            cronTimer = Timer(fireAt: nextDate, interval: 0, target: self,
                              selector: #selector(scheduledContentUpdate), userInfo: nil, repeats: false)
            if let cronTimer {
                RunLoop.main.add(cronTimer, forMode: .common)
            }
            return
        }
        guard cancellable.isEmpty else { return }
        updateTimerPublisher
            .autoconnect()
            .receive(on: invokeQueue)
            .sink(receiveValue: { [weak self] _ in
                guard let self else { return }
                self.lastRefreshReason = .Schedule
                self.invokeQueue.addOperation(RunPluginOperation<FolderPlugin>(plugin: self))
            }).store(in: &cancellable)
    }

    func disableTimer() {
        cancellable.forEach { $0.cancel() }
        cancellable.removeAll()
        cronTimer?.invalidate()
        cronTimer = nil
    }

    func disable() {
        lastState = .Disabled
        disableTimer()
        prefs.disablePlugin(id)
    }

    func terminate() {
        disableTimer()
    }

    func enable() {
        prefs.enablePlugin(id)
        refresh(reason: .FirstLaunch)
    }

    func start() {
        if lastUpdated != nil {
            if let metadata, metadata.nextDate != nil {
                enableTimer()
            } else if updateInterval > 0, updateInterval < pluginNeverUpdateInterval {
                if let lastUpdated {
                    let nextUpdateTime = lastUpdated.addingTimeInterval(updateInterval)
                    if Date() > nextUpdateTime {
                        refresh(reason: .WakeFromSleep)
                    } else {
                        enableTimer()
                    }
                }
            } else {
                refresh(reason: .WakeFromSleep)
            }
        } else {
            refresh(reason: .FirstLaunch)
        }
    }

    func refresh(reason: PluginRefreshReason) {
        guard enabled else {
            os_log("Skipping refresh for disabled plugin\n%{public}@", log: Log.plugin, description)
            return
        }
        os_log("Requesting refresh for folder plugin\n%{public}@", log: Log.plugin, description)
        debugInfo.addEvent(type: .PluginRefresh, value: "Requesting refresh")
        disableTimer()
        operation?.cancel()

        lastRefreshReason = reason
        operation = RunPluginOperation<FolderPlugin>(plugin: self)
        invokeQueue.addOperation(operation!)
    }

    func invoke() -> String? {
        lastUpdated = Date()
        do {
            let out = try runScript(to: mainExecutable.path,
                                    env: env,
                                    workingDirectory: packageDirectory.path,
                                    runInBash: metadata?.shouldRunInBash ?? true)
            error = nil
            lastState = .Success
            os_log("Successfully executed folder plugin script \n%{public}@", log: Log.plugin, file)
            debugInfo.addEvent(type: .ContentUpdate, value: out.out)
            if let err = out.err, err != "" {
                debugInfo.addEvent(type: .ContentUpdateError, value: err)
                os_log("Error output from the script: \n%{public}@:", log: Log.plugin, err)
            }
            return out.out
        } catch let shellError as ShellOutError {
            os_log("Failed to execute folder plugin script\n%{public}@\n%{public}@",
                   log: Log.plugin, type: .error, file, shellError.message)
            self.error = shellError
            debugInfo.addEvent(type: .ContentUpdateError, value: shellError.message)
            lastState = .Failed
        } catch {
            os_log("Failed to execute folder plugin script\n%{public}@\n%{public}@",
                   log: Log.plugin, type: .error, file, error.localizedDescription)
            self.error = error
            lastState = .Failed
        }
        return nil
    }

    @objc func scheduledContentUpdate() {
        refresh(reason: .Schedule)
    }

    // MARK: - Environment

    var env: [String: String] {
        var pluginEnv: [String: String] = [
            Environment.Variables.menubar01PluginPath.rawValue: file,
            Environment.Variables.osAppearance.rawValue: AppShared.isDarkTheme ? "Dark" : "Light",
            Environment.Variables.menubar01PluginCachePath.rawValue: cacheDirectoryPath,
            Environment.Variables.menubar01PluginDataPath.rawValue: dataDirectoryPath,
            Environment.Variables.menubar01PluginRefreshReason.rawValue: lastRefreshReason.rawValue,
            Environment.Variables.menubar01PluginPackagePath.rawValue: packageDirectory.path,
        ]

        metadata?.environment.forEach { k, v in
            pluginEnv[k] = v
        }

        for (k, v) in refreshEnv {
            pluginEnv[k] = v
        }
        refreshEnv.removeAll()

        if let variables = metadata?.variables, !variables.isEmpty {
            let userValues = PluginVariableStorage.loadUserValues(pluginFile: file)
            let varEnv = PluginVariableStorage.buildEnvironment(variables: variables, userValues: userValues)
            for (k, v) in varEnv {
                pluginEnv[k] = v
            }
        }

        return pluginEnv
    }
}

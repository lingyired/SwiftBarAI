import Combine
import Foundation
import os

class ExecutablePlugin: TimerArmingPlugin {
    var id: PluginID
    let type: PluginType = .Executable
    let name: String
    let file: String
    var refreshEnv: [String: String] = [:]

    var updateInterval: Double = pluginNeverUpdateInterval
    private var _metadata: PluginMetadata?
    private let metadataQueue = DispatchQueue(label: "com.lingyi.menubar01.ExecutablePlugin.metadata", attributes: .concurrent)
    
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
    var operation: RunPluginOperation<ExecutablePlugin>?

    var content: String? = "..." {
        didSet {
            // force update menu if refresh triggered manually, even if the output of the plugin didn't changed
            guard content != oldValue || PluginRefreshReason.manualReasons().contains(lastRefreshReason) else { return }
            contentUpdatePublisher.send(content)
        }
    }

    var error: Error?
    var debugInfo = PluginDebugInfo()

    lazy var invokeQueue: OperationQueue = delegate.pluginManager.pluginInvokeQueue

    var updateTimerPublisher: Timer.TimerPublisher {
        Timer.TimerPublisher(interval: updateInterval, runLoop: .main, mode: .common)
    }

    var cronTimer: Timer?

    var cancellable: Set<AnyCancellable> = []

    let prefs = PreferencesStore.shared

    init(fileURL: URL) {
        let nameComponents = fileURL.lastPathComponent.components(separatedBy: ".")
        // Use resolved path as ID to ensure uniqueness even with symlinks
        id = fileURL.resolvingSymlinksInPath().path
        name = nameComponents.first ?? ""
        file = fileURL.path

        lastState = .Loading
        makeScriptExecutable(file: file)
        refreshPluginMetadata()

        if metadata?.nextDate == nil, nameComponents.count > 2 {
            updateInterval = nameComponents.dropFirst().compactMap { parseRefreshInterval(intervalStr: $0, baseUpdateinterval: updateInterval) }.reduce(updateInterval, min)
        }
        createSupportDirs()
        os_log("Initialized executable plugin\n%{public}@", log: Log.plugin, description)
        refresh(reason: .FirstLaunch)
    }

    // this function called each time plugin updated(manual or scheduled)
    func enableTimer() {
        // handle cron scheduled plugins
        if let nextDate = metadata?.nextDate {
            cronTimer?.invalidate()
            cronTimer = Timer(fireAt: nextDate, interval: 0, target: self, selector: #selector(scheduledContentUpdate), userInfo: nil, repeats: false)
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
                self?.lastRefreshReason = .Schedule
                self?.invokeQueue.addOperation(RunPluginOperation<ExecutablePlugin>(plugin: self!))
            }).store(in: &cancellable)
    }

    func disableTimer() {
        cancellable.forEach { $0.cancel() }
        cancellable.removeAll()
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
        // Check if this is a wake from sleep event by checking if lastUpdated exists
        if lastUpdated != nil {
            // Handle wake from sleep differently - check if it's time to update based on schedule
            if let metadata, metadata.nextDate != nil {
                // For cron-scheduled plugins, calculate next date and set timer
                refreshPluginMetadata()
                enableTimer()
            } else if updateInterval > 0, updateInterval < pluginNeverUpdateInterval {
                // For interval-based plugins (excluding "never" plugins), check if the scheduled time has passed
                if let lastUpdated {
                    let nextUpdateTime = lastUpdated.addingTimeInterval(updateInterval)
                    if Date() > nextUpdateTime {
                        // It's time to update
                        refresh(reason: .WakeFromSleep)
                    } else {
                        // Not yet time to update, just re-enable the timer
                        enableTimer()
                    }
                }
            } else {
                // For plugins without a specific interval ("never" plugins), always refresh on wake
                refresh(reason: .WakeFromSleep)
            }
        } else {
            // First start of the plugin
            refresh(reason: .FirstLaunch)
        }
    }

    func refresh(reason: PluginRefreshReason) {
        guard enabled else {
            os_log("Skipping refresh for disabled plugin\n%{public}@", log: Log.plugin, description)
            return
        }
        os_log("Requesting manual refresh for plugin\n%{public}@", log: Log.plugin, description)
        debugInfo.addEvent(type: .PluginRefresh, value: "Requesting manual refresh")
        disableTimer()
        operation?.cancel()

        refreshPluginMetadata()
        lastRefreshReason = reason
        operation = RunPluginOperation<ExecutablePlugin>(plugin: self)
        invokeQueue.addOperation(operation!)
    }

    func invoke() -> String? {
        lastUpdated = Date()
        // Double-layered isolation:
        //   1. The `runScript` call may throw (file not found, non-zero
        //      exit, sandbox denial, Mach port failure, etc.).
        //   2. *Any other* error from the surrounding code (string
        //      conversion OOM, a plugin path containing NUL bytes, an
        //      exception from Combine's `onOutputUpdate` callback)
        //      would normally propagate up the OperationQueue and out
        //      of our control.
        //
        // Both cases must never reach the main app process. We catch
        // them here, mark the plugin as failed, and let SwiftBar
        // continue running.
        do {
            do {
                let out = try runScript(to: file, env: env,
                                        runInBash: metadata?.shouldRunInBash ?? true)
                error = nil
                lastState = .Success
                os_log("Successfully executed script \n%{public}@", log: Log.plugin, file)
                debugInfo.addEvent(type: .ContentUpdate, value: out.out)
                if let err = out.err, err != "" {
                    debugInfo.addEvent(type: .ContentUpdateError, value: err)
                    os_log("Error output from the script: \n%{public}@:", log: Log.plugin, err)
                }
                return out.out
            } catch {
                // We treat *every* error (ShellOutError or otherwise) as
                // a plugin failure, log it, and continue. The previous
                // version returned `nil` for non-ShellOutError
                // exceptions which silently dropped them on the floor.
                let message: String
                if let shellError = error as? ShellOutError {
                    message = shellError.message
                } else {
                    message = String(describing: error)
                }
                os_log("Failed to execute script\n%{public}@\n%{public}@", log: Log.plugin, type: .error, file, message)
                os_log("Error output from the script: \n%{public}@", log: Log.plugin, message)
                self.error = error
                debugInfo.addEvent(type: .ContentUpdateError, value: message)
                lastState = .Failed
            }
        } catch {
            // Defensive second net — a `debugInfo.addEvent` that
            // itself throws, or a `lastUpdated = Date()` overflow, must
            // still not bring down SwiftBar.
            os_log("Plugin execution isolation: unexpected error in invoke() for %{public}@: %{public}@",
                   log: Log.plugin, type: .error, file, String(describing: error))
        }
        return nil
    }

    @objc func scheduledContentUpdate() {
        refresh(reason: .Schedule)
    }
}

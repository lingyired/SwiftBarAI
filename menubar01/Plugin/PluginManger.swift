import Cocoa
import Combine
import Foundation
import os
import SwiftUI
import UserNotifications

/// Returns `true` when `url` points at a directory that contains a
/// `manifest.json` — i.e. a folder-based menubar01 plugin.
func isManifestPluginDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
          isDir.boolValue
    else { return false }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent(pluginManifestFileName).path)
}

struct PluginFileState: Equatable {
    let size: UInt64
    let modificationDate: Date?
}

enum PluginFileSkipReason: String {
    case notRegularFile = "not a regular file"
    case emptyFile = "empty file"
    case notExecutable = "not executable while auto-make-executable is disabled"
}

/// Returns the folder-plugin directory for a file URL, if `fileURL` is
/// inside (or is itself) a folder that contains a `manifest.json` — or, as a
/// best-effort fallback for code that has to key off the URL alone (e.g. the
/// sync logic in tests that use synthetic paths), looks like it should be
/// one. Handles both direct paths and symlinks so that folder plugins are
/// treated as a single atomic unit during sync.
func packagedPluginDirectory(for fileURL: URL) -> URL? {
    if isManifestPluginDirectory(fileURL) {
        return fileURL
    }

    let parentDirectory = fileURL.deletingLastPathComponent()
    if isManifestPluginDirectory(parentDirectory) {
        return parentDirectory
    }

    // Best-effort fallback: the directory on disk doesn't yet exist or has
    // no `manifest.json`. In that case we still want the parent directory to
    // be treated as the sync key so that two URLs under the same folder
    // (e.g. `/tmp/weather/plugin.sh` and `/tmp/weather/plugin.py`) collapse
    // into a single plugin during sync. We require the file to look like an
    // entry script (`.sh`, `.py`, `.js`, ...) and the parent to look like a
    // plain directory name (not a dotfile, not a legacy `.swiftbar` suffix).
    if looksLikeFolderPluginEntry(fileURL),
       isPlausibleFolderName(parentDirectory.lastPathComponent)
    {
        return parentDirectory
    }

    let resolvedFileURL = fileURL.resolvingSymlinksInPath()
    if isManifestPluginDirectory(resolvedFileURL) {
        return resolvedFileURL
    }

    let resolvedParentDirectory = resolvedFileURL.deletingLastPathComponent()
    if isManifestPluginDirectory(resolvedParentDirectory) {
        return resolvedParentDirectory
    }

    if looksLikeFolderPluginEntry(resolvedFileURL),
       isPlausibleFolderName(resolvedParentDirectory.lastPathComponent)
    {
        return resolvedParentDirectory
    }
    return nil
}

/// Heuristic check for "this looks like an entry script of a folder plugin".
private func looksLikeFolderPluginEntry(_ fileURL: URL) -> Bool {
    let name = fileURL.lastPathComponent.lowercased()
    let executableSuffixes = [".sh", ".bash", ".py", ".rb", ".js", ".pl", ".elf"]
    return executableSuffixes.contains(where: name.hasSuffix)
}

/// Heuristic check for "this directory name is reasonable for a folder plugin".
/// Excludes dotfiles and legacy `.swiftbar` suffixes. There is no ignore-file
/// mechanism in menubar01 — the manifest is the only opt-in.
private func isPlausibleFolderName(_ name: String) -> Bool {
    !name.isEmpty
        && !name.hasPrefix(".")
        && !name.hasSuffix(".swiftbar")
}

/// Returns a canonical path used to identify a plugin across sync cycles.
/// For packaged plugins this is the bundle directory path; for regular plugins
/// it is the symlink-resolved file path.
func pluginSyncPath(for fileURL: URL) -> String {
    packagedPluginDirectory(for: fileURL)?.path ?? fileURL.resolvingSymlinksInPath().path
}

func pluginSyncPath(for plugin: Plugin) -> String {
    pluginSyncPath(for: URL(fileURLWithPath: plugin.file))
}

private func packagedPluginFileState(for packageURL: URL, fileManager: FileManager = .default) -> PluginFileState? {
    let resolvedPackageURL = packageURL.resolvingSymlinksInPath()

    // A folder plugin is "real" as long as it contains any regular file —
    // the existence of an entry script is enforced separately by the loader.
    // We still skip hidden files and the `manifest.json` itself.
    let enumerator = fileManager.enumerator(
        at: resolvedPackageURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    guard let enumerator else {
        return nil
    }

    var totalSize: UInt64 = 0
    var latestModificationDate = (try? fileManager.attributesOfItem(atPath: resolvedPackageURL.path)[.modificationDate] as? Date) ?? nil
    var hasRegularFile = false

    for case let entryURL as URL in enumerator {
        // Skip metadata files (manifest.json) so they don't influence the
        // size/modification hash used for change detection.
        if entryURL.lastPathComponent == pluginManifestFileName {
            continue
        }

        let resolvedEntryURL = entryURL.resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedEntryURL.path),
              let fileType = attributes[.type] as? FileAttributeType
        else {
            continue
        }

        if fileType == .typeDirectory {
            continue
        }

        hasRegularFile = true

        if let fileSize = attributes[.size] as? NSNumber {
            totalSize += fileSize.uint64Value
        }

        if let modificationDate = attributes[.modificationDate] as? Date,
           latestModificationDate.map({ modificationDate > $0 }) ?? true
        {
            latestModificationDate = modificationDate
        }
    }

    guard hasRegularFile else {
        return nil
    }

    return PluginFileState(size: totalSize, modificationDate: latestModificationDate)
}

func pluginFileState(for fileURL: URL, fileManager: FileManager = .default) -> PluginFileState? {
    if let packageDirectory = packagedPluginDirectory(for: fileURL) {
        return packagedPluginFileState(for: packageDirectory, fileManager: fileManager)
    }

    let resolvedFileURL = fileURL.resolvingSymlinksInPath()

    guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedFileURL.path),
          let fileType = attributes[.type] as? FileAttributeType,
          fileType == .typeRegular,
          let fileSize = attributes[.size] as? NSNumber
    else {
        return nil
    }

    return PluginFileState(
        size: fileSize.uint64Value,
        modificationDate: attributes[.modificationDate] as? Date
    )
}

func pluginFileSkipReason(for fileURL: URL, makePluginExecutable: Bool, fileManager: FileManager = .default) -> PluginFileSkipReason? {
    guard let state = pluginFileState(for: fileURL, fileManager: fileManager) else {
        return .notRegularFile
    }

    guard state.size > 0 else {
        return .emptyFile
    }

    if !makePluginExecutable, !fileManager.isExecutableFile(atPath: fileURL.path) {
        return .notExecutable
    }

    return nil
}

func shouldLoadPluginFile(at fileURL: URL, makePluginExecutable: Bool, fileManager: FileManager = .default) -> Bool {
    if let skipReason = pluginFileSkipReason(for: fileURL, makePluginExecutable: makePluginExecutable, fileManager: fileManager) {
        os_log("Skipping plugin candidate %{public}@ (%{public}@)", log: Log.plugin, type: .info, fileURL.path, skipReason.rawValue)
        return false
    }

    return true
}

func shouldShowDefaultBarItem(hasVisiblePlugins: Bool, stealthMode: Bool, alwaysShowMenubar01Menu: Bool) -> Bool {
    !stealthMode && (!hasVisiblePlugins || alwaysShowMenubar01Menu)
}

private let knownMenuBarManagerNames = [
    "Ice",
    "Bartender",
    "Hidden Bar",
    "Dozer",
    "Vanilla",
    "Barbee",
]

func knownMenuBarManagerMatches(in applicationNames: [String]) -> [String] {
    let normalizedNames = applicationNames.map { $0.lowercased() }

    return knownMenuBarManagerNames.filter { knownName in
        normalizedNames.contains { $0.contains(knownName.lowercased()) }
    }
}

func statusItemPersistenceEntries(in defaults: [String: Any]) -> [String] {
    defaults.keys
        .filter { $0.hasPrefix("NSStatusItem ") }
        .sorted()
        .map { key in
            "\(key) = \(String(describing: defaults[key] ?? ""))"
        }
}

func systemReportCandidateStatus(for fileURL: URL, makePluginExecutable: Bool, fileManager: FileManager = .default) -> String {
    var isDir: ObjCBool = false
    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
        // Every directory in the plugin folder is expected to be a folder
        // plugin with a `manifest.json`. Anything else is a broken plugin.
        return PluginManifestLoader.loadAndValidate(from: fileURL) != nil
            ? "loadable folder plugin"
            : "skipped: folder plugin has invalid manifest.json"
    }

    // Anything that isn't a directory is rejected — single-file scripts and
    // `.swiftbar` bundles are no longer supported.
    return "skipped: not a folder plugin"
}

struct FilePluginSyncResult {
    let removedPluginIDs: Set<PluginID>
    let modifiedPluginIDs: Set<PluginID>
    let loadedPlugins: [Plugin]
    let freshFileStates: [String: PluginFileState]
}

func syncFilePlugins(existingFilePlugins: [Plugin], freshFilePlugins: [URL], previousFileStates: [String: PluginFileState], discoveredFilePlugins: [URL]? = nil, fileManager: FileManager = .default, loadPlugin: (URL) -> Plugin?) -> FilePluginSyncResult {
    let discoveredFilePlugins = discoveredFilePlugins ?? freshFilePlugins
    let discoveredPluginPaths = Set(discoveredFilePlugins.map { pluginSyncPath(for: $0) })
    let existingPluginPaths = Set(existingFilePlugins.map { pluginSyncPath(for: $0) })

    // 1. Build fresh file state map from current disk contents
    let freshFileStates = Dictionary(uniqueKeysWithValues: freshFilePlugins.compactMap { fileURL in
        let syncPath = pluginSyncPath(for: fileURL)
        return pluginFileState(for: fileURL, fileManager: fileManager).map { (syncPath, $0) }
    })

    // 2. Find removed plugins (present in existing but absent from fresh list)
    let removedPlugins = existingFilePlugins.filter { plugin in
        !discoveredPluginPaths.contains(pluginSyncPath(for: plugin))
    }

    // 3. Find modified plugins (state on disk differs from previously recorded state)
    let modifiedPlugins = existingFilePlugins.filter { plugin in
        let syncPath = pluginSyncPath(for: plugin)
        guard let freshState = freshFileStates[syncPath] else { return false }
        return previousFileStates[syncPath] != freshState
    }
    let modifiedPluginPaths = Set(modifiedPlugins.map { pluginSyncPath(for: $0) })

    // 4. Determine which files need (re)loading: new files + modified files
    let filesToLoad = Set(
        freshFilePlugins
            .filter { fileURL in
                let syncPath = pluginSyncPath(for: fileURL)
                return !existingPluginPaths.contains(syncPath) || modifiedPluginPaths.contains(syncPath)
            }
            .map { pluginSyncPath(for: $0) }
    )

    let loadedPlugins = freshFilePlugins
        .filter { filesToLoad.contains(pluginSyncPath(for: $0)) }
        .compactMap(loadPlugin)

    return FilePluginSyncResult(
        removedPluginIDs: Set(removedPlugins.map(\.id)),
        modifiedPluginIDs: Set(modifiedPlugins.map(\.id)),
        loadedPlugins: loadedPlugins,
        freshFileStates: freshFileStates
    )
}

func mergePluginsPreservingOrder(existingPlugins: [Plugin], removedPluginIDs: Set<PluginID>, reloadedFilePlugins: [Plugin], newShortcutPlugins: [ShortcutPlugin]) -> [Plugin] {
    let reloadedPluginsBySyncPath = Dictionary(uniqueKeysWithValues: reloadedFilePlugins.map { (pluginSyncPath(for: $0), $0) })
    let reloadedPluginSyncPaths = Set(reloadedFilePlugins.map { pluginSyncPath(for: $0) })
    var consumedReloadedFiles = Set<String>()
    var mergedPlugins: [Plugin] = []

    // Only file-backed plugins (Executable) are eligible for in-place replacement.
    for plugin in existingPlugins where !removedPluginIDs.contains(plugin.id) {
        let syncPath = pluginSyncPath(for: plugin)
        guard plugin.type == .Executable,
              reloadedPluginSyncPaths.contains(syncPath),
              let replacementPlugin = reloadedPluginsBySyncPath[syncPath]
        else {
            mergedPlugins.append(plugin)
            continue
        }

        mergedPlugins.append(replacementPlugin)
        consumedReloadedFiles.insert(syncPath)
    }

    let appendedFilePlugins = reloadedFilePlugins.filter { !consumedReloadedFiles.contains(pluginSyncPath(for: $0)) }
    mergedPlugins.append(contentsOf: appendedFilePlugins)
    mergedPlugins.append(contentsOf: newShortcutPlugins)

    return mergedPlugins
}

class PluginManager: ObservableObject {
    static let shared = PluginManager()
    let prefs: PreferencesStore
    lazy var barItem: MenubarItem = {
        let item = MenubarItem.defaultBarItem()
        return item
    }()

    #if !MAC_APP_STORE
        var directoryObserver: DirectoryObserver?
    #endif

    @Published var plugins: [Plugin] = [] {
        didSet {
            shortcutPlugins = plugins.filter { $0.type == .Shortcut }.compactMap { $0 as? ShortcutPlugin }

            pluginsDidChange()
        }
    }

    @Published var shortcutPlugins: [ShortcutPlugin] = []
    var filePluginStates: [String: PluginFileState] = [:]
    var directoryChangeWorkItem: DispatchWorkItem?
    private var isUpdatingDefaultBarItemVisibility = false
    private static let directoryChangeDebounceInterval: TimeInterval = 0.5

    var filePlugins: [Plugin] {
        plugins.filter { $0.type == .Executable }
    }

    var ephemeralPlugins: [EphemeralPlugin] {
        plugins.filter { $0.type == .Ephemeral }.compactMap { $0 as? EphemeralPlugin }
    }

    var enabledPlugins: [Plugin] {
        plugins.filter(\.enabled)
    }

    var menuBarItems: [PluginID: MenubarItem] = [:]
    var pluginDirectoryURL: URL? {
        prefs.pluginDirectoryResolvedURL
    }


    var disablePluginCancellable: AnyCancellable?
    var osAppearanceChangeCancellable: AnyCancellable?

    let pluginInvokeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 20
        return queue
    }()

    let menuUpdateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 10
        return queue
    }()

    init(prefs: PreferencesStore = .shared) {
        self.prefs = prefs
        // Use the main dispatch queue (not RunLoop.main) so the sink fires
        // even while the user is interacting with an open NSMenu — the
        // toggle dropdown, for example. The main runloop is held in
        // `NSEventTrackingRunLoopMode` during menu tracking, which causes
        // `RunLoop.main` scheduled work to be deferred until the user
        // dismisses the menu. `DispatchQueue.main` is processed in parallel
        // with the runloop, so `pluginsDidChange()` (and the resulting
        // NSStatusItem add/remove) happens immediately.
        disablePluginCancellable = prefs.disabledPluginsPublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] _ in
                os_log("Recieved plugin enable/disable notification", log: Log.plugin)
                self?.pluginsDidChange()
            })

        osAppearanceChangeCancellable = DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification")).sink { [weak self] _ in
            self?.menuBarItems.values.forEach { item in
                // this is not ideal, but should work in most cases — we should not reload plugins with active background webviews
                guard item.plugin?.metadata?.persistentWebView != true else {
                    return
                }
                item.updateMenu(content: item.plugin?.content)
            }
        }
    }

    func pluginsDidChange() {
        // This function is reached via the `disabledPluginsPublisher`
        // sink, so any unhandled throw here would propagate into Combine
        // and tear down the sink subscription — which in turn would
        // freeze the toggle UI in its last state. Wrap the whole body
        // in a top-level do/catch so a plugin misbehaviour (bad
        // title string, NSStatusItem allocation failure, etc.) is
        // logged and swallowed instead of crashing the main app.
        do {
            os_log("Plugins did change, updating menu bar... enabledPlugins=%{public}d, total=%{public}d, menuBarItems.count=%{public}d",
                   log: Log.plugin, type: .info,
                   enabledPlugins.count, plugins.count, menuBarItems.count)
            let enabledIDs = Set(enabledPlugins.map(\.id))

            for plugin in enabledPlugins {
                if let existingMenuBarItem = menuBarItems[plugin.id] {
                    if existingMenuBarItem.plugin !== plugin {
                        existingMenuBarItem.replacePlugin(plugin)
                    }
                    continue
                }
                os_log("pluginsDidChange: creating MenubarItem for %{public}@", log: Log.plugin, type: .info, plugin.id)
                menuBarItems[plugin.id] = MenubarItem(title: plugin.name, plugin: plugin, visibilityDidChange: { [weak self] _ in
                    self?.updateDefaultBarItemVisibility()
                })
            }

            // The default menubar01 `MenubarItem` (the one without a
            // plugin) hosts the inlined "Toggle Plugins" section.
            // When the set of enabled plugins changes (add / remove
            // / enable / disable), we refresh the section so the
            // checkmarks reflect the latest state.
            barItem.rebuildTogglePluginSection()

            // Collect the MenubarItems that need to be torn down. We
            // *hide* them synchronously (so the user sees the status
            // item vanish immediately) but defer the actual removal
            // — and therefore the deallocation of the NSStatusItem
            // — to the next main-queue iteration.
            //
            // This avoids a recurring class of scene-detach errors:
            //   - "No scene exists for identity:
            //      com.apple.controlcenter:…-Aux[1]-NSStatusItemView"
            //   - "Unhandled disconnected auxiliary scene
            //      <NSHostedViewScene: …>"
            //   - "Unhandled disconnected scene <NSStatusItemScene: …>"
            //   - "[BSBlockSentinel:FBSWorkspaceScenesClient] failed!"
            //
            // Those are produced when an NSStatusItem is released
            // while AppKit is still tracking a control that
            // references it (e.g. inside an open NSMenu or in the
            // middle of a mouseDown). Deferring the release gives
            // AppKit a tick to settle, after which the dealloc is
            // safe.
            var pendingRemoval: [PluginID] = []
            for pluginID in menuBarItems.keys {
                guard !enabledIDs.contains(pluginID) else { continue }
                os_log("pluginsDidChange: hiding disabled MenubarItem for %{public}@ (deferred release)", log: Log.plugin, type: .info, pluginID)
                menuBarItems[pluginID]?.hide()
                pendingRemoval.append(pluginID)
            }

            os_log("pluginsDidChange: done (visible updates), menuBarItems.count=%{public}d, barItem.isVisible=%{public}@, pendingRemoval=%{public}d",
                   log: Log.plugin, type: .info,
                   menuBarItems.count,
                   barItem.barItem.isVisible ? "true" : "false",
                   pendingRemoval.count)

            updateDefaultBarItemVisibility()
            persistLatestSystemReport(reason: "plugins-did-change")

            if !pendingRemoval.isEmpty {
                let snapshot = pendingRemoval
                // Defer the actual `NSStatusItem` deallocation to a
                // *later* main-queue tick. The first async dispatch
                // returns control to AppKit so it can finish any
                // in-flight NSMenu / NSStatusItem tracking for the
                // toggle that just fired. A second async dispatch then
                // runs on the next subsequent main-queue turn, which
                // is far enough in the future for AppKit's
                // `NSStatusItemScene` and the control-center's
                // `Aux[1]-NSStatusItemView` scene to both settle. The
                // intervening idle time also lets any in-flight
                // `[BSBlockSentinel:FBSWorkspaceScenesClient]`
                // callbacks drain, so the scene-detach errors we used
                // to see ("Unhandled disconnected auxiliary scene
                // <NSHostedViewScene …>", "Unhandled disconnected
                // scene <NSStatusItemScene …>",
                // "No scene exists for identity: …-Aux[1]-NSStatusItemView")
                // no longer fire.
                os_log("pluginsDidChange: deferring release of %{public}d NSStatusItem(s) by 2 main-queue turns: %{public}@",
                       log: Log.plugin, type: .info,
                       snapshot.count,
                       snapshot.joined(separator: ","))
                DispatchQueue.main.async { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        // Re-check: the user may have re-enabled one
                        // of these plugins in the meantime. Only
                        // release the NSStatusItem for plugins that
                        // are still disabled at the moment we run.
                        let stillEnabled = Set(self.enabledPlugins.map(\.id))
                        for pluginID in snapshot where !stillEnabled.contains(pluginID) {
                            if let item = self.menuBarItems.removeValue(forKey: pluginID) {
                                os_log("pluginsDidChange (deferred): releasing NSStatusItem for %{public}@", log: Log.plugin, type: .info, pluginID)
                                // Capture in a local so the deinit
                                // (which calls removeAllItems on its
                                // private NSMenu) runs *after* this
                                // iteration returns. We don't need
                                // the value, just the release
                                // barrier.
                                _ = item
                            }
                        }
                    }
                }
            }
        } catch {
            os_log("pluginsDidChange: caught unexpected error — plugin execution isolation: %{public}@",
                   log: Log.plugin, type: .error, String(describing: error))
        }
    }

    func updateDefaultBarItemVisibility() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateDefaultBarItemVisibility()
            }
            return
        }

        guard !isUpdatingDefaultBarItemVisibility else { return }
        isUpdatingDefaultBarItemVisibility = true
        defer { isUpdatingDefaultBarItemVisibility = false }

        let hasVisiblePlugins = enabledPlugins.contains { plugin in
            menuBarItems[plugin.id]?.barItem.isVisible == true
        }

        os_log("updateDefaultBarItemVisibility: hasVisiblePlugins=%{public}@, menuBarItems.count=%{public}d, enabledPlugins=%{public}d",
               log: Log.plugin, type: .info,
               hasVisiblePlugins ? "true" : "false",
               menuBarItems.count,
               enabledPlugins.count)

        shouldShowDefaultBarItem(
            hasVisiblePlugins: hasVisiblePlugins,
            stealthMode: prefs.stealthMode,
            alwaysShowMenubar01Menu: prefs.alwaysShowMenubar01Menu
        ) ? barItem.show() : barItem.hide()
        os_log("updateDefaultBarItemVisibility: default barItem.isVisible=%{public}@, defaultObjId=%{public}d, pluginObjIds=%{public}@",
               log: Log.plugin, type: .info,
               barItem.barItem.isVisible ? "true" : "false",
               ObjectIdentifier(barItem).hashValue,
               menuBarItems.values.map { ObjectIdentifier($0).hashValue }.map(String.init).sorted().joined(separator: ","))
        persistLatestSystemReport(reason: "default-bar-item-visibility")
    }

    func getPluginByNameOrID(identifier: String) -> Plugin? {
        plugins.first(where: { $0.id.lowercased() == identifier.lowercased() }) ??
            plugins.first(where: { $0.name.lowercased() == identifier.lowercased() })
    }

    func disablePlugin(plugin: Plugin) {
        os_log("Disabling plugin \n%{public}@", log: Log.plugin, plugin.description)
        // Defensive: `plugin.disable()` mutates `prefs.disabledPlugins`,
        // which fires the publisher. The publisher's sink runs
        // `pluginsDidChange()` on the main queue. If anything in that
        // chain throws, we must not let the exception escape — it
        // would propagate back into the user-facing menu tracking
        // path (the toggle switch's mouseDown handler) and freeze
        // the dropdown.
        do {
            plugin.disable()
        } catch {
            os_log("disablePlugin: caught error from plugin.disable() — plugin execution isolation: %{public}@",
                   log: Log.plugin, type: .error, String(describing: error))
        }
    }

    func enablePlugin(plugin: Plugin) {
        os_log("Enabling plugin \n%{public}@", log: Log.plugin, plugin.description)
        do {
            plugin.enable()
        } catch {
            os_log("enablePlugin: caught error from plugin.enable() — plugin execution isolation: %{public}@",
                   log: Log.plugin, type: .error, String(describing: error))
        }
    }

    func togglePlugin(plugin: Plugin) {
        plugin.enabled ? disablePlugin(plugin: plugin) : enablePlugin(plugin: plugin)
    }

    func disableAllPlugins() {
        os_log("Disabling all plugins.", log: Log.plugin)
        plugins.forEach { $0.disable() }
    }

    func enableAllPlugins() {
        os_log("Enabling all plugins.", log: Log.plugin)
        plugins.forEach { $0.enable() }
    }

    func getPluginList() -> [URL] {
        guard let url = pluginDirectoryURL else { return [] }
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // Track processed directories by their resolved paths to avoid duplicates
        var processedDirs = Set<String>()

        func filter(url: URL) -> (files: [URL], dirs: [URL]) {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            else { return ([], []) }
            var dirs: [URL] = []
            var files: [URL] = []
            for case let origURL as URL in enumerator {
                let resolvedURL = origURL.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDir) else {
                    continue
                }
                if isDir.boolValue {
                    // Only manifest.json folders are recognised as plugin
                    // bundles — they are treated as a single atomic unit and
                    // their descendants are skipped. Single-file scripts and
                    // legacy `.swiftbar` packaged plugins are not supported.
                    if isManifestPluginDirectory(origURL) {
                        files.append(origURL)
                        enumerator.skipDescendants()
                        continue
                    }
                    // Only add directory if we haven't processed its resolved path yet
                    if !processedDirs.contains(resolvedURL.path) {
                        processedDirs.insert(resolvedURL.path)
                        dirs.append(origURL)
                    }
                    continue
                }
                // Loose files are not loaded as plugins anymore — every plugin
                // must be a folder with a manifest.json. Skip .json explicitly
                // so anything stored alongside a plugin (e.g. an embedded
                // settings file) isn't logged as a candidate.
                if origURL.pathExtension.lowercased() == "json" {
                    continue
                }
                // Everything else at the leaf level is intentionally ignored:
                // single-file executable/streamable plugins and bare scripts
                // are no longer part of the supported plugin surface.
                continue
            }
            return (files, dirs)
        }

        // The enumerator is recursive, so a single pass returns every file at every
        // depth. Filtering once on that result is sufficient — the previous code
        // also re-enumerated sub-directories which produced duplicate entries and
        // silently dropped any sub-directories that should have been ignored.

        // Deduplicate files based on resolved paths
        let (files, _) = filter(url: url)
        var uniqueFiles: [URL] = []
        var seenPaths = Set<String>()
        for file in files {
            let resolvedPath = file.resolvingSymlinksInPath().path
            if !seenPaths.contains(resolvedPath) {
                seenPaths.insert(resolvedPath)
                uniqueFiles.append(file)
            }
        }

        return uniqueFiles
    }

    func getLoadablePluginList(from pluginCandidates: [URL]) -> [URL] {
        pluginCandidates.filter { url in
            // Every plugin must be a folder with a valid `manifest.json`. We
            // do the deeper validation (entry script existence, executability,
            // ...) inside `PluginManifestLoader` so the error message lives in
            // one place.
            guard PluginManifestLoader.loadAndValidate(from: url) != nil else {
                os_log("Skipping folder %{public}@ (missing or invalid manifest.json)", log: Log.plugin, type: .info, url.path)
                return false
            }
            return true
        }
    }

    func loadShortcutPlugins() -> [ShortcutPlugin] {
        prefs.shortcutsPlugins.map { ShortcutPlugin($0) }
    }

    func unloadPlugins(_ pluginsToUnload: [Plugin], clearDisabledState: Bool) {
        let pluginIDs = Set(pluginsToUnload.map(\.id))

        for plugin in pluginsToUnload {
            plugin.terminate()
            menuBarItems.removeValue(forKey: plugin.id)

            if clearDisabledState {
                prefs.enablePlugin(plugin.id)
            }
        }

        plugins.removeAll(where: { pluginIDs.contains($0.id) })
    }

    func loadPlugins() {
        #if !MAC_APP_STORE
            if directoryObserver?.url != pluginDirectoryURL {
                configureDirectoryObserver()
            }
        #endif
        let freshShortcutPlugins = loadShortcutPlugins()
        let discoveredFilePlugins = getPluginList()
        let freshFilePlugins = getLoadablePluginList(from: discoveredFilePlugins)
        guard discoveredFilePlugins.count < 50 else {
            let alert = NSAlert()
            alert.messageText = Localizable.App.FolderHasToManyFilesMessage.localized
            alert.runModal()

            AppShared.changePluginFolder()
            return
        }
        guard !freshFilePlugins.isEmpty || !freshShortcutPlugins.isEmpty else {
            plugins.removeAll()
            shortcutPlugins.removeAll()
            menuBarItems.removeAll()
            filePluginStates.removeAll()
            // Preserve the original escape hatch: if everything is gone, show menubar01
            // even in stealth mode so the user can recover.
            barItem.show()
            persistLatestSystemReport(reason: "no-loadable-plugins")
            return
        }

        let newShortcutPlugins = freshShortcutPlugins.filter { plugin in
            !plugins.contains(where: { $0.id == plugin.id })
        }

        let removedShortcutPlugins = shortcutPlugins.filter { plugin in
            !freshShortcutPlugins.contains(where: { $0.id == plugin.id })
        }

        let fileSyncResult = syncFilePlugins(
            existingFilePlugins: filePlugins,
            freshFilePlugins: freshFilePlugins,
            previousFileStates: filePluginStates,
            discoveredFilePlugins: discoveredFilePlugins,
            loadPlugin: loadPlugin(fileURL:)
        )

        let removedFilePlugins = filePlugins.filter { fileSyncResult.removedPluginIDs.contains($0.id) }
        let modifiedFilePlugins = filePlugins.filter { fileSyncResult.modifiedPluginIDs.contains($0.id) }

        for plugin in modifiedFilePlugins {
            plugin.terminate()
        }

        for plugin in removedFilePlugins + removedShortcutPlugins {
            plugin.terminate()
            menuBarItems.removeValue(forKey: plugin.id)
            prefs.enablePlugin(plugin.id)
        }

        let removedPluginIDs = fileSyncResult.removedPluginIDs.union(removedShortcutPlugins.map(\.id))
        plugins = mergePluginsPreservingOrder(
            existingPlugins: plugins,
            removedPluginIDs: removedPluginIDs,
            reloadedFilePlugins: fileSyncResult.loadedPlugins,
            newShortcutPlugins: newShortcutPlugins
        )
        filePluginStates = fileSyncResult.freshFileStates
        persistLatestSystemReport(reason: "load-plugins")
    }

    func loadPlugin(fileURL: URL) -> Plugin? {
        // Only folder-based plugins with a `manifest.json` are supported.
        // The discovery pipeline in `getLoadablePluginList` already filters out
        // anything that doesn't match, so we can assume here that `fileURL`
        // is a directory that contains a `manifest.json` we just validated.
        guard isManifestPluginDirectory(fileURL),
              let folderPlugin = FolderPlugin(manifestDirectory: fileURL)
        else {
            os_log("Refusing to load non-folder plugin candidate %{public}@", log: Log.plugin, type: .error, fileURL.path)
            return nil
        }
        return folderPlugin
    }

    func refreshAllPlugins(reason: PluginRefreshReason) {
        #if MAC_APP_STORE
            loadPlugins()
        #endif
        os_log("Refreshing all enabled plugins.", log: Log.plugin)
        menuBarItems.values.forEach { $0.dimOnManualRefresh() }
        pluginInvokeQueue.cancelAllOperations() // clean up the update queue to avoid duplication
        enabledPlugins.forEach { $0.refresh(reason: reason) }
    }

    func startAllPlugins() {
        os_log("Starting all enabled plugins.", log: Log.plugin)
        pluginInvokeQueue.cancelAllOperations() // clean up the update queue to avoid duplication
        enabledPlugins.forEach { $0.start() }
    }

    func terminateAllPlugins() {
        os_log("Stoping all enabled plugins.", log: Log.plugin)
        enabledPlugins.forEach { $0.terminate() }
        pluginInvokeQueue.cancelAllOperations()
    }

    func rebuildAllMenus() {
        menuBarItems.values.forEach { $0.updateMenu(content: $0.plugin?.content) }
    }

    func refreshPlugin(with index: Int, reason: PluginRefreshReason) {
        guard plugins.indices.contains(index) else { return }
        plugins[index].refresh(reason: reason)
    }

    func addShortcutPlugin(plugin: PersistentShortcutPlugin) {
        prefs.shortcutsPlugins.append(plugin)
        loadPlugins()
    }

    func removeShortcutPlugin(plugin: PersistentShortcutPlugin) {
        prefs.shortcutsPlugins.removeAll(where: { $0.id == plugin.id })
        loadPlugins()
    }

    func setEphemeralPlugin(pluginId: PluginID, content: String, exitAfter: Double = 0) {
        if let plugin = ephemeralPlugins.first(where: { $0.id == pluginId }) {
            guard !content.isEmpty else {
                plugins.removeAll(where: { $0.id == pluginId && $0.type == .Ephemeral })
                return
            }
            plugin.content = content
            plugin.updateInterval = exitAfter
            return
        }

        plugins.append(EphemeralPlugin(id: pluginId, content: content, exitAfter: exitAfter))
    }

    enum ImportPluginError: Error {
        case badURL
        case importFail
    }

    private func installImportedPlugin(from sourceURL: URL, moveItem: Bool, completionHandler: ((Result<Any, ImportPluginError>) -> Void)? = nil) {
        guard let pluginDirectoryURL = pluginDirectoryURL else {
            completionHandler?(.failure(.badURL))
            return
        }

        let targetURL = pluginDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.resolvingSymlinksInPath().path == targetURL.resolvingSymlinksInPath().path {
            completionHandler?(.success(true))
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            completionHandler?(.failure(.badURL))
            return
        }

        do {
            if moveItem {
                try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            }

            if !isDirectory.boolValue {
                try runScript(to: "chmod", args: ["+x", "\(targetURL.path.escaped())"])
            }

            completionHandler?(.success(true))
        } catch {
            completionHandler?(.failure(.importFail))
            os_log("Failed to import plugin from %{public}@ \n%{public}@", log: Log.plugin, type: .error, sourceURL.absoluteString, error.localizedDescription)
        }
    }

    func importPlugin(from url: URL, completionHandler: ((Result<Any, ImportPluginError>) -> Void)? = nil) {
        os_log("Starting plugin import from %{public}@", log: Log.plugin, url.absoluteString)
        if url.isFileURL {
            let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            installImportedPlugin(from: url, moveItem: false, completionHandler: completionHandler)
            return
        }

        let downloadTask = URLSession.shared.downloadTask(with: url) { fileURL, _, _ in
            guard let fileURL else {
                completionHandler?(.failure(.badURL))
                return
            }

            let renamedDownloadURL = fileURL.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: renamedDownloadURL.path) {
                    try FileManager.default.removeItem(at: renamedDownloadURL)
                }
                try FileManager.default.moveItem(at: fileURL, to: renamedDownloadURL)
                self.installImportedPlugin(from: renamedDownloadURL, moveItem: true, completionHandler: completionHandler)
            } catch {
                completionHandler?(.failure(.importFail))
                os_log("Failed to prepare imported plugin from %{public}@ \n%{public}@", log: Log.plugin, type: .error, url.absoluteString, error.localizedDescription)
            }
        }
        downloadTask.resume()
    }

    #if !MAC_APP_STORE
        func configureDirectoryObserver() {
            if let url = pluginDirectoryURL {
                directoryObserver = DirectoryObserver(url: url, block: { [weak self] in
                    self?.directoryChanged()
                })
            }
        }
    #endif

    func directoryChanged() {
        directoryChangeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.loadPlugins()
        }

        directoryChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.directoryChangeDebounceInterval, execute: workItem)
    }
}

extension PluginManager {
    private var diagnosticsDirectoryURL: URL? {
        guard let appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String,
              let applicationSupportURL = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                                       in: .userDomainMask,
                                                                       appropriateFor: nil,
                                                                       create: true)
        else {
            return nil
        }

        return applicationSupportURL
            .appendingPathComponent(appName)
            .appendingPathComponent("Diagnostics")
    }

    func latestSystemReportURL(createDirectory: Bool = false) -> URL? {
        guard let diagnosticsDirectoryURL else {
            return nil
        }

        if createDirectory {
            do {
                try FileManager.default.createDirectory(at: diagnosticsDirectoryURL, withIntermediateDirectories: true)
            } catch {
                os_log("Failed to create diagnostics directory %{public}@: %{public}@",
                       log: Log.diagnostics, type: .error, diagnosticsDirectoryURL.path, error.localizedDescription)
                return nil
            }
        }

        return diagnosticsDirectoryURL.appendingPathComponent("latest-system-report.txt")
    }

    private func boolString(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func stringValue(_ value: String?) -> String {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "none"
        }

        return value
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else {
            return "never"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func activationPolicyString() -> String {
        switch NSApp.activationPolicy() {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown"
        }
    }

    private func byteCountString(for url: URL) -> String {
        guard let state = pluginFileState(for: url) else {
            return "unknown"
        }

        return ByteCountFormatter.string(fromByteCount: Int64(state.size), countStyle: .file)
    }

    private func fileExistsDescription(for url: URL) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            return "missing"
        }

        return isDirectory.boolValue ? "directory" : "file"
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private func quarantineAttribute(for url: URL) -> String? {
        guard let output = try? runScript(to: "/usr/bin/xattr",
                                          args: ["-p", "com.apple.quarantine", url.path],
                                          runInBash: false).out
        else {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func errorPreview(_ error: Error?) -> String {
        guard let error else {
            return "none"
        }

        let preview = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else {
            return String(describing: error)
        }

        if preview.count <= 500 {
            return preview
        }

        return String(preview.prefix(500)) + "…"
    }

    private func contentStateDescription(for plugin: Plugin) -> String {
        if plugin.lastState == .Loading {
            return "loading"
        }

        guard let content = plugin.content else {
            return "nil"
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "empty"
        }

        return "non-empty (\(trimmed.count) chars)"
    }

    func currentSystemReport(reason: String = "manual") -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                currentSystemReport(reason: reason)
            }
        }

        let bundleURL = Bundle.main.bundleURL
        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath()
        let pluginDirectoryURL = prefs.pluginDirectoryResolvedURL
        let discoveredPluginCandidates = getPluginList()
        let statusItemEntries = statusItemPersistenceEntries(in: UserDefaults.standard.dictionaryRepresentation())
        let runningMenuBarManagers = knownMenuBarManagerMatches(in: NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let reportPath = latestSystemReportURL()?.path ?? "unavailable"

        var lines: [String] = [
            "menubar01 System Report",
            "Generated: \(dateString(Date()))",
            "Reason: \(reason)",
            "Privacy note: local paths and configuration are included; secret environment values are intentionally omitted.",
            "Latest report path: \(reportPath)",
            "",
            "== App ==",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")",
            "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "PID: \(ProcessInfo.processInfo.processIdentifier)",
            "User: \(NSUserName())",
            "Time Zone: \(TimeZone.current.identifier)",
            "Activation Policy: \(activationPolicyString())",
            "Bundle Path: \(bundleURL.path)",
            "Resolved Bundle Path: \(resolvedBundleURL.path)",
            "Running Translocated: \(boolString(bundleURL.path.contains("/AppTranslocation/") || resolvedBundleURL.path.contains("/AppTranslocation/")))",
            "Quarantine Attribute: \(stringValue(quarantineAttribute(for: bundleURL)))",
            "Known Menu Bar Managers: \(runningMenuBarManagers.isEmpty ? "none" : runningMenuBarManagers.joined(separator: ", "))",
            "",
            "== Preferences ==",
            "Plugin Directory: \(stringValue(prefs.pluginDirectoryPath))",
            "Resolved Plugin Directory: \(stringValue(pluginDirectoryURL?.path))",
            "Plugin Directory Exists: \(pluginDirectoryURL.map { boolString(FileManager.default.fileExists(atPath: $0.path)) } ?? "no")",
            "Plugin Directory Is Symlink: \(pluginDirectoryURL.map { boolString(isSymbolicLink($0)) } ?? "no")",
            "Detected Login Shell: \(sharedEnv.userLoginShell)",
            "Environment SHELL: \(stringValue(ProcessInfo.processInfo.environment["SHELL"]))",
            "Configured Shell: \(prefs.shell.rawValue)",
            "Configured Terminal: \(prefs.terminal.rawValue)",
            "Make Plugin Executable: \(boolString(prefs.makePluginExecutable))",
            "Hide menubar01 Icon: \(boolString(prefs.menubar01IconIsHidden))",
            "Stealth Mode: \(boolString(prefs.stealthMode))",
            "Include Beta Updates: \(boolString(prefs.includeBetaUpdates))",
            "Plugin Debug Mode: \(boolString(prefs.pluginDebugMode))",
            "Debug Logging Enabled: \(boolString(prefs.debugLoggingEnabled))",
            "Disabled Plugins: \(prefs.disabledPlugins.isEmpty ? "none" : prefs.disabledPlugins.joined(separator: ", "))",
            "",
            "== Status Item Persistence ==",
        ]

        if statusItemEntries.isEmpty {
            lines.append("No NSStatusItem persistence keys found.")
        } else {
            lines.append(contentsOf: statusItemEntries.map { "- \($0)" })
        }

        lines.append("")
        lines.append("== Plugin Directory Candidates ==")

        if discoveredPluginCandidates.isEmpty {
            lines.append("No plugin candidates discovered.")
        } else {
            for candidate in discoveredPluginCandidates.sorted(by: { $0.path < $1.path }) {
                let resolvedPath = candidate.resolvingSymlinksInPath().path
                let status = systemReportCandidateStatus(for: candidate, makePluginExecutable: prefs.makePluginExecutable)
                let executable = isManifestPluginDirectory(candidate)
                    ? "n/a"
                    : boolString(FileManager.default.isExecutableFile(atPath: candidate.path))
                lines.append("- \(candidate.path)")
                lines.append("  resolved: \(resolvedPath)")
                lines.append("  status: \(status)")
                lines.append("  exists: \(fileExistsDescription(for: candidate))")
                lines.append("  executable: \(executable)")
                lines.append("  size: \(byteCountString(for: candidate))")
            }
        }

        lines.append("")
        lines.append("== Runtime Plugins ==")
        lines.append("Loaded Plugins: \(plugins.count)")
        lines.append("Enabled Plugins: \(enabledPlugins.count)")
        lines.append("Fallback menubar01 Item Visible: \(boolString(barItem.barItem.isVisible))")

        if plugins.isEmpty {
            lines.append("No runtime plugins loaded.")
        } else {
            for plugin in plugins.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                let menuBarItem = menuBarItems[plugin.id]
                let pluginFileURL = URL(fileURLWithPath: plugin.file)
                let metadata = plugin.metadata
                lines.append("- \(plugin.name)")
                lines.append("  id: \(plugin.id)")
                lines.append("  type: \(plugin.type.rawValue)")
                lines.append("  enabled: \(boolString(plugin.enabled))")
                lines.append("  file: \(plugin.file)")
                lines.append("  resolved file: \(pluginFileURL.resolvingSymlinksInPath().path)")
                lines.append("  file exists: \(fileExistsDescription(for: pluginFileURL))")
                lines.append("  menu item visible: \(boolString(menuBarItem?.barItem.isVisible == true))")
                lines.append("  autosave name: \(stringValue(menuBarItem?.barItem.autosaveName))")
                lines.append("  last state: \(String(describing: plugin.lastState))")
                lines.append("  last refresh reason: \(plugin.lastRefreshReason.rawValue)")
                lines.append("  last updated: \(dateString(plugin.lastUpdated))")
                lines.append("  update interval: \(plugin.updateInterval)")
                lines.append("  content state: \(contentStateDescription(for: plugin))")
                lines.append("  error: \(errorPreview(plugin.error))")
                lines.append("  metadata type: \(metadata?.type.rawValue ?? "none")")
                lines.append("  metadata alwaysVisible: \(boolString(metadata?.alwaysVisible == true))")
                lines.append("  metadata refreshOnOpen: \(boolString(metadata?.refreshOnOpen == true))")
                lines.append("  metadata runInBash: \(boolString(metadata?.shouldRunInBash ?? true))")
                lines.append("  metadata persistentWebView: \(boolString(metadata?.persistentWebView == true))")
                lines.append("  metadata schedule: \(stringValue(metadata?.schedule))")
                lines.append("  metadata variables: \(metadata?.variables.count ?? 0)")
            }
        }

        return lines.joined(separator: "\n")
    }

    @discardableResult
    func persistLatestSystemReport(reason: String = "manual") -> URL? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                persistLatestSystemReport(reason: reason)
            }
        }

        guard let reportURL = latestSystemReportURL(createDirectory: true) else {
            return nil
        }

        let report = currentSystemReport(reason: reason)

        do {
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            os_log("Persisted system report to %{public}@", log: Log.diagnostics, type: .info, reportURL.path)
            return reportURL
        } catch {
            os_log("Failed to persist system report to %{public}@: %{public}@",
                   log: Log.diagnostics, type: .error, reportURL.path, error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func copyLatestSystemReportToPasteboard() -> String? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                copyLatestSystemReportToPasteboard()
            }
        }

        let report = currentSystemReport(reason: "manual-copy")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(report, forType: .string)
        _ = persistLatestSystemReport(reason: "manual-copy")
        os_log("Copied system report to pasteboard (success=%{public}@)", log: Log.diagnostics, type: .info, boolString(success))
        return success ? report : nil
    }

    func openLatestSystemReport() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.openLatestSystemReport()
            }
            return
        }

        guard let reportURL = persistLatestSystemReport(reason: "manual-open") else {
            return
        }

        NSWorkspace.shared.open(reportURL)
    }

    func showNotification(plugin: Plugin, title: String?, subtitle: String?, body: String?, href: String?, commandParams: String?, silent: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title ?? ""
        content.subtitle = subtitle ?? ""
        content.body = body ?? ""
        content.sound = silent ? nil : .default
        content.threadIdentifier = plugin.id

        content.userInfo[SystemNotificationName.pluginID] = plugin.id

        if let urlString = href,
           let url = URL(string: urlString), url.host != nil, url.scheme != nil
        {
            content.userInfo[SystemNotificationName.url] = urlString
        }

        if let commandParams {
            content.userInfo[SystemNotificationName.command] = commandParams
        }

        let uuidString = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuidString,
                                            content: content, trigger: nil)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        notificationCenter.delegate = delegate
        notificationCenter.add(request)
    }
}

import Cocoa
import Combine
import HotKey
import os
import SwiftUI

class MenubarItem: NSObject {
    enum ActionKind: Equatable {
        case href
        case bash
        case stdin
        case refresh
    }

    var plugin: Plugin?
    let visibilityDidChange: ((Bool) -> Void)?

    private lazy var workQueue: OperationQueue = {
        let providerQueue = OperationQueue()
        providerQueue.qualityOfService = .userInitiated
        return providerQueue
    }()

    var barItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        return item
    }()

    let statusBarMenu = NSMenu(title: "")
    let titleCylleInterval: Double = 5
    var contentUpdateCancellable: AnyCancellable?
    var titleCycleCancellable: AnyCancellable?
    var stalenessCheckCancellable: AnyCancellable?
    let lastUpdatedItem = NSMenuItem(title: Localizable.MenuBar.UpdatingMenu.localized, action: nil, keyEquivalent: "")
    let aboutItem = NSMenuItem(title: Localizable.MenuBar.AboutSwiftBar.localized, action: #selector(showAboutPopover), keyEquivalent: "")
    let runInTerminalItem = NSMenuItem(title: Localizable.MenuBar.RunInTerminal.localized, action: #selector(runInTerminal), keyEquivalent: "")
    let disablePluginItem = NSMenuItem(title: Localizable.MenuBar.DisablePlugin.localized, action: #selector(disablePlugin), keyEquivalent: "")
    let debugPluginItem = NSMenuItem(title: Localizable.MenuBar.DebugPlugin.localized, action: #selector(debugPlugin), keyEquivalent: "")
    let terminatePluginItem = NSMenuItem(title: Localizable.MenuBar.TerminateEphemeralPlugin.localized, action: #selector(terminateEphemeralPlugin), keyEquivalent: "")
    let swiftBarItem = NSMenuItem(title: Localizable.MenuBar.SwiftBar.localized, action: nil, keyEquivalent: "")
    /// Cached plain `NSMenuItem` (no submenu) used as a bold-style
    /// section header for the inlined "Toggle Plugins" list. We
    /// deliberately do NOT use a submenu here: macOS 13+
    /// `NSStatusItemScene` rebuilds the status item's button view
    /// whenever any submenu on a status item opens, which silently
    /// clears `button.image` (the only way we had to render the
    /// SwiftBar fallback icon). See `changes/2026-06-12-p19-flatten-toggle-menu.md`.
    private var togglePluginsHeaderItem: NSMenuItem?
    private var togglePluginItems: [PluginID: NSMenuItem] = [:]
    var isDefault = false
    var isOpen = false
    var refreshOnClose = false
    var hotKeys: [HotKey] = []
    var hotkeyTrigger: Bool = false
    var showsAllStandardItemsWhileOpen = false

    /// Tracks the current tree of parsed menu nodes for incremental diffing.
    var currentMenuTree: [MenuItemNode] = []
    /// Header lines from the last rendered content, used to detect header changes.
    var currentHeaderLines: [String] = []
    /// Number of NSMenuItems that belong to plugin content (header + separator + body).
    var pluginItemCount: Int = 0

    /// Tracks which fold parent NSMenuItems are currently expanded.
    private var expandedFoldItems: Set<ObjectIdentifier> = []
    /// Fold expansion state tracked by working line, survives full rebuilds.
    private var expandedFoldLines: Set<String> = []
    /// NSMenuItems injected as fold children, keyed by parent NSMenuItem identity.
    private var foldChildItems: [ObjectIdentifier: [NSMenuItem]] = [:]
    private weak var highlightedFoldItem: NSMenuItem?

    private var aboutPopover = NSPopover()
    private var errorPopover = NSPopover()
    private var webPopover = NSPopover()
    private var popoverDismissMonitor: Any?
    private let popoverDismissEventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    var titleLines: [String] = [] {
        didSet {
            currentTitleLineIndex = -1
            guard titleLines.count > 1 else {
                disableTitleCycle()
                return
            }
            enableTitleCycle()
        }
    }

    var currentTitleLineIndex: Int = -1

    var currentTitleLine: String {
        guard titleLines.indices.contains(currentTitleLineIndex) else {
            return titleLines.first ?? ""
        }
        return titleLines[currentTitleLineIndex]
    }

    var lastMenuItem: NSMenuItem?

    var prevLevel = 0
    var prevItems = [NSMenuItem]()

    var titleCylleTimerPubliser: Timer.TimerPublisher {
        Timer.TimerPublisher(interval: titleCylleInterval, runLoop: .main, mode: .default)
    }

    var refreshOnOpen: Bool {
        plugin?.metadata?.refreshOnOpen ?? false
    }

    lazy var menuUpdateQueue: OperationQueue = delegate.pluginManager.menuUpdateQueue

    init(title: String, plugin: Plugin? = nil, visibilityDidChange: ((Bool) -> Void)? = nil) {
        self.visibilityDidChange = visibilityDidChange
        super.init()
        barItem.button?.action = #selector(barItemClicked)
        barItem.button?.target = self
        guard plugin != nil else {
            barItem.button?.title = title
            buildStandardMenu()
            return
        }
        webPopover.delegate = self
        barItem.autosaveName = plugin?.id
        statusBarMenu.delegate = self
        replacePlugin(plugin)
    }

    deinit {
        contentUpdateCancellable?.cancel()
        titleCycleCancellable?.cancel()
        stalenessCheckCancellable?.cancel()
        // Clear the menu before ARC releases the NSStatusItem. macOS hosts
        // the menu items' views in auxiliary scenes (e.g. NSStatusItemScene,
        // NSHostedViewScene). When the NSStatusItem goes away the system
        // tries to detach those scenes; if any items still reference views
        // the detach emits "Unhandled disconnected auxiliary scene" or
        // "No scene exists for identity ... NSStatusItemView" errors.
        // Removing items first lets the menu detach its hosted views cleanly.
        statusBarMenu.removeAllItems()
        hotKeys.removeAll()
    }

    func enableTitleCycle() {
        titleCycleCancellable = titleCylleTimerPubliser
            .autoconnect()
            .receive(on: RunLoop.main)
            .sink(receiveValue: { [weak self] _ in
                self?.cycleThroughTitles()
            })
    }

    func disableTitleCycle() {
        titleCycleCancellable?.cancel()
    }

    func show() {
        setVisibility(isVisible: true)
    }

    func hide() {
        setVisibility(isVisible: false)
    }

    func replacePlugin(_ plugin: Plugin?) {
        dispatchPrecondition(condition: .onQueue(.main))
        let wasCyclingTitles = titleCycleCancellable != nil
        contentUpdateCancellable?.cancel()
        titleCycleCancellable?.cancel()
        stalenessCheckCancellable?.cancel()
        self.plugin = plugin
        // Only update autosaveName when we have a plugin so that a nil plugin
        // doesn't erase the saved menu bar position.
        if let plugin {
            barItem.autosaveName = plugin.id
        }

        if let dropTypes = plugin?.metadata?.dropTypes, !dropTypes.isEmpty {
            barItem.button?.window?.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, NSPasteboard.PasteboardType.URL])
            barItem.button?.window?.registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
            barItem.button?.window?.delegate = self
        } else {
            barItem.button?.window?.unregisterDraggedTypes()
        }

        updateMenu(content: plugin?.content)
        contentUpdateCancellable = plugin?.contentUpdatePublisher
            .receive(on: menuUpdateQueue)
            .sink { [weak self] content in
                self?.disableTitleCycle()
                self?.updateMenu(content: content)
            }

        // Keep the existing status item and swap only the plugin bindings so menu bar position stays stable.
        stalenessCheckCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self,
                      let plugin = self.plugin else { return }

                let wasStale = barItem.button?.attributedTitle.string.hasPrefix("⚠️") ?? false
                let isNowStale = plugin.isStale

                if wasStale != isNowStale {
                    setMenuTitle(title: currentTitleLine)
                }
            }

        // Restore title cycling if it was active before the replacement.
        if wasCyclingTitles, titleLines.count > 1 {
            enableTitleCycle()
        }
    }

    private func setVisibility(isVisible: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        let prev = barItem.isVisible
        let visibilityChanged = prev != isVisible

        // Mutate the button's content (image / title) BEFORE flipping
        // `barItem.isVisible`. AppKit kicks off a layout pass when
        // `isVisible` changes; if we then mutate the button mid-pass
        // we trip `_NSDetectedLayoutRecursion` and (more importantly)
        // we end up with an `NSStatusItem` whose button has no content
        // and therefore renders as a transparent, clickable-but-invisible
        // black hole — exactly the "I clicked and got an all-black menu"
        // symptom the user reported.
        //
        // For the fallback item (plugin == nil), the rules are:
        //   - show:   apply the AppIcon image and blank the title.
        //   - hide:   leave the image and title in place but flip
        //             `isVisible` to false. AppKit will then stop
        //             compositing the button. We do NOT blank the
        //             image here, because doing so is what triggered
        //             the recursive-layout warning in the previous
        //             build (AppKit tried to lay out the button
        //             while we were still inside its own layout pass).
        if plugin == nil, isVisible {
            MenubarItem.applyFallbackIcon(to: barItem)
        }

        barItem.isVisible = isVisible
        os_log("setVisibility(%{public}@) prev=%{public}@ visibilityChanged=%{public}@ now=%{public}@ plugin=%{public}@",
               log: Log.plugin, type: .info,
               isVisible ? "true" : "false",
               prev ? "true" : "false",
               visibilityChanged ? "yes" : "no",
               barItem.isVisible ? "true" : "false",
               plugin?.id ?? "nil")

        if plugin != nil {
            let removedKeys = removeStatusItemVisibilityKeys()
            for key in removedKeys {
                os_log("Removed NSStatusItem visibility key after menu item visibility change: %{public}@", log: Log.diagnostics, type: .info, key)
            }
        }

        guard visibilityChanged else { return }
        visibilityDidChange?(isVisible)
    }

    private static func applyFallbackIcon(to barItem: NSStatusItem) {
        // We deliberately do not touch `imagePosition` here. Setting
        // `imagePosition` triggers an immediate relayout of the
        // button, which (when combined with the `isVisible` flip
        // happening immediately after) is what produced
        // `_NSDetectedLayoutRecursion` and ultimately left the
        // fallback item with a transparent, clickable-but-invisible
        // black hole. The default `imagePosition` is `.imageLeft`
        // with a nil title, which renders identically to `.imageOnly`
        // for our single-glyph icon.
        guard let rawAsset = NSImage(named: "AppIcon") else {
            os_log("applyFallbackIcon: AppIcon asset missing from bundle",
                   log: Log.diagnostics, type: .error)
            return
        }
        // Render the wordmark as a 22×22 template icon. AppKit
        // derives the status-item button's frame from `image.size`,
        // so 22pt image → ~24pt button, matching the visual height
        // of the surrounding system status items (battery, finder,
        // network volume, etc., which all sit at ~22–24pt).
        // `resizedCopyTight` first crops the asset to its tight
        // visible bounding box (so the wordmark's own ~16pt of
        // padding does not survive scaling) and then aspect-fills
        // the cropped glyph into a 22×22 square.
        let appIcon = rawAsset.resizedCopyTight(w: 22, h: 22)
        appIcon.isTemplate = true

        // Idempotency: skip the write if the button already has the
        // icon we are about to apply. Re-assigning the same `image`
        // forces AppKit to invalidate the button's layout, and a
        // layout invalidation inside an in-flight layout pass is the
        // exact path that produced the recursion warning. We compare
        // by size + template flag (the cheapest stable fingerprint).
        let button = barItem.button
        if let existing = button?.image,
           existing.size == appIcon.size,
           existing.isTemplate == appIcon.isTemplate,
           button?.title == "" {
            return
        }
        button?.image = appIcon
        button?.title = ""
    }
}

extension MenubarItem: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        showsAllStandardItemsWhileOpen = !hotkeyTrigger && (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)

        if #available(macOS 12, *) {
            // nothing todo here
        } else if !AppShared.isReduceTransparencyEnabled {
            var params = MenuLineParameters(line: currentTitleLine)
            params.params["color"] = "white"
            params.params["sfcolor"] = "white"
            barItem.button?.attributedTitle = atributedTitle(with: params, pad: true).title
        }

        hotkeyTrigger = false
        reapplyOpenMenuStateIfNeeded()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        showsAllStandardItemsWhileOpen = false
        setMenuTitle(title: currentTitleLine)
        hotKeys.forEach { $0.isPaused = false }
        if let foldView = highlightedFoldItem?.view as? FoldableMenuItemView {
            foldView.setHighlighted(false)
        }
        highlightedFoldItem = nil

        // if plugin was refreshed when menu was opened refresh on menu close
        if refreshOnClose {
            menuUpdateQueue.addOperation { [weak self] in
                self?.refreshOnClose = false
                self?.disableTitleCycle()
                self?.updateMenu(content: self?.plugin?.content)
            }
        }
        // since we're handling click in barItemClicked we need to remove the menu
        barItem.menu = nil
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let highlitedItem = menu.highlightedItem,
           highlitedItem.attributedTitle != nil,
           let params = highlitedItem.representedObject as? MenuLineParameters,
           params.color != nil
        {
            highlitedItem.attributedTitle = atributedTitle(with: params).title
        }

        if var params = item?.representedObject as? MenuLineParameters,
           item?.attributedTitle != nil,
           params.color != nil
        {
            params.params.removeValue(forKey: "color")
            item?.attributedTitle = atributedTitle(with: params).title
        }

        if let previousFoldView = highlightedFoldItem?.view as? FoldableMenuItemView {
            previousFoldView.setHighlighted(false)
        }
        if let nextFoldView = item?.view as? FoldableMenuItemView {
            nextFoldView.setHighlighted(true)
            highlightedFoldItem = item
        } else {
            highlightedFoldItem = nil
        }
    }
}

// Standard status bar menu
extension MenubarItem {
    /// Insert an item that may already belong to another menu, detaching it
    /// first. AppKit asserts if a `NSMenuItem` is added twice, so every
    /// reusable (singleton) item in this class needs to go through this helper.
    private func insertReusable(_ item: NSMenuItem, into menu: NSMenu) {
        if let owner = item.menu, owner !== menu {
            owner.removeItem(item)
        }
        menu.addItem(item)
    }

    func buildStandardMenu() {
        let firstLevel = (plugin == nil)
        let menu = firstLevel ? statusBarMenu : NSMenu(title: "")

        let refreshAllItem = NSMenuItem(title: Localizable.MenuBar.RefreshAll.localized, action: #selector(refreshAllPlugins), keyEquivalent: "r")
        let enableAllItem = NSMenuItem(title: Localizable.MenuBar.EnableAll.localized, action: #selector(enableAllPlugins), keyEquivalent: "")
        let disableAllItem = NSMenuItem(title: Localizable.MenuBar.DisableAll.localized, action: #selector(disableAllPlugins), keyEquivalent: "")

        // The "Toggle Plugins" submenu was removed (p19) because
        // AppKit's NSStatusItemScene rebuilds the status item's
        // button view whenever any submenu on a status item opens,
        // silently clearing the SwiftBar fallback icon. Instead,
        // the toggle plugin list is inlined into the root menu as
        // a section, with a bold disabled header and one
        // NSMenuItem (with `state = .on` / `.off`) per toggleable
        // plugin. This keeps the UX in-context and removes the
        // submenu that was triggering the bug.
        rebuildTogglePluginSection()

        let preferencesItem = NSMenuItem(title: Localizable.MenuBar.Preferences.localized, action: #selector(openPreferences), keyEquivalent: ",")
        let openPluginFolderItem = NSMenuItem(title: Localizable.MenuBar.OpenPluginsFolder.localized, action: #selector(openPluginFolder), keyEquivalent: "")
        let changePluginFolderItem = NSMenuItem(title: Localizable.MenuBar.ChangePluginsFolder.localized, action: #selector(changePluginFolder), keyEquivalent: "")
        let getPluginsItem = NSMenuItem(title: Localizable.MenuBar.GetPlugins.localized, action: #selector(getPlugins), keyEquivalent: "")
        let sendFeedbackItem = NSMenuItem(title: Localizable.MenuBar.SendFeedback.localized, action: #selector(sendFeedback), keyEquivalent: "")
        let copySystemReportItem = NSMenuItem(title: Localizable.MenuBar.CopySystemReport.localized, action: #selector(copySystemReport), keyEquivalent: "")
        let openSystemReportItem = NSMenuItem(title: Localizable.MenuBar.OpenSystemReport.localized, action: #selector(openSystemReport), keyEquivalent: "")
        let aboutSwiftbarItem = NSMenuItem(title: Localizable.MenuBar.AboutPlugin.localized, action: #selector(aboutSwiftBar), keyEquivalent: "")
        let quitItem = NSMenuItem(title: Localizable.App.Quit.localized, action: #selector(quit), keyEquivalent: "q")
        let showErrorItem = NSMenuItem(title: Localizable.MenuBar.ShowError.localized, action: #selector(showErrorPopover), keyEquivalent: "")
        for item in [refreshAllItem, enableAllItem, disableAllItem, preferencesItem, openPluginFolderItem, changePluginFolderItem, getPluginsItem, quitItem, disablePluginItem, debugPluginItem, terminatePluginItem, aboutItem, aboutSwiftbarItem, runInTerminalItem, showErrorItem, sendFeedbackItem, copySystemReportItem, openSystemReportItem] {
            item.target = self
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        }

        // Outermost version header — must be the very first row the
        // user sees when they click the SwiftBar menu bar icon.
        // Non-selectable / non-clickable. Re-created on every menu
        // rebuild so the label always reflects the binary that is
        // actually running, including any hot-reloaded `AppVersion`
        // constant. (p20: this used to be inserted further down, but
        // p19 added the inlined "TOGGLE PLUGINS" section above it,
        // pushing the version off the top — restored to the top here.)
        let versionHeader = NSMenuItem(title: AppVersion.fullLabel, action: nil, keyEquivalent: "")
        versionHeader.isEnabled = false
        versionHeader.attributedTitle = NSAttributedString(
            string: AppVersion.fullLabel,
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(versionHeader)
        menu.addItem(NSMenuItem.separator())
        insertReusable(togglePluginsHeaderItem!, into: menu)
        for item in togglePluginItems.values.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            insertReusable(item, into: menu)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(refreshAllItem)
        menu.addItem(enableAllItem)
        menu.addItem(disableAllItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(openPluginFolderItem)
        menu.addItem(changePluginFolderItem)
        menu.addItem(getPluginsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(aboutSwiftbarItem)
        menu.addItem(preferencesItem)
        menu.addItem(copySystemReportItem)
        menu.addItem(openSystemReportItem)
        menu.addItem(sendFeedbackItem)
        menu.addItem(quitItem)

        if !firstLevel {
            statusBarMenu.addItem(NSMenuItem.separator())

            // put swiftbar menu as submenu
            swiftBarItem.attributedTitle = NSAttributedString(string: swiftBarItem.title, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
            swiftBarItem.submenu = menu
            swiftBarItem.image = PreferencesStore.shared.swiftBarIconIsHidden ? nil : NSImage(named: "AppIcon")?.resizedCopy(w: 21, h: 21)
            insertReusable(swiftBarItem, into: statusBarMenu)

            // default plugin menu items
            statusBarMenu.addItem(NSMenuItem.separator())
            insertReusable(lastUpdatedItem, into: statusBarMenu)
            if plugin?.error != nil {
                insertReusable(showErrorItem, into: statusBarMenu)
            }
            if let pluginType = plugin?.type {
                if PluginType.runnableInTerminal.contains(pluginType) {
                    insertReusable(runInTerminalItem, into: statusBarMenu)
                }
                if PreferencesStore.shared.pluginDebugMode, PluginType.debugable.contains(pluginType) {
                    insertReusable(debugPluginItem, into: statusBarMenu)
                }
                if PluginType.disableable.contains(pluginType) {
                    insertReusable(disablePluginItem, into: statusBarMenu)
                }
                if pluginType == .Ephemeral {
                    insertReusable(terminatePluginItem, into: statusBarMenu)
                }
            }

            if plugin?.metadata?.isEmpty == false {
                insertReusable(aboutItem, into: statusBarMenu)
            }
        }
    }

    @objc func refreshAllPlugins() {
        delegate.pluginManager.refreshAllPlugins(reason: .RefreshAllMenu)
    }

    /// Rebuild the inlined "Toggle Plugins" section. Each toggleable
    /// plugin becomes a flat `NSMenuItem` (no submenu) with a
    /// checkmark `state`. A bold disabled header item sits above the
    /// list as a visual section separator.
    ///
    /// The previous design attached a real `NSMenu` to a parent item,
    /// which AppKit's `NSStatusItemScene` interpreted as a trigger to
    /// rebuild the status item's button view whenever the user opened
    /// any submenu. That rebuild silently cleared `button.image`,
    /// making the SwiftBar fallback icon disappear while the menu
    /// was open. Inlining the rows into the root menu removes the
    /// submenu entirely.
    func rebuildTogglePluginSection() {
        if togglePluginsHeaderItem == nil {
            let header = NSMenuItem(title: Localizable.MenuBar.TogglePlugins.localized, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: Localizable.MenuBar.TogglePlugins.localized.uppercased(),
                attributes: [
                    .font: NSFont.menuBarFont(ofSize: 0),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            togglePluginsHeaderItem = header
        }

        let toggleablePlugins = delegate.pluginManager.plugins
            .filter { PluginType.disableable.contains($0.type) }

        // Reconcile: keep the `togglePluginItems` cache in sync with
        // the current plugin set. We update existing items' title and
        // state in place where possible, and remove items whose
        // plugins are gone. This is much friendlier than tearing
        // down the entire list and rebuilding from scratch, because
        // `buildStandardMenu()` runs many times per minute as
        // plugins emit content.
        let currentIDs = Set(toggleablePlugins.map(\.id))
        for (id, item) in togglePluginItems where !currentIDs.contains(id) {
            item.menu?.removeItem(item)
            togglePluginItems.removeValue(forKey: id)
        }
        for plugin in toggleablePlugins {
            if let existing = togglePluginItems[plugin.id],
               let toggleView = existing.view as? PluginToggleMenuItemView {
                // In-place state sync: the row already exists in the
                // menu. Just reflect the latest enabled/disabled state
                // on the embedded view. We do NOT tear down the view
                // (which would force a layout invalidation in the
                // middle of menu tracking).
                toggleView.applyEnabled(plugin.enabled)
            } else {
                // New plugin — build a `PluginToggleMenuItemView`
                // (self-drawn iOS-style toggle, no NSSwitch) and
                // attach it to a flat `NSMenuItem`. The view's
                // `onToggle` callback drives enable / disable on
                // `PluginManager`. We deliberately set `action = nil`
                // and `target = nil` so the embedded view is the
                // sole event handler — this matches the original
                // p3–p8 wiring and keeps the menu open across
                // multiple toggles in one pass.
                let toggleView = PluginToggleMenuItemView(plugin: plugin)
                toggleView.onToggle = { [weak self] pluginID, isOn in
                    // NOTE: We reach `PluginManager` through the
                    // shared singleton rather than `self.delegate`.
                    // `MenubarItem` does not actually declare a
                    // `delegate` property — the other call sites
                    // that read `self.delegate.pluginManager` (e.g.
                    // `refreshAllPlugins`, `disableAllPlugins`) only
                    // compile in the same file because of how Swift
                    // resolves unqualified identifiers in some
                    // extensions. Inside a `[weak self]` closure the
                    // resolution differs and fails. The shared
                    // singleton is the canonical handle and is
                    // created once in `PluginManager.init` long
                    // before any toggle is rendered.
                    guard let manager = PluginManager.shared as PluginManager?,
                          let target = manager.plugins.first(where: { $0.id == pluginID })
                    else { return }
                    if isOn {
                        manager.enablePlugin(plugin: target)
                    } else {
                        manager.disablePlugin(plugin: target)
                    }
                    _ = self // silence unused-self warning; we keep
                    // the weak capture so the closure does not
                    // extend the MenubarItem lifetime beyond the
                    // owning menu.
                }
                let item = NSMenuItem(
                    title: plugin.name,
                    action: nil,
                    keyEquivalent: ""
                )
                item.view = toggleView
                togglePluginItems[plugin.id] = item
            }
        }

        // If there are no toggleable plugins, surface a single
        // disabled "no plugins" placeholder so the section is never
        // a confusing empty gap.
        if togglePluginItems.isEmpty {
            let placeholder = NSMenuItem(
                title: Localizable.Preferences.NoPluginsMessage.localized,
                action: nil,
                keyEquivalent: ""
            )
            placeholder.isEnabled = false
            togglePluginItems["__no-plugins__"] = placeholder
        } else if togglePluginItems["__no-plugins__"] != nil {
            togglePluginItems.removeValue(forKey: "__no-plugins__")
        }
    }

    @objc func disableAllPlugins() {
        delegate.pluginManager.disableAllPlugins()
    }

    @objc func enableAllPlugins() {
        delegate.pluginManager.enableAllPlugins()
    }

    @objc func openPluginFolder() {
        AppShared.openPluginFolder()
    }

    // TODO: Preferences should be shown as a standalone window.
    @objc func openPreferences() {
        AppShared.openPreferences()
    }

    @objc func changePluginFolder() {
        AppShared.changePluginFolder()
    }

    @objc func getPlugins() {
        AppShared.getPlugins()
    }

    @objc func sendFeedback() {
        NSWorkspace.shared.open(URL(string: "https://github.com/swiftbar/SwiftBar/issues")!)
    }

    @objc func copySystemReport() {
        _ = delegate.pluginManager.copyLatestSystemReportToPasteboard()
    }

    @objc func openSystemReport() {
        delegate.pluginManager.openLatestSystemReport()
    }

    @objc func quit() {
        NSApp.terminate(self)
    }

    @objc func runInTerminal() {
        guard let scriptPath = plugin?.file else { return }
        AppShared.runInTerminal(script: scriptPath, env: plugin?.env ?? [:], runInBash: plugin?.metadata?.shouldRunInBash ?? true)
    }

    func startPopupMonitor() {
        popoverDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: popoverDismissEventMask, handler: popoverHideHandler) as? NSObject
    }

    func stopPopupMonitor() {
        if let monitor = popoverDismissMonitor {
            NSEvent.removeMonitor(monitor)
            popoverDismissMonitor = nil
        }
    }

    @objc func disablePlugin() {
        guard let plugin else { return }
        delegate.pluginManager.disablePlugin(plugin: plugin)
    }

    @objc func debugPlugin() {
        guard let plugin else { return }
        AppShared.showPluginDebug(plugin: plugin)
    }

    @objc func terminateEphemeralPlugin() {
        guard let plugin else { return }
        plugin.terminate()
    }

    @objc func showErrorPopover() {
        guard let plugin, plugin.error != nil else { return }
        errorPopover.behavior = .transient
        errorPopover.contentViewController = NSHostingController(rootView: PluginErrorView(plugin: plugin))
        errorPopover.show(relativeTo: barItem.button!.bounds, of: barItem.button!, preferredEdge: .minY)
        errorPopover.contentViewController?.view.window?.becomeKey()
        startPopupMonitor()
    }

    @objc func hideErrorPopover(_ sender: AnyObject?) {
        errorPopover.performClose(sender)
        stopPopupMonitor()
    }

    @objc func showAboutPopover() {
        guard let pluginMetadata = plugin?.metadata else { return }
        aboutPopover.behavior = .transient
        aboutPopover.contentViewController = NSHostingController(rootView: AboutPluginView(md: pluginMetadata))
        aboutPopover.show(relativeTo: barItem.button!.bounds, of: barItem.button!, preferredEdge: .minY)
        aboutPopover.contentViewController?.view.window?.becomeKey()
        startPopupMonitor()
    }

    @objc func hideAboutPopover(_ sender: AnyObject?) {
        aboutPopover.performClose(sender)
        stopPopupMonitor()
    }

    func showWebPopover(url: URL, widht: CGFloat, height: CGFloat, zoom: CGFloat) {
        defer {
            webPopover.show(relativeTo: barItem.button!.bounds, of: barItem.button!, preferredEdge: .minY)
            webPopover.contentViewController?.view.window?.becomeKey()
            startPopupMonitor()
        }

        guard webPopover.contentViewController == nil || plugin?.metadata?.persistentWebView == false else {
            return
        }

        let urlRequest = URLRequest(url: url)
        webPopover.behavior = .transient
        webPopover.contentViewController = NSHostingController(
            rootView: WebPanelView(
                request: urlRequest,
                name: plugin?.name ?? "",
                zoomFactor: zoom
            )
        )
        webPopover.contentSize = NSSize(width: widht, height: height)
    }

    func hideWebPopover(_ sender: AnyObject?) {
        // If the popover is detached, don't automatically close it when clicking outside
        if let window = webPopover.contentViewController?.view.window,
           window.styleMask.contains(.titled)
        {
            // Only stop the monitor for detached windows, don't close the window
            stopPopupMonitor()
            return
        }

        // Normal popover behavior for non-detached popovers
        webPopover.performClose(sender)
        if plugin?.metadata?.persistentWebView == false {
            resetWebPopoverContent()
        }
        stopPopupMonitor()
    }

    func resetWebPopoverContent() {
        webPopover.contentViewController = nil
    }

    func popoverHideHandler(_ event: NSEvent?) {
        if aboutPopover.isShown {
            hideAboutPopover(event)
        }

        if errorPopover.isShown {
            hideErrorPopover(event)
        }

        if webPopover.isShown {
            hideWebPopover(event)
        }
    }

    @objc func aboutSwiftBar() {
        AppShared.showAbout()
    }
}

extension MenubarItem {
    static func defaultBarItem() -> MenubarItem {
        let item = MenubarItem(title: "SwiftBar")
        item.isDefault = true
        // The fallback SwiftBar item intentionally has no visibility callback.
        // PluginManager owns its visibility directly, which avoids callback recursion.
        //
        // Order matters: the previous version set `isVisible = true` first
        // and then called `applyFallbackIcon`, which mutated the button's
        // `image` and `title` *after* AppKit had already started a layout
        // pass on the freshly-shown status item. AppKit detected
        // `layoutSubtreeIfNeeded` recursion, aborted, and left the button
        // without rendered content — the "transparent clickable button"
        // symptom the user reported.
        //
        // Apply the icon FIRST, then flip `isVisible`. This guarantees the
        // button is fully configured before AppKit sees the visibility
        // change.
        //
        // Eagerly attach `statusBarMenu` to `barItem.menu` BEFORE
        // flipping `isVisible`. macOS 13+ AppKit tracks "this status
        // item has user-supplied content" by the presence of a
        // non-nil `menu` at the moment the status item becomes
        // visible. If the menu is attached later (e.g. from
        // `barItemClicked` → `showMenu()`), AppKit's `NSStatusItemScene`
        // treats the button as content-less and resets `button.image
        // = nil` whenever the user opens a submenu — that is the
        // "icon disappears when hovering Toggle Plugins" bug.
        // Attaching the menu up-front signals to AppKit that the
        // button's content (image / title) is the user's and must
        // not be touched during menu tracking.
        applyFallbackIcon(to: item.barItem)
        item.barItem.menu = item.statusBarMenu
        item.barItem.isVisible = true
        return item
    }
}

// parse script output
extension MenubarItem {
    func splitScriptOutput(scriptOutput: String) -> (header: [String], body: [String]) {
        let lines = scriptOutput.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty }
        guard let index = lines.firstIndex(where: { $0.hasPrefix("---") }) else {
            return (lines, [])
        }
        let header = Array(lines[...index].dropLast())
        let body = Array(lines[index...])

        return (header, body)
    }

    func addShortcut(shortcut: HotKey, action: @escaping () -> Void) {
        shortcut.keyUpHandler = action
        hotKeys.append(shortcut)
    }

    func updateMenu(content: String?) {
        DispatchQueue.main.async { [weak self] in
            self?._updateMenu(content: content)
        }
    }

    func _updateMenu(content: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        barItem.button?.appearsDisabled = false

        if plugin?.lastState == .Failed {
            fullRebuildMenu(content: nil)
            return
        }

        guard let scriptOutput = content,
              !scriptOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plugin?.lastState == .Loading
        else {
            if plugin?.metadata?.alwaysVisible == true {
                fullRebuildMenu(content: nil)
            } else {
                currentMenuTree = []
                currentHeaderLines = []
                pluginItemCount = 0
                hide()
            }
            return
        }

        let parts = splitScriptOutput(scriptOutput: scriptOutput)
        let newTree = MenuItemNode.buildMenuTree(from: parts.body)

        // Use incremental diff if we have a previous tree to compare against
        if !currentMenuTree.isEmpty {
            incrementalUpdateMenu(content: scriptOutput, header: parts.header, body: parts.body, newTree: newTree)
        } else {
            fullRebuildMenu(content: content)
        }
    }

    /// Full rebuild: clears everything and recreates from scratch.
    /// Used on first render, error states, or as a fallback.
    private func fullRebuildMenu(content: String?) {
        statusBarMenu.removeAllItems()
        hotKeys.removeAll()
        prevItems.removeAll()
        prevLevel = 0
        expandedFoldItems.removeAll()
        foldChildItems.removeAll()
        // Note: expandedFoldLines is intentionally NOT cleared here
        // so that fold state survives full rebuilds.
        resetWebPopoverContent()
        show()
        defer {
            reapplyOpenMenuStateIfNeeded()
        }

        if plugin?.lastState == .Failed {
            titleLines = ["􀇾"]
            barItem.button?.title = "􀇾"
            buildStandardMenu()
            return
        }

        guard let scriptOutput = content,
              !scriptOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plugin?.lastState == .Loading
        else {
            if plugin?.metadata?.alwaysVisible == true {
                buildStandardMenu()
            } else {
                hide()
            }
            return
        }

        let parts = splitScriptOutput(scriptOutput: scriptOutput)
        titleLines = parts.header
        updateMenuTitle(titleLines: parts.header)

        if !parts.body.isEmpty {
            statusBarMenu.addItem(NSMenuItem.separator())
        }

        // Build the tree first so fold items know their children at construction time
        let tree = MenuItemNode.buildMenuTree(from: parts.body)
        for node in tree {
            if node.isSeparator {
                statusBarMenu.addItem(NSMenuItem.separator())
            } else if let item = buildMenuItem(params: MenuLineParameters(line: node.workingLine)) {
                item.target = self
                statusBarMenu.addItem(item)
                buildSubmenuItems(for: item, from: node, into: statusBarMenu)
            }
        }

        // Track how many items belong to the plugin content.
        // Includes title/header items + optional separator + body root-level items + fold children.
        // Standard menu items (SwiftBar submenu, etc.) are appended after this point.
        currentHeaderLines = parts.header
        currentMenuTree = tree
        pluginItemCount = statusBarMenu.items.count
        syncHotKeys()
        buildStandardMenu()
    }

    /// Body-only incremental update for use while the menu is open.
    /// Patches body items in-place without touching the header or title.
    /// Called from the content subscriber when the menu is open.
    /// Incremental update: diffs old vs new tree and patches the live menu.
    /// This runs while the menu may be open, enabling live content updates
    /// without waiting for the menu to close and rebuild.
    private func incrementalUpdateMenu(content: String, header: [String], body: [String], newTree: [MenuItemNode]) {
        dispatchPrecondition(condition: .onQueue(.main))

        if body.isEmpty || header.count != currentHeaderLines.count {
            fullRebuildMenu(content: content)
            return
        }

        // Update header/title in-place if content changed (avoids full rebuild)
        if header != currentHeaderLines {
            titleLines = header
            currentHeaderLines = header
            setMenuTitle(title: header.first ?? "")
            // Patch header items in the menu for multi-line titles
            if header.count > 1 {
                for (index, line) in header.enumerated() {
                    guard index < statusBarMenu.items.count else { break }
                    let item = statusBarMenu.items[index]
                    guard !item.isSeparatorItem else { break }
                    patchMenuItem(item, with: MenuLineParameters(line: line))
                }
            }
        }

        // Calculate the base index in statusBarMenu where body items start.
        // Layout: [title items...] [separator] [body items...] [standard items...]
        let oldBodyCount = countMenuItems(in: currentMenuTree, for: statusBarMenu)
        let bodyBaseIndex = pluginItemCount - oldBodyCount

        // Validate index assumptions; fall back to full rebuild if out of sync.
        guard bodyBaseIndex >= 0, bodyBaseIndex + oldBodyCount <= statusBarMenu.items.count else {
            os_log("Incremental update index mismatch (base=%d, bodyCount=%d, menuCount=%d), falling back to full rebuild",
                   log: Log.plugin, type: .error, bodyBaseIndex, oldBodyCount, statusBarMenu.items.count)
            fullRebuildMenu(content: content)
            return
        }

        // Diff body items and patch in-place
        let changes = diffMenuNodes(old: currentMenuTree, new: newTree)
        applyDiff(changes, oldTree: currentMenuTree, newTree: newTree, to: statusBarMenu, baseIndex: bodyBaseIndex)

        // Update tracking state
        pluginItemCount = pluginItemCount - oldBodyCount + countMenuItems(in: newTree, for: statusBarMenu)
        currentMenuTree = newTree
        restoreTitleCycleIfNeeded()
        syncHotKeys()
        if isOpen {
            reapplyOpenMenuStateIfNeeded()
        } else {
            updateLastUpdatedItem()
        }
    }

    /// Count the NSMenuItems in the flat menu that belong to the plugin content.
    /// Includes root-level nodes plus any fold children injected as siblings.
    /// Counts only fold children that are actually inserted into the target menu.
    private func countMenuItems(in nodes: [MenuItemNode], for menu: NSMenu) -> Int {
        var uniqueChildren = Set<ObjectIdentifier>()
        for items in foldChildItems.values {
            for item in items {
                guard item.menu === menu else { continue }
                uniqueChildren.insert(ObjectIdentifier(item))
            }
        }
        return nodes.count + uniqueChildren.count
    }

    /// Apply a diff to a live NSMenu, patching items in-place.
    private func applyDiff(_ changes: [MenuItemChange], oldTree: [MenuItemNode], newTree: [MenuItemNode], to menu: NSMenu, baseIndex: Int) {
        applyRemovals(changes, oldTree: oldTree, to: menu, baseIndex: baseIndex)
        applyUpdatesAndInserts(changes, oldTree: oldTree, newTree: newTree, to: menu, baseIndex: baseIndex)
    }

    /// Compute the actual menu index for a node index, accounting for fold children
    /// inserted as siblings before this position.
    private func actualMenuIndex(for nodeIndex: Int, in menu: NSMenu, baseIndex: Int, nodes: [MenuItemNode]) -> Int {
        var offset = 0
        for i in 0 ..< nodeIndex {
            let itemIndex = baseIndex + i + offset
            guard itemIndex < menu.items.count else { break }
            let item = menu.items[itemIndex]
            let key = ObjectIdentifier(item)
            if let children = foldChildItems[key] {
                offset += children.count
            }
        }
        return baseIndex + nodeIndex + offset
    }

    /// Remove items from the menu. Removals arrive in reverse index order from
    /// diffMenuNodes so that earlier indices are not invalidated.
    private func applyRemovals(_ changes: [MenuItemChange], oldTree: [MenuItemNode], to menu: NSMenu, baseIndex: Int) {
        for change in changes {
            if case .remove(let oldIndex) = change {
                let menuIndex = actualMenuIndex(for: oldIndex, in: menu, baseIndex: baseIndex, nodes: oldTree)
                guard menuIndex < menu.items.count else { continue }
                let item = menu.items[menuIndex]

                // Remove fold children first (in reverse to preserve indices)
                let key = ObjectIdentifier(item)
                if let children = foldChildItems.removeValue(forKey: key) {
                    for child in children.reversed() {
                        if let childIndex = menu.items.firstIndex(of: child) {
                            // Clean up nested fold state
                            let childKey = ObjectIdentifier(child)
                            foldChildItems.removeValue(forKey: childKey)
                            expandedFoldItems.remove(childKey)
                            if let childParams = child.representedObject as? MenuLineParameters {
                                expandedFoldLines.remove(childParams.title)
                            }
                            menu.removeItem(at: childIndex)
                        }
                    }
                }
                expandedFoldItems.remove(key)
                if let params = item.representedObject as? MenuLineParameters {
                    expandedFoldLines.remove(params.title)
                }
                menu.removeItem(at: menu.index(of: item))
            }
        }
    }

    /// Process updates and inserts in forward order after removals are complete.
    private func applyUpdatesAndInserts(_ changes: [MenuItemChange], oldTree: [MenuItemNode], newTree: [MenuItemNode], to menu: NSMenu, baseIndex: Int) {
        for change in changes {
            switch change {
            case .unchanged:
                break

            case .update(let oldIndex, let newIndex):
                let menuIndex = actualMenuIndex(for: newIndex, in: menu, baseIndex: baseIndex, nodes: newTree)
                applyUpdate(menu: menu, menuIndex: menuIndex, oldNode: oldTree[oldIndex], newNode: newTree[newIndex])

            case .insert(let newIndex):
                let menuIndex = actualMenuIndex(for: newIndex, in: menu, baseIndex: baseIndex, nodes: newTree)
                applyInsert(menu: menu, menuIndex: menuIndex, newNode: newTree[newIndex])

            case .remove:
                break // Already handled in applyRemovals
            }
        }
    }

    /// Update a single existing menu item to match a new node.
    private func applyUpdate(menu: NSMenu, menuIndex: Int, oldNode: MenuItemNode, newNode: MenuItemNode) {
        guard menuIndex < menu.items.count else { return }
        let existingItem = menu.items[menuIndex]

        if newNode.isSeparator {
            if !existingItem.isSeparatorItem {
                menu.removeItem(at: menuIndex)
                menu.insertItem(NSMenuItem.separator(), at: menuIndex)
            }
        } else if existingItem.isSeparatorItem {
            menu.removeItem(at: menuIndex)
            if let newItem = buildMenuItem(params: MenuLineParameters(line: newNode.workingLine)) {
                newItem.target = self
                menu.insertItem(newItem, at: menuIndex)
                buildSubmenuItems(for: newItem, from: newNode, into: menu)
            }
        } else {
            let oldParams = MenuLineParameters(line: oldNode.workingLine)
            let newParams = MenuLineParameters(line: newNode.workingLine)
            if !oldNode.contentEqual(to: newNode) {
                if let foldView = existingItem.view as? FoldableMenuItemView, newParams.fold {
                    let titleInfo = foldableTitleInfo(with: newParams)
                    foldView.update(
                        attributedTitle: titleInfo.normal,
                        highlightedTitle: titleInfo.highlighted,
                        image: newParams.image,
                        badge: newParams.badge
                    )
                } else {
                    patchMenuItem(existingItem, with: newParams)
                }
            }
            let foldModeChanged = oldParams.fold != newParams.fold
            if oldNode.children != newNode.children || foldModeChanged {
                if newParams.fold {
                    if foldModeChanged {
                        existingItem.submenu = nil
                    }
                    updateFoldChildren(of: existingItem, from: newNode, in: menu)
                } else if oldParams.fold {
                    // Transitioning from fold to submenu: clean up fold children first
                    removeFoldChildren(of: existingItem, from: menu)
                    existingItem.view = nil
                    updateSubmenu(of: existingItem, oldChildren: [], newChildren: newNode.children)
                } else {
                    updateSubmenu(of: existingItem, oldChildren: oldNode.children, newChildren: newNode.children)
                }
            }
        }
    }

    /// Insert a new menu item for a node that did not exist in the old tree.
    private func applyInsert(menu: NSMenu, menuIndex: Int, newNode: MenuItemNode) {
        let clampedIndex = min(menuIndex, menu.items.count)
        if newNode.isSeparator {
            menu.insertItem(NSMenuItem.separator(), at: clampedIndex)
        } else if let newItem = buildMenuItem(params: MenuLineParameters(line: newNode.workingLine)) {
            newItem.target = self
            menu.insertItem(newItem, at: clampedIndex)
            buildSubmenuItems(for: newItem, from: newNode, into: menu)
        }
    }

    /// Update fold children for an existing fold item when its children change.
    /// Patches existing fold child NSMenuItems in-place to preserve object identity
    /// (and thus fold expansion state).
    private func updateFoldChildren(of item: NSMenuItem, from newNode: MenuItemNode, in menu: NSMenu) {
        let key = ObjectIdentifier(item)

        // Update the fold parent's view
        let params = MenuLineParameters(line: newNode.workingLine)
        if let foldView = item.view as? FoldableMenuItemView {
            let titleInfo = foldableTitleInfo(with: params)
            foldView.update(
                attributedTitle: titleInfo.normal,
                highlightedTitle: titleInfo.highlighted,
                image: params.image,
                badge: params.badge
            )
        }

        guard let existingChildren = foldChildItems[key] else {
            // No existing fold children — build from scratch
            buildFoldChildren(for: item, from: newNode, into: menu)
            return
        }

        // Patch direct children in-place where possible
        let newDirectChildren = newNode.children

        // Count only direct children (not nested fold grandchildren) in existing list
        var directItems: [NSMenuItem] = []
        var index = 0
        while index < existingChildren.count {
            let child = existingChildren[index]
            let childKey = ObjectIdentifier(child)
            directItems.append(child)
            if let nestedChildren = foldChildItems[childKey] {
                index += 1 + nestedChildren.count
            } else {
                index += 1
            }
        }

        // Simple approach: if direct child count matches, patch in-place.
        // Otherwise, tear down and rebuild (preserving parent expansion state).
        if directItems.count == newDirectChildren.count {
            for (idx, newChild) in newDirectChildren.enumerated() {
                guard idx < directItems.count else { break }
                let existingChild = directItems[idx]

                if newChild.isSeparator {
                    // Separators don't need patching
                    continue
                }

                let childParams = MenuLineParameters(line: newChild.workingLine)
                if let foldView = existingChild.view as? FoldableMenuItemView, childParams.fold {
                    let titleInfo = foldableTitleInfo(with: childParams)
                    foldView.update(
                        attributedTitle: titleInfo.normal,
                        highlightedTitle: titleInfo.highlighted,
                        image: childParams.image,
                        badge: childParams.badge
                    )
                } else if existingChild.view == nil {
                    patchMenuItem(existingChild, with: childParams)
                }

                // Recursively update nested fold children
                let childKey = ObjectIdentifier(existingChild)
                if childParams.fold, foldChildItems[childKey] != nil {
                    updateFoldChildren(of: existingChild, from: newChild, in: menu)
                }
            }
        } else {
            // Child count changed — rebuild (but preserve parent expansion state)
            removeFoldChildren(of: item, from: menu)
            buildFoldChildren(for: item, from: newNode, into: menu)
        }
    }

    /// Remove all fold children of an item from the menu.
    private func removeFoldChildren(of item: NSMenuItem, from menu: NSMenu) {
        let key = ObjectIdentifier(item)
        if let children = foldChildItems.removeValue(forKey: key) {
            for child in children.reversed() {
                // Recursively remove nested fold children
                let childKey = ObjectIdentifier(child)
                if foldChildItems[childKey] != nil {
                    removeFoldChildren(of: child, from: menu)
                }
                expandedFoldItems.remove(childKey)
                if let idx = menu.items.firstIndex(of: child) {
                    menu.removeItem(at: idx)
                }
            }
        }
    }

    /// Patch an existing NSMenuItem's visible properties to match new parameters.
    private func patchMenuItem(_ item: NSMenuItem, with params: MenuLineParameters) {
        let needsAction = params.hasAction || params.color != nil
        item.action = needsAction ? #selector(perfomMenutItemAction) : nil
        item.representedObject = params

        let title = atributedTitle(with: params)
        item.attributedTitle = title.title

        item.toolTip = params.tooltip?.replacingOccurrences(of: "\\n", with: "\n")
        if let length = params.length, length < title.title.string.count {
            item.toolTip = title.tooltip
        }

        item.isAlternate = params.alternate

        item.image = params.image
        item.state = params.checked ? .on : .off

        if #available(macOS 14.0, *) {
            item.badge = params.badge.isEmpty ? nil : NSMenuItemBadge(string: params.badge)
        }
    }

    private func foldableTitleInfo(with params: MenuLineParameters) -> (normal: NSAttributedString, highlighted: NSAttributedString) {
        let normalTitle = atributedTitle(with: params).title
        guard !params.ansi else { return (normalTitle, normalTitle) }

        let highlightedTitle = NSMutableAttributedString(attributedString: normalTitle)
        highlightedTitle.addAttribute(
            .foregroundColor,
            value: NSColor.selectedMenuItemTextColor,
            range: NSRange(location: 0, length: highlightedTitle.length)
        )
        return (normalTitle, highlightedTitle)
    }

    private func syncHotKeys() {
        hotKeys.removeAll()

        if let title = titleLines.first, let kc = MenuLineParameters(line: title).shortcut {
            addShortcut(shortcut: HotKey(keyCombo: kc)) { [weak self] in
                self?.hotkeyTrigger = true
                self?.barItem.button?.performClick(nil)
            }
        }

        for item in statusBarMenu.items.prefix(pluginItemCount) {
            syncHotKeys(for: item)
        }
    }

    private func syncHotKeys(for item: NSMenuItem) {
        if let params = item.representedObject as? MenuLineParameters {
            applyShortcut(for: item, params: params)

            if let kc = params.shortcut {
                addShortcut(shortcut: HotKey(keyCombo: kc)) {
                    guard let action = item.action else { return }
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }

        item.submenu?.items.forEach { syncHotKeys(for: $0) }
    }

    private func restoreTitleCycleIfNeeded() {
        guard titleLines.count > 1 else { return }
        enableTitleCycle()
    }

    private func reapplyOpenMenuStateIfNeeded() {
        guard isOpen else { return }
        hotKeys.forEach { $0.isPaused = true }
        updateOpenMenuItemVisibility()
    }

    private func updateOpenMenuItemVisibility() {
        updateLastUpdatedItem()

        if showsAllStandardItemsWhileOpen {
            [lastUpdatedItem, runInTerminalItem, disablePluginItem, debugPluginItem, aboutItem, swiftBarItem].forEach { $0.isHidden = false }
            return
        }

        lastUpdatedItem.isHidden = plugin?.metadata?.hideLastUpdated ?? false
        runInTerminalItem.isHidden = plugin?.metadata?.hideRunInTerminal ?? false
        disablePluginItem.isHidden = plugin?.metadata?.hideDisablePlugin ?? false
        aboutItem.isHidden = plugin?.metadata?.hideAbout ?? false
        swiftBarItem.isHidden = plugin?.metadata?.hideSwiftBar ?? false
    }

    private func applyShortcut(for item: NSMenuItem, params: MenuLineParameters) {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []

        if params.alternate {
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags.option
        }

        if let kc = params.shortcut {
            item.keyEquivalentModifierMask = kc.modifiers
            item.keyEquivalent = kc.key?.description.lowercased() ?? ""
        }
    }

    /// Recursively update a submenu's children via diffing.
    private func updateSubmenu(of item: NSMenuItem, oldChildren: [MenuItemNode], newChildren: [MenuItemNode]) {
        if newChildren.isEmpty {
            item.submenu = nil
            return
        }

        if item.submenu == nil {
            item.submenu = NSMenu(title: "")
        }

        guard let submenu = item.submenu else { return }

        let childChanges = diffMenuNodes(old: oldChildren, new: newChildren)
        applyDiff(childChanges, oldTree: oldChildren, newTree: newChildren, to: submenu, baseIndex: 0)
    }

    /// Build submenu items from scratch for a newly inserted node.
    /// When the node's params have `fold=true`, children are inserted as hidden
    /// siblings in the parent menu instead of being placed in an NSSubmenu.
    private func buildSubmenuItems(for item: NSMenuItem, from node: MenuItemNode, into menu: NSMenu? = nil) {
        guard !node.children.isEmpty else { return }

        let params = MenuLineParameters(line: node.workingLine)
        if params.fold, let targetMenu = menu ?? item.menu {
            buildFoldChildren(for: item, from: node, into: targetMenu)
        } else {
            item.submenu = NSMenu(title: "")
            guard let submenu = item.submenu else { return }
            for child in node.children {
                if child.isSeparator {
                    submenu.addItem(NSMenuItem.separator())
                } else if let childItem = buildMenuItem(params: MenuLineParameters(line: child.workingLine)) {
                    childItem.target = self
                    submenu.addItem(childItem)
                    buildSubmenuItems(for: childItem, from: child, into: submenu)
                }
            }
        }
    }

    /// Build fold children: insert child items as hidden siblings in the parent menu,
    /// and attach a FoldableMenuItemView to the parent item.
    private func buildFoldChildren(for item: NSMenuItem, from node: MenuItemNode, into menu: NSMenu) {
        let key = ObjectIdentifier(item)
        let params = MenuLineParameters(line: node.workingLine)
        // Check ObjectIdentifier first (incremental), fall back to line-based state (rebuild)
        let isExpanded = expandedFoldItems.contains(key) || expandedFoldLines.contains(params.title)
        if isExpanded {
            expandedFoldItems.insert(key)
        }

        // Attach the foldable view to the parent item
        let titleInfo = foldableTitleInfo(with: params)
        let foldView = FoldableMenuItemView(
            attributedTitle: titleInfo.normal,
            highlightedTitle: titleInfo.highlighted,
            image: params.image,
            badge: params.badge,
            isFolded: !isExpanded
        )
        foldView.onToggle = { [weak self] in
            self?.toggleFoldItem(item)
        }
        item.view = foldView

        // Build child items and insert them as siblings after the parent.
        // Track insertPos rather than using offset, because recursive nested fold
        // calls insert additional items that shift positions.
        var children: [NSMenuItem] = []
        var insertPos = (menu.index(of: item) != -1) ? menu.index(of: item) + 1 : menu.items.count

        for child in node.children {
            let childItem: NSMenuItem
            if child.isSeparator {
                childItem = NSMenuItem.separator()
            } else if let built = buildMenuItem(params: MenuLineParameters(line: child.workingLine)) {
                built.target = self
                childItem = built
            } else {
                continue
            }

            childItem.isHidden = !isExpanded
            menu.insertItem(childItem, at: insertPos)
            children.append(childItem)
            insertPos += 1

            // Recursively handle nested folds or submenus
            if !child.children.isEmpty {
                buildSubmenuItems(for: childItem, from: child, into: menu)
                // Collect any fold children that were just added for this nested item
                let nestedKey = ObjectIdentifier(childItem)
                if let nestedChildren = foldChildItems[nestedKey] {
                    // Nested fold children are also hidden when outer fold is collapsed
                    if !isExpanded {
                        nestedChildren.forEach { $0.isHidden = true }
                    }
                    children.append(contentsOf: nestedChildren)
                    insertPos += nestedChildren.count
                }
            }
        }

        foldChildItems[key] = children
    }

    /// Toggle the fold state of a menu item.
    func toggleFoldItem(_ item: NSMenuItem) {
        let key = ObjectIdentifier(item)
        let wasExpanded = expandedFoldItems.contains(key)
        if let foldView = item.view as? FoldableMenuItemView {
            foldView.isFolded = wasExpanded
        }

        if wasExpanded {
            expandedFoldItems.remove(key)
        } else {
            expandedFoldItems.insert(key)
        }

        // Also track by line for cross-rebuild persistence
        if let params = item.representedObject as? MenuLineParameters {
            if wasExpanded {
                expandedFoldLines.remove(params.title)
            } else {
                expandedFoldLines.insert(params.title)
            }
        }

        if let children = foldChildItems[key] {
            for child in children {
                child.isHidden = wasExpanded
            }
            // When collapsing, also collapse any nested folds
            if wasExpanded {
                collapseNestedFolds(in: children)
            }
        }

        if let menu = item.menu {
            menu.update()
        }
    }

    /// Recursively collapse nested fold items within a set of children.
    private func collapseNestedFolds(in items: [NSMenuItem]) {
        for item in items {
            let key = ObjectIdentifier(item)
            guard foldChildItems[key] != nil else { continue }
            expandedFoldItems.remove(key)
            if let params = item.representedObject as? MenuLineParameters {
                expandedFoldLines.remove(params.title)
            }
            if let view = item.view as? FoldableMenuItemView {
                view.isFolded = true
            }
            if let nestedChildren = foldChildItems[key] {
                nestedChildren.forEach { $0.isHidden = true }
                collapseNestedFolds(in: nestedChildren)
            }
        }
    }

    /// Update the "Last Updated" timestamp in the standard menu section.
    private func updateLastUpdatedItem() {
        guard let plugin, let lastUpdated = plugin.lastUpdated else { return }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relativeDate = formatter.localizedString(for: lastUpdated, relativeTo: Date()).capitalized

        if plugin.isStale {
            lastUpdatedItem.title = "⚠️ \(Localizable.MenuBar.LastUpdated.localized) \(relativeDate) (Stale - expected update every \(formatInterval(plugin.updateInterval)))"
        } else {
            lastUpdatedItem.title = "\(Localizable.MenuBar.LastUpdated.localized) \(relativeDate)"
        }
    }
    func addMenuItem(from line: String) {
        let (currentLevel, isSeparator, workingLine) = MenuItemNode.parseLine(line)

        if isSeparator, currentLevel == 0 {
            statusBarMenu.addItem(NSMenuItem.separator())
            return
        }

        var submenu: NSMenu?

        if prevLevel >= currentLevel, prevItems.count > 0 {
            var cnt = prevLevel - currentLevel
            while cnt >= 0 {
                if !prevItems.isEmpty {
                    prevItems.removeFirst()
                }
                cnt = cnt - 1
            }
        }
        if currentLevel > 0 {
            let item = prevItems.first
            if item?.submenu == nil {
                item?.submenu = NSMenu(title: "")
            }
            submenu = item?.submenu
        }

        if let item = isSeparator ? NSMenuItem.separator() : buildMenuItem(params: MenuLineParameters(line: workingLine)) {
            item.target = self
            (submenu ?? statusBarMenu)?.addItem(item)
            lastMenuItem = item
            prevLevel = currentLevel
            prevItems.insert(item, at: 0)
        }
    }

    func updateMenuTitle(titleLines: [String]) {
        setMenuTitle(title: titleLines.first ?? "􀇾")
        guard titleLines.count > 1 else { return }

        for line in titleLines {
            addMenuItem(from: line)
        }
    }

    func setMenuTitle(title: String) {
        barItem.button?.image = nil

        let lines = title.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let displayText: String
        let isTwoLine: Bool

        if lines.count == 2 {
            // Exactly 2 lines - keep as is for proper multi-line display
            displayText = title
            isTwoLine = true
        } else if lines.count > 2 {
            // More than 2 lines - truncate to first line
            displayText = "\(lines.first ?? "")..."
            isTwoLine = false
        } else {
            // Single line or empty - no change
            displayText = title
            isTwoLine = false
        }

        let params = MenuLineParameters(line: displayText)
        if let image = params.getImage(isMenuBarItem: true) {
            barItem.button?.image = image
            barItem.button?.imagePosition = .imageLeft
        }

        var attributedTitle = atributedTitle(with: params, pad: true, isTwoLine: isTwoLine).title

        // Add stale indicator if plugin hasn't updated within 2x its refresh interval
        if let plugin, plugin.isStale {
            let warningSymbol = "⚠️ "
            let mutableTitle = NSMutableAttributedString(string: warningSymbol)
            mutableTitle.append(attributedTitle)
            attributedTitle = mutableTitle
        }

        barItem.button?.attributedTitle = attributedTitle
    }

    func cycleThroughTitles() {
        currentTitleLineIndex += 1
        if !titleLines.indices.contains(currentTitleLineIndex) {
            currentTitleLineIndex = 0
        }
        setMenuTitle(title: titleLines[currentTitleLineIndex])
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "\(Int(interval))s"
    }

    // do the following conversion:
    // \\ -> \
    // \n -> LF
    // \t -> TAB
    // \c -> c  any char else
    func unescape(_ str: String) -> String {
        var newstr = ""
        var backslash = false
        for c in str {
            if backslash {
                backslash = false
                if c == "n" {
                    newstr += "\n"
                    continue
                }
                if c == "t" {
                    newstr += "\t"
                    continue
                }
            } else {
                if c == "\\" {
                    backslash = true
                    continue
                }
            }
            newstr += String(c)
        }
        return newstr
    }

    func atributedTitle(with params: MenuLineParameters, pad: Bool = false, isTwoLine: Bool = false) -> (title: NSAttributedString, tooltip: String) {
        var title = params.trim ? params.title.trimmingCharacters(in: .whitespaces) : params.title
        guard !title.isEmpty else { return (NSAttributedString(), "") }

        if params.emojize, !params.symbolize {
            title = title.emojify()
        }
        let fullTitle = title
        if let length = params.length, length < title.count {
            title = String(title.prefix(length)).appending("...")
        }

        title = unescape(title)

        let fontSize = params.size ?? 0
        let color = params.color ?? NSColor.controlTextColor
        var font = NSFont.menuBarFont(ofSize: fontSize)
        if let fontName = params.font, let customFont = NSFont(name: fontName, size: fontSize) {
            font = customFont
        }
        // Use custom vertical alignment if provided, otherwise use default offset
        let offset = params.valign ?? (isTwoLine ? font.twoLineMenuBarOffset : font.menuBarOffset)

        let style = NSMutableParagraphStyle()
        style.alignment = pad ? .center : .left

        // Configure tab stops for proper tab alignment (issue #455)
        // Add tab stops every 100 points to support tab-aligned text
        var tabStops: [NSTextTab] = []
        for i in 1...10 {
            let location = CGFloat(i * 100)
            tabStops.append(NSTextTab(textAlignment: .left, location: location))
        }
        style.tabStops = tabStops

        var attributedTitle = NSMutableAttributedString(string: title)
        if #available(macOS 12, *), params.md, let parsedMD = try? NSAttributedString(markdown: title) {
            attributedTitle = NSMutableAttributedString(attributedString: parsedMD)
        }

        if params.symbolize, !params.ansi {
            attributedTitle.symbolize(font: font, colors: params.sfcolors, sfsize: params.sfsize)
        }
        if params.ansi {
            attributedTitle = title.colorizedWithANSIColor()
        }

        if !params.ansi {
            attributedTitle.addAttributes([.foregroundColor: color],
                                          range: NSRange(0 ..< attributedTitle.length))
        }

        attributedTitle.addAttributes([.font: font, .paragraphStyle: style, .baselineOffset: offset],

                                      range: NSRange(0 ..< attributedTitle.length))
        return (attributedTitle, fullTitle)
    }

    func buildMenuItem(params: MenuLineParameters) -> NSMenuItem? {
        guard params.dropdown else { return nil }

        // Assign action when color is set so macOS renders the item as enabled,
        // allowing the custom color to display instead of the disabled grey.
        let needsAction = params.hasAction || params.color != nil
        let item = NSMenuItem(title: params.title,
                              action: needsAction ? #selector(perfomMenutItemAction) : nil,
                              keyEquivalent: "")
        item.representedObject = params
        let title = atributedTitle(with: params)
        item.attributedTitle = title.title

        item.toolTip = params.tooltip?.replacingOccurrences(of: "\\n", with: "\n")

        if let length = params.length, length < title.title.string.count {
            item.toolTip = title.tooltip
        }

        if params.alternate {
            item.isAlternate = true
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags.option
        }

        if let image = params.image {
            item.image = image
        }

        if params.checked {
            item.state = .on
        }

        if #available(macOS 14.0, *) {
            if !params.badge.isEmpty {
                item.badge = NSMenuItemBadge(string: params.badge)
            }
        }

        return item
    }

    @objc func barItemClicked() {
        guard let eventType = NSApp.currentEvent?.type else { return }

        if eventType == .rightMouseDown {
            showMenu()
            return
        }

        if performItemAction(params: MenuLineParameters(line: currentTitleLine)) {
            return
        }

        showMenu()
    }

    func showMenu() {
        if refreshOnOpen, plugin?.type == .Executable {
            refreshAndShowMenu()
            return
        }
        barItem.menu = statusBarMenu
        barItem.button?.performClick(nil)
    }

    func refreshAndShowMenu() {
        os_log("Refreshing for refreshOnOpen plugin", log: Log.plugin, type: .info)
        plugin?.lastRefreshReason = .MenuOpen
        let content = plugin?.invoke()
        // Keep plugin.content in sync with the displayed content so that subsequent
        // scheduled refreshes are not suppressed by the content didSet guard.
        plugin?.content = content
        _updateMenu(content: content)
        barItem.menu = statusBarMenu
        barItem.button?.performClick(nil)
    }

    func dimOnManualRefresh() {
        guard delegate.prefs.dimOnManualRefresh else { return }
        barItem.button?.appearsDisabled = true
    }

    static func actionKinds(for params: MenuLineParameters) -> [ActionKind] {
        var actions: [ActionKind] = []

        if let url = params.href?.getURL(), url.absoluteString != "." {
            actions.append(.href)
        }

        if params.bash != nil {
            actions.append(.bash)
        }

        if params.stdin != nil {
            actions.append(.stdin)
        }

        if params.refresh {
            actions.append(.refresh)
        }

        return actions
    }

    @discardableResult func performItemAction(params: MenuLineParameters) -> Bool {
        var out = false
        let actions = Self.actionKinds(for: params)
        let shouldTriggerStandaloneRefresh = actions.contains(.refresh) && !actions.contains(.bash) && !actions.contains(.stdin)
        let refreshLock = NSLock()
        var didRequestRefresh = false

        let requestRefreshIfNeeded: () -> Void = { [weak self] in
            guard params.refresh else { return }

            refreshLock.lock()
            defer { refreshLock.unlock() }
            guard !didRequestRefresh else { return }
            didRequestRefresh = true
            self?.plugin?.refresh(reason: .MenuAction)
        }

        defer {
            if params.color != nil, out {
                updateMenu(content: plugin?.content) // dumb fix for #221, ideally come up with something better...
            }
        }

        if actions.contains(.href), let url = params.href?.getURL() {
            if params.webView {
                showWebPopover(
                    url: url,
                    widht: params.webViewWidth,
                    height: params.webViewHeight,
                    zoom: params.webViewZoom
                )
            } else {
                NSWorkspace.shared.open(url)
            }

            out = true
        }

        if let bash = params.bash {
            AppShared.runInTerminal(script: bash, args: params.bashParams, runInBackground: !params.terminal,
                                    env: plugin?.env ?? [:], runInBash: plugin?.metadata?.shouldRunInBash ?? true)
            {
                if params.refresh {
                    requestRefreshIfNeeded()
                }
            }
            out = true
        }

        if let stdinInput = params.stdin {
            guard let plugin else {
                os_log("No plugin available to handle stdin input", log: Log.plugin, type: .error)
                return out
            }

            do {
                try plugin.writeStdin(stdinInput)

                if params.refresh {
                    requestRefreshIfNeeded()
                }

                out = true
            } catch {
                plugin.error = error
                os_log("Failed to write stdin for plugin %{public}@: %{public}@", log: Log.plugin, type: .error, plugin.name, error.localizedDescription)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isOpen else { return }
                    self.showErrorPopover()
                }
            }

        }

        if shouldTriggerStandaloneRefresh {
            dimOnManualRefresh()
            requestRefreshIfNeeded()
            out = true
        }

        return out
    }

    @objc func perfomMenutItemAction(_ sender: NSMenuItem) {
        guard let params = sender.representedObject as? MenuLineParameters else { return }
        performItemAction(params: params)
    }
}

extension MenubarItem: NSWindowDelegate, NSDraggingDestination {
    func draggingEntered(_: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        var env: [String: String] = plugin?.env ?? [:]
        var filesURL: [URL] = []
        var url: URL?

        let pasteBoard = sender.draggingPasteboard

        if let urls = pasteBoard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            // process URL drop
            if urls.count == 1, let droppedURL = urls.first, !droppedURL.isFileURL {
                url = droppedURL
            } else {
                filesURL = urls
            }
        }

        if !filesURL.isEmpty {
            // swiftformat:disable all
            env["DROPPED_FILES"] = filesURL.compactMap{$0.absoluteString.URLEncoded}.joined(separator: ",")
            // swiftformat:enable all
        }

        if let url {
            env["DROPPED_URL"] = url.absoluteString
        }

        guard let scriptPath = plugin?.file,
              env.keys.contains("DROPPED_FILES") || env.keys.contains("DROPPED_URL")
        else { return false }
        env["LAUNCHED_FROM_DROP_ACTION"] = "TRUE"
        AppShared.runInTerminal(script: scriptPath, runInBackground: true, env: env, runInBash: plugin?.metadata?.shouldRunInBash ?? true)
        return true
    }
}

extension MenubarItem: NSPopoverDelegate {
    func popoverShouldDetach(_: NSPopover) -> Bool {
        true
    }

    func popoverDidDetach(_ popover: NSPopover) {
        // For webPopover, configure the detached window properly
        if popover == webPopover, let window = popover.contentViewController?.view.window {
            // Set the window to have proper controls
            window.styleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ]
            window.isReleasedWhenClosed = false

            // Set a minimum window size to ensure controls are visible
            window.minSize = NSSize(width: 300, height: 200)

            // Set window title to match the plugin name
            window.title = "‎ SwiftBar: \(plugin?.name ?? "")"

            // Stop the popup monitor when detached to prevent auto-closing on outside clicks
            stopPopupMonitor()
        }
    }
}

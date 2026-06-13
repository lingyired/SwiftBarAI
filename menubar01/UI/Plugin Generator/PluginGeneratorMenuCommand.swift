// PluginGeneratorMenuCommand.swift
// menubar01 — AI Plugin Generator (M2)
//
// Wires the "Generate plugin with AI…" command into the existing
// menubar01 app menu (see `AppDelegate+Menu.swift`) and presents
// the `AIGeneratorSheet` when the item is clicked.
//
// v1 (M2) keeps the presenter minimal: a single AppKit window
// wrapping a SwiftUI `NSHostingController` for the sheet. The
// window is held by the `AppDelegate`-rooted
// `aiGeneratorWindowController` so the sheet can be reused
// across clicks. A real "save to Plugin Folder" path lands in M3 —
// the M2 sheet shows a stub alert instead.

import AppKit
import SwiftUI

/// Action helper for the "Generate plugin with AI…" menu item.
///
/// `AppDelegate+Menu.swift` calls `PluginGeneratorMenuCommand.install(into:)`
/// once during `AppMenu.init`; that registers the `NSMenuItem` and
/// its `@objc` action (`AppMenu.openAIGenerator`). The action in
/// turn calls `PluginGeneratorMenuCommand.presentSheet()`, which
/// lazily creates a hosting window and shows the SwiftUI sheet.
enum PluginGeneratorMenuCommand {

    /// Localized title for the menu item. Mirrors the §2 user-flow
    /// description ("User clicks 'Generate plugin with AI…' in
    /// the Plugin Repository window"). v1 surfaces the same item
    /// in the main menubar01 app menu so it is reachable without
    /// opening the Plugin Repository window first.
    static let menuItemTitle = "Generate plugin with AI…"

    /// Install the menu item into the given `AppMenu` instance.
    /// Inserts a separator and the item at the start of the
    /// submenu (after the "About menubar01" item) so the AI
    /// command sits next to the existing top-of-menu items.
    ///
    /// - Parameter menu: The `AppMenu` instance the item is being
    ///   inserted into. The item's `target` is set to `menu`
    ///   so the `@objc` selector resolves to `AppMenu`'s
    ///   `openAIGenerator` method.
    @MainActor
    static func install(into menu: AppMenu) {
        guard let submenu = menu.items.first?.submenu else { return }
        let item = NSMenuItem(
            title: menuItemTitle,
            action: #selector(AppMenu.openAIGenerator),
            keyEquivalent: ""
        )
        item.target = menu
        // The submenu layout is:
        //   [aboutMenubar01Item, separator, sendFeedbackItem,
        //    preferencesItem, separator, quitItem]
        // We want the new item to sit right after
        // `aboutMenubar01Item`, then a separator, then the
        // existing flow.
        let separator = NSMenuItem.separator()
        if submenu.items.count > 1 {
            submenu.insertItem(separator, at: 1)
            submenu.insertItem(item, at: 2)
        } else {
            submenu.addItem(separator)
            submenu.addItem(item)
        }
    }

    /// Show the generator sheet. Mirrors the lifecycle pattern
    /// `AppShared.getPlugins()` uses: lazily create a window
    /// hosted by a SwiftUI `NSHostingController`, and surface it
    /// in front of whatever window is currently key. v1 (M2) does
    /// not present a real AppKit sheet — a standalone window keeps
    /// the menu → window plumbing identical to the existing
    /// Plugin Repository flow.
    ///
    /// The `appDelegate:` parameter is optional for backwards
    /// compatibility with the M2 call site
    /// (`AppMenu.openAIGenerator`). When supplied, the
    /// `GeneratorHistoryMenuCommand`'s "Re-generate" hook uses the
    /// same window controller so the history → generator → history
    /// round-trip reuses the in-flight VM state.
    ///
    /// The `prefillRequest:` parameter is the M5 history
    /// follow-up: when non-nil, the M2 sheet is constructed with
    /// `viewModel.request` pre-populated with the selected
    /// history entry's request, so the user does not have to
    /// copy / paste from the detail pane. The window is reset
    /// (replacing any previous content view controller) so the
    /// pre-filled text shows up immediately rather than being
    /// clobbered by a stale `viewModel`.
    @MainActor
    static func presentSheet(
        appDelegate: AppDelegate? = nil,
        prefillRequest: String? = nil
    ) {
        let resolvedDelegate: AppDelegate
        if let appDelegate {
            resolvedDelegate = appDelegate
        } else if let appDelegate = NSApp.delegate as? AppDelegate {
            resolvedDelegate = appDelegate
        } else {
            return
        }
        let windowController = ensureWindowController(appDelegate: resolvedDelegate)
        // When a prefill is supplied we always rebuild the hosting
        // controller so a stale `viewModel.request` from a prior
        // click cannot clobber the new value. Without a prefill we
        // keep the existing controller so the user does not lose
        // any in-flight input.
        if prefillRequest != nil || windowController.contentViewController == nil {
            let viewModel = AIGeneratorViewModel()
            viewModel.request = prefillRequest ?? ""
            windowController.contentViewController = NSHostingController(
                rootView: AIGeneratorSheet(viewModel: viewModel)
            )
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window Lifecycle

    /// Lazily create the generator window the first time it is
    /// requested. We keep a strong reference on the `AppDelegate`
    /// so the window survives multiple clicks on the menu item.
    @MainActor
    private static func ensureWindowController(appDelegate: AppDelegate) -> NSWindowController {
        if let existing = appDelegate.aiGeneratorWindowController {
            return existing
        }
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: CGSize(width: 640, height: 600)),
            styleMask: [.closable, .miniaturizable, .resizable, .titled],
            backing: .buffered,
            defer: false
        )
        window.title = menuItemTitle
        window.center()
        let controller = NSWindowController(window: window)
        appDelegate.aiGeneratorWindowController = controller
        return controller
    }
}

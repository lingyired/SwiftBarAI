// MarketplaceBrowserMenuCommand.swift
// menubar01 — PluginMarketplace (M5)
//
// Wires the "Browse Marketplace…" command into the existing
// menubar01 app menu (see `AppDelegate+Menu.swift`) and presents
// the `MarketplaceBrowserSheet` when the item is clicked.
//
// v1 (M5) keeps the presenter minimal — a single AppKit window
// wrapping a SwiftUI `NSHostingController` for the sheet, the
// same lifecycle pattern the M2 AI generator sheet uses. The
// window is held by the `AppDelegate`-rooted
// `marketplaceBrowserWindowController` so the sheet can be
// reused across clicks.

import AppKit
import SwiftUI

/// Action helper for the "Browse Marketplace…" menu item.
///
/// `AppDelegate+Menu.swift` calls
/// `MarketplaceBrowserMenuCommand.install(into:)` once during
/// `AppMenu.init`; that registers the `NSMenuItem` and its
/// `@objc` action (`AppMenu.openMarketplaceBrowser`). The
/// action in turn calls
/// `MarketplaceBrowserMenuCommand.presentSheet(appDelegate:)`,
/// which lazily creates a hosting window and shows the SwiftUI
/// sheet.
enum MarketplaceBrowserMenuCommand {

    /// Localized title for the menu item. Mirrors the M5
    /// user-flow description ("User clicks 'Browse Marketplace…'
    /// in the menubar01 app menu"). v1 surfaces the same item
    /// in the main menubar01 app menu so it is reachable
    /// without opening the Plugin Repository window first.
    static let menuItemTitle = "Browse Marketplace…"

    /// Install the menu item into the given `AppMenu` instance.
    /// Inserts a separator and the item at the start of the
    /// submenu (after the "About menubar01" item and the
    /// M2 "Generate plugin with AI…" item) so the marketplace
    /// command sits next to the existing top-of-menu items.
    ///
    /// - Parameter menu: The `AppMenu` instance the item is
    ///   being inserted into. The item's `target` is set to
    ///   `menu` so the `@objc` selector resolves to `AppMenu`'s
    ///   `openMarketplaceBrowser` method.
    @MainActor
    static func install(into menu: AppMenu) {
        guard let submenu = menu.items.first?.submenu else { return }
        let item = NSMenuItem(
            title: menuItemTitle,
            action: #selector(AppMenu.openMarketplaceBrowser),
            keyEquivalent: ""
        )
        item.target = menu
        // The submenu layout is:
        //   [aboutMenubar01Item, separator, sendFeedbackItem,
        //    preferencesItem, separator, quitItem]
        // After M2's `PluginGeneratorMenuCommand.install(...)`:
        //   [aboutMenubar01Item, separator, generateAIItem,
        //    separator, sendFeedbackItem, preferencesItem,
        //    separator, quitItem]
        // We want the new item to sit right after
        // `generateAIItem` and a new separator, before
        // `sendFeedbackItem`.
        let separator = NSMenuItem.separator()
        // Find the index of the M2 AI generator item; insert
        // after it + 1 (after its trailing separator). If the
        // M2 item is missing (older build), fall back to
        // position 1 (right after the about item + separator).
        let aiGeneratorIndex = submenu.items.firstIndex { existing in
            existing.title == PluginGeneratorMenuCommand.menuItemTitle
        }
        let insertIndex: Int
        if let aiGeneratorIndex {
            insertIndex = aiGeneratorIndex + 2 // after the AI item + its trailing separator
        } else {
            insertIndex = submenu.items.count > 1 ? 2 : submenu.items.count
        }
        let safeInsertIndex = min(insertIndex, submenu.items.count)
        submenu.insertItem(separator, at: safeInsertIndex)
        submenu.insertItem(item, at: safeInsertIndex + 1)
    }

    /// Show the marketplace browser sheet. Mirrors the
    /// lifecycle pattern
    /// `PluginGeneratorMenuCommand.presentSheet()` uses:
    /// lazily create a window hosted by a SwiftUI
    /// `NSHostingController`, and surface it in front of
    /// whatever window is currently key. v1 (M5) does not
    /// present a real AppKit sheet — a standalone window keeps
    /// the menu → window plumbing identical to the existing
    /// Plugin Repository flow.
    @MainActor
    static func presentSheet(appDelegate: AppDelegate) {
        let windowController = ensureWindowController(appDelegate: appDelegate)
        if windowController.contentViewController == nil {
            let viewModel = MarketplaceBrowserViewModel()
            windowController.contentViewController = NSHostingController(
                rootView: MarketplaceBrowserSheet(viewModel: viewModel)
            )
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window Lifecycle

    /// Lazily create the marketplace browser window the first
    /// time it is requested. We keep a strong reference on the
    /// `AppDelegate` so the window survives multiple clicks on
    /// the menu item.
    @MainActor
    private static func ensureWindowController(appDelegate: AppDelegate) -> NSWindowController {
        if let existing = appDelegate.marketplaceBrowserWindowController {
            return existing
        }
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: CGSize(width: 880, height: 600)),
            styleMask: [.closable, .miniaturizable, .resizable, .titled],
            backing: .buffered,
            defer: false
        )
        window.title = menuItemTitle
        window.center()
        let controller = NSWindowController(window: window)
        appDelegate.marketplaceBrowserWindowController = controller
        return controller
    }
}

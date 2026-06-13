// GeneratorHistoryMenuCommand.swift
// menubar01 — AI Plugin Generator (M5 history UI)
//
// Wires the "Generator History…" command into the existing menubar01
// app menu (see `AppDelegate+Menu.swift`) and presents the
// `GeneratorHistorySheet` when the item is clicked.
//
// v1 keeps the presenter minimal — a single AppKit window wrapping
// a SwiftUI `NSHostingController` for the sheet, the same lifecycle
// pattern the M2 AI generator sheet and the M5 marketplace
// browser sheet use. The window is held by the `AppDelegate`-rooted
// `generatorHistoryWindowController` so the sheet can be reused
// across clicks.

import AppKit
import SwiftUI

/// Action helper for the "Generator History…" menu item.
///
/// `AppDelegate+Menu.swift` calls
/// `GeneratorHistoryMenuCommand.install(into:)` once during
/// `AppMenu.init`; that registers the `NSMenuItem` and its
/// `@objc` action (`AppMenu.openGeneratorHistory`). The action in
/// turn calls `GeneratorHistoryMenuCommand.presentSheet(...)`,
/// which lazily creates a hosting window and shows the SwiftUI
/// sheet.
enum GeneratorHistoryMenuCommand {

    /// Localized title for the menu item. Mirrors the M5
    /// user-flow description ("User clicks 'Generator History…' in
    /// the menubar01 app menu"). v1 surfaces the item in the
    /// main menubar01 app menu so it is reachable from the
    /// top-of-screen status bar without opening the Plugin
    /// Repository window first.
    static let menuItemTitle = "Generator History…"

    /// Install the menu item into the given `AppMenu` instance.
    /// Inserts a separator and the item next to the M2 AI
    /// generator item and the M5 marketplace browser item, so
    /// all three "AI / Marketplace / History" entries sit
    /// together at the top of the submenu.
    ///
    /// - Parameter menu: The `AppMenu` instance the item is
    ///   being inserted into. The item's `target` is set to
    ///   `menu` so the `@objc` selector resolves to `AppMenu`'s
    ///   `openGeneratorHistory` method.
    @MainActor
    static func install(into menu: AppMenu) {
        guard let submenu = menu.items.first?.submenu else { return }
        let item = NSMenuItem(
            title: menuItemTitle,
            action: #selector(AppMenu.openGeneratorHistory),
            keyEquivalent: ""
        )
        item.target = menu
        // The submenu layout (after M2 + M5-marketplace):
        //   [aboutMenubar01Item, separator, generateAIItem,
        //    separator, marketplaceItem, separator,
        //    sendFeedbackItem, preferencesItem, separator,
        //    quitItem]
        // We want the new "Generator History…" item to sit right
        // after the marketplace item + its trailing separator, so
        // the three top-of-menu entries form a cluster.
        let separator = NSMenuItem.separator()
        let marketplaceIndex = submenu.items.firstIndex { existing in
            existing.title == MarketplaceBrowserMenuCommand.menuItemTitle
        }
        let insertIndex: Int
        if let marketplaceIndex {
            // After the marketplace item + its trailing separator.
            insertIndex = marketplaceIndex + 2
        } else {
            // Fall back to right after the AI generator item (M2
            // always installs first), then a separator, then the
            // history item. If the AI item is also missing, append
            // at the end.
            let aiIndex = submenu.items.firstIndex { existing in
                existing.title == PluginGeneratorMenuCommand.menuItemTitle
            }
            if let aiIndex {
                insertIndex = aiIndex + 2
            } else {
                insertIndex = submenu.items.count
            }
        }
        let safeInsertIndex = min(insertIndex, submenu.items.count)
        submenu.insertItem(separator, at: safeInsertIndex)
        submenu.insertItem(item, at: safeInsertIndex + 1)
    }

    /// Show the generator history sheet. Mirrors the lifecycle
    /// pattern `MarketplaceBrowserMenuCommand.presentSheet(...)`
    /// uses: lazily create a window hosted by a SwiftUI
    /// `NSHostingController`, and surface it in front of whatever
    /// window is currently key. v1 does not present a real AppKit
    /// sheet — a standalone window keeps the menu → window
    /// plumbing identical to the existing Plugin Generator and
    /// Marketplace Browser flows.
    @MainActor
    static func presentSheet(appDelegate: AppDelegate) {
        let windowController = ensureWindowController(appDelegate: appDelegate)
        if windowController.contentViewController == nil {
            let viewModel = GeneratorHistoryViewModel()
            windowController.contentViewController = NSHostingController(
                rootView: GeneratorHistorySheet(
                    viewModel: viewModel,
                    onRegenerate: { entry in
                        // M5 history follow-up: open the M2 sheet
                        // with `entry.request` pre-filled. The
                        // `PluginGeneratorMenuCommand.presentSheet(...)`
                        // overload accepts a `prefillRequest:`
                        // argument and rebuilds the hosting
                        // controller so the pre-filled text is
                        // visible immediately, replacing the v1
                        // workaround of "user copies / pastes
                        // from the detail pane".
                        PluginGeneratorMenuCommand.presentSheet(
                            appDelegate: appDelegate,
                            prefillRequest: entry.request
                        )
                    }
                )
            )
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window Lifecycle

    /// Lazily create the generator history window the first time
    /// it is requested. We keep a strong reference on the
    /// `AppDelegate` so the window survives multiple clicks on
    /// the menu item.
    @MainActor
    private static func ensureWindowController(appDelegate: AppDelegate) -> NSWindowController {
        if let existing = appDelegate.generatorHistoryWindowController {
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
        appDelegate.generatorHistoryWindowController = controller
        return controller
    }
}

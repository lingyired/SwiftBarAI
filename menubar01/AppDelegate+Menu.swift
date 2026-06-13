import Cocoa

@MainActor
class AppMenu: NSMenu {
    private lazy var applicationName = ProcessInfo.processInfo.processName
    let preferencesItem = NSMenuItem(title: Localizable.MenuBar.Preferences.localized, action: #selector(openPreferences), keyEquivalent: ",")
    let sendFeedbackItem = NSMenuItem(title: Localizable.MenuBar.SendFeedback.localized, action: #selector(sendFeedback), keyEquivalent: "")
    let aboutMenubar01Item = NSMenuItem(title: Localizable.MenuBar.AboutPlugin.localized, action: #selector(aboutMenubar01), keyEquivalent: "")
    let quitItem = NSMenuItem(title: Localizable.App.Quit.localized, action: #selector(quit), keyEquivalent: "q")
    override init(title: String) {
        super.init(title: title)
        let menuItemOne = NSMenuItem()
        menuItemOne.submenu = NSMenu(title: "menuItemOne")
        menuItemOne.submenu?.items = [aboutMenubar01Item, NSMenuItem.separator(), sendFeedbackItem, preferencesItem, NSMenuItem.separator(), quitItem]
        for item in [aboutMenubar01Item, preferencesItem, sendFeedbackItem, quitItem] {
            item.target = self
        }
        items = [menuItemOne]
        PluginGeneratorMenuCommand.install(into: self)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc func openPreferences() {
        AppShared.openPreferences()
    }

    @objc func openAIGenerator() {
        PluginGeneratorMenuCommand.presentSheet()
    }

    @objc func sendFeedback() {
        NSWorkspace.shared.open(URL(string: "https://github.com/lingyi/menubar01/issues")!)
    }

    @objc func aboutMenubar01() {
        AppShared.showAbout()
    }

    @objc func quit() {
        // Ensure the app is in regular activation policy before quitting
        // This fixes an issue where CMD+Q would hide the dock instead of quitting
        NSApp.setActivationPolicy(.regular)
        NSApp.terminate(self)
    }
}

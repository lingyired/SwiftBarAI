import Cocoa

/// A custom NSView for the "Toggle Plugins" submenu that keeps the menu open
/// when the user clicks the switch, so they can toggle multiple plugins in
/// a single pass. Left side shows the plugin name; right side hosts a
/// `ToggleSwitchView` that drives the enable/disable state.
///
/// The toggle is fully self-drawn so we can guarantee a blue ON state on
/// every macOS version and appearance (AppKit's `NSSwitch` relies on the
/// system accent colour which can be uninitialised, missing, or non-blue).
class PluginToggleMenuItemView: NSView {
    private enum Layout {
        // The row is taller than the switch on purpose: with the
        // inline iOS-style toggle sitting next to the plugin name,
        // the default 22pt NSMenuItem height made adjacent rows feel
        // glued together. Bumping the row to 30pt and shrinking the
        // switch to 20pt keeps the switch looking identical to
        // before, but gives ~5pt of vertical breathing room above
        // and below it (and around the title baseline). 30 is the
        // smallest height that does not crowd a 13pt menu font on
        // both top and bottom; going lower clips the descender of
        // the title in some localisations (e.g. "y" in Cyrillic).
        static let itemHeight: CGFloat = 30
        static let leadingPadding: CGFloat = 30
        static let trailingPadding: CGFloat = 18
        static let spacing: CGFloat = 10
        static let switchWidth: CGFloat = 36
        static let switchHeight: CGFloat = 20
        /// Used as the initial frame width. NSMenu resizes us via
        /// `autoresizingMask = .width` so the row always matches the menu.
        /// The value just needs to be wide enough to host the text + switch.
        static let preferredWidth: CGFloat = 260
    }

    private let titleField = NSTextField(labelWithString: "")
    private let toggleSwitch = ToggleSwitchView()
    private let pluginName: String
    private var pluginID: PluginID?

    /// Invoked when the user flips the switch. The host (MenubarItem) uses
    /// this to call `PluginManager.enablePlugin` / `disablePlugin`.
    var onToggle: ((PluginID, Bool) -> Void)?

    init(plugin: Plugin) {
        self.pluginName = plugin.name
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.preferredWidth, height: Layout.itemHeight))
        autoresizingMask = [.width]
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilitySubrole(.toggle)
        setAccessibilityLabel(plugin.name)

        pluginID = plugin.id

        setupViews()
        applyEnabled(plugin.enabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.wraps = false
        titleField.cell?.isScrollable = false
        let title = NSAttributedString(
            string: pluginName,
            attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
        )
        titleField.attributedStringValue = title
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(titleField)

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)
        toggleSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggleSwitch.onChange = { [weak self] isOn in
            guard let self, let pluginID = self.pluginID else { return }
            self.onToggle?(pluginID, isOn)
        }
        addSubview(toggleSwitch)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.leadingPadding),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -Layout.spacing),

            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.trailingPadding),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.widthAnchor.constraint(equalToConstant: Layout.switchWidth),
            toggleSwitch.heightAnchor.constraint(equalToConstant: Layout.switchHeight),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Layout.itemHeight)
    }

    /// Reflect the latest plugin state (e.g. after an external enable/disable).
    func applyEnabled(_ enabled: Bool) {
        toggleSwitch.isOn = enabled
    }
}

/// A self-drawn iOS-style toggle switch. The ON state is always painted in
/// `NSColor.systemBlue` so the user sees a clear, consistent blue colour
/// regardless of the system accent setting or the host app's `AccentColor`
/// asset. Tracking area captures clicks across the whole bounds.
final class ToggleSwitchView: NSView {
    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Invoked with the new value after the user clicks the switch.
    var onChange: ((Bool) -> Void)?

    private enum Style {
        static let trackCornerRadius: CGFloat = 11
        static let knobInset: CGFloat = 2
        static let knobSize: CGFloat = 18
        static let onColor = NSColor.systemBlue
        static let offColor = NSColor(white: 0.78, alpha: 1)
        static let knobColor = NSColor.white
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: Style.trackCornerRadius, yRadius: Style.trackCornerRadius)
        (isOn ? Style.onColor : Style.offColor).setFill()
        trackPath.fill()

        let knobSize = Style.knobSize
        let knobY = (bounds.height - knobSize) / 2
        let knobX: CGFloat = isOn
            ? bounds.width - knobSize - Style.knobInset
            : Style.knobInset
        let knobRect = NSRect(x: knobX, y: knobY, width: knobSize, height: knobSize)
        let knobPath = NSBezierPath(ovalIn: knobRect)
        Style.knobColor.setFill()
        knobPath.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onChange?(isOn)
    }
}
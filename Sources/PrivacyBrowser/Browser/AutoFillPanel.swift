import AppKit
import BrowserCore

/// The saved logins listed under a login field, as Safari's AutoFill list: one row per login (user
/// name, and the website when it is another host of the site), then "Passwords…". A borderless
/// child panel that never becomes key, so the field keeps the keyboard: ↓/↑ move through the list,
/// Return fills the highlighted login, Esc closes it; any other key goes on to the page. A click
/// outside closes it. Nothing is filled until a row is chosen.
@MainActor
final class AutoFillPanel: NSPanel {
    enum Choice {
        case entry(PasswordEntry)
        case manager
    }

    /// The panel on screen (self-test hook).
    private(set) static weak var current: AutoFillPanel?

    let field: TabPasswordAutoFill.FieldReference?
    private(set) var entries: [PasswordEntry] = []
    /// The line above the logins (a frame's site), if any (self-test hook).
    private(set) var header: String?
    private var rows: [AutoFillRow] = []
    private var highlighted: Int?
    /// Return picks only a row chosen with ↓/↑, never one the mouse happens to rest on.
    private var highlightedByKeyboard = false
    /// When it appeared: a click in its first moments was aimed at what was there before (a page
    /// can focus a field just as the user clicks), so it picks nothing.
    private var shownAt = Date()
    private var monitor: Any?
    private var onChoice: ((Choice) -> Void)?
    private weak var parentWindowRef: NSWindow?
    private var resignObserver: NSObjectProtocol?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the list under `anchor` (a rectangle in `view`'s coordinates), above it when there is
    /// no room below.
    static func show(entries: [PasswordEntry], pageHost: String, header: String?, field: TabPasswordAutoFill.FieldReference?,
                     anchor: NSRect, of view: NSView, in window: NSWindow, showsManager: Bool,
                     onChoice: @escaping (Choice) -> Void) -> AutoFillPanel {
        current?.dismiss()
        let panel = AutoFillPanel(field: field)
        panel.entries = entries
        panel.header = header
        panel.onChoice = onChoice
        panel.parentWindowRef = window
        panel.build(pageHost: pageHost, header: header, showsManager: showsManager, minimumWidth: anchor.width)
        let anchorInWindow = view.convert(anchor, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        var frame = panel.frame
        frame.origin.x = anchorOnScreen.minX
        frame.origin.y = anchorOnScreen.minY - frame.height - 3
        if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
            frame.origin.y = anchorOnScreen.maxY + 3
        }
        panel.setFrame(frame, display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.startMonitoring()
        panel.shownAt = Date()
        current = panel
        return panel
    }

    private init(field: TabPasswordAutoFill.FieldReference?) {
        self.field = field
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        // Part of the app's chrome (dark), like the window it opens over.
        appearance = Theme.chromeAppearance
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Row titles, top to bottom (self-test hook).
    var titles: [String] { rows.map(\.title) }

    private func build(pageHost: String, header: String?, showsManager: Bool, minimumWidth: CGFloat) {
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let header {
            let label = NSTextField(labelWithString: header)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let holder = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3),
            ])
            stack.addArrangedSubview(holder)
        }
        for (index, entry) in entries.enumerated() {
            let title = entry.username.isEmpty ? L("pw.panel.savedPassword") : entry.username
            let subtitle = entry.host == pageHost ? nil : entry.host
            rows.append(AutoFillRow(title: title, subtitle: subtitle, symbol: "key.fill", index: index, panel: self))
        }
        if showsManager {
            rows.append(AutoFillRow(title: L("pw.panel.passwords"), subtitle: nil, symbol: "ellipsis.circle", index: entries.count, panel: self))
        }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        let width = min(max(minimumWidth, 260), 420)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        background.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: width, height: stack.fittingSize.height))
    }

    private func startMonitoring() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event) // nil: the key was the list's
            }
        }
        if let parent = parentWindowRef {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parent,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }
        if event.type != .keyDown {
            if event.window !== self { dismiss() }
            return event
        }
        guard event.window === parentWindowRef else { return event }
        switch event.keyCode {
        case 125: // ↓
            highlight(highlighted.map { min($0 + 1, rows.count - 1) } ?? 0, byKeyboard: true)
            return nil
        case 126: // ↑
            highlight(highlighted.map { max($0 - 1, 0) } ?? rows.count - 1, byKeyboard: true)
            return nil
        case 36, 76: // Return, Enter: with a row chosen by ↓/↑, that row; otherwise the page's
            guard let highlighted, highlightedByKeyboard else { return event }
            choose(at: highlighted)
            return nil
        case 53: // Esc
            dismiss()
            return nil
        default:
            return event
        }
    }

    fileprivate func highlight(_ index: Int?, byKeyboard: Bool = false) {
        highlighted = index
        highlightedByKeyboard = byKeyboard && index != nil
        for row in rows { row.isHighlighted = row.index == index }
    }

    /// A click on row `index`, unless the list has only just appeared under the mouse.
    fileprivate func click(at index: Int) {
        guard Date().timeIntervalSince(shownAt) >= 0.5 else { return }
        choose(at: index)
    }

    /// Picks row `index` (an entry, or the last row: "Passwords…").
    func choose(at index: Int) {
        guard let onChoice else { return }
        let choice: Choice? = entries.indices.contains(index) ? .entry(entries[index]) : index == entries.count ? .manager : nil
        guard let choice else { return }
        self.onChoice = nil
        dismiss()
        onChoice(choice)
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        onChoice = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}

/// One row of the list: icon, title, optional subtitle; highlighted under the mouse or by ↑/↓.
@MainActor
private final class AutoFillRow: NSView {
    let title: String
    let index: Int
    private weak var panel: AutoFillPanel?
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?
    private let icon: NSImageView

    var isHighlighted = false {
        didSet {
            layer?.backgroundColor = isHighlighted ? NSColor.selectedContentBackgroundColor.cgColor : nil
            titleLabel.textColor = isHighlighted ? .white : .labelColor
            subtitleLabel?.textColor = isHighlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
            icon.contentTintColor = isHighlighted ? .white : .secondaryLabelColor
        }
    }

    init(title: String, subtitle: String?, symbol: String, index: Int, panel: AutoFillPanel) {
        self.title = title
        self.index = index
        self.panel = panel
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel = subtitle.map { text in
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        let labels = NSStackView(views: [titleLabel] + (subtitleLabel.map { [$0] } ?? []))
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        for view in [icon, labels] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: subtitleLabel == nil ? 26 : 36),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { panel?.highlight(index) }
    override func mouseExited(with event: NSEvent) { if isHighlighted { panel?.highlight(nil) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { panel?.click(at: index) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

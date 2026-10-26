import AppKit

@MainActor
protocol TabStripViewDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelect index: Int)
    func tabStrip(_ strip: TabStripView, didClose index: Int)
    func tabStripDidRequestNewTab(_ strip: TabStripView)
}

/// Horizontal tab bar: one `TabItemView` per tab plus a "+" button. Tabs share the available
/// width equally between `minTabWidth` and `maxTabWidth`; beyond that they are clipped,
/// and the selected tab is always kept visible.
@MainActor
final class TabStripView: NSView {
    struct Item: Equatable {
        var title: String
        var toolTip: String
        var isLoading: Bool
    }

    weak var delegate: TabStripViewDelegate?

    private var itemViews: [TabItemView] = []
    private var selectedIndex = 0
    private let newTabButton: NSButton
    private let separator = NSBox()

    /// Safari 26's tab bar (outerHeight − innerHeight goes from 52 to 90 with a second tab).
    static let height: CGFloat = 38
    private let minTabWidth: CGFloat = 72
    private let maxTabWidth: CGFloat = 240
    private let buttonWidth: CGFloat = 30

    override init(frame frameRect: NSRect) {
        newTabButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab") ?? NSImage(),
                                target: nil, action: nil)
        super.init(frame: frameRect)
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        newTabButton.isBordered = false
        newTabButton.toolTip = "New Tab (⌘T)"
        addSubview(newTabButton)
        separator.boxType = .separator
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var isFlipped: Bool { true }

    func update(items: [Item], selectedIndex: Int) {
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onSelect = { [weak self, weak view] in
                guard let self, let view, let index = self.itemViews.firstIndex(where: { $0 === view }) else { return }
                self.delegate?.tabStrip(self, didSelect: index)
            }
            view.onClose = { [weak self, weak view] in
                guard let self, let view, let index = self.itemViews.firstIndex(where: { $0 === view }) else { return }
                self.delegate?.tabStrip(self, didClose: index)
            }
            addSubview(view, positioned: .below, relativeTo: newTabButton)
            itemViews.append(view)
        }
        while itemViews.count > items.count {
            itemViews.removeLast().removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            itemViews[index].configure(item, selected: index == selectedIndex)
        }
        self.selectedIndex = selectedIndex
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - buttonWidth)
        let count = CGFloat(max(itemViews.count, 1))
        let width = min(maxTabWidth, max(minTabWidth, floor(available / count)))
        // When tabs overflow, shift so that the selected tab stays visible.
        let total = width * CGFloat(itemViews.count)
        var offset: CGFloat = 0
        if total > available {
            let selectedMaxX = width * CGFloat(selectedIndex + 1)
            offset = min(max(0, selectedMaxX - available), total - available)
        }
        for (index, view) in itemViews.enumerated() {
            let x = CGFloat(index) * width - offset
            view.frame = NSRect(x: x, y: 0, width: width, height: Self.height - 1)
            view.isHidden = x + width <= 0 || x >= available
        }
        newTabButton.frame = NSRect(x: min(total, available), y: 0, width: buttonWidth, height: Self.height - 1)
        separator.frame = NSRect(x: 0, y: Self.height - 1, width: bounds.width, height: 1)
    }

    @objc private func newTab() {
        delegate?.tabStripDidRequestNewTab(self)
    }
}

/// One tab in the strip: spinner while loading, title, close button.
@MainActor
final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let spinner = NSProgressIndicator()
    private var isSelected = false
    private var isLoading = false
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init() {
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") ?? NSImage(),
                               target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.cell?.usesSingleLineMode = true
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Close Tab (⌘W)"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, titleField, closeButton] as [NSView] { addSubview(view) }
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ item: TabStripView.Item, selected: Bool) {
        titleField.stringValue = item.title
        toolTip = item.toolTip
        setAccessibilityLabel(item.title)
        setAccessibilityValue(selected)
        if item.isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        isLoading = item.isLoading
        isSelected = selected
        titleField.textColor = selected ? .labelColor : .secondaryLabelColor
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let closeSize: CGFloat = 14
        closeButton.frame = NSRect(x: bounds.width - closeSize - 8, y: (h - closeSize) / 2, width: closeSize, height: closeSize)
        closeButton.isHidden = !(isSelected || isHovered) || bounds.width < 90
        spinner.frame = NSRect(x: 8, y: (h - 14) / 2, width: 14, height: 14)
        let titleX: CGFloat = isLoading ? 26 : 10
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: titleX, y: (h - titleHeight) / 2,
                                  width: max(0, closeButton.frame.minX - titleX - 4), height: titleHeight)
    }

    override func updateLayer() {
        // Resolved against the current appearance (light/dark) each time AppKit asks.
        layer?.backgroundColor = isSelected
            ? NSColor.controlBackgroundColor.cgColor
            : (isHovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor)
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    /// Middle-click closes, like other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func close() {
        onClose?()
    }
}

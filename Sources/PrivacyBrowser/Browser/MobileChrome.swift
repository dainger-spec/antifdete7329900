import AppKit
import SwiftUI

/// An iPhone view's own window, laid out as Safari on an iPhone in its "Bottom" layout (iOS 26 and
/// 27, the owner's iPhone, 8 November): one bar at the bottom — Back in a circle, the address pill
/// ("Search or enter website"), the tabs button in a circle — and the tab overview the tabs button
/// opens: the tabs as cards in two columns, each with its close button, and below them + (a new
/// tab), the number of tabs, and the blue check that goes back to the selected one. A horizontal
/// swipe along the bottom bar goes to the next or the previous tab, as it does on the phone.
/// Desktop Safari's tab strip and toolbar buttons are not shown in it.

/// The bottom bar's view: it takes the swipe (two fingers on a trackpad, or a drag with the
/// mouse) along it.
final class MobileBottomBar: NSView {
    var onSwipe: ((_ towardsNext: Bool) -> Void)?
    private var swipeDelta: CGFloat = 0
    static let height: CGFloat = 64

    override func scrollWheel(with event: NSEvent) {
        guard event.phase != [] || event.momentumPhase != [] else { return super.scrollWheel(with: event) }
        if event.phase == .began { swipeDelta = 0 }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { swipeDelta += event.scrollingDeltaX }
        if event.phase == .ended || event.phase == .cancelled { finishSwipe() }
    }

    private var dragStart: CGFloat?
    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        if let dragStart { swipeDelta = event.locationInWindow.x - dragStart }
    }
    override func mouseUp(with event: NSEvent) {
        if let dragStart { swipeDelta = event.locationInWindow.x - dragStart }
        dragStart = nil
        finishSwipe()
    }

    /// Natural scrolling: content follows the fingers, so fingers moving left (a negative delta)
    /// bring the next tab in, as on the phone.
    private func finishSwipe() {
        defer { swipeDelta = 0 }
        guard abs(swipeDelta) > 40 else { return }
        onSwipe?(swipeDelta < 0)
    }
}

/// A round button of the bottom bar, as the phone draws them: a dark glass circle.
final class MobileCircleButton: NSButton {
    convenience init(symbol: String, label: String, identifier: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.92).cgColor
        contentTintColor = .white
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 44)])
    }
}

/// "2 tabs", "1 tab", in the interface's language (Russian has three forms).
func mobileTabCount(_ count: Int) -> String {
    let key: String
    if Localization.languageCode == "ru" {
        let ten = count % 10, hundred = count % 100
        if ten == 1 && hundred != 11 { key = "mobile.tabs.one" }
        else if (2...4).contains(ten) && !(12...14).contains(hundred) { key = "mobile.tabs.few" }
        else { key = "mobile.tabs.many" }
    } else {
        key = count == 1 ? "mobile.tabs.one" : "mobile.tabs.many"
    }
    return String(format: L(key), count)
}

/// The tab overview: the tabs as cards in two columns, each with its ×, and below them +, the
/// number of tabs and the blue check. AppKit controls, so that each is a control of the window a
/// person — or VoiceOver, or the self-test — presses.
final class MobileTabOverview: NSView {
    struct Card {
        var title: String
        var image: NSImage?
    }

    var select: (Int) -> Void = { _ in }
    var close: (Int) -> Void = { _ in }
    var newTab: () -> Void = {}
    var done: () -> Void = {}

    private let scroll = NSScrollView()
    private let grid = FlippedView()
    private let plus = NSButton()
    private let count = NSTextField(labelWithString: "")
    private let countPill = NSView()
    private var images: [NSImage?] = []
    private let check = NSButton()
    private var cards: [(card: NSButton, close: NSButton, title: NSTextField)] = []
    private var selected = 0
    private static let barHeight: CGFloat = 64

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        addSubview(scroll)
        Self.circle(plus, symbol: "plus", fill: NSColor(white: 0.2, alpha: 1), label: L("mobile.tabs.new"), identifier: "mobile-new-tab")
        plus.target = self
        plus.action = #selector(plusPressed)
        Self.circle(check, symbol: "checkmark", fill: .controlAccentColor, label: L("mobile.tabs.done"), identifier: "mobile-tabs-done")
        check.target = self
        check.action = #selector(checkPressed)
        count.font = .systemFont(ofSize: 15, weight: .semibold)
        count.textColor = .white
        count.alignment = .center
        count.setAccessibilityIdentifier("mobile-tab-count")
        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = 22
        countPill.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        countPill.addSubview(count)
        for view in [plus, countPill, check] as [NSView] { addSubview(view) }
        setAccessibilityIdentifier("mobile-tab-overview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func circle(_ button: NSButton, symbol: String, fill: NSColor, label: String, identifier: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 22
        button.layer?.backgroundColor = fill.cgColor
        button.contentTintColor = .white
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }

    func show(_ cards: [Card], selected: Int) {
        self.selected = selected
        images = cards.map(\.image)
        self.cards.forEach { $0.card.removeFromSuperview(); $0.close.removeFromSuperview(); $0.title.removeFromSuperview() }
        self.cards = cards.enumerated().map { index, card in
            let button = NSButton()
            button.isBordered = false
            button.title = ""
            button.image = card.image
            button.imageScaling = .scaleProportionallyUpOrDown
            button.wantsLayer = true
            button.layer?.cornerRadius = 18
            button.layer?.masksToBounds = true
            button.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            button.layer?.borderWidth = index == selected ? 3 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            if card.image == nil {
                button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                button.imageScaling = .scaleNone
                button.contentTintColor = NSColor(white: 0.5, alpha: 1)
            }
            button.tag = index
            button.target = self
            button.action = #selector(cardPressed(_:))
            button.setAccessibilityLabel(card.title)
            button.setAccessibilityIdentifier("mobile-tab-card-\(index)")
            let close = NSButton()
            Self.circle(close, symbol: "xmark", fill: NSColor(white: 0, alpha: 0.55),
                        label: String(format: L("mobile.tabs.close"), card.title), identifier: "mobile-tab-close-\(index)")
            close.image = close.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            close.layer?.cornerRadius = 13
            close.tag = index
            close.target = self
            close.action = #selector(closePressed(_:))
            let title = NSTextField(labelWithString: card.title)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.textColor = .white
            title.lineBreakMode = .byTruncatingTail
            for view in [button, close, title] as [NSView] { grid.addSubview(view) }
            return (button, close, title)
        }
        count.stringValue = mobileTabCount(cards.count)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bar = Self.barHeight
        scroll.frame = NSRect(x: 0, y: bar, width: bounds.width, height: bounds.height - bar)
        let margin: CGFloat = 16, gap: CGFloat = 14, cardHeight: CGFloat = 220, rowHeight = cardHeight + 30
        let width = (bounds.width - margin * 2 - gap) / 2
        for (index, entry) in cards.enumerated() {
            let x = margin + CGFloat(index % 2) * (width + gap), y = 20 + CGFloat(index / 2) * (rowHeight + 18)
            entry.card.frame = NSRect(x: x, y: y, width: width, height: cardHeight)
            // The page's top as the card's picture, filling it, as on the phone.
            if index < images.count, let image = images[index] {
                entry.card.image = Self.top(of: image, aspect: width / cardHeight)
                entry.card.imageScaling = .scaleAxesIndependently
            }
            entry.close.frame = NSRect(x: x + width - 34, y: y + 8, width: 26, height: 26)
            entry.title.frame = NSRect(x: x + 4, y: y + cardHeight + 6, width: width - 8, height: 18)
        }
        let rows = CGFloat((cards.count + 1) / 2)
        grid.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, 20 + rows * (rowHeight + 18)))
        plus.frame = NSRect(x: margin, y: (bar - 44) / 2, width: 44, height: 44)
        check.frame = NSRect(x: bounds.width - margin - 44, y: (bar - 44) / 2, width: 44, height: 44)
        countPill.frame = NSRect(x: margin + 56, y: (bar - 44) / 2, width: bounds.width - 2 * (margin + 56), height: 44)
        count.frame = NSRect(x: 0, y: 12, width: countPill.frame.width, height: 20)
    }

    /// The top of `image`, cut to `aspect` (width over height).
    private static func top(of image: NSImage, aspect: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0, aspect > 0 else { return image }
        let height = min(size.height, size.width / aspect)
        let source = NSRect(x: 0, y: size.height - height, width: size.width, height: height)
        let cut = NSImage(size: NSSize(width: size.width, height: height))
        cut.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: cut.size), from: source, operation: .copy, fraction: 1)
        cut.unlockFocus()
        return cut
    }

    @objc private func cardPressed(_ sender: NSButton) { select(sender.tag) }
    @objc private func closePressed(_ sender: NSButton) { close(sender.tag) }
    @objc private func plusPressed() { newTab() }
    @objc private func checkPressed() { done() }
}

/// A view whose y runs down, for the overview's grid.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

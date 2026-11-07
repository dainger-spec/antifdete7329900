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

/// What the tab overview shows: one card a tab.
@MainActor
final class MobileTabsModel: ObservableObject {
    struct Card: Identifiable {
        let id: Int
        var title: String
        var image: NSImage?
    }

    @Published var cards: [Card] = []
    @Published var selected = 0
    var select: @MainActor (Int) -> Void = { _ in }
    var close: @MainActor (Int) -> Void = { _ in }
    var newTab: @MainActor () -> Void = {}
    var done: @MainActor () -> Void = {}
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

struct MobileTabOverview: View {
    @ObservedObject var model: MobileTabsModel
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.cards) { card in
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                Button { model.select(card.id) } label: {
                                    thumbnail(card)
                                        .frame(height: 220)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(card.id == model.selected ? Color.accentColor : .clear, lineWidth: 3))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(card.title)
                                .accessibilityIdentifier("mobile-tab-card-\(card.id)")
                                Button { model.close(card.id) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(Color.black.opacity(0.55)))
                                }
                                .buttonStyle(.plain)
                                .padding(8)
                                .accessibilityLabel(String(format: L("mobile.tabs.close"), card.title))
                                .accessibilityIdentifier("mobile-tab-close-\(card.id)")
                            }
                            Text(card.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
            HStack(spacing: 12) {
                circle("plus", L("mobile.tabs.new"), "mobile-new-tab", action: model.newTab)
                Text(mobileTabCount(model.cards.count))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color(white: 0.2)))
                    .accessibilityIdentifier("mobile-tab-count")
                Button(action: model.done) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("mobile.tabs.done"))
                .accessibilityIdentifier("mobile-tabs-done")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.11))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile-tab-overview")
    }

    @ViewBuilder
    private func thumbnail(_ card: MobileTabsModel.Card) -> some View {
        if let image = card.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(white: 0.2)
                Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(Color(white: 0.5))
            }
        }
    }

    private func circle(_ symbol: String, _ label: String, _ identifier: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(white: 0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

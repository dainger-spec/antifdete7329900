import AppKit
import SwiftUI

/// A row of tabs in Lumen's style, in place of a segmented picker: NSSegmentedControl gives every
/// segment the width of the longest label, so five Russian labels ("Конфиденциальность") did not
/// fit a 600 pt sheet and the outer ones were cut ("Основные" → "ые").
///
/// Each tab is as wide as its text; the free space is spread evenly between them. When the labels
/// do not fit, the row scrolls sideways rather than cutting or wrapping a label. The selected tab
/// has the accent fill. ⌘1…⌘9 pick a tab; with the bar focused, ← and → move between tabs.
struct LumenTabBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    /// The bar's own name for VoiceOver ("Sections").
    let label: String
    let title: (Item) -> String

    /// The labels' font (`.system(size: 13, weight: .medium)` in the view), as AppKit measures it:
    /// `UISnapshots` checks that no label is laid out narrower than its text.
    static var labelFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    static var horizontalPadding: CGFloat { 12 }

    @FocusState private var focused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(spread: true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(spread: false)
                }
                .onChange(of: selection) { _, item in
                    withAnimation(Theme.hoverAnimation) { proxy.scrollTo(item, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius + 2, style: .continuous).fill(Theme.controlFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 2, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func row(spread: Bool) -> some View {
        HStack(spacing: spread ? 0 : 4) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if spread, index > 0 { Spacer(minLength: 4) }
                tab(item, index: index).id(item)
            }
        }
    }

    private func tab(_ item: Item, index: Int) -> some View {
        let text = title(item)
        let selected = item == selection
        return Button {
            withAnimation(Theme.hoverAnimation) { selection = item }
        } label: {
            Text(verbatim: text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { TabBarLayoutLog.shared?.record(text, width: geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in TabBarLayoutLog.shared?.record(text, width: width) }
                })
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: Theme.controlHeight - 4)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(selected ? Theme.accentFill : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(TabButtonStyle(selected: selected))
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
        .accessibilityLabel(text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard let index = items.firstIndex(of: selection) else { return .ignored }
        let next = index + step
        guard items.indices.contains(next) else { return .handled }
        withAnimation(Theme.hoverAnimation) { selection = items[next] }
        return .handled
    }
}

/// A tab's hover: a faint fill under an unselected tab, as Lumen's ghost buttons have.
private struct TabButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Hovering(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }

    private struct Hovering<Label: View>: View {
        let selected: Bool
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hover = false

        var body: some View {
            label()
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(!selected && (hover || pressed) ? Theme.controlHover : Color.clear))
                .onHover { hover = $0 }
                .animation(Theme.hoverAnimation, value: hover)
        }
    }
}

/// The width each tab label was laid out at, kept only while `--render-ui-snapshots` runs, so the
/// snapshots can check that no label is narrower than its text. Used on the main thread only.
final class TabBarLayoutLog {
    static var shared: TabBarLayoutLog?
    private(set) var widths: [String: CGFloat] = [:]

    func record(_ text: String, width: CGFloat) { widths[text] = width }
    func reset() { widths = [:] }
}

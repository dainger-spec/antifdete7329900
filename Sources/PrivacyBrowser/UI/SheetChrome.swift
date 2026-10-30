import SwiftUI

/// A sheet's title block: the title (15 / semibold) and, when there is one, a sentence under it.
struct SheetHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.lumenSheetTitle)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }
}

/// A sheet's bottom bar: a hairline, a note or status on the left, its buttons on the right.
struct SheetFooter<Leading: View, Buttons: View>: View {
    let leading: Leading
    let buttons: Buttons

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder buttons: () -> Buttons) {
        self.leading = leading()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 12)
                buttons
            }
            .padding(.horizontal, 24)
            .frame(height: 60)
        }
    }
}

extension SheetFooter where Leading == EmptyView {
    init(@ViewBuilder buttons: () -> Buttons) {
        self.init(leading: { EmptyView() }, buttons: buttons)
    }
}

extension View {
    /// A native grouped `Form` on the sheet's own surface (no second background behind its groups).
    func lumenForm() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - One size rule for every sheet

/// How much of the Profiles window a sheet may take: the window's content less a margin around
/// the sheet (`providesSheetRoom` measures it). Zero: not known — a sheet then takes the size it
/// asks for (the UI snapshots, which set it to show a sheet in the narrowest window).
private struct SheetRoomKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    var sheetRoom: CGSize {
        get { self[SheetRoomKey.self] }
        set { self[SheetRoomKey.self] = newValue }
    }
}

/// The size a sheet asks for, but never more than the window has room for: what does not fit
/// scrolls in the sheet's own list or scroll view. A sheet of a fixed size used to be cut by a
/// window narrower or lower than it. Without a height, the sheet is as tall as its content, up to
/// the room there is.
private struct SheetFrame: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?
    @Environment(\.sheetRoom) private var room

    func body(content: Content) -> some View {
        content
            .frame(width: width.map { capped($0, room.width) }, height: height.map { capped($0, room.height) })
            .frame(maxHeight: height == nil && room.height > 0 ? room.height : nil)
    }

    private func capped(_ wanted: CGFloat, _ available: CGFloat) -> CGFloat {
        available > 0 ? min(wanted, available) : wanted
    }
}

/// The room every sheet of a window has: the window's content, measured, less a margin around the
/// sheet. The Profiles window's root view gives it (`RootView`); the UI snapshots give it to a
/// window with a real sheet, to check that the sheet fits.
struct SheetRoomProvider: ViewModifier {
    @State private var windowSize: CGSize = .zero

    /// A sheet hangs under the title bar: 20 pt of margin on each side, the title bar's band above
    /// and 28 pt below.
    static func room(in window: CGSize) -> CGSize {
        guard window.width > 0, window.height > 0 else { return .zero }
        return CGSize(width: max(0, window.width - 40), height: max(0, window.height - 56))
    }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { windowSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in windowSize = size }
            })
            .environment(\.sheetRoom, Self.room(in: windowSize))
    }
}

extension View {
    /// A sheet's size: see `SheetFrame`.
    func sheetFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        modifier(SheetFrame(width: width, height: height))
    }

    /// The room for this window's sheets: see `SheetRoomProvider`.
    func providesSheetRoom() -> some View {
        modifier(SheetRoomProvider())
    }
}

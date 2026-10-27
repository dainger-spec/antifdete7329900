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

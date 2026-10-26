import AppKit
import SwiftUI

/// Design tokens. System colors throughout, so the same views work in the light appearance
/// (the default) and in the optional dark one (Settings ▸ Appearance), the way System Settings
/// looks. Text uses the system font (SF Pro) at the standard text styles.
enum Theme {
    static let accent = Color.accentColor
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let fieldBackground = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let runningDot = Color(nsColor: .systemGreen)

    static let cornerRadius: CGFloat = 10
    static let spacing: CGFloat = 12

    /// A stable, pleasant color per profile (avatar), derived from its id.
    static func profileColor(_ id: UUID) -> Color {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal,
                                  .systemIndigo, .systemGreen, .systemBrown, .systemRed, .systemMint]
        let byte = withUnsafeBytes(of: id.uuid) { $0[0] ^ $0[5] ^ $0[11] }
        return Color(nsColor: palette[Int(byte) % palette.count])
    }
}

extension View {
    /// Wraps content in a rounded card with a hairline border, like a System Settings group.
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        self
            .padding(padding)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )
    }
}

/// Rounded-square SF Symbol icon, as in System Settings' sidebar.
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// A profile's avatar: its initial on the profile's color.
struct ProfileAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 28

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.profileColor(id).gradient)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }
}

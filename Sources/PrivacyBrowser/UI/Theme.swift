import SwiftUI

/// Light-theme design tokens. The app forces the Aqua (light) appearance
/// (`NSApp.appearance` + `.preferredColorScheme(.light)`), so these intentionally use fixed
/// light values for a clean, consistent "white" look rather than dynamic system colors.
enum Theme {
    static let accent = Color.accentColor
    static let pageBackground = Color(white: 0.965)
    static let cardBackground = Color.white
    static let fieldBackground = Color(white: 0.98)
    static let separator = Color(white: 0.90)
    static let runningDot = Color(red: 0.20, green: 0.78, blue: 0.35)

    static let cornerRadius: CGFloat = 12
    static let spacing: CGFloat = 12
}

extension View {
    /// Wraps content in a white rounded card with a hairline border.
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        self
            .padding(padding)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
    }
}

/// Circular SF-Symbol icon badge used for section/headers.
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

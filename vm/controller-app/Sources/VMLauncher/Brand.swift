import AppKit
import SwiftUI

/// The app's name and logo in one place. To use your own logo, put a square
/// PNG at vm/controller-app/Resources/Brand/logo.png (and, for the Dock/Finder
/// icon, Resources/Brand/AppIcon.icns) — build-app.sh bundles both.
enum Brand {
    static let name = "Privacy Browser"
    static let tagline = "Настоящий Safari в отдельной системе для каждого профиля"

    /// Contents/Resources/Brand/logo.png, if the build has one.
    static var customLogo: NSImage? {
        Bundle.main.url(forResource: "logo", withExtension: "png", subdirectory: "Brand")
            .flatMap { NSImage(contentsOf: $0) }
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.16, green: 0.40, blue: 0.98),
                                Color(red: 0.44, green: 0.24, blue: 0.94)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The logo: the custom image when bundled, otherwise a drawn mark.
struct BrandLogo: View {
    var size: CGFloat = 64

    var body: some View {
        if let image = Brand.customLogo {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Brand.gradient)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.04)
        }
    }
}

/// A profile's round badge: its initial on a colour picked from its id, so
/// profiles are easy to tell apart at a glance.
struct ProfileAvatar: View {
    let name: String
    let id: String
    var size: CGFloat = 28

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .brown]

    var body: some View {
        let color = Self.palette[Int(id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }) % Self.palette.count]
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

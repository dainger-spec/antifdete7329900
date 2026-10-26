import AppKit
import SwiftUI

/// App-wide preferences that are not secret and are needed before the vault is unlocked
/// (appearance, whether the first-launch introduction was shown). Stored in `UserDefaults`;
/// nothing about profiles, sites or proxies is kept here — that lives in the encrypted vault.
@MainActor
final class AppPreferences: ObservableObject {
    enum Appearance: String, CaseIterable, Identifiable {
        case light, dark, system
        var id: String { rawValue }

        var labelKey: String {
            switch self {
            case .light: return "settings.appearance.light"
            case .dark: return "settings.appearance.dark"
            case .system: return "settings.appearance.system"
            }
        }

        /// nil = follow the system setting.
        var nsAppearance: NSAppearance? {
            switch self {
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            case .system: return nil
            }
        }

        /// For `.preferredColorScheme`; nil = follow the system.
        var colorScheme: ColorScheme? {
            switch self {
            case .light: return .light
            case .dark: return .dark
            case .system: return nil
            }
        }
    }

    static let shared = AppPreferences()

    private enum Key {
        static let appearance = "appearance"
        static let onboardingDone = "onboardingCompleted"
    }

    private let defaults: UserDefaults

    /// Light by default (the app's native light style); dark and "as the system" are optional.
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingDone) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .light
        onboardingCompleted = defaults.bool(forKey: Key.onboardingDone)
    }

    /// Applies the appearance to every window, including the browser windows built with AppKit.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }
}

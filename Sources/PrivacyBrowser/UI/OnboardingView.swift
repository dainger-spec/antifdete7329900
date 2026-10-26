import SwiftUI

/// First launch: what the app is for, in three short pages, then the master password.
/// Shown once (AppPreferences.onboardingCompleted); a vault that already exists skips it.
struct OnboardingView: View {
    @ObservedObject var preferences: AppPreferences
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let titleKey: String
        let textKey: String
    }

    private let pages = [
        Page(id: 0, symbol: "square.stack.3d.up.fill", titleKey: "onboarding.1.title", textKey: "onboarding.1.text"),
        Page(id: 1, symbol: "network.badge.shield.half.filled", titleKey: "onboarding.2.title", textKey: "onboarding.2.text"),
        Page(id: 2, symbol: "lock.fill", titleKey: "onboarding.3.title", textKey: "onboarding.3.text"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            let current = pages[page]
            VStack(spacing: 18) {
                IconBadge(symbol: current.symbol, size: 76)
                Text(L(current.titleKey))
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(L(current.textKey))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            .id(page)
            .transition(.opacity)
            Spacer(minLength: 24)
            HStack(spacing: 8) {
                ForEach(pages) { item in
                    Circle()
                        .fill(item.id == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 20)
            HStack {
                if page > 0 {
                    Button(L("onboarding.back")) { withAnimation { page -= 1 } }
                        .controlSize(.large)
                }
                Spacer()
                Button(page == pages.count - 1 ? L("onboarding.start") : L("onboarding.next")) {
                    if page == pages.count - 1 {
                        preferences.onboardingCompleted = true
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
    }
}

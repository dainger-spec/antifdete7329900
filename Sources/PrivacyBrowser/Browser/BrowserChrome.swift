import AppKit
import BrowserCore
import SwiftUI

/// What a browser window's own chrome shows about its profile: the chip in the toolbar (glyph,
/// name, the flag of where it exits) and the start page of an empty tab (favourites, recently
/// visited pages, the proxy it goes through). `BrowserWindowController` fills it from its session
/// and library and keeps it current.
@MainActor
final class BrowserChromeModel: ObservableObject {
    struct Site: Identifiable, Equatable {
        let id: String
        let title: String
        let url: URL
        var visitedAt: Date?

        var host: String { url.host ?? url.absoluteString }
    }

    let profileName: String
    let profileID: UUID
    /// How the profile's glyph looks (`ProfileConfiguration.avatar`).
    let avatar: ProfileAvatarStyle?
    @Published var exit: ProfileExit
    @Published var favorites: [Site] = []
    @Published var recents: [Site] = []

    init(profileName: String, profileID: UUID, exit: ProfileExit, avatar: ProfileAvatarStyle? = nil) {
        self.profileName = profileName
        self.profileID = profileID
        self.exit = exit
        self.avatar = avatar
    }

    /// Top-level bookmarks (the favourites bar's) and the latest web pages from history.
    func update(bookmarks: [Bookmark], history: [HistoryEntry]) {
        favorites = bookmarks.filter { $0.folder == nil }.compactMap { bookmark in
            guard let url = Self.webURL(bookmark.url) else { return nil }
            return Site(id: bookmark.id.uuidString, title: bookmark.title.isEmpty ? (url.host ?? bookmark.url) : bookmark.title,
                        url: url)
        }
        .prefix(12).map { $0 }
        recents = history.compactMap { entry in
            guard let url = Self.webURL(entry.url) else { return nil }
            return Site(id: entry.url, title: entry.title.isEmpty ? (url.host ?? entry.url) : entry.title, url: url,
                        visitedAt: entry.lastVisitedAt)
        }
        .prefix(5).map { $0 }
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

// MARK: - Toolbar chip

/// The profile chip in a browser window's toolbar: its glyph and name and, through a proxy, the
/// flag of the country it exits in (a network symbol while that is unknown).
struct ProfileChipView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        HStack(spacing: 6) {
            ProfileAvatar(name: model.profileName, id: model.profileID, size: 16, style: model.avatar)
            Text(model.profileName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if case let .proxy(_, code) = model.exit {
                Rectangle().fill(Theme.strongBorder).frame(width: 1, height: 12)
                if let code {
                    CountryFlag(code: code, size: 12)
                } else {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.accentTint))
        .fixedSize()
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(description))
        .environment(\.colorScheme, .dark)
    }

    private var description: String {
        switch model.exit {
        case .direct:
            return String(format: L("chip.direct"), model.profileName)
        case let .proxy(endpoint, code?):
            return String(format: L("chip.exits"), model.profileName, CountryNames.name(for: code), endpoint)
        case let .proxy(endpoint, nil):
            return String(format: L("chip.proxy"), model.profileName, endpoint)
        }
    }
}

// MARK: - Start page

/// What an empty tab shows instead of a blank page: the Lumen lockup, a search field, the
/// profile's favourites and recently visited pages and — through a proxy — where it exits. A
/// native view laid over the tab's web view: none of it is web content, so pages never see it.
struct StartPageView: View {
    @ObservedObject var model: BrowserChromeModel
    var open: (URL) -> Void = { _ in }
    var submit: (String) -> Void = { _ in }
    @State private var query = ""

    static let tile = CGSize(width: 104, height: 84)
    static let gap: CGFloat = 16

    /// Six tiles across, fewer in a narrow window (a mobile device's screen).
    static func columns(for width: CGFloat) -> Int {
        max(2, min(6, Int((width - 32 + gap) / (tile.width + gap))))
    }

    static func contentWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                let columns = Self.columns(for: proxy.size.width)
                let width = Self.contentWidth(columns: columns)
                ScrollView {
                    VStack(spacing: 0) {
                        LumenLockup.large
                            .padding(.top, proxy.size.height > 560 ? 96 : 48)
                            .padding(.bottom, 28)
                        searchField
                            .frame(width: min(520, width))
                            .padding(.bottom, 44)
                        VStack(alignment: .leading, spacing: 32) {
                            if !model.favorites.isEmpty { favorites(columns: columns) }
                            if !model.recents.isEmpty { recents }
                            if model.favorites.isEmpty && model.recents.isEmpty {
                                Text(L("start.empty"))
                                    .font(.lumenBody)
                                    .foregroundStyle(Theme.textTertiary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(width: width, alignment: .leading)
                        .padding(.bottom, 72)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
            }
            if case .proxy = model.exit {
                ExitPill(exit: model.exit).padding(16)
            }
        }
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
            TextField(text: $query, prompt: Text(verbatim: "")) {
                Text(L("toolbar.address.placeholder"))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .overlay(alignment: .leading) {
                if query.isEmpty {
                    // Lumen's placeholder: macOS draws an unfocused field's prompt almost as bright as text.
                    Text(L("toolbar.address.placeholder"))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onSubmit {
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                submit(text)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
    }

    private func favorites(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("start.favorites"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile.width), spacing: Self.gap), count: columns),
                      alignment: .leading, spacing: Self.gap) {
                ForEach(model.favorites) { site in
                    FavoriteTile(site: site) { open(site.url) }
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("start.recents"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(model.recents) { site in
                    RecentRow(site: site) { open(site.url) }
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
        }
    }
}

private struct FavoriteTile: View {
    let site: BrowserChromeModel.Site
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                SiteGlyph(host: site.host, size: 28)
                Text(site.title)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
            }
            .frame(width: StartPageView.tile.width, height: StartPageView.tile.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Theme.raised : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Theme.hoverAnimation, value: hovered)
        .help(site.url.absoluteString)
    }
}

private struct RecentRow: View {
    let site: BrowserChromeModel.Site
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SiteGlyph(host: site.host, size: 16)
                Text(site.title)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(site.host)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                if let date = site.visitedAt {
                    Text(Self.when(date))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.controlRadius)
        .help(site.url.absoluteString)
    }

    /// The time today, else how long ago.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.relative(presentation: .named))
    }
}

/// A site's initial on a flat tint chosen from its host (no favicons are fetched: that would be a
/// request the page did not make).
struct SiteGlyph: View {
    let host: String
    var size: CGFloat = 16

    var body: some View {
        let colors = ProfileAvatar.colors(forKey: host)
        Text(initial)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Color(hex: colors.text))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color(hex: colors.fill)))
            .accessibilityHidden(true)
    }

    private var initial: String {
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.first.map { String($0).uppercased() } ?? "·"
    }
}

/// "Through the profile's proxy · Germany", bottom left of the start page.
struct ExitPill: View {
    let exit: ProfileExit

    var body: some View {
        HStack(spacing: 6) {
            switch exit {
            case let .proxy(_, code?):
                CountryFlag(code: code, size: 12)
                Text(String(format: L("start.exit"), CountryNames.name(for: code)))
            case let .proxy(endpoint, nil):
                Image(systemName: "network").font(.system(size: 11))
                Text(String(format: L("start.exit"), endpoint))
            case .direct:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.accent)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Theme.accentTint))
        .accessibilityElement(children: .combine)
    }
}

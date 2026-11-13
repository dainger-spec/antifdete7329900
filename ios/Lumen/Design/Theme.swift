import LumenCore
import SwiftUI
import UIKit

/// «Приборная панель» (the owner, 13 November 2026; the handoff in ios/DESIGN_DASHBOARD.md): the
/// system's own lists, sheets, menus and bars, the system's semantic colours — so the light theme
/// needs nothing more — and one accent, only on what can be tapped. A status is a small light, a
/// country its code. No drawn glass but the browser's address capsule (iOS 26's own), no gradients,
/// no glows, no pills.
enum Theme {
    /// Under white text on a prominent button: the accent dark enough to read on (4.8:1 in the dark).
    static let accentFill = Color("AccentFill")
    /// Progress and meters: neutral, never the accent.
    static let progress = Color(.label)

    /// The app's appearance: dark, as the app has always been; the light theme (the `*-light` mockups)
    /// once the owner decides — `LUMEN_LIGHT_THEME` in Info.plist (YES: the iPhone's own appearance).
    /// A DEBUG build's screenshots fix one or the other (LUMEN_TEST_THEME = light | dark).
    static var colorScheme: ColorScheme? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["LUMEN_TEST_THEME"] {
        case "light": return .light
        case "dark": return .dark
        default: break
        }
        #endif
        let light = Bundle.main.object(forInfoDictionaryKey: "LUMEN_LIGHT_THEME") as? Bool ?? false
        return light ? nil : .dark
    }
}

// MARK: The status light

/// What a light says: a proxy that works, one that does not answer (or an error), a check under way,
/// or no proxy at all.
enum Light: Equatable {
    case working, failing, checking, none

    var color: Color {
        switch self {
        case .working: return Color(.systemGreen)
        case .failing: return Color(.systemRed)
        case .checking: return Color(.systemOrange)
        case .none: return Color(.systemGray3)
        }
    }

    /// The light of a proxy (or of none).
    static func of(_ proxy: ProxyEntry?, checking: Bool) -> Light {
        guard let proxy else { return .none }
        if checking { return .checking }
        guard let check = proxy.check else { return .none }
        return check.alive ? .working : .failing
    }
}

/// The light itself: a 7 pt dot that grows with the text.
struct StatusLight: View {
    let light: Light
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 7

    var body: some View {
        Circle().fill(light.color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension VerticalAlignment {
    /// The middle of a row's first line: where its light sits, whatever the text size.
    private enum FirstLineCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.firstTextBaseline] }
    }

    static let firstLineCenter = VerticalAlignment(FirstLineCenter.self)
}

extension View {
    /// Puts a leading mark (a light, a lock) at the middle of the first line of `style`'s text.
    func centredOnFirstLine(of style: UIFont.TextStyle = .headline) -> some View {
        alignmentGuide(.firstLineCenter) { d in
            d[VerticalAlignment.center] + UIFont.preferredFont(forTextStyle: style).capHeight / 2
        }
    }
}

// MARK: Times and lines

enum RowTime {
    /// When, as the list says it: today the time, yesterday "Вчера", this week the day, before that the date.
    static func text(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let locale = Localization.locale
        if calendar.isDateInToday(date) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        }
        if calendar.isDateInYesterday(date) { return L("Вчера") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 {
            let day = date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(locale))
            return day.prefix(1).uppercased() + day.dropFirst()
        }
        return date.formatted(Date.FormatStyle().day(.twoDigits).month(.twoDigits).year(.twoDigits).locale(locale))
    }

    /// "Открывали 9:29" — what VoiceOver says of a row's time.
    static func opened(_ date: Date?) -> String {
        guard let date else { return L("Ещё не открывали") }
        return L("Открывали %@", text(date))
    }
}

/// Where a session goes out, in words: "DE · Берлин · 203.0.113.10", the proxy's state when it does not work.
enum ExitWords {
    /// The parts after the country: the proxy's name and its exit address, as far as its check knows them.
    static func place(_ proxy: ProxyEntry) -> [String] {
        var parts: [String] = []
        if let country = proxy.check?.country, proxy.check?.alive == true { parts.append(country) }
        parts.append(proxy.displayName)
        if let ip = proxy.check?.exitIP, proxy.check?.alive == true { parts.append(ip) }
        return parts
    }

    /// The second line of a session's row: its exit, or "Без прокси"; red only on "не отвечает".
    static func line(_ proxy: ProxyEntry?, boundToProxy: Bool, checking: Bool) -> Text {
        guard let proxy else { return Text(boundToProxy ? L("Прокси удалён") : L("Без прокси")) }
        if checking { return Text((place(proxy) + [L("проверка…")]).joined(separator: " · ")) }
        if let check = proxy.check, !check.alive {
            let head = [check.country, proxy.displayName].compactMap { $0 }.joined(separator: " · ")
            return Text(head + " · ") + Text(L("не отвечает")).foregroundColor(Color(.systemRed))
        }
        if proxy.check == nil { return Text([proxy.displayName, L("не проверен")].joined(separator: " · ")) }
        return Text(place(proxy).joined(separator: " · "))
    }

    /// The same, as plain words (VoiceOver, the browser's line).
    static func plain(_ proxy: ProxyEntry?, boundToProxy: Bool, checking: Bool) -> String {
        guard let proxy else { return boundToProxy ? L("Прокси удалён") : L("Без прокси") }
        if checking { return (place(proxy) + [L("проверка…")]).joined(separator: " · ") }
        if let check = proxy.check, !check.alive {
            return ([check.country, proxy.displayName].compactMap { $0 } + [L("не отвечает")]).joined(separator: " · ")
        }
        if proxy.check == nil { return [proxy.displayName, L("не проверен")].joined(separator: " · ") }
        return place(proxy).joined(separator: " · ")
    }
}

/// What the browser says of a session and its page.
@MainActor
enum PageWords {
    /// "DE · 203.0.113.10 · Europe/Berlin · de-DE" — or "Без прокси · Europe/Moscow · ru-RU": where the
    /// session goes out, and the time zone and language its pages get.
    static func exitLine(_ session: Session, proxy: ProxyEntry?, checking: Bool) -> String {
        let locale = PageSettings.locale(of: session, proxy: proxy)
        let zone = locale.timeZone ?? TimeZone.current.identifier
        let language = locale.language ?? Locale.preferredLanguages.first ?? "en-US"
        guard let proxy else { return [L("Без прокси"), zone, language].joined(separator: " · ") }
        if checking { return [proxy.displayName, L("проверка…")].joined(separator: " · ") }
        guard let check = proxy.check else { return [proxy.displayName, L("не проверен")].joined(separator: " · ") }
        guard check.alive else {
            return ([check.country, proxy.displayName].compactMap { $0 } + [L("не отвечает")]).joined(separator: " · ")
        }
        return [check.country, check.exitIP, zone, language].compactMap { $0 }.joined(separator: " · ")
    }

    /// The site's name in the capsule: the host without "www.".
    static func domain(_ url: URL?) -> String {
        guard let host = url?.host() else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A failure that, behind a proxy, means the proxy did not answer (the relay lets nothing go around it).
    static func proxyFailure(_ code: URLError.Code) -> Bool {
        [.timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet,
         .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork].contains(code)
    }
}

/// Russian counts: "1 сессия", "2 сессии", "5 сессий"; English: "1 session", "2 sessions".
enum Count {
    static func of(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if Localization.isEnglish { return "\(n) " + (n == 1 ? one : many) }
        let tens = n % 100, ones = n % 10
        let word = (11...14).contains(tens) ? many : ones == 1 ? one : (2...4).contains(ones) ? few : many
        return "\(n) \(word)"
    }

    static func sessions(_ n: Int) -> String { of(n, L("сессия"), L("сессии"), L("сессий")) }
    static func tabs(_ n: Int) -> String { of(n, L("вкладка"), L("вкладки"), L("вкладок")) }
}

// MARK: Rows

/// A session in the list: its light (or a lock), name and when it was opened; where it goes out; its
/// tags, or that it came from the Mac.
struct SessionRow: View {
    let session: Session
    let proxy: ProxyEntry?
    var lock = SessionLock.open
    var lockedForProxy = true
    var checking = false

    private var locked: Bool { lock.isLocked }

    var body: some View {
        HStack(alignment: .firstLineCenter, spacing: 12) {
            Group {
                if locked {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                } else {
                    StatusLight(light: Light.of(proxy, checking: checking))
                }
            }
            .centredOnFirstLine()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.name).font(.headline).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let date = session.lastOpenedAt {
                        Text(RowTime.text(date)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                secondLine.font(.subheadline).foregroundStyle(.secondary)
                if session.syncedProfileID != nil {
                    Label(L("С Mac"), systemImage: "laptopcomputer").font(.subheadline).foregroundStyle(.tertiary)
                } else if !session.tags.isEmpty {
                    Text(tags).font(.subheadline).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var tags: String { session.tags.map { "#\($0)" }.joined(separator: " ") }

    private var secondLine: Text {
        if locked {
            let place = proxy.map { ExitWords.place($0).joined(separator: " · ") }
            return Text(([L("Заперта")] + [place].compactMap { $0 }).joined(separator: " · "))
        }
        return ExitWords.line(proxy, boundToProxy: session.boundToProxy, checking: checking)
    }

    /// Everything the row says, and the description it does not show (VoiceOver reads it).
    private var spoken: String {
        var parts = [session.name]
        if case let .locked(reason) = lock {
            parts.append(lockedForProxy ? L("Заперта: без прокси не откроется") : L("Заперта: %@", reason))
        } else {
            parts.append(ExitWords.plain(proxy, boundToProxy: session.boundToProxy, checking: checking))
        }
        parts.append(RowTime.opened(session.lastOpenedAt))
        if !session.notes.isEmpty { parts.append(session.notes) }
        if !session.tags.isEmpty { parts.append(tags) }
        if session.syncedProfileID != nil { parts.append(L("С Mac")) }
        return parts.joined(separator: ", ")
    }
}

/// A proxy in the list: the same rhythm — name and type; where it exits, or why it does not; its
/// address and login; UDP.
struct ProxyRow: View {
    let entry: ProxyEntry
    let checking: Bool

    var body: some View {
        HStack(alignment: .firstLineCenter, spacing: 12) {
            StatusLight(light: Light.of(entry, checking: checking)).centredOnFirstLine()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.displayName).font(.headline).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(entry.kind == .socks5 ? "SOCKS5" : "HTTP").font(.subheadline).foregroundStyle(.secondary)
                }
                state.font(.subheadline).foregroundStyle(.secondary)
                Text(address).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                Text(udp).font(.subheadline).foregroundStyle(.tertiary)
            }
            if checking {
                ProgressView()
            } else {
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var address: String { "\(entry.host):\(entry.port)" + (entry.username.isEmpty ? "" : " · \(entry.username)") }

    private var state: Text {
        if checking { return Text(L("Проверка…")) }
        guard let check = entry.check else { return Text(L("Не проверен")) }
        guard check.alive else {
            return Text(L("Недоступен")).foregroundColor(Color(.systemRed)) + Text(": " + (check.error ?? L("нет ответа")))
        }
        return Text([check.country, check.exitIP].compactMap { $0 }.joined(separator: " · "))
    }

    private var stateWords: String {
        if checking { return L("Проверка…") }
        guard let check = entry.check else { return L("Не проверен") }
        guard check.alive else { return L("Недоступен: %@", check.error ?? L("нет ответа")) }
        return ([L("Работает")] + [check.country, check.exitIP].compactMap { $0 }).joined(separator: " · ")
    }

    private var udp: String {
        if checking { return L("UDP: проверяется") }
        switch entry.check?.udp ?? .unchecked {
        case .supported: return L("UDP: умеет")
        case .unsupported: return L("UDP: не умеет")
        case .unchecked: return L("UDP: не проверен")
        }
    }

    private var spoken: String {
        [entry.displayName, entry.kind == .socks5 ? "SOCKS5" : "HTTP", stateWords, address, udp].joined(separator: ", ")
    }
}

/// What the account says that the person must read: an ordinary cell, an orange sign, the words —
/// and a cross for the notices that may be closed.
struct NoticeRow: View {
    let text: String
    var dismiss: (() -> Void)?
    /// The words' own identifier (the tests read them).
    var identifier: String?

    var body: some View {
        HStack(alignment: .firstLineCenter, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color(.systemOrange))
                .centredOnFirstLine(of: .subheadline)
                .accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(OptionalIdentifier(identifier: identifier))
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("dismissNotice")
                .accessibilityLabel(L("Скрыть"))
            }
        }
    }
}

/// A row of facts in a list: the name on the left, the value on the right — one element for VoiceOver,
/// "Тариф: Профессиональный".
struct FactRow: View {
    let title: String
    let value: String
    var identifier: String?
    var valueStyle: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(valueStyle).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(.isStaticText)
        .modifier(OptionalIdentifier(identifier: identifier))
    }
}

struct OptionalIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

// MARK: The mark

/// Lumen's mark — only on the icon and the launch screen: two halves of a disc, slid apart along a slanted cut.
struct LumenMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 32
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 16) * scale, y: rect.midY + (y - 16) * scale)
        }
        var path = Path()
        path.move(to: point(14.435, 23.858))
        path.addLine(to: point(20.728, 4.98))
        path.addCurve(to: point(26.119, 17.265), control1: point(25.413, 7.083), control2: point(27.743, 12.393))
        path.addCurve(to: point(14.435, 23.858), control1: point(24.495, 22.137), control2: point(19.445, 24.987))
        path.closeSubpath()
        path.move(to: point(11.272, 27.02))
        path.addLine(to: point(17.565, 8.142))
        path.addCurve(to: point(5.881, 14.735), control1: point(12.555, 7.013), control2: point(7.505, 9.863))
        path.addCurve(to: point(11.272, 27.02), control1: point(4.257, 19.607), control2: point(6.587, 24.917))
        path.closeSubpath()
        return path
    }
}

import BrowserCore
import SwiftUI

/// One thing a profile's circle can show instead of the first letter of its name: an emoji, a
/// currency's sign, or a company's two letters with the palette's colour nearest its own.
///
/// A company is its letters, never its logo: a logo is the company's drawing and mark, which the
/// app has no right to carry. `glyph` is at most `ProfileAvatarStyle.maximumLetters` characters
/// with no space, so it is kept, synced and shown as the letters a person types are — nothing new
/// is stored (an emoji or a flag is one character).
struct AvatarGlyph: Identifiable, Equatable {
    let glyph: String
    /// What it stands for: a company's or a currency's own name, the same in every language.
    let name: String
    /// The palette's colour chosen with it (`ProfileAvatar.palette`); nil: the colour stays.
    var color: Int?

    var id: String { glyph + "|" + name }

    init(_ glyph: String, _ name: String, color: Int? = nil) {
        self.glyph = glyph
        self.name = name
        self.color = color
    }
}

/// A part of the choice (the owner, 12 November: "structured, with sections").
struct AvatarGlyphSection: Identifiable, Equatable {
    /// The end of its title's key (`editor.avatar.section.<key>`).
    let key: String
    let symbol: String
    /// Shown with their names beside them (companies: two letters alone say little).
    var named = false
    let glyphs: [AvatarGlyph]

    var id: String { key }
    var title: String { L("editor.avatar.section.\(key)") }

    // The palette: 0 blue, 1 green, 2 sand, 3 lavender, 4 gray, 5 teal, 6 rose, 7 olive.
    static let all: [AvatarGlyphSection] = [
        AvatarGlyphSection(key: "crypto", symbol: "bitcoinsign.circle", glyphs: [
            AvatarGlyph("₿", "Bitcoin", color: 2), AvatarGlyph("Ξ", "Ethereum", color: 3), AvatarGlyph("₮", "Tether", color: 1),
            AvatarGlyph("◎", "Solana", color: 3), AvatarGlyph("Ł", "Litecoin", color: 4), AvatarGlyph("Ð", "Dogecoin", color: 2),
            AvatarGlyph("✕", "XRP", color: 4), AvatarGlyph("₳", "Cardano", color: 0), AvatarGlyph("ɱ", "Monero", color: 2),
            AvatarGlyph("BN", "BNB", color: 2), AvatarGlyph("TN", "TON", color: 0), AvatarGlyph("TR", "TRON", color: 6),
            AvatarGlyph("UC", "USDC", color: 0), AvatarGlyph("MM", "MetaMask", color: 2), AvatarGlyph("🪙", "Coin"),
            AvatarGlyph("💎", "Gem"), AvatarGlyph("⛏️", "Mining"), AvatarGlyph("🔗", "Chain"), AvatarGlyph("🦊", "Fox"),
            AvatarGlyph("🐕", "Dog"), AvatarGlyph("🚀", "Rocket"), AvatarGlyph("🌕", "Moon"), AvatarGlyph("🔑", "Key"),
            AvatarGlyph("👛", "Wallet"),
        ]),
        AvatarGlyphSection(key: "currency", symbol: "dollarsign.circle", glyphs: [
            AvatarGlyph("$", "USD", color: 1), AvatarGlyph("€", "EUR", color: 0), AvatarGlyph("£", "GBP", color: 3),
            AvatarGlyph("¥", "JPY / CNY", color: 6), AvatarGlyph("₽", "RUB", color: 4), AvatarGlyph("₴", "UAH", color: 0),
            AvatarGlyph("₸", "KZT", color: 5), AvatarGlyph("₺", "TRY", color: 6), AvatarGlyph("₹", "INR", color: 2),
            AvatarGlyph("₩", "KRW", color: 0), AvatarGlyph("₪", "ILS", color: 0), AvatarGlyph("₫", "VND", color: 6),
            AvatarGlyph("฿", "THB", color: 3), AvatarGlyph("₱", "PHP", color: 0), AvatarGlyph("₦", "NGN", color: 1),
            AvatarGlyph("₾", "GEL", color: 6), AvatarGlyph("zł", "PLN", color: 6), AvatarGlyph("Kč", "CZK", color: 0),
            AvatarGlyph("kr", "SEK / NOK / DKK", color: 0), AvatarGlyph("Fr", "CHF", color: 6), AvatarGlyph("R$", "BRL", color: 1),
            AvatarGlyph("C$", "CAD", color: 6), AvatarGlyph("A$", "AUD", color: 0), AvatarGlyph("د", "AED", color: 1),
        ]),
        AvatarGlyphSection(key: "money", symbol: "creditcard", glyphs: [
            AvatarGlyph("💵", "Dollar"), AvatarGlyph("💶", "Euro"), AvatarGlyph("💷", "Pound"), AvatarGlyph("💴", "Yen"),
            AvatarGlyph("💳", "Card"), AvatarGlyph("💰", "Money"), AvatarGlyph("🏦", "Bank"), AvatarGlyph("🏧", "ATM"),
            AvatarGlyph("💸", "Transfer"), AvatarGlyph("🧾", "Receipt"), AvatarGlyph("📈", "Growth"), AvatarGlyph("📉", "Fall"),
            AvatarGlyph("📊", "Chart"), AvatarGlyph("💱", "Exchange"), AvatarGlyph("💲", "Price"), AvatarGlyph("🤑", "Profit"),
            AvatarGlyph("🛒", "Shop"), AvatarGlyph("🛍️", "Purchases"), AvatarGlyph("🏷️", "Tag"), AvatarGlyph("📦", "Parcel"),
            AvatarGlyph("🎁", "Gift"), AvatarGlyph("🎰", "Casino"), AvatarGlyph("🎲", "Dice"), AvatarGlyph("⚖️", "Scales"),
        ]),
        AvatarGlyphSection(key: "payments", symbol: "arrow.left.arrow.right.circle", named: true, glyphs: [
            AvatarGlyph("PP", "PayPal", color: 0), AvatarGlyph("ST", "Stripe", color: 3), AvatarGlyph("VI", "Visa", color: 0),
            AvatarGlyph("MC", "Mastercard", color: 6), AvatarGlyph("AX", "American Express", color: 5), AvatarGlyph("AP", "Apple Pay", color: 4),
            AvatarGlyph("GP", "Google Pay", color: 0), AvatarGlyph("CA", "Cash App", color: 1), AvatarGlyph("VE", "Venmo", color: 0),
            AvatarGlyph("ZE", "Zelle", color: 3), AvatarGlyph("WI", "Wise", color: 1), AvatarGlyph("RV", "Revolut", color: 4),
            AvatarGlyph("PY", "Payoneer", color: 6), AvatarGlyph("SK", "Skrill", color: 3), AvatarGlyph("NT", "Neteller", color: 1),
            AvatarGlyph("KL", "Klarna", color: 6), AvatarGlyph("SQ", "Square", color: 4), AvatarGlyph("AD", "Adyen", color: 1),
            AvatarGlyph("AF", "Affirm", color: 0), AvatarGlyph("WU", "Western Union", color: 7), AvatarGlyph("CB", "Coinbase", color: 0),
            AvatarGlyph("BI", "Binance", color: 2), AvatarGlyph("KR", "Kraken", color: 3), AvatarGlyph("BY", "Bybit", color: 2),
            AvatarGlyph("OK", "OKX", color: 4),
        ]),
        AvatarGlyphSection(key: "banksUS", symbol: "building.columns", named: true, glyphs: [
            AvatarGlyph("JP", "JPMorgan Chase", color: 0), AvatarGlyph("BA", "Bank of America", color: 6), AvatarGlyph("WF", "Wells Fargo", color: 2),
            AvatarGlyph("CI", "Citi", color: 0), AvatarGlyph("US", "U.S. Bank", color: 0), AvatarGlyph("PN", "PNC", color: 2),
            AvatarGlyph("CO", "Capital One", color: 6), AvatarGlyph("TD", "TD Bank", color: 1), AvatarGlyph("TR", "Truist", color: 3),
            AvatarGlyph("GS", "Goldman Sachs", color: 4), AvatarGlyph("MS", "Morgan Stanley", color: 0), AvatarGlyph("SC", "Charles Schwab", color: 5),
            AvatarGlyph("DS", "Discover", color: 2), AvatarGlyph("AL", "Ally", color: 3), AvatarGlyph("CZ", "Citizens", color: 1),
            AvatarGlyph("FT", "Fifth Third", color: 1), AvatarGlyph("KB", "KeyBank", color: 6), AvatarGlyph("NF", "Navy Federal", color: 0),
            AvatarGlyph("UA", "USAA", color: 0), AvatarGlyph("CH", "Chime", color: 1), AvatarGlyph("SF", "SoFi", color: 5),
            AvatarGlyph("MR", "Mercury", color: 4),
        ]),
        AvatarGlyphSection(key: "banksEU", symbol: "building.columns.circle", named: true, glyphs: [
            AvatarGlyph("HS", "HSBC", color: 6), AvatarGlyph("BC", "Barclays", color: 5), AvatarGlyph("LL", "Lloyds", color: 1),
            AvatarGlyph("NW", "NatWest", color: 3), AvatarGlyph("BN", "BNP Paribas", color: 1), AvatarGlyph("CA", "Crédit Agricole", color: 1),
            AvatarGlyph("SG", "Société Générale", color: 6), AvatarGlyph("DB", "Deutsche Bank", color: 0), AvatarGlyph("CB", "Commerzbank", color: 2),
            AvatarGlyph("SA", "Santander", color: 6), AvatarGlyph("BB", "BBVA", color: 0), AvatarGlyph("CX", "CaixaBank", color: 0),
            AvatarGlyph("IN", "ING", color: 2), AvatarGlyph("AB", "ABN AMRO", color: 1), AvatarGlyph("RB", "Rabobank", color: 2),
            AvatarGlyph("UC", "UniCredit", color: 6), AvatarGlyph("IS", "Intesa Sanpaolo", color: 1), AvatarGlyph("UB", "UBS", color: 4),
            AvatarGlyph("ND", "Nordea", color: 0), AvatarGlyph("SE", "SEB", color: 1), AvatarGlyph("DN", "Danske Bank", color: 0),
            AvatarGlyph("ER", "Erste", color: 0), AvatarGlyph("RF", "Raiffeisen", color: 2), AvatarGlyph("KB", "KBC", color: 0),
            AvatarGlyph("PK", "PKO BP", color: 0), AvatarGlyph("N2", "N26", color: 5), AvatarGlyph("RV", "Revolut", color: 4),
            AvatarGlyph("MZ", "Monzo", color: 6), AvatarGlyph("BQ", "bunq", color: 5),
        ]),
        AvatarGlyphSection(key: "platforms", symbol: "globe", named: true, glyphs: [
            AvatarGlyph("G", "Google", color: 0), AvatarGlyph("FB", "Facebook", color: 0), AvatarGlyph("IG", "Instagram", color: 6),
            AvatarGlyph("TT", "TikTok", color: 4), AvatarGlyph("X", "X", color: 4), AvatarGlyph("YT", "YouTube", color: 6),
            AvatarGlyph("TG", "Telegram", color: 0), AvatarGlyph("WA", "WhatsApp", color: 1), AvatarGlyph("LI", "LinkedIn", color: 0),
            AvatarGlyph("RD", "Reddit", color: 6), AvatarGlyph("DC", "Discord", color: 3), AvatarGlyph("SN", "Snapchat", color: 7),
            AvatarGlyph("PN", "Pinterest", color: 6), AvatarGlyph("AZ", "Amazon", color: 2), AvatarGlyph("EB", "eBay", color: 0),
            AvatarGlyph("ET", "Etsy", color: 2), AvatarGlyph("SH", "Shopify", color: 1), AvatarGlyph("WM", "Walmart", color: 0),
            AvatarGlyph("AE", "AliExpress", color: 6), AvatarGlyph("AB", "Airbnb", color: 6), AvatarGlyph("BK", "Booking", color: 0),
            AvatarGlyph("UB", "Uber", color: 4), AvatarGlyph("MS", "Microsoft", color: 5), AvatarGlyph("GH", "GitHub", color: 4),
        ]),
        AvatarGlyphSection(key: "flags", symbol: "flag", glyphs: [
            AvatarGlyph("🇺🇸", "US"), AvatarGlyph("🇬🇧", "GB"), AvatarGlyph("🇨🇦", "CA"), AvatarGlyph("🇦🇺", "AU"),
            AvatarGlyph("🇩🇪", "DE"), AvatarGlyph("🇫🇷", "FR"), AvatarGlyph("🇮🇹", "IT"), AvatarGlyph("🇪🇸", "ES"),
            AvatarGlyph("🇳🇱", "NL"), AvatarGlyph("🇵🇱", "PL"), AvatarGlyph("🇵🇹", "PT"), AvatarGlyph("🇸🇪", "SE"),
            AvatarGlyph("🇨🇭", "CH"), AvatarGlyph("🇦🇹", "AT"), AvatarGlyph("🇮🇪", "IE"), AvatarGlyph("🇨🇿", "CZ"),
            AvatarGlyph("🇺🇦", "UA"), AvatarGlyph("🇰🇿", "KZ"), AvatarGlyph("🇹🇷", "TR"), AvatarGlyph("🇦🇪", "AE"),
            AvatarGlyph("🇮🇱", "IL"), AvatarGlyph("🇮🇳", "IN"), AvatarGlyph("🇯🇵", "JP"), AvatarGlyph("🇰🇷", "KR"),
            AvatarGlyph("🇸🇬", "SG"), AvatarGlyph("🇭🇰", "HK"), AvatarGlyph("🇧🇷", "BR"), AvatarGlyph("🇲🇽", "MX"),
            AvatarGlyph("🇪🇺", "EU"), AvatarGlyph("🌍", "World"), AvatarGlyph("🌎", "Americas"), AvatarGlyph("🌏", "Asia"),
        ]),
        AvatarGlyphSection(key: "other", symbol: "star", glyphs: [
            AvatarGlyph("⭐", "Star"), AvatarGlyph("🔥", "Fire"), AvatarGlyph("⚡", "Bolt"), AvatarGlyph("🎯", "Target"),
            AvatarGlyph("🧪", "Test"), AvatarGlyph("🤖", "Robot"), AvatarGlyph("👤", "Person"), AvatarGlyph("👥", "People"),
            AvatarGlyph("💼", "Work"), AvatarGlyph("🏠", "Home"), AvatarGlyph("🔒", "Lock"), AvatarGlyph("🛡️", "Shield"),
            AvatarGlyph("📱", "Phone"), AvatarGlyph("💻", "Laptop"), AvatarGlyph("✉️", "Mail"), AvatarGlyph("📣", "Ads"),
            AvatarGlyph("🎮", "Games"), AvatarGlyph("🎬", "Video"), AvatarGlyph("🎵", "Music"), AvatarGlyph("✈️", "Travel"),
            AvatarGlyph("❤️", "Heart"), AvatarGlyph("✅", "Done"), AvatarGlyph("⏳", "Waiting"), AvatarGlyph("🚫", "Blocked"),
        ]),
    ]
}

/// The choice itself: the sections on the left, the chosen one's glyphs on the right. A click puts
/// the glyph in the profile's circle — and, for a company, its colour — and the window stays, so
/// several can be tried; the circle above the form shows the result at once.
struct AvatarGlyphPicker: View {
    @Binding var draft: ProfileDraft
    let avatarID: UUID
    var close: () -> Void = {}
    @State var sectionKey = AvatarGlyphSection.all[0].key

    private var section: AvatarGlyphSection {
        AvatarGlyphSection.all.first { $0.key == sectionKey } ?? AvatarGlyphSection.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileAvatar(name: draft.name.isEmpty ? "?" : draft.name, id: avatarID, size: 36, style: draft.avatarStyle)
                Text(L("editor.avatar.pick.title")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(L("editor.avatar.pick.reset")) { draft.avatarLetters = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(draft.avatarLetters.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                    .disabled(draft.avatarLetters.isEmpty)
                Button(L("common.done"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                sections.frame(width: 190)
                Rectangle().fill(Theme.divider).frame(width: 1)
                ScrollView {
                    Group {
                        if section.named { named } else { grid }
                    }
                    .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 440)
        .background(Theme.card)
        .onExitCommand(perform: close)
    }

    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AvatarGlyphSection.all) { item in
                    let chosen = item.key == sectionKey
                    Button {
                        sectionKey = item.key
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12))
                                .frame(width: 18)
                                .foregroundStyle(chosen ? Theme.textPrimary : Theme.textTertiary)
                            Text(item.title)
                                .font(.system(size: 13))
                                .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(chosen ? Theme.rowSelected : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(8)
        }
    }

    /// Emoji and signs: a grid of circles, each with its name under the pointer.
    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(42), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
            ForEach(section.glyphs) { item in
                Button {
                    choose(item)
                } label: {
                    circle(item, size: 38)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isChosen(item) ? Theme.rowSelected : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isChosen(item) ? Theme.strongBorder : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: item.name))
                .accessibilityLabel(Text(verbatim: item.name))
                .accessibilityAddTraits(isChosen(item) ? .isSelected : [])
            }
        }
    }

    /// Companies: the circle as the profile will have it, and the company's name beside it.
    private var named: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), alignment: .leading, spacing: 4) {
            ForEach(section.glyphs) { item in
                Button {
                    choose(item)
                } label: {
                    HStack(spacing: 10) {
                        circle(item, size: 28)
                        Text(verbatim: item.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isChosen(item) ? Theme.rowSelected : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isChosen(item) ? Theme.strongBorder : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen(item) ? .isSelected : [])
            }
        }
    }

    /// The glyph as a profile's circle shows it: in its own colour, or the one the profile has.
    private func circle(_ item: AvatarGlyph, size: CGFloat) -> some View {
        ProfileAvatar(name: item.name, id: avatarID, size: size,
                      style: ProfileAvatarStyle(color: item.color ?? draft.avatarColor, letters: item.glyph))
    }

    private func isChosen(_ item: AvatarGlyph) -> Bool {
        draft.avatarLetters == item.glyph && (item.color == nil || item.color == draft.avatarColor)
    }

    private func choose(_ item: AvatarGlyph) {
        draft.avatarLetters = item.glyph
        if let color = item.color { draft.avatarColor = color }
    }
}

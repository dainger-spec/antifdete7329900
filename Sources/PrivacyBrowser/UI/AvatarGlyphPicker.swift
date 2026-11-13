import BrowserCore
import SwiftUI

/// One thing a profile's circle can show instead of the first letter of its name: an emoji or a
/// currency's sign.
///
/// No company is among them, neither by its logo nor by its letters (the owner, 12 November: a
/// logo is the company's mark, and nothing is to come of carrying one). `glyph` is at most
/// `ProfileAvatarStyle.maximumLetters` characters with no space, so it is kept, synced and shown
/// as the letters a person types are — nothing new is stored (an emoji or a flag is one character).
struct AvatarGlyph: Identifiable, Equatable {
    let glyph: String
    /// What it stands for, in a word; shown under the pointer.
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
    let glyphs: [AvatarGlyph]

    var id: String { key }
    var title: String { L("editor.avatar.section.\(key)") }

    // The palette: 0 blue, 1 green, 2 sand, 3 lavender, 4 gray, 5 teal, 6 rose, 7 olive.
    static let all: [AvatarGlyphSection] = [
        AvatarGlyphSection(key: "crypto", symbol: "bitcoinsign.circle", glyphs: [
            AvatarGlyph("₿", "Bitcoin", color: 2), AvatarGlyph("Ξ", "Ethereum", color: 3), AvatarGlyph("₮", "Tether", color: 1),
            AvatarGlyph("◎", "Solana", color: 3), AvatarGlyph("Ł", "Litecoin", color: 4), AvatarGlyph("Ð", "Dogecoin", color: 2),
            AvatarGlyph("✕", "XRP", color: 4), AvatarGlyph("₳", "Cardano", color: 0), AvatarGlyph("ɱ", "Monero", color: 2),
            AvatarGlyph("🪙", "Coin"),
            AvatarGlyph("💎", "Gem"), AvatarGlyph("⛏️", "Mining"), AvatarGlyph("🔗", "Chain"), AvatarGlyph("🦊", "Fox"),
            AvatarGlyph("🐕", "Dog"), AvatarGlyph("🚀", "Rocket"), AvatarGlyph("🌕", "Moon"), AvatarGlyph("🔑", "Key"),
            AvatarGlyph("👛", "Wallet"), AvatarGlyph("🏴‍☠️", "Pirate"), AvatarGlyph("🐂", "Bull"), AvatarGlyph("🐻", "Bear"),
            AvatarGlyph("🐳", "Whale"), AvatarGlyph("🧊", "Cold"),
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
        AvatarGlyphSection(key: "faces", symbol: "face.smiling", glyphs: [
            AvatarGlyph("😀", "Smile"), AvatarGlyph("😎", "Cool"), AvatarGlyph("🤓", "Nerd"), AvatarGlyph("🥸", "Disguise"),
            AvatarGlyph("🤠", "Cowboy"), AvatarGlyph("😇", "Angel"), AvatarGlyph("😈", "Devil"), AvatarGlyph("🤡", "Clown"),
            AvatarGlyph("👻", "Ghost"), AvatarGlyph("👽", "Alien"), AvatarGlyph("💀", "Skull"), AvatarGlyph("🤖", "Robot"),
            AvatarGlyph("🥷", "Ninja"), AvatarGlyph("🕵️", "Detective"), AvatarGlyph("🧑‍💻", "Developer"), AvatarGlyph("🧑‍💼", "Office"),
            AvatarGlyph("🧑‍🎨", "Artist"), AvatarGlyph("🧑‍🚀", "Astronaut"), AvatarGlyph("🧙", "Wizard"), AvatarGlyph("🧛", "Vampire"),
            AvatarGlyph("👑", "Crown"), AvatarGlyph("🎩", "Hat"), AvatarGlyph("🎭", "Masks"), AvatarGlyph("👀", "Eyes"),
        ]),
        AvatarGlyphSection(key: "animals", symbol: "pawprint", glyphs: [
            AvatarGlyph("🐶", "Dog"), AvatarGlyph("🐱", "Cat"), AvatarGlyph("🦊", "Fox"), AvatarGlyph("🐻", "Bear"),
            AvatarGlyph("🐼", "Panda"), AvatarGlyph("🐨", "Koala"), AvatarGlyph("🐯", "Tiger"), AvatarGlyph("🦁", "Lion"),
            AvatarGlyph("🐺", "Wolf"), AvatarGlyph("🐵", "Monkey"), AvatarGlyph("🐸", "Frog"), AvatarGlyph("🐧", "Penguin"),
            AvatarGlyph("🦉", "Owl"), AvatarGlyph("🦅", "Eagle"), AvatarGlyph("🦄", "Unicorn"), AvatarGlyph("🐉", "Dragon"),
            AvatarGlyph("🦈", "Shark"), AvatarGlyph("🐙", "Octopus"), AvatarGlyph("🐝", "Bee"), AvatarGlyph("🦋", "Butterfly"),
            AvatarGlyph("🐢", "Turtle"), AvatarGlyph("🦖", "Dinosaur"), AvatarGlyph("🐍", "Snake"), AvatarGlyph("🦂", "Scorpion"),
        ]),
        AvatarGlyphSection(key: "work", symbol: "briefcase", glyphs: [
            AvatarGlyph("💼", "Work"), AvatarGlyph("📱", "Phone"), AvatarGlyph("💻", "Laptop"), AvatarGlyph("🖥️", "Desktop"),
            AvatarGlyph("⌨️", "Keyboard"), AvatarGlyph("🖱️", "Mouse"), AvatarGlyph("📷", "Camera"), AvatarGlyph("🎥", "Video"),
            AvatarGlyph("🎙️", "Microphone"), AvatarGlyph("🎧", "Headphones"), AvatarGlyph("✉️", "Mail"), AvatarGlyph("📣", "Ads"),
            AvatarGlyph("📝", "Notes"), AvatarGlyph("📅", "Calendar"), AvatarGlyph("📌", "Pin"), AvatarGlyph("📎", "Clip"),
            AvatarGlyph("🔍", "Search"), AvatarGlyph("🔧", "Tool"), AvatarGlyph("⚙️", "Settings"), AvatarGlyph("🧪", "Test"),
            AvatarGlyph("🔒", "Lock"), AvatarGlyph("🛡️", "Shield"), AvatarGlyph("🌐", "Web"), AvatarGlyph("📡", "Signal"),
        ]),
        AvatarGlyphSection(key: "leisure", symbol: "gamecontroller", glyphs: [
            AvatarGlyph("🎮", "Games"), AvatarGlyph("🕹️", "Joystick"), AvatarGlyph("🎬", "Film"), AvatarGlyph("🎵", "Music"),
            AvatarGlyph("🎨", "Art"), AvatarGlyph("📚", "Books"), AvatarGlyph("⚽", "Football"), AvatarGlyph("🏀", "Basketball"),
            AvatarGlyph("🎾", "Tennis"), AvatarGlyph("🏎️", "Racing"), AvatarGlyph("🏋️", "Gym"), AvatarGlyph("🎣", "Fishing"),
            AvatarGlyph("✈️", "Travel"), AvatarGlyph("🚗", "Car"), AvatarGlyph("🏝️", "Island"), AvatarGlyph("🏔️", "Mountain"),
            AvatarGlyph("🏠", "Home"), AvatarGlyph("🏙️", "City"), AvatarGlyph("☕", "Coffee"), AvatarGlyph("🍕", "Pizza"),
            AvatarGlyph("🍔", "Burger"), AvatarGlyph("🍣", "Sushi"), AvatarGlyph("🍺", "Beer"), AvatarGlyph("🍷", "Wine"),
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
            AvatarGlyph("❤️", "Heart"), AvatarGlyph("💙", "Blue"), AvatarGlyph("💚", "Green"), AvatarGlyph("💛", "Yellow"),
            AvatarGlyph("💜", "Purple"), AvatarGlyph("🖤", "Black"), AvatarGlyph("🔴", "Red circle"), AvatarGlyph("🟠", "Orange circle"),
            AvatarGlyph("🟡", "Yellow circle"), AvatarGlyph("🟢", "Green circle"), AvatarGlyph("🔵", "Blue circle"), AvatarGlyph("🟣", "Purple circle"),
            AvatarGlyph("✅", "Done"), AvatarGlyph("❌", "No"), AvatarGlyph("⚠️", "Warning"), AvatarGlyph("🚫", "Blocked"),
            AvatarGlyph("⏳", "Waiting"), AvatarGlyph("🆕", "New"), AvatarGlyph("🔝", "Top"), AvatarGlyph("💯", "Hundred"),
            AvatarGlyph("1️⃣", "One"), AvatarGlyph("2️⃣", "Two"), AvatarGlyph("3️⃣", "Three"), AvatarGlyph("4️⃣", "Four"),
            AvatarGlyph("5️⃣", "Five"), AvatarGlyph("6️⃣", "Six"), AvatarGlyph("7️⃣", "Seven"), AvatarGlyph("8️⃣", "Eight"),
        ]),
    ]
}

/// The choice itself: the sections on the left, the chosen one's glyphs on the right. A click puts
/// the glyph in the profile's circle — and, for a sign that has one, its colour — and the window
/// stays, so several can be tried; the circle above the form shows the result at once.
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
                    grid.padding(14)
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

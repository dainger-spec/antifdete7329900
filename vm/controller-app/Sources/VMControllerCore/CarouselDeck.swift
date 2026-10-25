import Foundation

/// A benefit card shown on the splash while the environment sets up.
public struct BenefitCard: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let subtitle: String
    /// An SF Symbol name for the icon.
    public let symbol: String
}

/// The splash carousel: the cards, and the "advance to the next one" logic.
/// Pure, so rotation is unit-tested without a timer or a view.
public enum CarouselDeck {
    public static let cards: [BenefitCard] = [
        BenefitCard(id: 0, title: "Настоящий браузер, не подмена",
                    subtitle: "Внутри — реальный Safari в macOS, а не его имитация.",
                    symbol: "safari"),
        BenefitCard(id: 1, title: "Полная изоляция профилей",
                    subtitle: "Каждый профиль — отдельная виртуальная машина со своим состоянием.",
                    symbol: "square.on.square.dashed"),
        BenefitCard(id: 2, title: "Свой прокси на каждый профиль",
                    subtitle: "Трафик выходит только через заданный прокси.",
                    symbol: "network"),
        BenefitCard(id: 3, title: "Никаких следов модификации",
                    subtitle: "Ничего не патчится в системе — браузер остаётся собой.",
                    symbol: "checkmark.seal"),
    ]

    /// The index after `current`, wrapping around. Empty deck stays at 0.
    public static func next(after current: Int, count: Int = CarouselDeck.cards.count) -> Int {
        count <= 0 ? 0 : (current + 1) % count
    }

    /// How long each card shows before advancing.
    public static let interval: TimeInterval = 4
}

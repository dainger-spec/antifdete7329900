import Foundation

/// How strong a new master password is, and whether it may be one (the security audit's APP-06):
/// four steps, from its length, the kinds of characters in it and how many different ones it has.
/// The meter under the field shows the steps as the person types; a new master password — the
/// first one, or one a change sets — must be at least `minimumLength` characters and at least
/// "fair" (`minimumScore`). A vault whose password was set before this rule still opens with it:
/// only a new password is held to it.
public enum MasterPasswordStrength {
    public static let minimumLength = 10
    /// 2: "fair" — 14 characters or more, or 10 or more of three kinds (lower case, upper case,
    /// digits, others); and in either case at least `minimumDistinct` different characters.
    public static let minimumScore = 2
    /// Fewer different characters than this ("aaaaaaaaaaaaaa", "12121212121212") is weak at any length.
    public static let minimumDistinct = 6

    /// 0 for an empty password, else 1 (weak) to 4 (strong).
    public static func score(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        guard Set(password).count >= minimumDistinct else { return 1 }
        let kinds = [password.contains { $0.isLowercase }, password.contains { $0.isUppercase },
                     password.contains { $0.isNumber }, password.contains { !$0.isLetter && !$0.isNumber }]
            .filter { $0 }.count
        var score = password.count >= minimumLength ? 1 : 0
        if password.count >= 14 { score += 1 }
        if password.count >= 20 { score += 1 }
        if kinds >= 3 { score += 1 }
        return min(max(score, 1), 4)
    }

    /// Long enough (`minimumLength`).
    public static func isLongEnough(_ password: String) -> Bool { password.count >= minimumLength }

    /// Strong enough (`minimumScore`), whatever its length.
    public static func isStrongEnough(_ password: String) -> Bool { score(password) >= minimumScore }

    /// Whether `password` may be a new master password: long enough and strong enough.
    public static func isAcceptable(_ password: String) -> Bool { isLongEnough(password) && isStrongEnough(password) }
}

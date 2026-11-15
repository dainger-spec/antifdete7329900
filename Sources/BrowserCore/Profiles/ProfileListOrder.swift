import Foundation

/// The order the Profiles list shows its rows in — the person's choice, kept between launches by
/// its raw value. The list's groups (need attention, running, ready) stay; this orders the rows
/// inside each.
public enum ProfileListOrder: String, CaseIterable, Sendable {
    /// As the profiles were made, the oldest first: the order the vault lists them in
    /// (`ProfileRepository.list()`), and the list's order before there was a choice.
    case created
    /// By name, as the Finder orders names: whatever their case, a number in a name by its value
    /// ("Shop 2" before "Shop 10").
    case name
    /// The profile launched last first; those never launched after all the others.
    case lastUsed

    /// `rows` — given as the vault lists them — in this order. Rows that compare the same (the
    /// same name, the same moment, never launched) keep the order they were given in, so the list
    /// does not shuffle when it is read again.
    public func sorted<Row>(_ rows: [Row], name: (Row) -> String, lastUsed: (Row) -> Date?) -> [Row] {
        switch self {
        case .created:
            return rows
        case .name:
            let keyed = rows.enumerated().map { (offset: $0.offset, key: name($0.element), row: $0.element) }
            return keyed.sorted { a, b in
                switch Self.compareNames(a.key, b.key) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.offset < b.offset
                }
            }.map { $0.row }
        case .lastUsed:
            let keyed = rows.enumerated().map { (offset: $0.offset, key: lastUsed($0.element), row: $0.element) }
            return keyed.sorted { a, b in
                switch (a.key, b.key) {
                case let (first?, second?) where first != second: return first > second
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.offset < b.offset
                }
            }.map { $0.row }
        }
    }

    /// Two names as the list orders them: without regard to case, digits by the number they write.
    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric])
    }
}

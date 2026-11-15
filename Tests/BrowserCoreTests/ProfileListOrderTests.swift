import XCTest
@testable import BrowserCore

/// The order of the Profiles list: as the profiles were made, by name, or by the last launch —
/// and the same every time the list is read.
final class ProfileListOrderTests: XCTestCase {
    private struct Row: Equatable {
        var name: String
        var lastUsed: Date?
    }

    private func names(_ order: ProfileListOrder, _ rows: [Row]) -> [String] {
        order.sorted(rows, name: { $0.name }, lastUsed: { $0.lastUsed }).map { $0.name }
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    func testAsMadeIsTheOrderGiven() {
        let rows = [Row(name: "b"), Row(name: "a", lastUsed: at(5)), Row(name: "c")]
        XCTAssertEqual(names(.created, rows), ["b", "a", "c"])
    }

    func testByNameIgnoresCaseAndReadsNumbersAsNumbers() {
        let rows = ["Shop 10", "shop 2", "Shop 1", "amazon", "Zeta", "Shop 9", "Ads 03", "ads 2"].map { Row(name: $0) }
        XCTAssertEqual(names(.name, rows), ["ads 2", "Ads 03", "amazon", "Shop 1", "shop 2", "Shop 9", "Shop 10", "Zeta"])
    }

    func testTheSameNameKeepsTheOrderGiven() {
        let rows = [Row(name: "Twin", lastUsed: at(1)), Row(name: "Alpha"), Row(name: "twin", lastUsed: at(2)), Row(name: "TWIN", lastUsed: at(3))]
        let sorted = ProfileListOrder.name.sorted(rows, name: { $0.name }, lastUsed: { $0.lastUsed })
        XCTAssertEqual(sorted.map { $0.name }, ["Alpha", "Twin", "twin", "TWIN"])
        // Sorted again from its own result, it stays as it is.
        XCTAssertEqual(ProfileListOrder.name.sorted(sorted, name: { $0.name }, lastUsed: { $0.lastUsed }), sorted)
    }

    func testByLastLaunchPutsTheLatestFirstAndTheNeverLaunchedLastInTheirOrder() {
        let rows = [Row(name: "never 1"), Row(name: "old", lastUsed: at(10)), Row(name: "new", lastUsed: at(900)),
                    Row(name: "never 2"), Row(name: "same a", lastUsed: at(300)), Row(name: "same b", lastUsed: at(300))]
        XCTAssertEqual(names(.lastUsed, rows), ["new", "same a", "same b", "old", "never 1", "never 2"])
    }

    /// The names the choice is kept under between launches: changing one forgets the person's order.
    func testTheNamesTheChoiceIsKeptUnderStay() {
        XCTAssertEqual(ProfileListOrder.allCases.map(\.rawValue), ["created", "name", "lastUsed"])
        XCTAssertNil(ProfileListOrder(rawValue: "byProxy"), "an order this version does not know is not read as one")
    }

    func testEmptyAndSingleListsAreLeftAlone() {
        XCTAssertEqual(names(.name, []), [])
        XCTAssertEqual(names(.lastUsed, [Row(name: "only")]), ["only"])
    }
}

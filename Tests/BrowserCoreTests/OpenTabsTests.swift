import XCTest
@testable import BrowserCore

final class OpenTabsTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    func testOnlyWebAddressesAreKeptAndTheShownTabFollows() {
        let tabs = OpenTabs(windows: [
            .init(tabs: [url("about:blank"), url("https://a.example/one"), url("file:///Users/me/secret.pdf"),
                         url("http://b.example/two?q=1"), url("javascript:alert(1)")], selected: 3),
            .init(tabs: [url("about:blank"), url("data:text/html,x")], selected: 1),
            .init(tabs: [url("https://c.example/")], selected: 7),
        ])
        XCTAssertEqual(tabs.windows, [
            .init(tabs: [url("https://a.example/one"), url("http://b.example/two?q=1")], selected: 1),
            .init(tabs: [url("https://c.example/")], selected: 0),
        ], "a window left without a page is dropped; an index past the end shows the first tab")
    }

    func testAtMostSoManyWindowsAndTabs() {
        let many = (0..<(OpenTabs.maximumTabs + 5)).map { url("https://example.com/\($0)") }
        let tabs = OpenTabs(windows: Array(repeating: .init(tabs: many), count: OpenTabs.maximumWindows + 3))
        XCTAssertEqual(tabs.windows.count, OpenTabs.maximumWindows)
        XCTAssertTrue(tabs.windows.allSatisfy { $0.tabs.count == OpenTabs.maximumTabs })
    }

    func testKeptEncryptedForThisMacAndFilteredAgainWhenRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "tabs", iterations: 1_000))
        let id = try repository.create(name: "Tabs", configuration: ProfileConfiguration()).id
        XCTAssertNil(try repository.openTabs(for: id))
        let tabs = OpenTabs(windows: [.init(tabs: [url("https://secret-site.example/path")])])
        try repository.saveOpenTabs(tabs, for: id)
        XCTAssertEqual(try repository.openTabs(for: id)?.windows, tabs.windows)
        let stored = try Data(contentsOf: repository.openTabsURL(for: id))
        XCTAssertNil(stored.range(of: Data("secret-site".utf8)), "the addresses are not in the file in clear")
        XCTAssertFalse(ProfileSyncFile.allCases.map(\.rawValue).contains("tabs.bin"), "never synced")
        try repository.removeOpenTabs(for: id)
        XCTAssertNil(try repository.openTabs(for: id))

        // What a file holds is filtered again when it is read: a page of another kind never opens.
        let planted = #"{"format":1,"windows":[{"tabs":["file:///etc/passwd","https://a.example/"],"selected":0}]}"#
        let file = try repository.openTabsFile(for: id)
        try SecureFile.write(AEAD.seal(Data(planted.utf8), key: file.key, aad: file.aad), to: repository.openTabsURL(for: id))
        XCTAssertEqual(try repository.openTabs(for: id)?.windows, [.init(tabs: [url("https://a.example/")])])
    }

    func testAChromesTabsBecomeWindowsWithTheTabShown() {
        // Safari's chrome hands out the tabs of every window as one list.
        let seen = [
            ObservedTab(window: 7, url: url("https://a.example/")),
            ObservedTab(window: 3, url: nil, isSelected: true),
            ObservedTab(window: 7, url: nil),
            ObservedTab(window: 7, url: url("https://b.example/"), isSelected: true),
            ObservedTab(window: 3, url: url("https://c.example/")),
            ObservedTab(window: 9, url: nil, isSelected: true),
        ]
        let windows = OpenTabs.windows(of: seen)
        XCTAssertEqual(windows.map(\.tabs.count), [3, 2, 1], "the windows in the order their first tab came, every tab in its place")
        XCTAssertEqual(windows.map(\.selected), [2, 0, 0])
        XCTAssertEqual(OpenTabs(windows: windows).windows, [
            .init(tabs: [url("https://a.example/"), url("https://b.example/")], selected: 1),
            .init(tabs: [url("https://c.example/")], selected: 0),
        ], "a tab without a page is not kept, the tab shown stays the one shown, a window of start pages is dropped")
        XCTAssertTrue(OpenTabs(windows: OpenTabs.windows(of: [])).windows.isEmpty)
    }

    func testTheFewestPressesToTheTabThatWasShown() {
        func steps(_ current: Int, _ wanted: Int, _ count: Int) -> [Int] {
            let found = OpenTabs.selectionSteps(from: current, to: wanted, count: count)
            return [found.presses, found.forward ? 1 : 0]
        }
        XCTAssertEqual(steps(4, 0, 5), [1, 1], "from the last tab, next goes round to the first")
        XCTAssertEqual(steps(4, 3, 5), [1, 0])
        XCTAssertEqual(steps(4, 2, 5), [2, 0])
        XCTAssertEqual(steps(4, 1, 5), [2, 1])
        XCTAssertEqual(steps(0, 2, 4), [2, 1], "as near either way: next")
        XCTAssertEqual(steps(1, 1, 3)[0], 0)
        XCTAssertEqual(steps(0, 0, 1)[0], 0)
        XCTAssertEqual(steps(0, 5, 3)[0], 0, "a tab the window does not have is not looked for")
        XCTAssertEqual(steps(-1, 1, 3)[0], 0)
        // Every pair of a window's tabs: that many presses that way arrive.
        for count in 2...7 {
            for current in 0..<count {
                for wanted in 0..<count {
                    let found = OpenTabs.selectionSteps(from: current, to: wanted, count: count)
                    let arrived = ((current + (found.forward ? found.presses : -found.presses)) % count + count) % count
                    XCTAssertEqual(arrived, wanted)
                    XCTAssertLessThanOrEqual(found.presses, count / 2)
                }
            }
        }
    }
}

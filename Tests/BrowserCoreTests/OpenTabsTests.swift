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
}

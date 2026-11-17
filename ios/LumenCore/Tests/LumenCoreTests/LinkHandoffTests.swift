import XCTest
@testable import LumenCore

/// Which navigations a tab holds back from the apps that claim their links (`LinkHandoff`): what
/// WebKit would offer to another app is loaded by the tab itself — after a warning for the hosts of
/// `LinkHandoff.apps` — and nothing WebKit never offers is touched.
final class LinkHandoffTests: XCTestCase {
    private let youtube = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
    private let shop = URL(string: "https://shop.example.org/item/1")!

    private func decide(_ url: URL, from current: String? = "www.google.com", target: LinkHandoff.Target = .mainFrame,
                        kind: LinkHandoff.Kind = .link, method: String? = "GET", ownLoad: Bool = false) -> LinkHandoff.Decision {
        LinkHandoff.decide(url: url, currentHost: current, target: target, kind: kind, method: method, ownLoad: ownLoad)
    }

    func testATappedLinkToAnotherHostOpensInTheSessionAndAnAppsHostIsWarnedOf() {
        XCTAssertEqual(decide(shop), .openHere, "no app is known for it, and none is let take it either")
        XCTAssertEqual(decide(youtube), .warn(app: "YouTube"))
        XCTAssertEqual(decide(URL(string: "https://t.me/durov")!, from: "example.org"), .warn(app: "Telegram"))
        XCTAssertEqual(decide(youtube, from: nil), .warn(app: "YouTube"), "a tab with no page yet")
        // A tap during the tab's own load is the person's, not the load's.
        XCTAssertEqual(decide(youtube, ownLoad: true), .warn(app: "YouTube"))
    }

    func testAPageStartedGetToAnotherHostIsHeldBackTooAndItsPostIsNot() {
        XCTAssertEqual(decide(shop, kind: .other), .openHere, "a script's navigation during a tap")
        XCTAssertEqual(decide(youtube, kind: .other), .warn(app: "YouTube"), "and a redirect of a tapped link")
        XCTAssertEqual(decide(youtube, kind: .form), .warn(app: "YouTube"), "a form sent with GET")
        XCTAssertEqual(decide(youtube, kind: .other, method: nil), .warn(app: "YouTube"), "no method is GET")
        XCTAssertEqual(decide(youtube, kind: .form, method: "POST"), .allow, "the page's body is not the tab's to send again")
        XCTAssertEqual(decide(shop, kind: .other, method: "post"), .allow)
    }

    func testWhatWebKitNeverOffersToAnAppGoesOnUntouched() {
        XCTAssertEqual(decide(URL(string: "https://www.google.com/search?q=lumen")!), .allow, "the same host")
        XCTAssertEqual(decide(URL(string: "https://WWW.Google.com/maps")!), .allow, "hosts compare without case")
        XCTAssertEqual(decide(youtube, target: .frame), .allow, "a frame")
        XCTAssertEqual(decide(youtube, kind: .backForward), .allow)
        XCTAssertEqual(decide(youtube, kind: .reload), .allow)
        XCTAssertEqual(decide(youtube, kind: .other, ownLoad: true), .allow, "the tab's own load and its redirects")
        XCTAssertEqual(decide(URL(string: "about:blank")!), .allow)
        XCTAssertEqual(decide(URL(string: "blob:https://www.google.com/1")!), .allow)
    }

    func testANewWindowFromALinkOpensInATabOfTheSessionAndAScriptsPopupKeepsItsOpener() {
        XCTAssertEqual(decide(shop, target: .newWindow), .openHere, "target=_blank")
        XCTAssertEqual(decide(youtube, target: .newWindow), .warn(app: "YouTube"))
        XCTAssertEqual(decide(shop, target: .newWindow, kind: .other), .allow, "window.open to a host no app is known for")
        XCTAssertEqual(decide(URL(string: "https://www.facebook.com/dialog/oauth")!, target: .newWindow, kind: .other),
                       .warn(app: "Facebook"))
        // The tab's own load is its main frame's: it does not cover a window the page opens.
        XCTAssertEqual(decide(youtube, target: .newWindow, kind: .other, ownLoad: true), .warn(app: "YouTube"))
    }

    func testTheAppsHostsWithTheirSubdomainsAndNothingThatOnlyLooksLikeThem() {
        let expected: [String: String?] = [
            "youtube.com": "YouTube", "m.youtube.com": "YouTube", "youtu.be": "YouTube", "YouTube.COM.": "YouTube",
            "www.instagram.com": "Instagram", "fb.com": "Facebook", "x.com": "X", "mobile.twitter.com": "X",
            "telegram.me": "Telegram", "vm.tiktok.com": "TikTok", "www.amazon.de": "Amazon", "smile.amazon.co.uk": "Amazon",
            "apps.apple.com": "App Store", "wa.me": "WhatsApp", "www.linkedin.com": "LinkedIn", "old.reddit.com": "Reddit",
            "open.spotify.com": "Spotify", "pinterest.com": "Pinterest",
            "notyoutube.com": nil, "youtube.com.example.net": nil, "www.apple.com": nil, "amazon.example": nil,
            "max.com": nil, "example.org": nil,
        ]
        for (host, app) in expected {
            XCTAssertEqual(LinkHandoff.app(forHost: host), app, host)
        }
        for entry in LinkHandoff.apps {
            XCTAssertFalse(entry.domains.isEmpty, entry.app)
            for domain in entry.domains {
                XCTAssertEqual(domain, domain.lowercased(), "a domain is written as it is compared")
            }
        }
    }
}

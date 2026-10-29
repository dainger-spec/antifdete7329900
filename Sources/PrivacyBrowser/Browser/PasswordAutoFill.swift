import AppKit
import BrowserCore
import os
import WebKit

/// Password AutoFill for WKWebView, as close to Safari's as the public API allows (macOS 26 has no
/// AutoFill hook for third-party web views; see docs/ISOLATION_AND_LIMITATIONS.md §8):
///   * SAVE: after a sign-in (`PasswordAutoFillScript` reports a submitted password the user typed)
///     the window shows Safari's question — Save Password / Not Now / Never for This Website, or
///     Update Password when the user name is saved with another password.
///   * FILL: when a login field gets focus, the profile's saved logins for the site are listed under
///     it (`AutoFillPanel`); nothing is filled until the user picks one. Never on page load, never
///     into hidden fields, never into a frame of another site.
///   * Matching by site (registrable domain), never an https login on http (`PasswordMatching`).
///
/// The script runs in its own content world. Its message handler is registered only there, so the
/// page world has no `window.webkit` (as Safari's pages) and cannot post to it or call into it.
@MainActor
enum PasswordAutoFill {
    static let handlerName = "pbPasswords"
    static let worldName = "PrivacyBrowser.Passwords"

    /// How the world was made: "autofill (public API)", "autofill (WebKit SPI)" or "isolated"
    /// (self-test information).
    private(set) static var worldKind = "isolated"

    /// The content world the AutoFill script and its handler live in. Where WebKit offers it, a
    /// world with AutoFill scripting: there the script can mark filled fields `:autofill` (Safari's
    /// highlight) and show WebKit's key button in the field. That is public API from macOS 27
    /// (`WKContentWorld.Configuration.autofillScriptingEnabled`) and WebKit SPI before
    /// (`_WKContentWorldConfiguration.allowAutofill`, macOS 15.4+); each is used only when this
    /// WebKit has it, otherwise a plain named world.
    static let world: WKContentWorld = makeWorld()

    private static func makeWorld() -> WKContentWorld {
        let candidates: [(configurationClass: String, flag: String, factory: String, kind: String)] = [
            ("WKContentWorldConfiguration", "setAutofillScriptingEnabled:", "worldWithConfiguration:", "autofill (public API)"),
            ("_WKContentWorldConfiguration", "setAllowAutofill:", "_worldWithConfiguration:", "autofill (WebKit SPI)"),
        ]
        for candidate in candidates {
            guard let type = NSClassFromString(candidate.configurationClass) as? NSObject.Type else { continue }
            let configuration = type.init()
            let factory = NSSelectorFromString(candidate.factory)
            guard configuration.responds(to: NSSelectorFromString("setName:")),
                  let method = class_getClassMethod(WKContentWorld.self, factory),
                  WebKitPreferences.setBool(configuration, candidate.flag, true) else { continue }
            configuration.setValue(worldName, forKey: "name")
            // +[WKContentWorld worldWithConfiguration:] (or its SPI predecessor): an autoreleased world.
            typealias Factory = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
            let make = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            if let world = make(WKContentWorld.self, factory, configuration)?.takeUnretainedValue() as? WKContentWorld {
                worldKind = candidate.kind
                return world
            }
        }
        return .world(name: worldName)
    }

    /// Adds the script (every frame, before page scripts) and the handler to a profile's controller.
    static func install(in controller: WKUserContentController, handler: WKScriptMessageHandlerWithReply, testHooks: Bool) {
        controller.addUserScript(WKUserScript(source: PasswordAutoFillScript.source(handlerName: handlerName, testHooks: testHooks),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addScriptMessageHandler(handler, contentWorld: world, name: handlerName)
    }

    /// Runs `body` in the AutoFill world of `frame` (nil: the main frame).
    static func call(_ body: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo?, of webView: WKWebView,
                     completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: frame, in: world) { result in
            if case let .success(value) = result { completion(value) } else { completion(nil) }
        }
    }
}

/// The origin of a frame as WebKit reports it (not as the page says); nil for an opaque origin
/// (sandboxed frame, `data:`) and anything but http(s).
extension WebOrigin {
    init?(_ securityOrigin: WKSecurityOrigin) {
        self.init(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port)
    }
}

/// Receives the AutoFill script's messages for one profile and hands each to its tab.
@MainActor
/// What AutoFill needs from whatever shows the page: our own tab, or a web view inside Safari's
/// chrome, where there is no tab of ours at all (`SafariChromeHost`). Small on purpose — this is
/// the whole surface `TabPasswordAutoFill` ever used from a tab.
@MainActor
protocol PasswordAutoFillHost: AnyObject {
    var webView: WKWebView { get }
    /// The page is the one in front: suggestions are not shown over another tab.
    var isSelected: Bool { get }
    var url: URL? { get }
    func showMessage(_ text: String)
    func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void)
}

/// A page in Safari's chrome, which has no tab of ours behind it. Everything AutoFill asks for is
/// answered from the web view itself.
@MainActor
final class HostedPageAutoFillHost: PasswordAutoFillHost {
    let webView: WKWebView
    init(webView: WKWebView) { self.webView = webView }
    var isSelected: Bool { webView.window != nil }
    var url: URL? { webView.url }

    func showMessage(_ text: String) {
        Logger(subsystem: "PrivacyBrowser", category: "PasswordAutoFill").notice("\(text, privacy: .public)")
    }

    func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}

final class PasswordAutoFillHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: BrowserSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.world == PasswordAutoFill.world, let body = message.body as? [String: Any],
              let webView = message.webView, let session,
              let autoFill = autoFill(for: webView, of: session) else {
            replyHandler(nil, nil)
            return
        }
        autoFill.handle(body, from: message.frameInfo, reply: { replyHandler($0, nil) })
    }

    /// Our own tab's AutoFill when the page is in one of our windows; otherwise one made for this
    /// web view, which is the case in Safari's chrome, kept for as long as the web view lives.
    private func autoFill(for webView: WKWebView, of session: BrowserSession) -> TabPasswordAutoFill? {
        if let tab = session.tab(for: webView) { return tab.passwords }
        if let known = hosted.object(forKey: webView) { return known }
        let autoFill = TabPasswordAutoFill(host: HostedPageAutoFillHost(webView: webView),
                                           vault: session.passwordVault, settings: session.passwordSettings)
        hosted.setObject(autoFill, forKey: webView)
        return autoFill
    }

    private let hosted = NSMapTable<WKWebView, TabPasswordAutoFill>.weakToStrongObjects()
}

/// The user's answer to "Save password?" / "Update password?".
enum PasswordPromptAnswer: Equatable {
    case save, notNow, never
}

/// A question the browser asked (self-test record).
struct PasswordPromptRecord: Equatable {
    enum Kind: Equatable { case save, update }
    var kind: Kind
    var username: String
    var host: String
}

/// One tab's AutoFill: suggestions under login fields, filling, and the save question after a sign-in.
@MainActor
final class TabPasswordAutoFill {
    private weak var host: PasswordAutoFillHost?
    private let vault: PasswordVault
    private let settings: ProfilePasswordSettings
    /// The user name of the first page of a two-step sign-in, for its password page.
    private var pendingUsername: (site: String, username: String, at: Date)?
    /// Sign-ins already asked about in this tab: one reported twice (submit event and navigation),
    /// or again after "Not Now", is asked once.
    private var asked: Set<String> = []
    private var panel: AutoFillPanel?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "PasswordAutoFill")

    /// Self-test hooks: answers the questions instead of the user, and records them.
    static var testAnswer: ((PasswordPromptRecord) -> PasswordPromptAnswer)?
    static var testPrompts: [PasswordPromptRecord] = []
    /// "host:count" for each login field that got focus, while `testAnswer` is set (self-test hook).
    static var testFocusLog: [String] = []

    init(host: PasswordAutoFillHost, vault: PasswordVault, settings: ProfilePasswordSettings) {
        self.host = host
        self.vault = vault
        self.settings = settings
    }

    // MARK: Messages from the page

    func handle(_ body: [String: Any], from frame: WKFrameInfo, reply: @escaping (Any?) -> Void) {
        guard let origin = WebOrigin(frame.securityOrigin), let type = body["type"] as? String else {
            reply(nil)
            return
        }
        let token = body["token"] as? String ?? ""
        switch type {
        case "focus":
            let candidates = settings.autoFill ? vault.candidates(for: origin) : []
            reply(["count": candidates.count])
            if Self.testAnswer != nil { Self.testFocusLog.append("\(origin.host):\(candidates.count)") }
            if let field = body["field"] as? Int, !candidates.isEmpty {
                showSuggestions(candidates, for: FieldReference(frame: frame, token: token, field: field, origin: origin),
                                rect: body["rect"] as? [String: Any], pointer: body["pointer"] as? [String: Any])
            }
        case "blur":
            reply(nil)
            // Shortly after: focus moving into another login field of the page has opened its own list.
            let field = body["field"] as? Int
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let panel = self.panel, panel.field?.token == token, panel.field?.field == field else { return }
                self.closeSuggestions()
            }
        case "moved":
            reply(nil)
            closeSuggestions()
        case "submit":
            reply(nil)
            guard let password = body["password"] as? String else { return }
            offerToSave(username: body["username"] as? String ?? "", password: password, at: origin, explicit: false)
        case "username":
            reply(nil)
            if let username = body["username"] as? String, !username.isEmpty {
                pendingUsername = (origin.site, username, Date())
            }
        default:
            reply(nil)
        }
    }

    // MARK: Suggestions and filling

    struct FieldReference {
        let frame: WKFrameInfo?
        let token: String?
        let field: Int?
        let origin: WebOrigin
    }

    private func showSuggestions(_ entries: [PasswordEntry], for field: FieldReference, rect: [String: Any]?, pointer: [String: Any]?) {
        guard let host, host.isSelected, let window = host.webView.window,
              let anchor = Self.anchor(rect: rect, pointer: pointer, in: host.webView) else { return }
        let webView = host.webView
        closeSuggestions()
        let header = field.frame?.isMainFrame == false ? String(format: L("pw.panel.frameHeader"), field.origin.host) : nil
        panel = AutoFillPanel.show(entries: entries, pageHost: field.origin.host, header: header, field: field,
                                   anchor: anchor, of: webView, in: window,
                                   showsManager: settings.showManager != nil) { [weak self] choice in
            guard let self else { return }
            self.panel = nil
            switch choice {
            case let .entry(entry): self.fill(entry, into: field)
            case .manager: self.settings.showManager?()
            }
        }
    }

    func closeSuggestions() {
        panel?.dismiss()
        panel = nil
    }

    /// Where the field is, in the web view's coordinates (flipped, points): from its rectangle in
    /// the top frame's CSS pixels, scaled by the page zoom and the pinch magnification; a field in a
    /// frame of another origin is placed from the click into it (or under the top of the view).
    private static func anchor(rect: [String: Any]?, pointer: [String: Any]?, in webView: WKWebView) -> NSRect? {
        guard let rect, let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let width = rect["width"] as? Double, let height = rect["height"] as? Double else { return nil }
        let scale = (rect["scale"] as? Double ?? 1) * webView.pageZoom
        let viewportX = rect["viewportX"] as? Double ?? 0, viewportY = rect["viewportY"] as? Double ?? 0
        var origin = NSPoint(x: (x - viewportX) * scale, y: (y - viewportY) * scale)
        if rect["crossOrigin"] as? Bool == true {
            // The frame's offset is unknown from inside it: where the mouse is now, less where the
            // click was in the frame, is.
            if let px = pointer?["x"] as? Double, let py = pointer?["y"] as? Double, let window = webView.window {
                let mouse = webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                origin = NSPoint(x: mouse.x - (px - x) * scale, y: mouse.y - (py - y) * scale)
            } else {
                origin = NSPoint(x: 16, y: 8)
            }
        }
        let field = NSRect(x: origin.x, y: origin.y, width: max(width * scale, 1), height: max(height * scale, 1))
        return field.intersects(webView.bounds) ? field : nil
    }

    /// Fills `entry` into the field's form, after checking again that it belongs on the frame's site.
    func fill(_ entry: PasswordEntry, into field: FieldReference) {
        guard let host, let saved = WebOrigin(entry.origin), PasswordMatching.offers(saved, on: field.origin) else {
            log.error("A login was not filled: it is not one for this site")
            return
        }
        let webView = host.webView
        var arguments: [String: Any] = ["username": entry.username, "password": entry.password,
                                        "origin": field.origin.serialized, "token": field.token ?? ""]
        arguments["field"] = field.field ?? 0
        let id = entry.id
        PasswordAutoFill.call("return globalThis.__pbPasswords ? globalThis.__pbPasswords.fill(token, field, username, password, origin) : 'missing';",
                              arguments, in: field.frame, of: webView) { [weak self] result in
            guard let self else { return }
            if result as? String == "filled" {
                try? self.vault.markUsed(id: id)
            } else if field.field == nil {
                self.host?.showMessage(L("pw.noField"))
            }
        }
    }

    /// The toolbar's key button: the page's saved logins under the button.
    func showSuggestionsFromToolbar(anchor button: NSView) {
        guard let host, let url = host.url, let origin = WebOrigin(url: url), let window = button.window else { return }
        let entries = vault.candidates(for: origin)
        guard !entries.isEmpty else {
            host.showMessage(String(format: L("pw.noSaved"), origin.host))
            return
        }
        closeSuggestions()
        let field = FieldReference(frame: nil, token: nil, field: nil, origin: origin)
        panel = AutoFillPanel.show(entries: entries, pageHost: origin.host, header: nil, field: field,
                                   anchor: button.bounds, of: button, in: window,
                                   showsManager: settings.showManager != nil) { [weak self] choice in
            guard let self else { return }
            self.panel = nil
            switch choice {
            case let .entry(entry): self.fill(entry, into: field)
            case .manager: self.settings.showManager?()
            }
        }
    }

    // MARK: Saving

    /// The toolbar's save button: what the page's password fields hold, typed or not.
    func saveFromPage() {
        guard let host, let url = host.url, let origin = WebOrigin(url: url) else { return }
        PasswordAutoFill.call("return globalThis.__pbPasswords ? globalThis.__pbPasswords.capture() : null;",
                              in: nil, of: host.webView) { [weak self] value in
            guard let self else { return }
            // Saved for the page's own origin only: the document must still be the one the address names.
            guard let fields = value as? [String: Any], let password = fields["password"] as? String, !password.isEmpty,
                  fields["origin"] as? String == origin.serialized else {
                self.host?.showMessage(L("pw.typeFirst"))
                return
            }
            self.offerToSave(username: fields["username"] as? String ?? "", password: password, at: origin, explicit: true)
        }
    }

    /// A form submission seen as a navigation (`form.submit()` sends no `submit` event): reads the
    /// password the user typed in that frame, then lets the navigation go on — at most 0.3 s later.
    func formSubmitted(from frame: WKFrameInfo, proceed: @escaping () -> Void) {
        guard let host, settings.autoFill, let origin = WebOrigin(frame.securityOrigin) else {
            proceed()
            return
        }
        let once = Once(proceed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { once.run() }
        PasswordAutoFill.call("return globalThis.__pbPasswords ? globalThis.__pbPasswords.submitted() : null;",
                              in: frame, of: host.webView) { [weak self] value in
            once.run()
            guard let self, let fields = value as? [String: Any], let password = fields["password"] as? String else { return }
            self.offerToSave(username: fields["username"] as? String ?? "", password: password, at: origin, explicit: false)
        }
    }

    /// Asks whether to save (or update) a password typed on `origin`. Not when AutoFill is off or the
    /// site is in the never list, unless the user asked (`explicit`, the toolbar).
    func offerToSave(username typedUsername: String, password: String, at origin: WebOrigin, explicit: Bool) {
        guard let host, !password.isEmpty else { return }
        if !explicit {
            guard settings.autoFill, !settings.isNeverSaved(origin) else { return }
        }
        var username = typedUsername
        if username.isEmpty, let step = pendingUsername, step.site == origin.site, Date().timeIntervalSince(step.at) < 600 {
            username = step.username
        }
        let key = [origin.serialized, username, password].joined(separator: "\u{0}")
        if !explicit {
            guard !asked.contains(key) else { return }
            asked.insert(key)
        }

        let decision = vault.saveDecision(username: username, password: password, at: origin)
        let record: PasswordPromptRecord
        switch decision {
        case .alreadySaved:
            if explicit { host.showMessage(L("pw.alreadySaved")) }
            return
        case .save:
            record = PasswordPromptRecord(kind: .save, username: username, host: origin.host)
        case let .update(entry):
            record = PasswordPromptRecord(kind: .update, username: username, host: WebOrigin(entry.origin)?.host ?? origin.host)
        }
        let apply: (PasswordPromptAnswer) -> Void = { [weak self] answer in
            guard let self else { return }
            do {
                switch (answer, decision) {
                case (.save, .update(var entry)):
                    entry.password = password
                    try self.vault.update(entry)
                case (.save, _):
                    try self.vault.upsert(PasswordEntry(origin: origin.serialized, username: username, password: password))
                case (.never, _):
                    try self.settings.neverSave(origin)
                case (.notNow, _):
                    break
                }
                if answer == .save { self.pendingUsername = nil }
            } catch {
                self.host?.showMessage(String(format: L("pw.couldNotSave"), error.localizedDescription))
            }
        }
        if let answer = Self.testAnswer {
            Self.testPrompts.append(record)
            apply(answer(record))
            return
        }
        host.presentAlert(Self.alert(for: record, profileName: settings.profileName)) { response in
            switch (record.kind, response) {
            case (_, .alertFirstButtonReturn): apply(.save)
            case (.save, .alertThirdButtonReturn): apply(.never)
            default: apply(.notNow)
            }
        }
    }

    /// Safari's wording: "Do you want to save your password for “site”?" — Save Password (default) /
    /// Not Now / Never for This Website; "Do you want to update the password saved for “user” on
    /// “site”?" — Update Password / Not Now.
    private static func alert(for record: PasswordPromptRecord, profileName: String) -> NSAlert {
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        let user = record.username.isEmpty ? L("passwords.noUsername") : record.username
        switch record.kind {
        case .save:
            alert.messageText = String(format: L("pw.save.title"), record.host)
            alert.informativeText = String(format: L("pw.save.message"), user, profileName)
            alert.addButton(withTitle: L("pw.save.button"))
            alert.addButton(withTitle: L("pw.notNow"))
            alert.addButton(withTitle: L("pw.never"))
        case .update:
            alert.messageText = String(format: L("pw.update.title"), user, record.host)
            alert.informativeText = String(format: L("pw.update.message"), profileName)
            alert.addButton(withTitle: L("pw.update.button"))
            alert.addButton(withTitle: L("pw.notNow"))
        }
        return alert
    }
}

/// Runs its action the first time `run()` is called.
@MainActor
private final class Once {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}

/// A profile's AutoFill settings as they are now (the editor and the password manager change them
/// while the profile runs), and the "Never for This Website" list.
@MainActor
final class ProfilePasswordSettings {
    let profileName: String
    private let profileID: UUID
    private let repository: ProfileRepository
    private let launchConfiguration: ProfileConfiguration
    /// Opens the profile's password manager ("Passwords…" in the suggestions); nil where there is none.
    var showManager: (() -> Void)?

    init(repository: ProfileRepository, profileID: UUID, profileName: String, launchConfiguration: ProfileConfiguration) {
        self.repository = repository
        self.profileID = profileID
        self.profileName = profileName
        self.launchConfiguration = launchConfiguration
    }

    private var current: ProfileConfiguration {
        (try? repository.loadConfiguration(profileID)) ?? launchConfiguration
    }

    var autoFill: Bool { current.passwordAutoFill }

    func isNeverSaved(_ origin: WebOrigin) -> Bool {
        PasswordMatching.isNeverSaved(origin, sites: current.passwordNeverSaveSites)
    }

    func neverSave(_ origin: WebOrigin) throws {
        var configuration = try repository.loadConfiguration(profileID)
        guard !PasswordMatching.isNeverSaved(origin, sites: configuration.passwordNeverSaveSites) else { return }
        configuration.passwordNeverSaveSites.append(origin.serialized)
        configuration.settingsModifiedAt = Date()
        try repository.saveConfiguration(configuration, for: profileID)
    }
}

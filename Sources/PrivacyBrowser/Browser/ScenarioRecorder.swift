import AppKit
import BrowserCore
import os
import WebKit

/// A scenario recorded from what a person does in a profile's window (docs/AUTOMATION.md,
/// "Recording"): the page's side (`ScenarioRecorderScript`, a world of its own) says each click,
/// each field's text and each Enter with a selector, and each page that loads; this side hands
/// them on as they come — to the app's process, through the profile's channel when the window is
/// in a process of its own — where `ScenarioRecording` makes the scenario's steps of them.
///
/// Nothing of it is in a profile's pages until the first recording there: the script and its
/// handler are added to the profile's content controllers then, and stay — idle, a page's script
/// asks at its start whether a recording is on and is told no.
@MainActor
final class ScenarioRecorder: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "pbRecorder"
    static let world = WKContentWorld.world(name: "PrivacyBrowser.Recorder")
    static let script = WKUserScript(source: ScenarioRecorderScript.source(handlerName: handlerName),
                                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)

    private(set) var isRecording = false
    /// The script and handler are in the profile's content controllers (`BrowserSession.startRecording`).
    private(set) var isInstalled = false
    /// What a page said: it loaded an address, or the person did something on it.
    enum Event: Codable, Equatable {
        case loaded(String)
        case acted(RecordedStep)
    }

    var onEvent: ((Event) -> Void)?
    /// The page that was in front when the recording began, when it had an address of the web:
    /// that address is the recording's first step.
    private weak var frontPage: WKWebView?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ScenarioRecorder")

    func install(in controller: WKUserContentController) {
        isInstalled = true
        if !controller.userScripts.contains(where: { $0.source == Self.script.source }) { controller.addUserScript(Self.script) }
        // A handler of this name twice in one controller is an exception: taken out first.
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// A page a person looks at and acts in: in a window that is shown — not the warm-up's, which
    /// is in front fully transparent (`BrowserSession.openOffscreenWindow`) — and not the page the
    /// profile's check measures with, whose address lives only while a snapshot is taken.
    private static func isSeen(_ page: WKWebView?) -> Bool {
        guard let page, let window = page.window, window.isVisible, window.alphaValue > 0 else { return false }
        return page.url.map(SiteSnapshotPage.isMeasuringPage) != true
    }

    /// Begins: the page in front is the recording's first step, and every page shown now is told
    /// to watch (one that has no script yet — it loaded before the first recording — gets it).
    func start(pages: [WKWebView]) {
        isRecording = true
        let shown = pages.filter { Self.isSeen($0) }
        let front = shown.first { $0.window == NSApp.mainWindow } ?? shown.first { $0.window == NSApp.keyWindow } ?? shown.first
        // Only an address of the web begins a recording (`ScenarioRecording.loaded`).
        let scheme = front?.url?.scheme?.lowercased()
        frontPage = scheme == "http" || scheme == "https" ? front : nil
        if let address = front?.url?.absoluteString { onEvent?(.loaded(address)) }
        // A page given the script here says so in its hello (`late`): it was open, it did not load.
        let source = "if (globalThis.__pbRecorder) { globalThis.__pbRecorder.set(true); } else {\n"
            + "globalThis.__pbRecorderLate = true;\n\(Self.script.source)\n}"
        for page in shown {
            page.callAsyncJavaScript(source, arguments: [:], in: nil, in: Self.world) { _ in }
        }
        log.notice("A scenario's recording began on \(shown.count, privacy: .public) pages")
    }

    func stop(pages: [WKWebView]) {
        guard isRecording else { return }
        isRecording = false
        for page in pages {
            page.callAsyncJavaScript("if (globalThis.__pbRecorder) { globalThis.__pbRecorder.set(false); }", arguments: [:],
                                     in: nil, in: Self.world) { _ in }
        }
        log.notice("A scenario's recording ended")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.world == Self.world, message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            replyHandler(nil, nil)
            return
        }
        // A page in no window a person sees (a tab behind, a page Safari loads for itself) is not
        // what they are doing.
        let shown = Self.isSeen(message.webView)
        if type == "hello" {
            replyHandler(["recording": isRecording && shown], nil)
            // A page that was open when the recording began has not loaded: with a first page
            // already, only that one's hello counts — another window's would be a second opening
            // step, and what was done in the first replayed on it.
            let late = body["late"] as? Bool == true
            if isRecording, shown, !late || frontPage == nil || message.webView === frontPage, let address = body["url"] as? String {
                onEvent?(.loaded(address))
            }
            return
        }
        replyHandler(nil, nil)
        guard isRecording, shown, let kind = RecordedStep.Kind(rawValue: type), kind != .goto, kind != .load else { return }
        // A password's text never leaves the page's process, whatever the page's side sent.
        let secret = body["secret"] as? Bool == true
        onEvent?(.acted(RecordedStep(kind, selector: body["selector"] as? String, value: secret ? nil : body["value"] as? String,
                                     secret: secret ? true : nil, replaces: body["replaces"] as? Bool == true ? true : nil)))
    }
}

import AppKit
import MachO
import WebKit

/// WebKit's behaviors that follow the SDK an app was built with, set as WebKit sets them for Safari.
///
/// WebKit turns some of its features on for an app only when the app's executable declares a recent
/// enough SDK (`linkedOnOrAfterSDKWithBehavior`: the network loader Safari uses, Trusted Types by
/// default, `user-select` superseding `-webkit-user-select`, and more), and for Safari always: WTF's
/// `computeSDKAlignedBehaviors` returns every behavior when the process is Safari. SwiftPM writes the
/// platform of Package.swift into the executable as its SDK ("sdk 14.0" on the owner's build with
/// Xcode 27.1), so every behavior gated after macOS 14 was off in every page — on the owner's Mac with
/// macOS 27, `window.trustedTypes`, which Safari 27 has and a profile did not. `+[WKProcessPool
/// _setLinkedOnOrAfterEverything]` is WebKit's own switch for this, made for Safari (WTF: "This can be
/// removed once Safari calls _setLinkedOnOrAfterEverything everywhere"): every behavior on, as in
/// Safari, whatever SDK this app was built with. WebKit hands the set to every process it starts
/// (`client-sdk-aligned-behaviors`), and reads it as preferences are made, so it is set first thing,
/// before any web view or web process exists (main.swift). WebKit's own code and Safari's real state:
/// the parity rule's first two points (docs/ISOLATION_AND_LIMITATIONS.md §2).
enum SDKBehaviors {
    /// Whether `matchSafari` turned every behavior on in this process (the self-test checks it).
    private(set) static var matched = false

    /// Every SDK-aligned behavior on, as in Safari. False when this WebKit has no such switch.
    @discardableResult
    static func matchSafari() -> Bool {
        let selector = NSSelectorFromString("_setLinkedOnOrAfterEverything")
        let pool: AnyObject = WKProcessPool.self
        guard pool.responds(to: selector) else { return false }
        _ = pool.perform(selector)
        matched = true
        return true
    }

    /// The SDK this executable was built with ("26.0"), from its `LC_BUILD_VERSION` load command, as
    /// dyld and WebKit read it; nil when it has none.
    static var linkedSDK: String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let image = UnsafeRawPointer(header)
        guard image.loadUnaligned(as: UInt32.self) == MH_MAGIC_64 else { return nil }
        let count = image.loadUnaligned(fromByteOffset: 16, as: UInt32.self) // ncmds
        var command = image.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<count {
            let kind = command.loadUnaligned(as: UInt32.self)
            let size = command.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            if kind == UInt32(LC_BUILD_VERSION) {
                // build_version_command: cmd, cmdsize, platform, minos, sdk (xxxx.yy.zz in nibbles).
                let sdk = command.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
                return "\(sdk >> 16).\((sdk >> 8) & 0xff)"
            }
            guard size > 0 else { return nil }
            command = command.advanced(by: Int(size))
        }
        return nil
    }
}

/// `PrivacyBrowser --sdk-check [--everything]`: what a page sees, and what the screen is, in a
/// process of this build — with WebKit's behaviors as the SDK this executable declares gives them,
/// or, with `--everything`, as Safari has them (`SDKBehaviors.matchSafari`). CI runs it on the app
/// as built and on a copy whose executable declares another SDK (scripts/sdk_check.sh), so that what
/// follows the SDK shows: `window.trustedTypes` and the window's other interfaces, by name, and the
/// screen's visible frame, which AppKit gives WebKit for `screen.availHeight`. A measurement: a plain
/// web view on a page given as a string, nothing loaded from the network.
@MainActor
enum SDKCheck {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let everything = arguments.contains("--everything")
        if everything {
            print("SDK-CHECK _setLinkedOnOrAfterEverything: \(SDKBehaviors.matchSafari() ? "called" : "not in this WebKit")")
        }
        print("SDK-CHECK built with the macOS \(SDKBehaviors.linkedSDK ?? "?") SDK, on macOS "
              + "\(ProcessInfo.processInfo.operatingSystemVersionString); WebKit's behaviors: \(everything ? "every one, as Safari's" : "this build's")")
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
            print("SDK-CHECK did not finish")
            exit(3)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        if let screen = NSScreen.main {
            let frame = screen.frame, visible = screen.visibleFrame
            print("SDK-CHECK the main screen: \(Int(frame.width))x\(Int(frame.height)); visible frame \(visible.width)x\(visible.height) "
                  + "from y \(visible.minY); the menu bar's thickness \(NSStatusBar.system.thickness); safe area top \(screen.safeAreaInsets.top)")
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        window.contentView = webView
        window.orderFrontRegardless()
        let loaded = SDKCheckPage()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<!doctype html><title>SDK check</title><p id=p>x</p>", baseURL: URL(string: "https://example.com/"))
        withExtendedLifetime((window, loaded)) { application.run() }
        exit(0)
    }
}

/// Asks the page, once it has loaded, what it sees, prints it, and ends the process.
private final class SDKCheckPage: NSObject, WKNavigationDelegate {
    private let script = """
        (() => {
          const p = document.getElementById('p');
          p.style.webkitUserSelect = 'none';
          const style = getComputedStyle(p);
          return JSON.stringify({
            trustedTypes: typeof trustedTypes,
            DigitalCredential: typeof DigitalCredential,
            MediaSessionCoordinator: typeof MediaSessionCoordinator,
            windowOwnProperties: Object.getOwnPropertyNames(window).length,
            screen: [screen.width, screen.height, screen.availWidth, screen.availHeight].join('x'),
            userSelectAfterWebkitUserSelectNone: style.userSelect + ' / ' + style.webkitUserSelect
          });
        })()
        """
    /// The window's own properties by name, for scripts/sdk_check.sh to tell the builds apart.
    private let names = "Object.getOwnPropertyNames(window).sort().join(',')"

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script) { [names] result, error in
            print("SDK-CHECK the page: \((result as? String) ?? "no answer: \(error.map { String(describing: $0) } ?? "nil")")")
            webView.evaluateJavaScript(names) { result, _ in
                print("SDK-CHECK window names: \((result as? String) ?? "")")
                exit(0)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("SDK-CHECK the page failed: \(error)")
        exit(1)
    }
}

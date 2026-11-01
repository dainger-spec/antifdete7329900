import AppKit
import ObjCExceptions
import SwiftUI
import WebKit

/// A MEASUREMENT on the branch claude/measure-pill, not for the product. The owner, 1 November: a
/// pill with the profile's flag and name in a profile's window, by the window's buttons, so that
/// among thirty profiles one sees which this is — "if it is costly or unreliable, say so".
///
/// `Lumen --titlebar-probe <folder>`: Safari's window in a process like a profile's
/// (`SafariChrome.prepareForCheck`: a home of its own, held to a closed proxy), and a pill put into
/// its title bar the way AppKit offers it to any window — an accessory of the title bar — at its
/// leading side, then at its trailing side; with one tab, with two, and in a narrow window. Each
/// time: where the window's buttons are, what Safari's own bar shows there and where, what of it
/// the pill covers, the size of the page (`innerWidth` × `innerHeight`, what a site sees) and of
/// its web view, the exceptions thrown, and a picture of the title bar (`titlebar-<step>.png`).
/// `TITLEBAR` lines; exit 0 when every step ran.
@MainActor
enum TitlebarProbe {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--titlebar-probe"), arguments.indices.contains(index + 1) else {
            print("usage: Lumen --titlebar-probe <folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        guard SafariChrome.prepareForCheck(arguments: arguments) else {
            print("TITLEBAR Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ExceptionLog.onCaughtInRunLoop = { exception, _ in
            print("TITLEBAR threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
        }
        // A step that waits for ever must not keep CI waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 100) {
            print("TITLEBAR did not finish")
            exit(3)
        }
        _ = SafariChrome.installMainMenu()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let controller = SafariChrome.openWindow(address: URL(string: "about:blank"))
                controller?.showWindow(nil)
                controller?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                guard let window = controller?.window else {
                    print("TITLEBAR Safari's window did not open")
                    SafariChrome.removeCheckHome()
                    exit(1)
                }
                print("TITLEBAR Safari's window is open")
                Task { @MainActor in
                    await probe(window, into: folder)
                    print("TITLEBAR exceptions: \(ExceptionLog.reported)")
                    SafariChrome.removeCheckHome()
                    exit(0)
                }
            }
        }
        application.run()
        exit(0)
    }

    private static func probe(_ window: NSWindow, into folder: URL) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let width = window.frame.width
        print("TITLEBAR macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version); "
              + "window \(Int(window.frame.width))×\(Int(window.frame.height)), title bar and toolbar \(Int(band(of: window).height)) pt; "
              + "toolbar \(window.toolbar?.identifier ?? "none"), style \(window.toolbarStyle.rawValue), "
              + "items \(window.toolbar?.items.map(\.itemIdentifier.rawValue).joined(separator: ", ") ?? "-")")
        let one = await look(window, "one-tab", into: folder, pill: nil, against: nil)

        let leading = pill(.leading)
        guard add(leading, to: window, "leading") else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await look(window, "leading", into: folder, pill: leading.view, against: one)
        remove(leading, from: window)

        let trailing = pill(.trailing)
        guard add(trailing, to: window, "trailing") else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await look(window, "trailing", into: folder, pill: trailing.view, against: one)
        remove(trailing, from: window)
        try? await Task.sleep(nanoseconds: 800_000_000)
        _ = await look(window, "one-tab-again", into: folder, pill: nil, against: one)

        // Two tabs: Safari's own tab bar comes in.
        let opened = NSApp.sendAction(NSSelectorFromString("newTab:"), to: nil, from: nil)
        print("TITLEBAR a second tab \(opened ? "asked for" : "could not be asked for")")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let two = await look(window, "two-tabs", into: folder, pill: nil, against: nil)
        let again = pill(.leading)
        guard add(again, to: window, "leading, with two tabs") else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await look(window, "two-tabs-leading", into: folder, pill: again.view, against: two)

        // A narrow window: where the pill goes when the bar is short of room.
        var frame = window.frame
        frame.size.width = 760
        window.setFrame(frame, display: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await look(window, "narrow-leading", into: folder, pill: again.view, against: nil)
        frame.size.width = width
        window.setFrame(frame, display: true)
        remove(again, from: window)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = await look(window, "two-tabs-again", into: folder, pill: nil, against: two)
    }

    /// The pill as the product would draw it: the flag, the profile's name, in a capsule.
    private struct Pill: View {
        var body: some View {
            HStack(spacing: 6) {
                Text(verbatim: "🇩🇪") // l10n: not text
                Text(verbatim: "Northwind") // l10n: not text
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 6)
        }
    }

    private static func pill(_ layout: NSLayoutConstraint.Attribute) -> NSTitlebarAccessoryViewController {
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = layout
        let host = NSHostingView(rootView: Pill())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        controller.view = host
        return controller
    }

    /// Adds the pill; an exception AppKit or Safari throws for it is said, and ends the probe.
    private static func add(_ controller: NSTitlebarAccessoryViewController, to window: NSWindow, _ side: String) -> Bool {
        if let exception = PBCatchException({ window.addTitlebarAccessoryViewController(controller) }) {
            print("TITLEBAR adding the pill (\(side)) threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
            return false
        }
        return true
    }

    private static func remove(_ controller: NSTitlebarAccessoryViewController, from window: NSWindow) {
        guard let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === controller }) else {
            print("TITLEBAR the pill was no longer among the window's accessories")
            return
        }
        if let exception = PBCatchException({ window.removeTitlebarAccessoryViewController(at: index) }) {
            print("TITLEBAR removing the pill threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
        }
    }

    /// The title bar and toolbar, in the window's coordinates: above the content's layout rect.
    private static func band(of window: NSWindow) -> NSRect {
        let top = window.contentLayoutRect.maxY
        return NSRect(x: 0, y: top, width: window.frame.width, height: max(0, window.frame.height - top))
    }

    private static func said(_ rect: NSRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    /// What one step shows; the page's size, for the next steps to compare with.
    private static func look(_ window: NSWindow, _ step: String, into folder: URL, pill: NSView?, against: String?) async -> String {
        let exceptions = ExceptionLog.reported
        let bar = band(of: window)
        let buttons: [(String, NSWindow.ButtonType)] = [("close", .closeButton), ("minimize", .miniaturizeButton), ("zoom", .zoomButton)]
        let buttonRects = buttons.compactMap { name, type in
            window.standardWindowButton(type).map { (name, $0.convert($0.bounds, to: nil)) }
        }
        print("TITLEBAR \(step) buttons: " + buttonRects.map { "\($0.0) \(said($0.1))" }.joined(separator: "; "))
        print("TITLEBAR \(step) accessories: " + window.titlebarAccessoryViewControllers.map {
            "\(NSStringFromClass(type(of: $0))) (\($0.layoutAttribute.rawValue)) \(said($0.view.convert($0.view.bounds, to: nil)))"
        }.joined(separator: "; "))
        // Safari's bar: the views drawn in the band that are not containers of others, by place.
        var views: [(name: String, rect: NSRect, view: NSView)] = []
        func walk(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.01 else { return }
            if let pill, view.isDescendant(of: pill) { return }
            let rect = view.convert(view.bounds, to: nil)
            if rect.intersects(bar), rect.width > 2, rect.height > 2, rect.width < bar.width * 0.8,
               view is NSControl || view is NSImageView || view.subviews.isEmpty {
                views.append((NSStringFromClass(type(of: view)), rect, view))
            }
            view.subviews.forEach(walk)
        }
        if let frameView = window.contentView?.superview { walk(frameView) }
        views.sort { $0.rect.minX < $1.rect.minX }
        print("TITLEBAR \(step) bar: \(views.count) views — " + views.prefix(60).map { "\($0.name) \(said($0.rect))" }.joined(separator: "; "))
        if let pill {
            let rect = pill.convert(pill.bounds, to: nil)
            // What the pill lies over, its own containers apart.
            let covered = views.filter { entry in
                let overlap = entry.rect.intersection(rect)
                return !overlap.isNull && overlap.width * overlap.height > 4 && !pill.isDescendant(of: entry.view)
            }
            let zoom = buttonRects.first { $0.0 == "zoom" }?.1
            print("TITLEBAR \(step) pill: \(said(rect)), in the bar \(bar.contains(rect) ? "wholly" : bar.intersects(rect) ? "partly" : "not at all"), "
                  + (zoom.map { "\(Int(rect.minX - $0.maxX)) pt after the zoom button, " } ?? "")
                  + "covers \(covered.isEmpty ? "nothing of Safari's" : covered.map { "\($0.name) \(said($0.rect))" }.joined(separator: "; "))")
        }
        let page = await pageSize(window)
        let compared = against.map { $0 == page ? " — the same as without the pill" : " — CHANGED from \($0)" } ?? ""
        print("TITLEBAR \(step) page: \(page)\(compared)")
        picture(window, "titlebar-\(step)", into: folder)
        let thrown = ExceptionLog.reported - exceptions
        if thrown > 0 { print("TITLEBAR \(step) exceptions during the step: \(thrown)") }
        return page
    }

    /// `innerWidth × innerHeight` of the page in front, and its web view's frame in the window.
    private static func pageSize(_ window: NSWindow) async -> String {
        var webViews: [WKWebView] = []
        func collect(_ view: NSView) {
            if let webView = view as? WKWebView, !webView.isHiddenOrHasHiddenAncestor { webViews.append(webView) }
            view.subviews.forEach(collect)
        }
        if let content = window.contentView { collect(content) }
        guard let webView = webViews.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            return "no web view"
        }
        let value = try? await webView.evaluateJavaScript("[innerWidth, innerHeight].join('×')")
        return "\(value as? String ?? "?") in a web view of \(said(webView.convert(webView.bounds, to: nil)))"
    }

    /// The title bar and toolbar, and a little of the page under them.
    private static func picture(_ window: NSWindow, _ name: String, into folder: URL) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        let height = min(frameView.bounds.height, band(of: window).height + 40)
        let rect = frameView.isFlipped
            ? NSRect(x: 0, y: 0, width: frameView.bounds.width, height: height)
            : NSRect(x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: rect) else {
            print("TITLEBAR no picture for \(name)")
            return
        }
        frameView.cacheDisplay(in: rect, to: rep)
        if let data = rep.representation(using: .png, properties: [:]),
           (try? data.write(to: folder.appendingPathComponent("\(name).png"))) != nil {
            print("WROTE \(name).png (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } else {
            print("TITLEBAR could not write \(name).png")
        }
    }
}

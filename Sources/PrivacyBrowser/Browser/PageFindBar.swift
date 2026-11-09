import AppKit
import WebKit

/// Find on the page in this app's window: a bar over the page's top edge, searching with WebKit's
/// public `WKWebView.find(_:configuration:)` (the match is selected and scrolled to, as Safari does).
/// AppKit's NSTextFinder bar never showed in a web view of ours, and its actions raised
/// NSInvalidArgumentException (CI 762, an iPhone view's window: ⌘F from the menu, no bar).
@MainActor
final class PageFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let webView: () -> WKWebView?
    /// What the last search found, for the window's audit: nil before any.
    private(set) var lastFound: Bool?

    init(webView: @escaping () -> WKWebView?) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityIdentifier("page-find-bar")
        field.placeholderString = L("find.placeholder")
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.setAccessibilityIdentifier("page-find-field")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("menu.findPrevious")) ?? NSImage(),
                                target: self, action: #selector(findPrevious))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("menu.findNext")) ?? NSImage(),
                            target: self, action: #selector(findNext))
        let done = NSButton(title: L("find.done"), target: self, action: #selector(close))
        for button in [previous, next] { button.isBordered = false }
        done.isBordered = false
        done.contentTintColor = .controlAccentColor
        done.setAccessibilityIdentifier("page-find-done")
        let row = NSStackView(views: [field, status, previous, next, done])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// ⌘F: the bar, its field focused with what it held selected.
    func show() {
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc func close() {
        isHidden = true
        status.stringValue = ""
        if let webView = webView() { window?.makeFirstResponder(webView) }
    }

    @objc func findNext() { search(backwards: false) }
    @objc func findPrevious() { search(backwards: true) }

    /// ⌘G and ⇧⌘G: the next or the previous match of what the field holds; with nothing to find,
    /// the bar opens for it.
    func search(backwards: Bool) {
        guard let webView = webView() else { return }
        guard !field.stringValue.isEmpty else { show(); return }
        isHidden = false
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(field.stringValue, configuration: configuration) { [weak self] result in
            self?.lastFound = result.matchFound
            self?.status.stringValue = result.matchFound ? "" : L("find.notFound")
        }
    }

    /// ⌘E: the page's selection becomes what is found.
    func useSelection() {
        guard let webView = webView() else { return }
        webView.evaluateJavaScript("String(getSelection())") { [weak self] value, _ in
            guard let self, let text = value as? String, !text.isEmpty else { return }
            self.field.stringValue = text
            self.isHidden = false
        }
    }

    func controlTextDidChange(_ notification: Notification) { search(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            search(backwards: NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

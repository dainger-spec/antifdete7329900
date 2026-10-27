import AppKit

/// The address field: Lumen's dark rounded box, drawn by the field itself rather than a system
/// bezel (which macOS 26 turns into glass), its text centred in the box, and an accent edge
/// while it is being edited. Otherwise a plain `NSTextField`: the window controller is its
/// delegate and target as before.
final class AddressBarField: NSTextField {
    override class var cellClass: AnyClass? {
        get { AddressBarFieldCell.self }
        set {}
    }

    private var isEditingText = false {
        didSet { if isEditingText != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        textColor = Theme.NS.textPrimary
        cell?.isScrollable = true
        cell?.wraps = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Theme.NS.field.setFill()
        box.fill()
        (isEditingText ? Theme.NS.accent : Theme.NS.fieldBorder).setStroke()
        box.lineWidth = 1
        box.stroke()
        super.draw(dirtyRect)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { isEditingText = true }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditingText = false
    }
}

/// Insets the text from the box's sides and centres its line vertically: for drawing, and for
/// the field editor, which AppKit places from the frame `edit`/`select` get (not from
/// `drawingRect`), so those get the text's rect directly.
final class AddressBarFieldCell: NSTextFieldCell {
    private static let inset: CGFloat = 10
    private var isPlacingEditor = false

    /// One line, inset from the sides, in the middle of `rect`.
    private func textRect(_ rect: NSRect) -> NSRect {
        let font = self.font ?? .systemFont(ofSize: 13)
        let inner = rect.insetBy(dx: Self.inset, dy: 0)
        let height = min(inner.height, ceil(font.ascender - font.descender + font.leading))
        return NSRect(x: inner.minX, y: inner.minY + ((inner.height - height) / 2).rounded(.down),
                      width: inner.width, height: height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let drawing = super.drawingRect(forBounds: rect)
        return isPlacingEditor ? drawing : textRect(drawing)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        isPlacingEditor = true
        defer { isPlacingEditor = false }
        super.edit(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        isPlacingEditor = true
        defer { isPlacingEditor = false }
        super.select(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

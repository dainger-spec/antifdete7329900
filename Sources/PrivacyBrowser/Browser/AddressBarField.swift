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

/// Insets the text from the box's sides and centres its line vertically, for drawing and for
/// the field editor alike.
final class AddressBarFieldCell: NSTextFieldCell {
    private static let inset: CGFloat = 10

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let inner = rect.insetBy(dx: Self.inset, dy: 0)
        var drawing = super.drawingRect(forBounds: inner)
        let slack = drawing.height - cellSize(forBounds: inner).height
        if slack > 0 {
            drawing.size.height -= slack
            drawing.origin.y += (slack / 2).rounded(.down)
        }
        return drawing
    }
}

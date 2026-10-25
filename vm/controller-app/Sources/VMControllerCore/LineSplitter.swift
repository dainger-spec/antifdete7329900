import Foundation

/// Turns a byte stream into display lines.
///
/// Splits on `\n` and `\r` (progress bars redraw with `\r`) and drops terminal
/// escape sequences: `tart` writes its pull progress with ANSI cursor moves even
/// when its output is a pipe. Escape state is kept across chunks, so a sequence
/// split between two reads is still removed. Blank lines are dropped.
public struct LineSplitter: Sendable {
    public static let maxLineBytes = 16 * 1024

    private enum State: Sendable { case text, escape, csi, osc, oscEscape }

    private var state = State.text
    private var current: [UInt8] = []

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            switch state {
            case .text:
                switch byte {
                case 0x1B: state = .escape
                case 0x0A, 0x0D: flush(into: &lines)
                case 0x08: if !current.isEmpty { current.removeLast() }
                case 0x09, 0x20...: // tab, printable, and UTF-8 continuation bytes
                    current.append(byte)
                    if current.count >= Self.maxLineBytes { flush(into: &lines) }
                default: break // other control characters
                }
            case .escape:
                switch byte {
                case 0x5B: state = .csi // ESC [
                case 0x5D: state = .osc // ESC ]
                default: state = .text  // two-byte sequence, e.g. ESC 7
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .text }
            case .osc:
                if byte == 0x07 { state = .text } else if byte == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            }
        }
        return lines
    }

    /// Emits whatever is left once the stream has ended.
    public mutating func finish() -> [String] {
        var lines: [String] = []
        flush(into: &lines)
        state = .text
        return lines
    }

    private mutating func flush(into lines: inout [String]) {
        defer { current.removeAll(keepingCapacity: true) }
        let text = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { lines.append(text) }
    }
}

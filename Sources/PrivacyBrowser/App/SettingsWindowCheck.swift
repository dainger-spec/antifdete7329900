import AppKit
import ImageIO
import SwiftUI

/// `--settings-window-check <folder> [--control]`: the Settings window as the person gets it. The real
/// app starts (in a temporary vault: PRIVACYBROWSER_VAULT_DIR must name one), Settings is opened the
/// way ⌘, opens it — the app menu's Settings… item, `AppModel.openSettingsWindow` — and the window
/// SwiftUI's Settings scene made is captured by the window server (`screencapture -l`: what is on the
/// screen, with whatever the system draws in the title bar and a toolbar). Then the picture is read
/// row by row, top to bottom, in the sidebar and in the page: a run of rows whose tone is none of
/// the design's is a band, and fails the check, by where it is and its colour.
///
/// Why (the owner, 2 November): after 246a900 the Settings window still had a grey band at its top
/// while the UI snapshots were green. Those host SettingsView in a window of their own and draw it
/// with `cacheDisplay`: that is not the Settings scene's window, and it draws none of what the window
/// server adds over the content. Their edge check looks for the window's own background showing
/// where the content does not reach; a band of a toolbar's system tone is not that, so it could not
/// see one at all.
///
/// The picture is kept in the folder (settings-window.png), with the screen around it (screen.png).
@MainActor
enum SettingsWindowCheck {
    /// Set from the command line (main.swift) before the app starts.
    static var folder: URL?
    /// `--control`: the same window with the fix taken back (`breaksTheFix`); the check must fail.
    static var control = false

    /// Read by the Settings scene: true only in the control's run.
    static var breaksTheFix: Bool { folder != nil && control }

    /// Called at the end of the app's launch (AppDelegate) when the check was asked for.
    static func start() {
        guard let folder else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in exit(await run(folder: folder)) }
    }

    private static func run(folder: URL) async -> Int32 {
        print("SETTINGS-WINDOW macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
              + "; this Mac's appearance \(NSApp.effectiveAppearance.name.rawValue)"
              + (control ? "; the control: the fix taken back" : ""))
        guard ProcessInfo.processInfo.environment["PRIVACYBROWSER_VAULT_DIR"].map({ !$0.isEmpty }) == true else {
            print("FAIL the check runs the whole app: PRIVACYBROWSER_VAULT_DIR must name a temporary vault")
            return 2
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The app's scenes and its menu first (SwiftUI makes the Settings… item with the scene).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        AppModel.openSettingsWindow()
        var opened: [NSWindow] = []
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            opened = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            if !opened.isEmpty { break }
        }
        for window in NSApp.windows {
            print("SETTINGS-WINDOW window \(window.windowNumber) \(type(of: window)) id=\(window.identifier?.rawValue ?? "-")"
                  + " visible=\(window.isVisible) new=\(!before.contains(ObjectIdentifier(window))) frame=\(window.frame)")
        }
        guard let window = opened.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            print("FAIL no window opened from the app menu's Settings… item")
            return 1
        }
        // Its opening animation, and SwiftUI's passes after it became key.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for line in describe(window) { print("SETTINGS-WINDOW \(line)") }

        let picture = folder.appendingPathComponent("settings-window.png")
        guard capture(["-x", "-o", "-l", "\(window.windowNumber)", picture.path]),
              let pixels = WindowPicture(contentsOf: picture) else {
            print("FAIL the window server's picture of the window could not be taken or read (\(picture.path))")
            return 1
        }
        _ = capture(["-x", folder.appendingPathComponent("screen.png").path])
        let verdict = Bands.read(pixels, window: window)
        for line in verdict.lines { print("SETTINGS-WINDOW \(line)") }
        if verdict.failures.isEmpty {
            print("PASS the Settings window, as the window server shows it, has no band of a tone that is not the design's")
        }
        for failure in verdict.failures { print("FAIL \(failure)") }
        return verdict.failures.isEmpty ? 0 : 1
    }

    /// `/usr/sbin/screencapture` with these arguments; true when it wrote its file.
    private static func capture(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        do { try process.run() } catch {
            print("SETTINGS-WINDOW screencapture could not start: \(error)")
            return false
        }
        process.waitUntilExit()
        let written = arguments.last.map { FileManager.default.fileExists(atPath: $0) } ?? false
        print("SETTINGS-WINDOW screencapture \(arguments.dropLast().joined(separator: " ")): status \(process.terminationStatus)"
              + (written ? "" : ", no file"))
        return process.terminationStatus == 0 && written
    }

    /// What the window is and what the system put in its title bar: its class, style, toolbar, and
    /// the views of its frame down a few levels (classes, frames, materials).
    private static func describe(_ window: NSWindow) -> [String] {
        var lines = [
            "settings \(window.windowNumber) \(type(of: window)) id=\(window.identifier?.rawValue ?? "-") title=\"\(window.title)\"",
            "frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect) styleMask=0x\(String(window.styleMask.rawValue, radix: 16))"
                + " fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView))",
            "titlebarAppearsTransparent=\(window.titlebarAppearsTransparent) titleVisibility=\(window.titleVisibility.rawValue)"
                + " titlebarSeparatorStyle=\(window.titlebarSeparatorStyle.rawValue) toolbarStyle=\(window.toolbarStyle.rawValue)",
            "appearance=\(window.appearance?.name.rawValue ?? "-") effective=\(window.effectiveAppearance.name.rawValue)"
                + " background=\(hex(window.backgroundColor))",
        ]
        if let toolbar = window.toolbar {
            lines.append("toolbar id=\(toolbar.identifier) visible=\(toolbar.isVisible) displayMode=\(toolbar.displayMode.rawValue)"
                         + " items=\(toolbar.items.map(\.itemIdentifier.rawValue))")
        } else {
            lines.append("toolbar none")
        }
        if let content = window.contentView {
            lines.append("contentView \(type(of: content)) frame=\(content.frame) safeArea=\(content.safeAreaInsets)")
        }
        if let frameView = window.contentView?.superview {
            walk(frameView, depth: 0, into: &lines)
        }
        return lines
    }

    private static func walk(_ view: NSView, depth: Int, into lines: inout [String]) {
        guard depth <= 5, lines.count < 120 else { return }
        var line = String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.convert(view.bounds, to: nil))"
        if view.isHidden { line += " hidden" }
        if view.alphaValue < 1 { line += " alpha=\(view.alphaValue)" }
        if let effect = view as? NSVisualEffectView {
            line += " material=\(effect.material.rawValue) state=\(effect.state.rawValue) blending=\(effect.blendingMode.rawValue)"
        }
        if let colour = view.layer?.backgroundColor, let ns = NSColor(cgColor: colour) { line += " layer=\(hex(ns))" }
        lines.append("view " + line)
        for child in view.subviews.prefix(12) { walk(child, depth: depth + 1, into: &lines) }
    }

    static func hex(_ colour: NSColor) -> String {
        guard let value = Bands.rgb(colour), let srgb = colour.usingColorSpace(.sRGB) else { return "\(colour)" }
        let alpha = srgb.alphaComponent < 1 ? String(format: "@%.2f", Double(srgb.alphaComponent)) : ""
        return String(format: "#%06X", value) + alpha
    }
}

/// A picture's pixels, drawn into sRGB at 8 bits a channel, the top row first.
struct WindowPicture {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// The colour at (x, y) from the top left as 0xRRGGBB; nil where the pixel is not opaque (the
    /// window's rounded corners, its antialiased edge).
    func colour(_ x: Int, _ y: Int) -> UInt32? {
        let index = (y * width + x) * 4
        guard bytes[index + 3] >= 250 else { return nil }
        let red = UInt32(bytes[index]), green = UInt32(bytes[index + 1]), blue = UInt32(bytes[index + 2])
        return red << 16 | green << 8 | blue
    }
}

/// The band reading: each row's most frequent colour, in the sidebar and in the page apart (a band
/// can be in one of them only), compared with the design's tones.
@MainActor
enum Bands {
    struct Verdict {
        var lines: [String] = []
        var failures: [String] = []
    }

    /// Each channel may differ by this much from a design tone: colour matching on the way to the
    /// screen and back moves a channel by one at most (CI's pictures had the design's tones exactly).
    /// At 5, the first version of this check took the title bar's grey for a design tone (CI run 596).
    static let tolerance = 2
    /// The design's tones are cool near-blacks, blue above red by 3 to 6, and stay so under its
    /// translucent whites; the system draws its title bar, toolbars and windows in neutral greys —
    /// #1E1E1E on macOS 26, #262626 on macOS 27, each a few steps from a white over the design's
    /// backdrop (CI run 596). A tone without the cast is not the design's, however near one it is.
    static let coolCast = 2
    /// A run of rows this tall, in points, of a tone that is not the design's, is a band.
    static let bandHeight: CGFloat = 2

    /// The design's tones as they can fill a row: its opaque surfaces, and its translucent whites
    /// over the two backgrounds a row of the Settings window is made of.
    static var designTones: [UInt32] {
        let opaque: [Color] = [Theme.backdrop, Theme.sidebar, Theme.surface, Theme.toolbar, Theme.card, Theme.raised,
                               Theme.raisedInset, Theme.field, Theme.avatarFill, Theme.controlFill, Theme.controlHover]
        let translucent: [Color] = [Theme.divider, Theme.hairline, Theme.fieldBorder, Theme.rowHover, Theme.rowSelected,
                                    Theme.accentTint, Theme.accentTintStrong]
        var tones = opaque.compactMap { rgb(NSColor($0)) }
        for base in [Theme.backdrop, Theme.sidebar] {
            guard let below = rgb(NSColor(base)) else { continue }
            for colour in translucent {
                guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { continue }
                tones.append(over(below, srgb))
            }
        }
        return tones
    }

    static func read(_ picture: WindowPicture, window: NSWindow) -> Verdict {
        var verdict = Verdict()
        let scale = CGFloat(picture.width) / max(window.frame.width, 1)
        verdict.lines.append("picture \(picture.width)×\(picture.height) px, window \(Int(window.frame.width))×\(Int(window.frame.height)) pt,"
                             + " scale \(String(format: "%.2f", scale))")
        guard abs(CGFloat(picture.height) / scale - window.frame.height) <= 2 else {
            verdict.failures.append("the picture is \(picture.width)×\(picture.height) px, not the window's \(window.frame.size) at one scale")
            return verdict
        }
        let px = { (points: CGFloat) in Int((points * scale).rounded()) }
        let edge = px(3)
        let split = px(SettingsView.sidebarWidth)
        let segments: [(name: String, columns: Range<Int>)] = [
            ("sidebar", edge..<max(edge + 1, split - px(1))),
            ("page", min(picture.width - edge - 1, split + px(2))..<(picture.width - edge)),
        ]
        let rows = px(2)..<(picture.height - px(2))
        let tones = designTones
        let minimumBand = max(2, px(bandHeight))

        // Something was drawn: the design's backgrounds fill most rows, and there is text.
        var designRows = 0
        var bright = 0
        for (name, columns) in segments {
            var runs: [(top: Int, bottom: Int, colour: UInt32?, share: Double)] = []
            var band: (top: Int, colour: UInt32?, share: Double)?
            func endBand(at row: Int) {
                guard let open = band else { return }
                band = nil
                guard row - open.top >= minimumBand else { return }
                let colour = open.colour.map { String(format: "#%06X", $0) } ?? "no single tone"
                let place = "from \(points(open.top, scale)) to \(points(row, scale)) pt (\(row - open.top) px)"
                verdict.failures.append("a band in the \(name) \(place): \(colour), \(Int(open.share * 100)) % of the row")
            }
            for row in rows {
                var counts: [UInt32: Int] = [:]
                var opaque = 0
                for x in columns {
                    guard let colour = picture.colour(x, row) else { continue }
                    counts[colour, default: 0] += 1
                    opaque += 1
                    if luminance(colour) > 0x90 { bright += 1 }
                }
                let best = counts.max { $0.value < $1.value }
                let share = best.map { Double($0.value) / Double(max(opaque, 1)) } ?? 0
                let colour = best?.key
                let isDesign = share >= 0.25 && colour.map { matches($0, tones) } == true
                if isDesign { designRows += 1 }
                // The row profile, for the log: runs of one dominant tone.
                if let last = runs.last, let a = last.colour, let b = colour, isNear(a, b, within: 2) {
                    runs[runs.count - 1].bottom = row + 1
                } else {
                    runs.append((row, row + 1, colour, share))
                }
                if isDesign {
                    endBand(at: row)
                } else if band == nil {
                    band = (row, colour, share)
                }
            }
            endBand(at: rows.upperBound)
            var profile: [String] = []
            for run in runs where run.bottom - run.top >= 2 && profile.count < 40 {
                var entry = "\(points(run.top, scale))–\(points(run.bottom, scale)) "
                if let colour = run.colour {
                    entry += String(format: "#%06X", colour)
                    if !matches(colour, tones) { entry += " (not the design's)" }
                } else {
                    entry += "-"
                }
                profile.append(entry)
            }
            verdict.lines.append("\(name) rows: " + profile.joined(separator: ", "))
        }
        let totalRows = rows.count * segments.count
        verdict.lines.append("rows in a design tone \(designRows) of \(totalRows); bright pixels (text) \(bright)")
        if designRows * 10 < totalRows * 8 {
            verdict.failures.append("only \(designRows) of \(totalRows) rows are in a design tone: this is not the Settings window drawn")
        }
        if bright < 200 {
            verdict.failures.append("no text in the picture (\(bright) bright pixels): the window's content was not drawn")
        }
        return verdict
    }

    private static func points(_ pixels: Int, _ scale: CGFloat) -> String {
        String(format: "%.0f", CGFloat(pixels) / scale)
    }

    /// 0xRRGGBB of a colour in sRGB, its alpha left out.
    static func rgb(_ colour: NSColor) -> UInt32? {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }

    /// `colour` (with its alpha) laid over the opaque `below`.
    private static func over(_ below: UInt32, _ colour: NSColor) -> UInt32 {
        let alpha = colour.alphaComponent
        func channel(_ shift: UInt32, _ top: CGFloat) -> UInt32 {
            let under = CGFloat((below >> shift) & 0xFF)
            return UInt32((top * 255 * alpha + under * (1 - alpha)).rounded())
        }
        let red = channel(16, colour.redComponent), green = channel(8, colour.greenComponent), blue = channel(0, colour.blueComponent)
        return red << 16 | green << 8 | blue
    }

    private static func matches(_ colour: UInt32, _ tones: [UInt32]) -> Bool {
        let cast = Int(colour & 0xFF) - Int((colour >> 16) & 0xFF)
        return cast >= coolCast && tones.contains { isNear(colour, $0, within: tolerance) }
    }

    private static func isNear(_ a: UInt32, _ b: UInt32, within limit: Int) -> Bool {
        for shift: UInt32 in [16, 8, 0] where abs(Int((a >> shift) & 0xFF) - Int((b >> shift) & 0xFF)) > limit {
            return false
        }
        return true
    }

    private static func luminance(_ colour: UInt32) -> Int {
        (Int((colour >> 16) & 0xFF) * 3 + Int((colour >> 8) & 0xFF) * 6 + Int(colour & 0xFF)) / 10
    }
}

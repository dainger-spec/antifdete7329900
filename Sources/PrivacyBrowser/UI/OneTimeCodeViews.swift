import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// What a QR code in a picture says. A site that turns two-step sign-in on shows its secret as a
/// QR code holding an `otpauth://` link; the picture comes from a file, from the clipboard (a part
/// of the screen copied with ⌃⇧⌘4) or is dropped in. The screen itself is never captured: that
/// needs the Screen Recording permission, for something the clipboard does as well.
enum QRCodeReader {
    static func payloads(in image: NSImage) -> [String] {
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: picture, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}

/// What a person gave for a one-time code, read: the generator, or why it is not one, in words.
enum OneTimeCodeInput {
    enum Outcome {
        case generator(OneTimeCode)
        case problem(String)
    }

    static func read(_ text: String) -> Outcome {
        do {
            return .generator(try OneTimeCode.parse(text))
        } catch let error as OneTimeCodeError {
            return .problem(message(error))
        } catch {
            return .problem(L("passwords.code.error.notASecret"))
        }
    }

    /// The first QR code of the picture that is a one-time code's; else why none is.
    static func read(_ image: NSImage) -> Outcome {
        let payloads = QRCodeReader.payloads(in: image)
        guard !payloads.isEmpty else { return .problem(L("passwords.code.error.noQR")) }
        var first: Outcome?
        for payload in payloads {
            let outcome = read(payload)
            if case .generator = outcome { return outcome }
            if first == nil { first = outcome }
        }
        return first ?? .problem(L("passwords.code.error.noQR"))
    }

    /// The clipboard: a secret or a link as text, or a picture with the QR code.
    static func readClipboard() -> Outcome {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty, case let .generator(found) = read(text) { return .generator(found) }
        if let image = NSImage(pasteboard: pasteboard) { return read(image) }
        return text.isEmpty ? .problem(L("passwords.code.error.noImage")) : read(text)
    }

    private static func message(_ error: OneTimeCodeError) -> String {
        switch error {
        case .empty: return L("passwords.code.error.empty")
        case .notASecret: return L("passwords.code.error.notASecret")
        case .counterBased: return L("passwords.code.error.counterBased")
        case .severalAccounts: return L("passwords.code.error.severalAccounts")
        case .unsupported: return L("passwords.code.error.unsupported")
        }
    }
}

/// The time a code still stands, as a ring that empties: amber in its last five seconds. With
/// movement reduced the ring steps from second to second.
private struct CodeCountdown: View {
    let left: Int
    let period: Int
    var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let urgent = left <= 5
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(left) / CGFloat(max(period, 1)))
                .stroke(urgent ? Theme.warning : Theme.greenDot, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.isReduced(reduceMotion) ? nil : Animation.linear(duration: 0.9), value: left)
            Text(verbatim: "\(left)")
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(urgent ? Theme.warning : Theme.textSecondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A login's one-time code as it stands now: the code in large digits, the time it has left, and
/// whose it is. The whole card is the Copy button — one click, and it says "Copied".
struct OneTimeCodeCard: View {
    let generator: OneTimeCode
    /// The moment shown, for a picture that must not change (the snapshots); nil: now, every second.
    var at: Date?
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        if let at {
            card(at)
        } else {
            // On the whole second: a tick a fraction of a second late would leave the old code
            // up after it turned over, and a click would copy it.
            TimelineView(.periodic(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), by: 1)) { context in
                card(context.date)
            }
        }
    }

    private func card(_ date: Date) -> some View {
        let code = generator.code(at: date)
        let left = generator.secondsLeft(at: date)
        return Button {
            Self.copy(code)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            HStack(spacing: 14) {
                CodeCountdown(left: left, period: generator.period)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.grouped(code))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                // The texts take the room there is: beside a spacer they were given half of it, and
                // whose code it is was cut short with room to spare.
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                    Text(copied ? L("passwords.code.copied") : L("passwords.copy")).font(.lumenSecondary)
                }
                .foregroundStyle(copied ? Theme.running : (hovered ? Theme.textPrimary : Theme.textSecondary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered ? Theme.rowSelected : Theme.rowHover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.hover(hovered), value: hovered)
        // "Copied" was said of the code that stood then, not of the one that replaced it.
        .onChange(of: code) { _, _ in copied = false }
        .help(L("passwords.code.copyHelp"))
        .accessibilityLabel(L("passwords.code.copyHelp"))
        // The label stands in for the card's content and the ring is hidden: the digits are read
        // one by one as the button's value.
        .accessibilityValue(Text(verbatim: code.map { String($0) }.joined(separator: " ")))
    }

    /// Whose code it is, as the site's link said; else what the code is for.
    private var subtitle: String {
        let named = [generator.issuer, generator.account].compactMap { $0 }.filter { !$0.isEmpty }
        return named.isEmpty ? L("passwords.code.subtitle") : named.joined(separator: " · ")
    }

    /// "123 456", "123 4567", "1234 5678": as authenticators show a code.
    static func grouped(_ code: String) -> String {
        let half = code.count / 2
        return String(code.prefix(half)) + " " + String(code.dropFirst(half))
    }

    /// To the clipboard, marked as concealed like a password (clipboard managers skip it).
    private static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

/// The one-time code's part of a login being edited. With a generator: its code, live, and
/// "Remove". Without: a field for the secret or the link, the clipboard, a picture's file — and a
/// picture dropped anywhere on it. What is typed and not yet added is the caller's to read when
/// the login is saved (`OneTimeCodeInput.read`). Nothing here is kept until the login is saved:
/// a code added and not saved, and a saved code that Save would remove, are both said.
struct OneTimeCodeSetup: View {
    @Binding var generator: OneTimeCode?
    @Binding var input: String
    /// The code the login is saved with (nil: none, or a new login): what Save would change is said.
    var saved: OneTimeCode?
    /// Why Save did not take what is typed (the caller's: `PasswordListView.save`).
    var saveProblem: String?
    /// Opens Help at "One-Time Codes"; nil: no link.
    var onHelp: (() -> Void)?
    @State private var problem: String?
    @State private var dropping = false

    /// What is wrong with what was given: found here, or by the caller's Save.
    private var shownProblem: String? { problem ?? saveProblem }

    var body: some View {
        // The box is where a picture is dropped, so it is drawn only while a code can be added:
        // around a code it would be a third frame, between the login's card and the code's own.
        let open = generator == nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("passwords.code.title"))
                    .font(.lumenSection)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if let onHelp {
                    Button(action: onHelp) { Label(L("passwords.code.help"), systemImage: "book") }
                        .buttonStyle(.lumenGhost)
                }
            }
            if let generator {
                OneTimeCodeCard(generator: generator)
                if generator != saved { pendingNote(L("passwords.code.unsaved")) }
                Button {
                    self.generator = nil
                    problem = nil
                } label: { Label(L("passwords.code.remove"), systemImage: "minus.circle") }
                    .buttonStyle(.lumenGhost)
            } else {
                if let saved {
                    HStack(alignment: .top, spacing: 8) {
                        pendingNote(L("passwords.code.willBeRemoved"))
                        Spacer(minLength: 8)
                        Button(L("passwords.code.restore")) {
                            generator = saved
                            input = ""
                            problem = nil
                        }
                        .buttonStyle(.lumenGhost)
                    }
                }
                HStack(spacing: 8) {
                    TextField(L("passwords.code.placeholder"), text: $input, prompt: Text(verbatim: ""))
                        .lumenField(L("passwords.code.placeholder"), isEmpty: input.isEmpty, error: shownProblem != nil)
                    Button(L("common.add")) { take(OneTimeCodeInput.read(input)) }
                        .buttonStyle(.lumenFieldButton)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                // Under the field it is about, and beside the hint rather than in its place: the
                // instruction is needed most when the attempt failed.
                if let shownProblem {
                    Text(shownProblem)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Button { take(OneTimeCodeInput.readClipboard()) } label: {
                        Label(L("passwords.code.paste"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.lumenGhost)
                    Button(action: chooseFile) { Label(L("passwords.code.qrFile"), systemImage: "qrcode.viewfinder") }
                        .buttonStyle(.lumenGhost)
                }
                Text(L("passwords.code.hint"))
                    .font(.lumenCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(open ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(open && dropping ? Theme.rowSelected : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(open ? (dropping ? Theme.strongBorder : Theme.hairline) : Color.clear,
                          style: StrokeStyle(lineWidth: 1, dash: open && dropping ? [4, 3] : [])))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropping) { providers in
            // Of several things dropped, the one that holds a picture; else the first, which may be a picture's file.
            guard generator == nil,
                  let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) ?? providers.first else { return false }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    let image = object as? NSImage
                    DispatchQueue.main.async {
                        take(image.map { OneTimeCodeInput.read($0) } ?? .problem(L("passwords.code.error.unreadable")))
                    }
                }
            } else {
                // A file dragged from Finder comes as its address alone (as `CookiePaste` takes one).
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    let image = url.flatMap { NSImage(contentsOf: $0) }
                    DispatchQueue.main.async {
                        take(image.map { OneTimeCodeInput.read($0) } ?? .problem(L("passwords.code.error.unreadable")))
                    }
                }
            }
            return true
        }
        .onChange(of: input) { _, _ in problem = nil }
    }

    /// What Save would do to the code and has not done yet, in amber.
    private func pendingNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.lumenSecondary)
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func take(_ outcome: OneTimeCodeInput.Outcome) {
        switch outcome {
        case let .generator(found):
            generator = found
            input = ""
            problem = nil
        case let .problem(message):
            problem = message
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        take(NSImage(contentsOf: url).map { OneTimeCodeInput.read($0) } ?? .problem(L("passwords.code.error.unreadable")))
    }
}

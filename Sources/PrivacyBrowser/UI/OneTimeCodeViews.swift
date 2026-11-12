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

/// The time a code still stands, as a ring that empties: amber in its last five seconds.
private struct CodeCountdown: View {
    let left: Int
    let period: Int
    var size: CGFloat = 34

    var body: some View {
        let urgent = left <= 5
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(left) / CGFloat(max(period, 1)))
                .stroke(urgent ? Theme.warning : Theme.greenDot, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: left)
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
            TimelineView(.periodic(from: .now, by: 1)) { context in card(context.date) }
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
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                    Text(copied ? L("passwords.code.copied") : L("passwords.copy")).font(.lumenSecondary)
                }
                .foregroundStyle(copied ? Theme.greenDot : (hovered ? Theme.textPrimary : Theme.textSecondary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered ? Theme.rowSelected : Theme.rowHover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L("passwords.code.copyHelp"))
        .accessibilityLabel(L("passwords.code.copyHelp"))
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
/// the login is saved (`OneTimeCodeInput.read`).
struct OneTimeCodeSetup: View {
    @Binding var generator: OneTimeCode?
    @Binding var input: String
    @State private var problem: String?
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("passwords.code.title"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
            if let generator {
                OneTimeCodeCard(generator: generator)
                Button {
                    self.generator = nil
                    problem = nil
                } label: { Label(L("passwords.code.remove"), systemImage: "minus.circle") }
                    .buttonStyle(.lumenGhost)
            } else {
                HStack(spacing: 8) {
                    TextField(L("passwords.code.placeholder"), text: $input, prompt: Text(verbatim: ""))
                        .lumenField(L("passwords.code.placeholder"), isEmpty: input.isEmpty, error: problem != nil)
                    Button(L("common.add")) { take(OneTimeCodeInput.read(input)) }
                        .buttonStyle(.lumenSecondary)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 4) {
                    Button { take(OneTimeCodeInput.readClipboard()) } label: {
                        Label(L("passwords.code.paste"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.lumenGhost)
                    Button(action: chooseFile) { Label(L("passwords.code.qrFile"), systemImage: "qrcode.viewfinder") }
                        .buttonStyle(.lumenGhost)
                }
                Text(problem ?? L("passwords.code.hint"))
                    .font(.lumenCaption)
                    .foregroundStyle(problem == nil ? Theme.textTertiary : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dropping ? Theme.rowSelected : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(dropping ? Theme.strongBorder : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: dropping ? [4, 3] : [])))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropping) { providers in
            guard generator == nil, let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) else { return false }
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                let image = object as? NSImage
                DispatchQueue.main.async {
                    take(image.map { OneTimeCodeInput.read($0) } ?? .problem(L("passwords.code.error.unreadable")))
                }
            }
            return true
        }
        .onChange(of: input) { _, _ in problem = nil }
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

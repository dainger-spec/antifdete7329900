import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds proxies to the list from pasted text (or a text file), one per line, in the forms
/// providers hand them out (`ProxyListImport`). What was read is shown as it is typed: how many
/// proxies, and every line that could not be read with its number and why — before anything is
/// added, as the cookie import shows its report.
struct ProxyImportView: View {
    @ObservedObject var proxies: ProxyListModel
    /// The proxies just added (the list selects them, so that checking them is one click).
    var onAdded: ([UUID]) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// The type of lines without a scheme; nil: found by the first check (until then such a
    /// proxy is given to no profile).
    @State private var kind: ProxySettings.Kind?
    @State private var report = ProxyListImport.Report()
    @State private var choosingFile = false
    @State private var error: String?
    @State private var added: ProxyList.AddResult?

    /// What the report is read from: re-read shortly after either changes.
    private struct Input: Equatable {
        var text: String
        var kind: ProxySettings.Kind?
    }

    /// A pasted file larger than this is not a proxy list.
    private static let maximumFileSize = 4 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("proxies.import.title"), subtitle: L("proxies.import.explanation"))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(L("proxies.import.kind"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Picker(L("proxies.import.kind"), selection: $kind) {
                        Text(L("proxies.import.kind.auto")).tag(ProxySettings.Kind?.none)
                        Text(verbatim: "SOCKS5").tag(ProxySettings.Kind?.some(.socks5))
                        Text(verbatim: "HTTP").tag(ProxySettings.Kind?.some(.httpConnect))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                    .help(L("proxies.import.kind.help"))
                    .disabled(added != nil)
                    Spacer(minLength: 12)
                    Button { choosingFile = true } label: { Label(L("proxies.import.chooseFile"), systemImage: "doc") }
                        .buttonStyle(.lumenSecondary)
                        .disabled(added != nil)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Theme.fieldBorder, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: Self.example)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(added != nil)
                if let added {
                    outcome(added)
                } else {
                    reportView
                }
                if let error {
                    Text(error).font(.lumenSecondary).foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter {
                Button(L(added == nil ? "common.cancel" : "common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if added == nil {
                    Button(String(format: L("proxies.import.add"), report.proxies.count), action: add)
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(report.proxies.isEmpty)
                }
            }
        }
        .sheetFrame(width: 680, height: 600)
        .background(Theme.raised)
        // Re-read a moment after the last keystroke: a list of thousands of lines is not taken
        // apart again on every key.
        .task(id: Input(text: text, kind: kind)) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            report = ProxyListImport.read(text, defaultKind: kind)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .text, .data]) { result in
            switch result {
            case let .success(url): read(url)
            case let .failure(failure): error = failure.localizedDescription
            }
        }
    }

    /// Shown in the empty editor: the forms it reads.
    private static let example = """
        1.2.3.4:1080
        1.2.3.4:1080:user:password
        user:password@proxy.example.com:3128
        socks5://user:password@1.2.3.4:1080  # Berlin 1
        """

    // MARK: Report

    private var reportView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.linesRead > 0 {
                Text(String(format: L("proxies.import.summary"), report.proxies.count, report.linesRead))
                    .font(.lumenSection)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                let unknownKinds = report.proxies.filter { !$0.kindGiven }.count
                if unknownKinds > 0 {
                    Text(String(format: L("proxies.import.unknownKinds"), unknownKinds))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.problems.isEmpty {
                Text(String(format: L("proxies.import.problemsTitle"), report.failures.count, report.problems.count - report.failures.count))
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textSecondary)
                List(Array(report.problems.prefix(500).enumerated()), id: \.offset) { _, problem in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(String(format: L("proxies.import.line"), problem.line))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(problem.text)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(problem.reason.words)
                            .font(.caption)
                            .foregroundStyle(problem.reason.isNotice ? Color.secondary : Theme.warning)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.raisedInset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            } else if report.linesRead == 0 {
                Text(L("proxies.import.hint"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func outcome(_ result: ProxyList.AddResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(format: L("proxies.import.done"), result.added.count), systemImage: "checkmark.circle")
                .font(.lumenLabel)
                .foregroundStyle(Theme.running)
            if result.alreadyListed > 0 {
                Text(String(format: L("proxies.import.alreadyListed"), result.alreadyListed))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            if result.overLimit > 0 {
                Text(String(format: L("proxies.import.overLimit"), result.overLimit, ProxyList.maximumEntries))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
            }
            Text(L("proxies.import.nextStep"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Actions

    private func add() {
        // The text as it is now, not as it was a moment ago.
        let current = ProxyListImport.read(text, defaultKind: kind)
        report = current
        guard let result = proxies.add(current.proxies) else { return }
        added = result
        onAdded(result.added)
    }

    private func read(_ url: URL) {
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maximumFileSize else {
                error = L("proxies.import.fileTooLarge")
                return
            }
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Wording

extension ProxyListImport.Reason {
    /// Why a line is not a proxy, in plain words: the import's report and the one-line field say it
    /// alike.
    var words: String {
        switch self {
        case .missingPort: return L("proxies.reason.missingPort")
        case let .duplicate(line): return String(format: L("proxies.reason.duplicate"), line)
        case let .tooMany(limit): return String(format: L("proxies.reason.tooMany"), limit)
        case let .unreadable(problem):
            switch problem {
            case .empty, .containsWhitespace: return L("proxies.reason.whitespace")
            case let .unsupportedScheme(scheme): return String(format: L("proxies.reason.scheme"), scheme)
            case .hasPath: return L("proxies.reason.path")
            case .emptyUserName: return L("proxies.reason.emptyUser")
            case .unterminatedIPv6, .textAfterIPv6: return L("proxies.reason.ipv6")
            case .notAHost: return L("proxies.reason.notAProxy")
            case let .invalidPort(text): return String(format: L("proxies.reason.port"), text)
            case let .invalidHost(host): return String(format: L("proxies.reason.host"), host)
            }
        }
    }

    /// Not a failure: the proxy was read on an earlier line.
    var isNotice: Bool {
        if case .duplicate = self { return true }
        return false
    }
}

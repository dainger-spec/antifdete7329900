import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Imports a cookie export (JSON or Netscape cookies.txt) into one profile: the file is read and
/// checked first, and the report — how many cookies can be imported, and every entry that cannot,
/// with its line and the reason — is shown before anything is imported. A running profile gets
/// the cookies at once (and those WebKit refused are listed); a stopped one at its next launch,
/// before its first page loads.
struct CookieImportView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var choosingFile = false
    @State private var fileName: String?
    @State private var reading = false
    @State private var report: CookieImportReport?
    @State private var importing = false
    @State private var outcome: ProfileManager.CookieImportOutcome?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("cookies.title"), profile.name), subtitle: L("cookies.explanation"))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { choosingFile = true } label: { Label(L("cookies.chooseFile"), systemImage: "doc") }
                        .buttonStyle(.lumenSecondary)
                        .disabled(reading || importing)
                    if let fileName {
                        Text(fileName).font(.lumenBody).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    if reading { ProgressView().controlSize(.small) }
                }
                if let report {
                    reportView(report)
                } else {
                    LumenEmptyHint(symbol: "doc.text.magnifyingglass", text: L("cookies.empty"))
                        .opacity(reading ? 0 : 1)
                }
                if let outcome { outcomeView(outcome) }
                if let error { Text(error).foregroundStyle(Theme.danger).font(.lumenSecondary) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter {
                Button(L(outcome == nil ? "common.cancel" : "common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if outcome == nil, let report, !report.cookies.isEmpty {
                    Button(String(format: L("cookies.import"), report.cookies.count)) { importCookies(report.cookies) }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(importing)
                }
            }
        }
        .sheetFrame(width: 680, height: 560)
        .background(Theme.raised)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json, .plainText, .text, .data]) { result in
            switch result {
            case let .success(url): read(url)
            case let .failure(failure): error = failure.localizedDescription
            }
        }
    }

    // MARK: Report

    private func reportView(_ report: CookieImportReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: L("cookies.summary"), report.cookies.count, report.entriesFound))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
            if let format = report.format {
                Text(String(format: L("cookies.formatLine"),
                            L(format == .json ? "cookies.format.json" : "cookies.format.netscape"), report.encoding))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if report.damagedByteSequences > 0 {
                Label(String(format: L("cookies.damagedBytes"), report.damagedByteSequences), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if !report.problems.isEmpty {
                Text(String(format: L("cookies.problemsTitle"), report.failures.count)).font(.lumenLabel)
                List(Array(report.problems.enumerated()), id: \.offset) { _, problem in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(Self.describe(problem.location)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let name = problem.name { Text(name).font(.caption.bold()).lineLimit(1) }
                        }
                        Text(Self.describe(problem.reason)).font(.caption)
                            .foregroundStyle(Self.isNotice(problem.reason) ? Color.secondary : Color.primary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.raisedInset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            } else {
                Spacer()
            }
        }
    }

    private func outcomeView(_ outcome: ProfileManager.CookieImportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch outcome {
            case let .applied(stored, refused):
                Label(String(format: L("cookies.done.applied"), stored), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.running)
                if !refused.isEmpty {
                    Text(String(format: L("cookies.done.refused"), refused.count,
                                refused.prefix(10).map { "\($0.name) (\($0.domain))" }.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            case let .queued(count):
                Label(String(format: L("cookies.done.queued"), count, profile.name), systemImage: "clock")
                    .foregroundStyle(Theme.running)
            }
        }
    }

    // MARK: Actions

    private func read(_ url: URL) {
        fileName = url.lastPathComponent
        report = nil
        outcome = nil
        error = nil
        reading = true
        Task {
            report = await model.readCookieFile(url)
            reading = false
        }
    }

    private func importCookies(_ cookies: [ImportedCookie]) {
        importing = true
        Task {
            do {
                outcome = try await model.importCookies(cookies, into: profile.id)
            } catch {
                self.error = error.localizedDescription
            }
            importing = false
        }
    }

    // MARK: Wording

    static func describe(_ location: CookieImportLocation) -> String {
        switch location {
        case .file: return L("cookies.where.file")
        case let .line(line): return String(format: L("cookies.where.line"), line)
        case let .entry(index, line): return String(format: L("cookies.where.entry"), index, line)
        }
    }

    /// Not a failure: the same cookie later in the file was imported instead.
    static func isNotice(_ reason: CookieImportReason) -> Bool {
        if case .replacedByLaterEntry = reason { return true }
        return false
    }

    static func describe(_ reason: CookieImportReason) -> String {
        switch reason {
        case .unrecognizedFormat: return L("cookies.reason.unrecognizedFormat")
        case let .fileTooLarge(size):
            return String(format: L("cookies.reason.fileTooLarge"),
                          ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        case let .unreadableFile(detail): return String(format: L("cookies.reason.unreadableFile"), detail)
        case let .unsupportedFile(kind): return String(format: L("cookies.reason.unsupportedFile"), kind)
        case .encryptedValue: return L("cookies.reason.encryptedValue")
        case .partitioned: return L("cookies.reason.partitioned")
        case let .damagedJSON(line): return String(format: L("cookies.reason.damagedJSON"), line)
        case .cutOff: return L("cookies.reason.cutOff")
        case .unreadableEntry: return L("cookies.reason.unreadableEntry")
        case .notACookie: return L("cookies.reason.notACookie")
        case let .wrongFieldCount(count): return String(format: L("cookies.reason.wrongFieldCount"), count)
        case .missingName: return L("cookies.reason.missingName")
        case .invalidName: return L("cookies.reason.invalidName")
        case .invalidValue: return L("cookies.reason.invalidValue")
        case .damagedText: return L("cookies.reason.damagedText")
        case .tooLarge: return L("cookies.reason.tooLarge")
        case .missingDomain: return L("cookies.reason.missingDomain")
        case let .invalidDomain(domain): return String(format: L("cookies.reason.invalidDomain"), domain)
        case let .publicSuffixDomain(domain): return String(format: L("cookies.reason.publicSuffix"), domain)
        case let .invalidPath(path): return String(format: L("cookies.reason.invalidPath"), path)
        case let .invalidExpiry(text): return String(format: L("cookies.reason.invalidExpiry"), text)
        case let .expired(date): return String(format: L("cookies.reason.expired"), date.formatted(date: .abbreviated, time: .shortened))
        case let .prefixRequirements(prefix):
            return L(prefix == "__Host-" ? "cookies.reason.hostPrefix" : "cookies.reason.securePrefix")
        case let .replacedByLaterEntry(later): return String(format: L("cookies.reason.replaced"), describe(later))
        }
    }
}

import BrowserCore
import Foundation

/// What became of an update that was not installed, as the app says it at the next launch and
/// after Install Now: a title of its own and sentences in the interface's language.
///
/// The installer and the quit's checks (`UpdateGate`) give their reasons in English, for the log
/// (`UpdateOutcome.detail`, "the swap failed (errno 13); …"). They were put into the notice as they
/// were, under the title «Ошибка»: a Russian window said why in English, with an error number (a
/// tester, 17 November). Each reason the app knows is said here in the person's words; one it
/// does not know is left out, and the notice says what happens next.
enum UpdateNoticeText {
    /// The notice's title.
    static func title(_ result: UpdateOutcome.Result?) -> String {
        result == .rolledBack ? L("updates.notice.title.rolledBack") : L("updates.notice.title")
    }

    /// The installer's outcome, at the launch after it.
    static func outcome(_ outcome: UpdateOutcome) -> String? {
        switch outcome.result {
        case .installed: return nil
        case .rolledBack: return String(format: L("updates.notice.rolledBack"), outcome.version)
        case .refused:
            return sentences(String(format: L("updates.notice.refused"), outcome.version), reasons([outcome.detail]), L("updates.notice.checkAgain"))
        case .gaveUp:
            return sentences(String(format: L("updates.notice.gaveUp"), outcome.version), reasons([outcome.detail]), L("updates.notice.nextQuit"))
        }
    }

    /// The last quit did not install it (the gate's reasons, or the installer not starting, in one
    /// line separated by "; " as `rememberNotInstalled` keeps them).
    static func deferred(_ reason: String) -> String {
        sentences(L("updates.notice.deferred"), reasons(reason.components(separatedBy: "; ")), L("updates.notice.nextQuitEncrypted"))
    }

    /// Install Now stopped by the quit's checks: the app stays open, locked.
    static func refusedNow(_ english: [String]) -> String {
        sentences(L("updates.now.refused"), reasons(english), L("updates.notice.nextQuitEncrypted"))
    }

    /// Install Now: the installer did not start. The reason only when it is in the person's words
    /// (a system's error is, in its own language; the code's English is not).
    static func failedNow(_ reason: String) -> String {
        sentences(L("updates.now.failed"), ErrorDetailText.text(reason).map { [$0] } ?? [], L("updates.now.failed.next"))
    }

    /// The first sentence, the reasons the app can say, and what happens next.
    private static func sentences(_ first: String, _ reasons: [String], _ next: String) -> String {
        ([first] + reasons + [next]).joined(separator: " ")
    }

    /// The reasons the app knows, each once, in the person's words.
    static func reasons(_ english: [String]) -> [String] {
        var said: [String] = []
        for line in english {
            guard let text = reason(line.trimmingCharacters(in: .whitespacesAndNewlines)), !said.contains(text) else { continue }
            said.append(text)
        }
        return said
    }

    /// One reason of the gate's or the installer's (UpdateGate.swift, UpdateInstaller), or nil.
    static func reason(_ english: String) -> String? {
        if english.hasPrefix("a profile is still running") { return L("updates.reason.profileRunning") }
        if english.contains("had to be killed during the quit") { return L("updates.reason.killed") }
        if english.hasSuffix("website data is not encrypted") || english.hasSuffix("Safari's home is not encrypted") {
            return L("updates.reason.notEncrypted")
        }
        if english.hasSuffix("a process still holds its home") { return L("updates.reason.profileRunning") }
        if english.hasPrefix("the app was started again") { return L("updates.reason.startedAgain") }
        if english.contains("still ran from the app") { return L("updates.reason.stillRunning") }
        if english.hasPrefix("the swap failed"), let detail = ErrorDetailText.errnoText(english) { return detail }
        return nil
    }
}

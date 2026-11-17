import BrowserCore
import SwiftUI

/// "Restore Cookies from a Snapshot…" (docs/COOKIE_RECOVERY.md): the profile's last cookie
/// snapshots, each with when it was taken and how many of its cookies are still valid, and a restore
/// of one, confirmed first. A restore puts back the snapshot's cookies that have not expired — they
/// replace the profile's cookies of the same name, domain and path, and leave the others — at once
/// when the profile runs, else at its next launch, before its first page loads.
struct CookieSnapshotsView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [CookieSnapshot] = []
    @State private var unreadable = false
    @State private var restoring: CookieSnapshot?
    @State private var working = false
    @State private var error: String?
    @State private var done: String?

    private var details: ProfileDetails? { model.details[profile.id] }
    private var ephemeral: Bool { details?.ephemeral ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("cookieSnapshots.title"), profile.name), subtitle: L("cookieSnapshots.explanation"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if ephemeral {
                        note(L("cookieSnapshots.ephemeral"), symbol: "info.circle")
                    } else if details?.keepsCookieSnapshots == false {
                        note(L("cookieSnapshots.off"), symbol: "pause.circle")
                    }
                    if unreadable { note(L("cookieSnapshots.unreadable"), symbol: "exclamationmark.triangle") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.lumenSecondary).foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let done {
                        Label(done, systemImage: "checkmark.circle")
                            .font(.lumenSecondary).foregroundStyle(Theme.running)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    list
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .frame(minHeight: 220, maxHeight: 420)
            SheetFooter(leading: {
                if working { ProgressView().controlSize(.small) }
            }, buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .sheetFrame(width: 560)
        .background(Theme.raised)
        .onAppear(perform: reload)
        .confirmationDialog(restoring.map { String(format: L("cookieSnapshots.restore.title"), $0.takenAt.shown(date: .long, time: .shortened)) } ?? "",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button(L("cookieSnapshots.restore.confirm")) {
                if let snapshot = restoring { restore(snapshot) }
            }
        } message: {
            Text(restoring.map(message(for:)) ?? "")
        }
    }

    // MARK: Parts

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: L("cookieSnapshots.list"), snapshots.count, CookieSnapshots.kept))
                .font(.lumenLabel).foregroundStyle(Theme.textSecondary)
            if snapshots.isEmpty {
                Text(L("cookieSnapshots.none"))
                    .font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(snapshots) { snapshot in
                    let valid = snapshot.liveCookies(at: Date()).count
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.takenAt.shown(date: .abbreviated, time: .shortened))
                                .font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(subtitle(of: snapshot, valid: valid))
                                .font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(L("cookieSnapshots.restore")) { restoring = snapshot }
                            .buttonStyle(.lumenGhost)
                            .disabled(working || valid == 0 || ephemeral || model.isBusy(profile.id))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "2 hours ago · 41 cookies", or "… · 38 of 41 cookies still valid".
    private func subtitle(of snapshot: CookieSnapshot, valid: Int) -> String {
        let count = valid == snapshot.cookies.count
            ? String(format: L("cookieSnapshots.count"), valid)
            : String(format: L("cookieSnapshots.count.valid"), valid, snapshot.cookies.count)
        return snapshot.takenAt.shownRelative + " · " + count
    }

    /// What the restore does, said before it is done.
    private func message(for snapshot: CookieSnapshot) -> String {
        var parts = [String(format: L("cookieSnapshots.restore.message"), snapshot.liveCookies(at: Date()).count)]
        parts.append(L(model.isRunning(profile.id) ? "cookieSnapshots.restore.now" : "cookieSnapshots.restore.nextLaunch"))
        if details?.syncsCookies == true { parts.append(L("cookieSnapshots.restore.sync")) }
        return parts.joined(separator: " ")
    }

    // MARK: Actions

    private func reload() {
        if let read = model.cookieSnapshots(for: profile.id) {
            snapshots = read
            unreadable = false
        } else {
            snapshots = []
            unreadable = true
        }
    }

    private func restore(_ snapshot: CookieSnapshot) {
        guard !working else { return }
        working = true
        error = nil
        done = nil
        Task {
            do {
                switch try await model.restoreCookies(from: snapshot, into: profile.id) {
                case let .applied(stored, refused):
                    done = refused.isEmpty
                        ? String(format: L("cookieSnapshots.restored.now"), stored)
                        : String(format: L("cookieSnapshots.restored.refused"), stored, refused.count)
                case let .queued(count):
                    done = String(format: L("cookieSnapshots.restored.queued"), count, profile.name)
                }
            } catch {
                self.error = errorText(error)
            }
            working = false
            reload()
        }
    }
}

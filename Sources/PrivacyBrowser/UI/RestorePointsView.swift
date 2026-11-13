import BrowserCore
import SwiftUI

/// A profile's restore points and its journal (`RestorePoint`, `ProfileJournal`): make a point of
/// the profile as it is — before a sign-up, a warm-up, a cookie import — and put it back as a point
/// had it. Points are made and restored only while the profile is stopped (its data sealed); a
/// restore keeps the state it replaces as a point first, so it can be undone.
struct RestorePointsView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var points: [RestorePoint] = []
    @State private var journal = ProfileJournal()
    @State private var name = ""
    @State private var working = false
    @State private var error: String?
    @State private var done: String?
    @State private var restoring: RestorePoint?
    @State private var removing: RestorePoint?

    private var inUse: Bool { model.isRunning(profile.id) || model.isBusy(profile.id) }
    private var ephemeral: Bool { model.details[profile.id]?.ephemeral ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("restorePoints.title"), profile.name), subtitle: L("restorePoints.explanation"))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ephemeral {
                        note(L("restorePoints.ephemeral"), symbol: "info.circle")
                    } else {
                        makeRow
                        if inUse { note(L("restorePoints.stopFirst"), symbol: "pause.circle") }
                        if model.details[profile.id]?.syncsCookies == true { note(L("restorePoints.sync"), symbol: "arrow.triangle.2.circlepath") }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.lumenSecondary).foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let done {
                        Label(done, systemImage: "checkmark.circle")
                            .font(.lumenSecondary).foregroundStyle(Theme.running)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    pointList
                    journalList
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .frame(minHeight: 320, maxHeight: 520)
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
        .confirmationDialog(restoring.map { String(format: L("restorePoints.restore.title"), title(of: $0)) } ?? "",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button(L("restorePoints.restore.confirm")) {
                if let point = restoring { restore(point) }
            }
        } message: {
            Text(restoring.map { String(format: L("restorePoints.restore.message"), $0.createdAt.shown(date: .long, time: .shortened)) } ?? "")
        }
        .confirmationDialog(removing.map { String(format: L("restorePoints.remove.title"), title(of: $0)) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button(L("restorePoints.remove.confirm"), role: .destructive) {
                if let point = removing { remove(point) }
            }
        } message: {
            Text(L("restorePoints.remove.message"))
        }
    }

    // MARK: Parts

    private var makeRow: some View {
        HStack(spacing: 8) {
            TextField(L("restorePoints.name"), text: $name, prompt: Text(verbatim: ""))
                .lumenField(L("restorePoints.name.placeholder"), isEmpty: name.isEmpty)
                .onSubmit(make)
            Button(L("restorePoints.make"), action: make)
                .buttonStyle(.lumenSecondary)
                .disabled(working || inUse || points.count >= ProfileRepository.maximumRestorePoints)
        }
    }

    @ViewBuilder private var pointList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: L("restorePoints.list"), points.count, ProfileRepository.maximumRestorePoints))
                .font(.lumenLabel).foregroundStyle(Theme.textSecondary)
            if points.isEmpty {
                Text(L("restorePoints.none"))
                    .font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(points) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: point.kind == .beforeRestore ? "arrow.uturn.backward.circle" : "clock.arrow.circlepath")
                            .foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(of: point))
                                .font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(subtitle(of: point))
                                .font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(L("restorePoints.restore")) { restoring = point }
                            .buttonStyle(.lumenGhost)
                            .disabled(working || inUse)
                        Button { removing = point } label: { Image(systemName: "trash") }
                            .buttonStyle(.lumenGhost)
                            .disabled(working)
                            .help(L("restorePoints.remove"))
                            .accessibilityLabel(L("restorePoints.remove"))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private var journalList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("journal.title")).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
            let events = journal.latest(60)
            if events.isEmpty {
                Text(L("journal.empty")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(events) { event in
                    JournalLine(event: event)
                }
            }
        }
        .padding(.top, 4)
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func title(of point: RestorePoint) -> String {
        if !point.name.isEmpty { return point.name }
        if point.kind == .beforeRestore { return L("restorePoints.beforeRestore") }
        return point.createdAt.shown(date: .abbreviated, time: .shortened)
    }

    private func subtitle(of point: RestorePoint) -> String {
        let size = point.bytes.formatted(.byteCount(style: .file).locale(Localization.locale))
        return point.createdAt.shownRelative + " · " + size
    }

    // MARK: Actions

    private func reload() {
        points = model.restorePoints(for: profile.id)
        journal = model.journal(for: profile.id)
    }

    private func make() {
        guard !working, !inUse else { return }
        working = true
        error = nil
        done = nil
        Task {
            let problem = await model.createRestorePoint(profile.id, name: name)
            working = false
            if let problem {
                error = problem
            } else {
                done = L("restorePoints.made")
                name = ""
            }
            reload()
        }
    }

    private func restore(_ point: RestorePoint) {
        guard !working else { return }
        working = true
        error = nil
        done = nil
        Task {
            let problem = await model.restore(profile.id, to: point)
            working = false
            if let problem { error = problem } else { done = String(format: L("restorePoints.restored"), title(of: point)) }
            reload()
        }
    }

    private func remove(_ point: RestorePoint) {
        error = model.removeRestorePoint(point, of: profile.id)
        done = nil
        reload()
    }
}

/// One event of a profile's journal: what happened, and when.
struct JournalLine: View {
    let event: ProfileJournal.Event

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(event.known))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
            Text(Self.text(event))
                .font(.lumenSecondary).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(event.at.shownRelative)
                .font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .help(event.at.shown(date: .long, time: .shortened))
    }

    static func symbol(_ kind: ProfileJournal.Kind?) -> String {
        switch kind {
        case .launched?: return "play.fill"
        case .warmedUp?: return "flame"
        case .cookiesImported?: return "square.and.arrow.down"
        case .proxyChanged?: return "network"
        case .ipChanged?: return "arrow.triangle.2.circlepath"
        case .restorePointMade?: return "clock.arrow.circlepath"
        case .restored?: return "arrow.uturn.backward"
        case .copied?: return "plus.square.on.square"
        case nil: return "circle"
        }
    }

    /// The event in the person's language, its detail (kept as written: a count, a name, an IP)
    /// put in.
    static func text(_ event: ProfileJournal.Event) -> String {
        let detail = event.detail
        func with(_ key: String, _ plain: String) -> String {
            detail.isEmpty ? L(plain) : String(format: L(key), detail)
        }
        switch event.known {
        case .launched?: return L("journal.launched")
        case .warmedUp?: return with("journal.warmedUp", "journal.warmedUp.plain")
        case .cookiesImported?: return with("journal.cookiesImported", "journal.cookiesImported.plain")
        case .proxyChanged?: return with("journal.proxyChanged", "journal.proxyChanged.plain")
        case .ipChanged?: return with("journal.ipChanged", "journal.ipChanged.plain")
        case .restorePointMade?: return with("journal.restorePointMade", "journal.restorePointMade.plain")
        case .restored?: return with("journal.restored", "journal.restored.plain")
        case .copied?: return with("journal.copied", "journal.copied.plain")
        case nil: return L("journal.other")
        }
    }
}

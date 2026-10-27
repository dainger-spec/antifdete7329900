import BrowserCore
import SwiftUI

/// Session warm-up for one profile: the pages (web addresses, and a search to start with), the
/// time on each page, scrolling and following a link; Start launches the profile when it is
/// stopped and runs `WarmUpRobot` in a tab of it. The run goes on when the sheet closes; the
/// sheet shows it again (each page, how long, what failed) when reopened.
struct WarmUpView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let manager = model.manager {
            WarmUpPanel(profile: profile, robot: manager.warmUpRobot(for: profile.id))
        }
    }
}

private struct WarmUpPanel: View {
    let profile: ProfileSummary
    @ObservedObject var robot: WarmUpRobot
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var plan = WarmUpPlan()
    @State private var loaded = false
    @State private var starting = false

    private var reading: (pages: [WarmUpPlan.Page], problems: [WarmUpPlan.Problem]) { plan.pages() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("warmup.title"), profile.name), subtitle: L("warmup.explanation"))
            HStack(alignment: .top, spacing: 16) {
                planEditor.frame(width: 330)
                progress
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter(leading: { status }, buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if robot.isRunning {
                    Button(L("warmup.stop")) { robot.stop() }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("warmup.start")) { start() }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(starting || reading.pages.isEmpty || model.isBusy(profile.id))
                }
            })
        }
        .frame(width: 780, height: 600)
        .background(Theme.raised)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            plan = model.warmUpPlan(for: profile.id)
        }
    }

    // MARK: Plan

    private var planEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("warmup.addresses")).font(.lumenLabel).foregroundStyle(Theme.textPrimary)
            TextEditor(text: $plan.addresses)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 150)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.fieldBorder, lineWidth: 1))
            problems
            TextField(L("warmup.search"), text: $plan.searchQuery, prompt: Text(L("warmup.searchPrompt")))
                .lumenField()
            HStack {
                Text(L("warmup.dwell"))
                Spacer()
                secondsField($plan.minimumDwell)
                Text(verbatim: "–")
                secondsField($plan.maximumDwell)
                Text(L("warmup.seconds")).foregroundStyle(.secondary)
            }
            Toggle(L("warmup.scroll"), isOn: $plan.scroll)
                .toggleStyle(.switch).controlSize(.small)
            Toggle(L("warmup.followLinks"), isOn: $plan.followLinks)
                .toggleStyle(.switch).controlSize(.small)
            Text(L("warmup.note")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(robot.isRunning || starting)
    }

    private func secondsField(_ value: Binding<TimeInterval>) -> some View {
        TextField("", value: Binding(get: { Int(value.wrappedValue) }, set: { value.wrappedValue = TimeInterval($0) }),
                  format: .number)
            .multilineTextAlignment(.trailing)
            .lumenField(height: 28)
            .frame(width: 56)
            .onSubmit { plan = plan.normalized }
    }

    @ViewBuilder private var problems: some View {
        let problems = reading.problems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(problems.prefix(4).enumerated()), id: \.offset) { _, problem in
                    Text(String(format: L("warmup.problem"), problem.line, Self.describe(problem.reason)))
                        .lineLimit(1).truncationMode(.middle)
                }
                if problems.count > 4 { Text(String(format: L("warmup.problems.more"), problems.count - 4)) }
            }
            .font(.caption).foregroundStyle(Theme.warning)
        }
    }

    static func describe(_ reason: WarmUpPlan.Problem.Reason) -> String {
        switch reason {
        case .notAWebAddress: return L("warmup.reason.notAWebAddress")
        case let .unsupportedScheme(scheme): return String(format: L("warmup.reason.unsupportedScheme"), scheme)
        case .duplicate: return L("warmup.reason.duplicate")
        case .tooMany: return String(format: L("warmup.reason.tooMany"), WarmUpPlan.maximumPages)
        }
    }

    // MARK: Progress

    @ViewBuilder private var progress: some View {
        if robot.visits.isEmpty {
            VStack {
                Spacer()
                Text(String(format: L("warmup.pagesToVisit"), reading.pages.count))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .card(fill: Theme.raisedInset)
        } else {
            List(robot.visits) { visit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        icon(for: visit)
                        Text(visit.url.host ?? visit.url.absoluteString).font(.callout.bold()).lineLimit(1)
                        Text(visit.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if !visit.title.isEmpty { Text(visit.title).font(.caption).lineLimit(1) }
                    Text(detail(of: visit)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.raisedInset)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder private func icon(for visit: WarmUpVisit) -> some View {
        switch visit.outcome {
        case nil:
            if robot.isRunning && visit.id == robot.visits.last?.id { ProgressView().controlSize(.mini) }
            else { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
        case .loaded?: Image(systemName: "checkmark.circle").foregroundStyle(Theme.running)
        case .timedOut?: Image(systemName: "clock").foregroundStyle(Theme.warning)
        case .failed?: Image(systemName: "xmark.circle").foregroundStyle(Theme.danger)
        }
    }

    private func detail(of visit: WarmUpVisit) -> String {
        var parts: [String] = []
        switch visit.outcome {
        case let .failed(message)?: parts.append(String(format: L("warmup.visit.failed"), message))
        case .timedOut?: parts.append(L("warmup.visit.timedOut"))
        default: break
        }
        if visit.dwell > 0 { parts.append(String(format: L("warmup.visit.stayed"), Int(visit.dwell.rounded()), visit.scrolls)) }
        if let followed = visit.followed {
            let outcome: String
            switch visit.followedOutcome {
            case let .failed(message)?: outcome = String(format: L("warmup.visit.failed"), message)
            case .timedOut?: outcome = L("warmup.visit.timedOut")
            default: outcome = ""
            }
            parts.append(String(format: L("warmup.visit.followed"), followed.absoluteString) + (outcome.isEmpty ? "" : " — " + outcome))
        }
        return parts.joined(separator: " · ")
    }

    private var status: some View {
        Group {
            switch robot.state {
            case .idle:
                if starting { Text(L("warmup.status.starting")) } else { EmptyView() }
            case .running:
                if robot.waitingForTab {
                    Label(L("warmup.status.waitingForTab"), systemImage: "pause.circle").foregroundStyle(Theme.warning)
                } else {
                    Text(String(format: L("warmup.status.running"), robot.visits.count, robot.pageCount))
                }
            case .finished:
                let failed = robot.visits.filter { if case .failed? = $0.outcome { return true } else { return false } }.count
                Label(String(format: L("warmup.status.finished"), robot.visits.count, failed), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.running)
            case let .stopped(reason):
                Label(Self.describe(reason), systemImage: "stop.circle").foregroundStyle(reason == .byUser ? Theme.textSecondary : Theme.warning)
            }
        }
        .font(.lumenSecondary)
        .lineLimit(2)
    }

    static func describe(_ reason: WarmUpRobot.StopReason) -> String {
        switch reason {
        case .byUser: return L("warmup.status.stopped")
        case .profileStopped: return L("warmup.status.profileStopped")
        case .tabClosed: return L("warmup.status.tabClosed")
        case .pageNeedsAttention: return L("warmup.status.pageNeedsAttention")
        }
    }

    // MARK: Actions

    private func start() {
        plan = plan.normalized
        starting = true
        Task {
            _ = await model.startWarmUp(plan, for: profile.id)
            starting = false
        }
    }
}

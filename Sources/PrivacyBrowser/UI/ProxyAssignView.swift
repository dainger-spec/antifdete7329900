import BrowserCore
import SwiftUI

/// Gives proxies of the list to profiles: the profiles on the left, the proxies on the right,
/// and what each profile will get below — the first profile the first proxy, the second the
/// second, and round again when there are more profiles than proxies (one proxy: every profile
/// gets it). Opened from the Proxies section with the proxies selected there, or from the Profiles
/// list with the profiles selected there. Saved as the editor saves a profile; a running profile
/// uses its new proxy from its next launch.
struct ProxyAssignView: View {
    /// What to start with ticked.
    struct Request: Identifiable {
        let id = UUID()
        var profileIDs: Set<UUID>
        var proxyIDs: Set<UUID>
    }

    let request: Request
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let proxies = model.proxyList {
            ProxyAssignPanel(proxies: proxies, request: request)
        }
    }
}

private struct ProxyAssignPanel: View {
    @ObservedObject var proxies: ProxyListModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var chosenProfiles: Set<UUID>
    @State private var chosenProxies: Set<UUID>
    /// Opened from the Profiles list, with no proxy chosen yet: the ones that answered at their
    /// last check are ticked when the sheet appears — what a rotation is usually meant to go through.
    private let startsWithAliveProxies: Bool

    init(proxies: ProxyListModel, request: ProxyAssignView.Request) {
        _proxies = ObservedObject(wrappedValue: proxies)
        _chosenProfiles = State(initialValue: request.profileIDs)
        _chosenProxies = State(initialValue: request.proxyIDs)
        startsWithAliveProxies = request.proxyIDs.isEmpty && !request.profileIDs.isEmpty
    }

    private var aliveProxies: Set<UUID> { Set(proxies.entries.filter { $0.kindKnown && $0.lastCheck?.isAlive == true }.map(\.id)) }

    /// The chosen profiles in the order of the list, and the chosen proxies in theirs — but for
    /// those whose type no check has found yet: a profile would connect with a guess.
    private var profileOrder: [ProfileSummary] { model.profiles.filter { chosenProfiles.contains($0.id) } }
    private var proxyOrder: [ProxyListEntry] { proxies.entries.filter { chosenProxies.contains($0.id) && $0.kindKnown } }
    /// Chosen, and left out for their unknown type.
    private var unknownKindChosen: Int { proxies.entries.filter { chosenProxies.contains($0.id) && !$0.kindKnown }.count }
    private var plan: [ProxyAssignment] { ProxyList.rotation(of: proxyOrder, over: profileOrder.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("proxies.assign.title"), subtitle: L("proxies.assign.explanation"))
            HStack(alignment: .top, spacing: 12) {
                checklist(title: L("proxies.assign.profiles"), chosen: chosenProfiles.intersection(model.profiles.map(\.id)).count,
                          total: model.profiles.count,
                          all: { chosenProfiles = Set(model.profiles.map(\.id)) }, none: { chosenProfiles = [] }) {
                    ForEach(model.profiles) { profile in
                        Toggle(isOn: member(profile.id, of: $chosenProfiles)) {
                            HStack(spacing: 8) {
                                ProfileAvatar(name: profile.name, id: profile.id, size: 20,
                                              style: model.details[profile.id]?.avatar)
                                Text(profile.name)
                                    .font(.lumenBody)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(currentExit(of: profile.id))
                                    .font(.lumenSecondary)
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                checklist(title: L("proxies.assign.proxies"), chosen: chosenProxies.intersection(proxies.entries.map(\.id)).count,
                          total: proxies.entries.count,
                          all: { chosenProxies = Set(proxies.entries.filter(\.kindKnown).map(\.id)) }, none: { chosenProxies = [] },
                          alive: { chosenProxies = aliveProxies }) {
                    ForEach(proxies.entries) { entry in
                        Toggle(isOn: member(entry.id, of: $chosenProxies)) {
                            HStack(spacing: 8) {
                                ProxyStatusIcon(state: entry.state(checking: proxies.checking.contains(entry.id)))
                                Text(entry.displayName)
                                    .font(.lumenBody)
                                    .foregroundStyle(entry.kindKnown ? Theme.textPrimary : Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                if entry.kindKnown {
                                    ProxyExitLabel(check: entry.lastCheck)
                                } else {
                                    Text(L("proxies.assign.unknownType"))
                                        .font(.lumenSecondary)
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!entry.kindKnown)
                        .help(entry.kindKnown ? "" : L("proxies.type.unknown.help"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 24)
            preview
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter(leading: {
                Text(L("proxies.assign.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }, buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(String(format: L("proxies.assign.action"), plan.count), action: assign)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
            })
        }
        .frame(width: 820, height: 640)
        .background(Theme.raised)
        .onAppear {
            if startsWithAliveProxies && chosenProxies.isEmpty { chosenProxies = aliveProxies }
        }
    }

    // MARK: Parts

    private func checklist<Rows: View>(title: String, chosen: Int, total: Int, all: @escaping () -> Void, none: @escaping () -> Void,
                                       alive: (() -> Void)? = nil, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.lumenSection).foregroundStyle(Theme.textPrimary)
                Text(String(format: L("proxies.assign.chosen"), chosen, total))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 6)
                if let alive {
                    Button(L("proxies.assign.aliveOnly"), action: alive).buttonStyle(.lumenGhost)
                }
                Button(L("proxies.assign.all"), action: all).buttonStyle(.lumenGhost)
                Button(L("proxies.assign.none"), action: none).buttonStyle(.lumenGhost)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) { rows() }
                    .padding(10)
            }
            .overlay {
                if total == 0 {
                    Text(L("proxies.assign.nothing")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.raisedInset))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    /// Who gets what, as Assign will give it.
    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(planLine)
                .font(.lumenLabel)
                .foregroundStyle(plan.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .monospacedDigit()
            if unknownKindChosen > 0 {
                Text(String(format: L("proxies.assign.unknownLeftOut"), unknownKindChosen))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(plan, id: \.profileID) { assignment in
                            HStack(spacing: 8) {
                                Text(name(of: assignment.profileID))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 220, alignment: .leading)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.textTertiary)
                                if let code = assignment.entry.lastCheck?.countryCode, assignment.entry.lastCheck?.isAlive == true {
                                    CountryFlag(code: code, size: 12)
                                }
                                Text(assignment.entry.displayName)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.lumenSecondary)
                        }
                    }
                }
            }
        }
    }

    private var planLine: String {
        if chosenProfiles.isEmpty { return L("proxies.assign.chooseProfiles") }
        if proxyOrder.isEmpty { return L("proxies.assign.chooseProxies") }
        if proxyOrder.count == 1 { return String(format: L("proxies.assign.planOne"), profileOrder.count) }
        return String(format: L("proxies.assign.planRotation"), profileOrder.count, proxyOrder.count)
    }

    private func name(of id: UUID) -> String { model.profiles.first { $0.id == id }?.name ?? "" }

    /// What a profile connects through now: its proxy's country or address, or "Direct".
    private func currentExit(of id: UUID) -> String {
        guard let details = model.details[id] else { return "" }
        if let code = details.exitCountryCode { return CountryNames.name(for: code) }
        return details.proxyEndpoint ?? L("profiles.exit.direct")
    }

    private func member(_ id: UUID, of set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { isOn in
                    if isOn { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
                })
    }

    // MARK: Assign

    private func assign() {
        guard !plan.isEmpty else { return }
        model.assignProxies(plan)
        dismiss()
    }
}

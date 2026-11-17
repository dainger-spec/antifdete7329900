import BrowserCore
import SwiftUI

// The Warm-up section of the main window: every profile by where it stands with warm-ups — the
// runs going on, live; those waiting; those a problem ended; the unwarmed; the warmed, with when —
// the templates, and the history of all runs. A screen of values (`WarmUpProfileItem`, the
// queue's summary, the person's lists) and closures (`WarmUpActions`), so that the snapshots draw
// it without a vault; `WarmUpSectionView` gives it the app's.

/// One profile, as the Warm-up section lists it.
struct WarmUpProfileItem: Identifiable, Equatable {
    enum State: Equatable {
        case running(WarmUpStatus)
        /// In the queue; `next`: the first to start.
        case waiting(next: Bool)
        /// Its last warm-up was ended by a problem (the proxy did not answer, it did not start).
        case attention(WarmUpRun)
        case never
        /// Its last warm-up read some sites and was stopped, or met checks on some.
        case partly(WarmUpRun)
        /// Warmed up: its last run when the history has it, and when.
        case warmed(WarmUpRun?, Date)
    }

    let id: UUID
    var name: String
    var avatar: ProfileAvatarStyle?
    var tags: [String] = []
    /// Where its proxy exits (ISO 3166-1 alpha-2); nil: unknown, or no proxy.
    var countryCode: String?
    var state: State
    /// Its warm-ups, the newest first.
    var history: [WarmUpRun] = []
    /// Repeats every so many hours (`WarmUpSchedule`), and when next.
    var repeatHours: Int?
    var nextRun: Date?

    var isRunning: Bool { if case .running = state { return true } else { return false } }
    var isWaiting: Bool { if case .waiting = state { return true } else { return false } }
}

/// The queue, as the bar above the list says it.
struct WarmUpQueueSummary: Equatable {
    var done: Int
    var total: Int
    var paused = false
    /// How many at once now, and whether that is the app's own number.
    var atOnce: Int
    var automatic = true
    var secondsLeft: TimeInterval?
    /// Profiles of this queue whose turn ended without a warm-up.
    var failed = 0
}

/// What the Warm-up section can do; the app's are `WarmUpSectionView`'s.
struct WarmUpActions {
    /// Starts (or schedules) a warm-up of these profiles with this choice; `repeatHours`: also
    /// repeat it every so many hours (nil: leave their repeating as it is).
    var start: ([UUID], WarmUpChoice, Int?) -> Void = { _, _, _ in }
    var stop: (UUID) -> Void = { _ in }
    var cancel: (UUID) -> Void = { _ in }
    var startNext: (UUID) -> Void = { _ in }
    var setPaused: (Bool) -> Void = { _ in }
    var stopAll: () -> Void = {}
    /// Nil: as many as the app finds right for this Mac.
    var setConcurrency: (Int?) -> Void = { _ in }
    var retryFailed: () -> Void = {}
    var stopRepeating: (UUID) -> Void = { _ in }
    var saveTemplate: (WarmUpTemplate) -> Bool = { _ in true }
    var deleteTemplate: (UUID) -> Void = { _ in }
    var checkProxy: (UUID) -> Void = { _ in }
}

/// The words and numbers the warm-up screens share.
enum WarmUpText {
    /// "20 мин", "1 ч 10 мин", "40 с".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: L("warmup.duration.seconds"), max(total, 1)) }
        let minutes = (total + 29) / 60
        if minutes < 60 { return String(format: L("warmup.duration.minutes"), minutes) }
        return String(format: L("warmup.duration.hours"), minutes / 60, minutes % 60)
    }

    /// A template's name: the app's own for a kind of browsing, the person's for a list of theirs
    /// (`names`: as the run kept them, then as they are now; a list deleted since is said so).
    static func template(_ id: String, names: [String: String] = [:], templates: [WarmUpTemplate] = []) -> String {
        if let interest = WarmUpInterest(rawValue: id) { return L("warm.template." + interest.rawValue) }
        return names[id] ?? templates.first { $0.presetID == id }?.name ?? L("warm.template.deleted")
    }

    static func templates(_ ids: [String], names: [String: String] = [:], templates: [WarmUpTemplate] = []) -> String {
        ids.map { template($0, names: names, templates: templates) }.joined(separator: ", ")
    }

    static func intensity(_ intensity: WarmUpIntensity) -> String { L("warm.intensity." + intensity.rawValue) }

    /// "Германия", or "Напрямую" without a country.
    static func country(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return L("warm.country.none") }
        return CountryNames.name(for: code.uppercased())
    }

    /// What the robot is doing now, in words; nothing for a step this version does not know.
    static func step(_ step: String?) -> String {
        guard let step else { return "" }
        let key = "warm.step." + step
        let text = L(key)
        return text == key ? "" : text
    }

    /// "19:58" for today, "вчера", "3 дня назад".
    static func when(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.locale))
        }
        return date.shownRelative
    }

    /// A run in one line: "Сайтов: 17 из 18 · страниц: 41 · cookies: +212 · 24 мин".
    static func summary(_ run: WarmUpRun) -> String {
        var parts = [String(format: L("warm.summary.sites"), run.visitedSites, max(run.plannedSites, run.visitedSites)),
                     String(format: L("warm.summary.pages"), run.pages), String(format: L("warm.summary.cookies"), run.cookies)]
        if run.duration >= 1 { parts.append(duration(run.duration)) }
        return parts.joined(separator: " · ")
    }

    /// What a run came to, for the lists: nil when there is nothing to remark.
    static func remark(_ run: WarmUpRun) -> String? {
        switch run.resultKind {
        case .proxyNotAnswering: return L("warm.result.proxy")
        case .notStarted: return L("warm.result.notStarted")
        case .stopped:
            if let reason = run.stopReason, reason != "byUser" { return L("warmup.status." + reason) }
            return String(format: L("warm.result.stopped"), run.visitedSites)
        case .finished:
            if !run.blockedSites.isEmpty { return String(format: L("warm.result.blocked"), run.blockedSites.count, max(run.plannedSites, run.sites.count)) }
            if !run.failedSites.isEmpty { return String(format: L("warm.result.failed"), run.failedSites.count) }
            return nil
        }
    }

    /// A site's problem in the report: "проверка Cloudflare", "не загрузился".
    static func problem(_ visit: WarmUpSiteVisit) -> String {
        switch visit.outcomeKind {
        case .visited: return ""
        case .failed: return L("warm.site.failed")
        case .timedOut: return L("warm.site.timedOut")
        case .sensitive: return L("warm.site.sensitive")
        case .blocked:
            let key = "warm.block." + (visit.detail ?? "")
            let name = L(key)
            return name == key ? L("warm.block.other") : name
        }
    }

    static func arrival(_ visit: WarmUpSiteVisit) -> String { L("warm.arrival." + visit.arrivalKind.rawValue) }
}

struct WarmUpScreen: View {
    enum Tab: Hashable { case profiles, templates, history }

    let profiles: [WarmUpProfileItem]
    var queue: WarmUpQueueSummary?
    var templates: [WarmUpTemplate] = []
    var actions = WarmUpActions()
    /// As the section opens (the snapshots).
    @State var tab: Tab = .profiles
    @State var selected: UUID?
    /// The profiles "New warm-up" opens with ticked; nil: the sheet is closed.
    @State var starting: WarmUpNewRequest?
    @State var report: WarmUpReportRequest?
    /// "New warm-up" asked for from outside the section (the Profiles list): taken as it comes.
    var incoming: Binding<WarmUpNewRequest?> = .constant(nil)
    @State private var search = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let fits = geometry.size.width - ProfilesScreen.inspectorWidth >= 620
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    LumenSegmented(selection: $tab, options: [(value: Tab.profiles, title: L("warm.tab.profiles")),
                                                              (value: Tab.templates, title: L("warm.tab.templates")),
                                                              (value: Tab.history, title: L("warm.tab.history"))], large: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(L("warm.title"))
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                    switch tab {
                    case .profiles: profilesTab
                    case .templates:
                        WarmUpTemplatesPane(templates: templates, countries: countries, actions: actions,
                                            warmUp: { ids in starting = WarmUpNewRequest(profiles: [], templates: ids) })
                    case .history:
                        WarmUpHistoryPane(profiles: profiles, templates: templates, search: search,
                                          open: { item, run in report = WarmUpReportRequest(profile: item, run: run) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if tab == .profiles, fits, let item = selectedItem {
                    inspector(item)
                }
            }
            // A window too narrow for the inspector beside the list has it over the list's end: a
            // click on a row there selected it and showed nothing (the run, its report, Warm Up
            // Again were then only on a right click).
            .overlay(alignment: .trailing) {
                if tab == .profiles, !fits, let item = selectedItem {
                    inspector(item)
                        .shadow(color: .black.opacity(0.45), radius: 18, x: -6)
                }
            }
            .animation(Motion.isReduced(reduceMotion) ? nil : Theme.appearAnimation, value: selectedItem?.id)
        }
        .onAppear(perform: takeIncoming)
        .onChange(of: incoming.wrappedValue?.id) { _, _ in takeIncoming() }
        .sheet(item: $starting) { request in
            WarmUpNewSheet(request: request, profiles: profiles, templates: templates, actions: actions)
        }
        .sheet(item: $report) { request in
            WarmUpReportSheet(request: request, templates: templates,
                              again: { starting = WarmUpNewRequest(profiles: [request.profile.id], templates: request.run.templates) })
        }
    }

    private var selectedItem: WarmUpProfileItem? { profiles.first { $0.id == selected } }

    private func inspector(_ item: WarmUpProfileItem) -> some View {
        WarmUpInspector(item: item, templates: templates, actions: actions,
                        openReport: { run in report = WarmUpReportRequest(profile: item, run: run) },
                        warmUp: { starting = WarmUpNewRequest(profiles: [item.id]) },
                        close: { selected = nil })
            .id(item.id)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func takeIncoming() {
        guard let request = incoming.wrappedValue else { return }
        tab = .profiles
        starting = request
        DispatchQueue.main.async { incoming.wrappedValue = nil }
    }

    /// The countries of the person's profiles, most profiles first: the templates show these first.
    private var countries: [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in profiles { if let code = item.countryCode?.lowercased(), !code.isEmpty { counts[code, default: 0] += 1 } }
        return counts.map { (code: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("warm.title"))
                    .lumenPageTitle()
                    .foregroundStyle(Theme.textPrimary)
                Text(summary)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 12)
            if tab != .templates {
                LumenSearchField(text: $search, prompt: L("warm.search"))
                    .frame(maxWidth: 240)
            }
            Button { starting = WarmUpNewRequest(profiles: selected.map { [$0] } ?? []) } label: {
                Label(L("warm.new"), systemImage: "plus")
            }
            .buttonStyle(.lumenPrimary)
            .disabled(profiles.isEmpty)
        }
        .frame(height: ProfilesScreen.headerHeight)
        .padding(.leading, 28)
        .padding(.trailing, ProfilesScreen.headerTrailing)
        .padding(.top, ProfilesScreen.headerTop)
        .padding(.bottom, 16)
    }

    /// "Прогрето: 29 из 52 · идёт: 4 · в очереди: 12".
    private var summary: String {
        let warmed = profiles.filter { if case .warmed = $0.state { return true } else { return false } }.count
        var parts = [String(format: L("warm.header.warmed"), warmed, profiles.count)]
        let running = profiles.filter(\.isRunning).count, waiting = profiles.filter(\.isWaiting).count
        if running > 0 { parts.append(String(format: L("warm.header.running"), running)) }
        if waiting > 0 { parts.append(String(format: L("warm.header.waiting"), waiting)) }
        return parts.joined(separator: " · ")
    }

    // MARK: The profiles

    private var shown: [WarmUpProfileItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { item in
            ([item.name, WarmUpText.country(item.countryCode)] + item.tags).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// The groups in the order a person needs them: what runs, what waits, what asks for them, what
    /// was never warmed, the warmed (the most recent first).
    private var groups: [(title: String, danger: Bool, items: [WarmUpProfileItem])] {
        var running: [WarmUpProfileItem] = [], waiting: [WarmUpProfileItem] = [], attention: [WarmUpProfileItem] = []
        var never: [WarmUpProfileItem] = [], warmed: [(Date, WarmUpProfileItem)] = []
        for item in shown {
            switch item.state {
            case .running: running.append(item)
            case .waiting(let next): if next { waiting.insert(item, at: 0) } else { waiting.append(item) }
            case .attention: attention.append(item)
            case .never: never.append(item)
            case .partly(let run): warmed.append((run.endedAt, item))
            case .warmed(_, let date): warmed.append((date, item))
            }
        }
        let recent = warmed.sorted { $0.0 > $1.0 }.map(\.1)
        return [(L("warm.group.running"), false, running), (L("warm.group.waiting"), false, waiting), (L("warm.group.attention"), true, attention),
                (L("warm.group.never"), false, never), (L("warm.group.warmed"), false, recent)].filter { !$0.items.isEmpty }
    }

    @ViewBuilder private var profilesTab: some View {
        if profiles.isEmpty {
            LumenEmptyHint(symbol: "flame", text: L("warm.empty.noProfiles"))
        } else if profiles.allSatisfy({ $0.state == .never }) && search.isEmpty {
            WarmUpEmptyState(start: { starting = WarmUpNewRequest(profiles: []) })
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let queue {
                    WarmUpQueueBar(queue: queue, actions: actions)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                }
                WarmUpColumnHeader()
                    .padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.title) { group in
                            Text(verbatim: "\(group.title)  \(group.items.count)")
                                .lumenCaps(group.danger ? Theme.danger : Theme.textTertiary)
                                .padding(.leading, 82)
                                .padding(.top, 24)
                                .padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in
                                WarmUpProfileRow(item: item, selected: item.id == selected, actions: actions,
                                                 warmUp: { starting = WarmUpNewRequest(profiles: [item.id]) })
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = selected == item.id ? nil : item.id }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// What "New warm-up" opens with.
struct WarmUpNewRequest: Identifiable {
    let id = UUID()
    var profiles: [UUID]
    /// Templates ticked as it opens; empty: the everyday mix.
    var templates: [String] = []
}

struct WarmUpReportRequest: Identifiable {
    let id = UUID()
    var profile: WarmUpProfileItem
    var run: WarmUpRun
}

// MARK: - The queue's bar

/// "Идёт прогрев: 5 из 21 · осталось около 1 ч 40 мин" with how many at once, Pause and Stop.
private struct WarmUpQueueBar: View {
    let queue: WarmUpQueueSummary
    let actions: WarmUpActions
    @State private var confirmingStop = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                LumenProgressBar(fraction: queue.total > 0 ? Double(queue.done) / Double(queue.total) : 0, width: 220)
            }
            Spacer(minLength: 12)
            Menu {
                Button(String(format: L("warm.queue.atOnce.auto"), WarmUpCoordinator.automaticConcurrency)) { actions.setConcurrency(nil) }
                Divider()
                ForEach(Array(WarmUpCoordinator.concurrencyRange), id: \.self) { count in
                    Button(String(count)) { actions.setConcurrency(count) }
                }
            } label: {
                Text(queue.automatic ? String(format: L("warm.queue.atOnce.auto"), queue.atOnce) : String(format: L("warm.queue.atOnce"), queue.atOnce))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help(L("warm.queue.atOnce.help"))
            if queue.failed > 0 {
                Button(String(format: L("warm.queue.retry"), queue.failed)) { actions.retryFailed() }
                    .buttonStyle(.lumenSecondary)
            }
            Button(queue.paused ? L("warm.queue.continue") : L("warm.queue.pause")) { actions.setPaused(!queue.paused) }
                .buttonStyle(.lumenSecondary)
            Button(L("warm.queue.stop")) { confirmingStop = true }
                .buttonStyle(.lumenGhost)
        }
        .padding(.vertical, 10)
        .confirmationDialog(L("warm.queue.stop.title"), isPresented: $confirmingStop, titleVisibility: .visible) {
            Button(L("warm.queue.stop.confirm"), role: .destructive) { actions.stopAll() }
        } message: {
            Text(String(format: L("warm.queue.stop.message"), max(0, queue.total - queue.done)))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var title: String {
        var text = String(format: queue.paused ? L("warm.queue.paused") : L("warm.queue.running"), queue.done, queue.total)
        if !queue.paused, let left = queue.secondsLeft, left >= 60 { text += " · " + String(format: L("warm.queue.left"), WarmUpText.duration(left)) }
        return text
    }
}

// MARK: - Rows

private enum WarmUpColumns {
    static let exit: CGFloat = 150
    static let state: CGFloat = 270
    static let cookies: CGFloat = 70
    static let when: CGFloat = 120
}

private struct WarmUpColumnHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(L("profiles.column.name")).lumenCaps().padding(.leading, 82).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("profiles.column.exit")).lumenCaps().frame(width: WarmUpColumns.exit, alignment: .leading)
            Text(L("warm.column.state")).lumenCaps().frame(width: WarmUpColumns.state, alignment: .leading)
            Text(verbatim: "Cookies").lumenCaps().frame(width: WarmUpColumns.cookies, alignment: .trailing) // l10n: not text
            Text(L("warm.column.when")).lumenCaps().frame(width: WarmUpColumns.when, alignment: .trailing).padding(.trailing, 12)
        }
        .lineLimit(1)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct WarmUpProfileRow: View {
    let item: WarmUpProfileItem
    let selected: Bool
    let actions: WarmUpActions
    let warmUp: () -> Void
    @Environment(\.tagColors) private var tagColors
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            ProfileAvatar(name: item.name, id: item.id, size: 30, style: item.avatar, running: item.isRunning)
                .padding(.leading, 40)
                .padding(.trailing, 12)
            HStack(spacing: 10) {
                Text(item.name)
                    .font(.lumenRowTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !item.tags.isEmpty {
                    TagLine.text(item.tags, colors: tagColors)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
            exit.frame(width: WarmUpColumns.exit, alignment: .leading)
            state.frame(width: WarmUpColumns.state, alignment: .leading)
            Text(cookies)
                .font(.lumenBody)
                .foregroundStyle(item.isRunning ? Theme.textPrimary : Theme.textSecondary)
                .monospacedDigit()
                .frame(width: WarmUpColumns.cookies, alignment: .trailing)
            Text(when)
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: WarmUpColumns.when, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(selected ? Theme.rowSelected : (hovered ? Theme.rowHover : Color.clear)))
        .overlay(alignment: .bottom) {
            if !selected { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 64).padding(.trailing, 8) }
        }
        .onHover { hovered = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var exit: some View {
        HStack(spacing: 8) {
            if let code = item.countryCode, !code.isEmpty {
                CountryFlag(code: code, size: 16)
                Text(WarmUpText.country(code)).font(.lumenLabel).foregroundStyle(Theme.textPrimary).lineLimit(1)
            } else {
                Text(L("warm.country.none")).font(.lumenBody).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var state: some View {
        switch item.state {
        case .running(let status):
            VStack(alignment: .leading, spacing: 6) {
                (Text(verbatim: status.currentHost ?? L("warmupQueue.starting")).font(.lumenLabel).foregroundColor(Theme.textPrimary)
                    + Text(verbatim: stepSuffix(status)).font(.lumenSecondary).foregroundColor(Theme.textSecondary))
                    .lineLimit(1)
                HStack(spacing: 9) {
                    LumenProgressBar(fraction: status.fraction, width: 148)
                    Text(String(format: L("warm.row.progress"), status.visited, status.total))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
        case .waiting(let next):
            Text(next ? L("warm.row.next") : L("warm.row.waiting"))
                .font(.lumenBody).foregroundStyle(Theme.textSecondary).lineLimit(1)
        case .attention(let run):
            Text(WarmUpText.remark(run) ?? L("warm.result.proxy"))
                .font(.lumenLabel).foregroundStyle(Theme.danger).lineLimit(1)
        case .never:
            Text(L("warm.row.never")).font(.lumenBody).foregroundStyle(Theme.textTertiary).lineLimit(1)
        case .partly(let run):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
                Text(WarmUpText.remark(run) ?? L("warm.row.partly")).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
        case .warmed(let run, _):
            (Text(L("warm.row.warmed")).font(.lumenLabel).foregroundColor(Theme.textPrimary)
                + Text(verbatim: run.map { " · " + String(format: L("warm.row.sites"), $0.visitedSites) } ?? "").font(.lumenBody).foregroundColor(Theme.textSecondary))
                .lineLimit(1)
        }
    }

    private func stepSuffix(_ status: WarmUpStatus) -> String {
        let text = WarmUpText.step(status.step)
        return text.isEmpty ? "" : " · " + text
    }

    private var cookies: String {
        switch item.state {
        case .running(let status): return "+\(status.cookies)"
        case .partly(let run): return "+\(run.cookies)"
        case .warmed(let run?, _): return "+\(run.cookies)"
        default: return "—"
        }
    }

    private var when: String {
        switch item.state {
        case .running(let status):
            return status.secondsRemaining.map { "≈ " + WarmUpText.duration($0) } ?? ""
        case .waiting, .never: return ""
        case .attention(let run), .partly(let run): return WarmUpText.when(run.endedAt)
        case .warmed(_, let date): return WarmUpText.when(date)
        }
    }

    @ViewBuilder private var menu: some View {
        if item.isRunning {
            Button(L("warmup.stop")) { actions.stop(item.id) }
        } else if item.isWaiting {
            Button(L("warm.menu.next")) { actions.startNext(item.id) }
            Button(L("warm.menu.cancel")) { actions.cancel(item.id) }
        } else {
            Button(L("warm.menu.warmUp")) { warmUp() }
        }
        if item.repeatHours != nil {
            Button(L("warm.menu.stopRepeating")) { actions.stopRepeating(item.id) }
        }
    }
}

// MARK: - Before the first warm-up

private struct WarmUpEmptyState: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(L("warm.empty.title"))
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
            Text(L("warm.empty.text"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            Button(action: start) { Label(L("warm.new"), systemImage: "plus") }
                .buttonStyle(.lumenPrimary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

// MARK: - The inspector

/// A profile's warm-up at the window's right: a run going on (where the robot is, what it has
/// gathered, what it did), or the last run and the history.
struct WarmUpInspector: View {
    let item: WarmUpProfileItem
    var templates: [WarmUpTemplate] = []
    let actions: WarmUpActions
    let openReport: (WarmUpRun) -> Void
    let warmUp: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                head
                switch item.state {
                case .running(let status): running(status)
                default: finished
                }
            }
            .padding(.top, ProfilesScreen.inspectorTop)
            .padding(.bottom, 20)
        }
        .frame(width: ProfilesScreen.inspectorWidth)
        .frame(maxHeight: .infinity)
        .lumenFrost()
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
    }

    private var last: WarmUpRun? { item.history.first }

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ProfileAvatar(name: item.name, id: item.id, size: 56, style: item.avatar, running: item.isRunning)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(LumenIconButtonStyle(size: 26))
                    .accessibilityLabel(L("inspector.hide"))
            }
            Text(item.name)
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .padding(.top, 12)
            Text(stateLine)
                .font(.lumenLabel)
                .foregroundStyle(stateColor)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let meta {
                Text(meta)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
            HStack(spacing: 6) {
                if item.isRunning {
                    Button(L("warmup.stop")) { actions.stop(item.id) }.buttonStyle(.lumenSecondary)
                } else if item.isWaiting {
                    Button(L("warm.menu.next")) { actions.startNext(item.id) }.buttonStyle(.lumenSecondary)
                    Button(L("warm.menu.cancel")) { actions.cancel(item.id) }.buttonStyle(.lumenGhost)
                } else {
                    if case .attention = item.state {
                        Button(L("warm.inspector.checkProxy")) { actions.checkProxy(item.id) }.buttonStyle(.lumenSecondary)
                    } else if let last {
                        Button(L("warm.inspector.report")) { openReport(last) }.buttonStyle(.lumenSecondary)
                    }
                    Button(last == nil ? L("warm.menu.warmUp") : L("warm.inspector.again")) { warmUp() }
                        .buttonStyle(LumenButtonStyle(kind: last == nil ? .secondary : .ghost))
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var stateLine: String {
        switch item.state {
        case .running(let status):
            if let number = status.siteNumber, let count = status.siteCount, count > 0 {
                return String(format: L("warm.inspector.runningSite"), number, count)
            }
            return String(format: L("warm.inspector.runningPage"), status.currentPage, status.total)
        case .waiting(let next): return next ? L("warm.row.next") : L("warm.row.waiting")
        case .attention(let run): return (WarmUpText.remark(run) ?? L("warm.result.proxy")) + " · " + WarmUpText.when(run.endedAt)
        case .never: return L("warm.row.never")
        case .partly(let run): return L("warm.row.partly") + " · " + WarmUpText.when(run.endedAt)
        case .warmed(_, let date): return L("warm.row.warmed") + " · " + WarmUpText.when(date)
        }
    }

    private var stateColor: Color {
        if case .attention = item.state { return Theme.danger }
        return Theme.textPrimary
    }

    /// "Германия · Обычный день, Покупки · обычный".
    private var meta: String? {
        var parts = [WarmUpText.country(item.countryCode)]
        if let last, !last.templates.isEmpty {
            parts.append(WarmUpText.templates(last.templates, names: last.templateNames, templates: templates))
            if let intensity = last.intensity.flatMap(WarmUpIntensity.init(rawValue:)) { parts.append(WarmUpText.intensity(intensity).lowercased()) }
        }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, trailing: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.lumenSection).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(trailing).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    @ViewBuilder private func running(_ status: WarmUpStatus) -> some View {
        section(L("warm.inspector.now"), trailing: status.secondsRemaining.map { String(format: L("warm.inspector.left"), WarmUpText.duration($0)) } ?? "") {
            Text(verbatim: status.currentHost ?? L("warmupQueue.starting"))
                .font(.lumenSheetTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
            let step = WarmUpText.step(status.step)
            if !step.isEmpty {
                Text(step.prefix(1).uppercased() + step.dropFirst()).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
            }
            LumenProgressBar(fraction: status.fraction, width: ProfilesScreen.inspectorWidth - 48)
            Text(gathered(status))
                .font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        if let visits = status.siteVisits, !visits.isEmpty {
            section(L("warm.inspector.log")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visits.reversed().enumerated()), id: \.offset) { _, visit in
                        WarmUpSiteLine(visit: visit)
                    }
                }
            }
        }
    }

    /// "Cookies: +84 · страниц: 14 · запросов: 2 · cookie-баннеров: 3".
    private func gathered(_ status: WarmUpStatus) -> String {
        var parts = [String(format: L("warm.summary.cookies"), status.cookies)]
        if let pages = status.pagesRead { parts.append(String(format: L("warm.summary.pages"), pages)) }
        if let searches = status.searchesTyped, searches > 0 { parts.append(String(format: L("warm.summary.searches"), searches)) }
        if let consents = status.consents, consents > 0 { parts.append(String(format: L("warm.summary.consents"), consents)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var finished: some View {
        if let last {
            section(L("warm.inspector.last"), trailing: WarmUpText.when(last.endedAt)) {
                Text(WarmUpText.summary(last))
                    .font(.lumenBody).foregroundStyle(Theme.textPrimary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let advice = advice(last) {
                    Text(advice)
                        .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let problems = last.sites.filter(\.isProblem)
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(problems.prefix(6)) { visit in WarmUpSiteLine(visit: visit) }
                    }
                }
            }
        } else if case .warmed(_, let date) = item.state {
            section(L("warm.inspector.last"), trailing: WarmUpText.when(date)) {
                Text(L("warm.inspector.noReport")).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let hours = item.repeatHours {
            section(L("warm.inspector.repeat")) {
                HStack {
                    Text(repeatLine(hours)).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("warm.inspector.repeat.off")) { actions.stopRepeating(item.id) }.buttonStyle(.lumenGhost)
                }
            }
        }
        if item.history.count > 1 {
            section(L("warm.tab.history")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.history.prefix(8)) { run in
                        Button { openReport(run) } label: {
                            HStack(spacing: 10) {
                                Text(WarmUpText.when(run.endedAt)).font(.lumenBody).foregroundStyle(Theme.textPrimary)
                                    .frame(width: 96, alignment: .leading)
                                Text(WarmUpText.remark(run) ?? String(format: L("warm.history.short"), run.visitedSites, run.cookies))
                                    .font(.lumenSecondary).foregroundStyle(run.hasRemarks ? Theme.warning : Theme.textSecondary)
                                Spacer(minLength: 0)
                            }
                            .lineLimit(1)
                            .monospacedDigit()
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func repeatLine(_ hours: Int) -> String {
        var text = String(format: L("warm.inspector.repeat.every"), hours)
        if let next = item.nextRun { text += " · " + String(format: L("warm.inspector.repeat.next"), next.shownRelative) }
        return text
    }

    /// What to do about the last run's problem, in a sentence.
    private func advice(_ run: WarmUpRun) -> String? {
        switch run.resultKind {
        case .proxyNotAnswering: return L("warm.advice.proxy")
        case .notStarted: return L("warm.advice.notStarted")
        default: return run.blockedSites.isEmpty ? nil : L("warm.advice.blocked")
        }
    }
}

/// One site of a run in a narrow column: its name, and what happened there.
private struct WarmUpSiteLine: View {
    let visit: WarmUpSiteVisit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: visit.site)
                .font(.lumenLabel).foregroundStyle(Theme.textPrimary).lineLimit(1)
                .frame(width: 124, alignment: .leading)
            Text(detail)
                .font(.lumenSecondary).foregroundStyle(visit.isProblem ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var detail: String {
        if visit.isProblem { return WarmUpText.problem(visit) }
        var parts: [String] = []
        if visit.arrivalKind != .address { parts.append(WarmUpText.arrival(visit)) }
        parts.append(String(format: L("warm.summary.pages"), visit.pages))
        if visit.cookies > 0 { parts.append("+\(visit.cookies)") }
        return parts.joined(separator: " · ")
    }
}

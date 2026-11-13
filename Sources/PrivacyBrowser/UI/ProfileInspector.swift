import BrowserCore
import SwiftUI

/// What the inspector shows of a profile beyond its row: its settings (nil: they cannot be read,
/// R1), what it keeps (`ProfileRepository.counts`, nil until counted), and the last check of its
/// proxy in the proxy list (its city and latency).
struct InspectorInfo {
    var details: ProfileDetails?
    var counts: ProfileCounts?
    var proxyCheck: ProxyCheckResult?
    /// The profile's WebDriver address, or why there is none to show; nil: not shown at all (a
    /// build without the automation API).
    var webDriver: WebDriver?

    enum WebDriver: Equatable {
        /// The address a WebDriver client (Selenium) is given for this profile.
        case address(String)
        /// The automation API is off: turned on, it listens here.
        case apiOff
        /// The automation API is on but does not listen (its port is taken, say).
        case apiFailed
        /// The plan has no automation.
        case notInPlan
    }
}

/// The inspector at the right of the Profiles window (the design's `insp`): what the selected profile
/// is and does, at a glance — how it reaches the web, how sites see it, what it keeps — with its
/// actions. 320 pt, over the light at 80 % like the sidebar; opaque when it lies over the list.
struct ProfileInspectorView: View {
    @Environment(\.tagColors) private var tagColors
    let row: ProfileRowItem
    let info: InspectorInfo
    let actions: ProfileActions
    /// The network guard is ready (`NetworkGuard`): a SOCKS5 profile's WebRTC can go through its proxy
    /// what its WebRTC amounts to, as the editor says it.
    var guardReady = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                head
                if row.exit == .unreadable {
                    // R1: its settings cannot be read — said here as in the row, with how to get them back.
                    advice(title: L("profiles.exit.unreadable"),
                           text: String(format: L("profiles.exit.unreadable.help"), L("profiles.menu.syncNow"), L("profiles.menu.more")))
                } else if let problem = row.problem {
                    advice(title: L("profiles.row.failed"), text: problem) {
                        HStack(spacing: 8) {
                            Button(L("inspector.failed.open")) { actions.showProxy(row.id) }.buttonStyle(.lumenSecondary)
                            Button(L("inspector.failed.retry")) { actions.launch(row.id) }.buttonStyle(.lumenGhost)
                        }
                    }
                }
                if let warmUp = row.warmUp {
                    section(L("inspector.warmUp"), trailing: String(format: L("inspector.warmUp.page"), warmUp.currentPage, warmUp.total)) {
                        // The width it is offered: a fixed 272 (+ 2 × 24 = 320) pushed the content 8 pt
                        // left, under the scroller, whenever the panel scrolled.
                        GeometryReader { geometry in
                            LumenProgressBar(fraction: warmUp.fraction, width: geometry.size.width)
                        }
                        .frame(height: 2)
                        .padding(.top, 2)
                        if warmUp.cookies > 0 {
                            Text(String(format: L("inspector.warmUp.cookies"), warmUp.cookies))
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                                .padding(.top, 8)
                        }
                    }
                }
                if let details = info.details {
                    network(details)
                    section(L("inspector.seen")) {
                        fact(L("inspector.device"), row.appearsAs)
                        fact(L("inspector.languages"), details.languages)
                        fact(L("inspector.window"), details.window)
                    }
                }
                links
                // Only an address makes a section: any other state is a row of the links above it.
                if case let .address(address)? = info.webDriver, row.exit != .unreadable { automation(address) }
            }
        }
        .scrollIndicators(.automatic)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ProfileAvatar(name: row.name, id: row.id, size: 56, style: row.avatar, running: row.isRunning)
                Spacer()
                Button { actions.edit(row.id) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(LumenIconButtonStyle(size: 30))
                .help(L("profiles.row.edit"))
                .accessibilityLabel(L("profiles.row.edit"))
            }
            Text(row.name)
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 7) {
                if row.isRunning { RunningDot() }
                Text(statusLine)
                    .font(.lumenBody)
                    .foregroundStyle(row.isRunning ? Theme.textPrimary : Theme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.top, 6)
            if !row.tags.isEmpty || row.ephemeral {
                TagLine.text((row.ephemeral ? [L("profiles.row.ephemeralTag")] : []) + row.tags, colors: tagColors)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
            }
            HStack(spacing: 10) {
                switch row.activity {
                case .running:
                    Button { actions.stop(row.id) } label: {
                        Label(L("profiles.row.stop"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.lumenSecondary)
                    Button(L("profiles.row.newWindow")) { actions.newWindow(row.id) }
                        .buttonStyle(.lumenGhost)
                case .stopped:
                    Button { actions.launch(row.id) } label: {
                        Label(L("profiles.row.launch"), systemImage: "play.fill")
                    }
                    .buttonStyle(.lumenPrimary)
                    // R1: it does not start without its settings.
                    .disabled(row.exit == .unreadable)
                case .starting, .sealing:
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(row.activity == .starting ? L("profiles.row.starting") : L("profiles.row.encrypting"))
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.top, 16)
            // The profile's check (`WhatSitesSeeView`), under its own name and on the first screen.
            // R1: without its settings there is nothing to check.
            if row.exit != .unreadable {
                Button { actions.whatSitesSee(row.id) } label: {
                    HStack(spacing: 4) {
                        Text(L("inspector.checkProfile"))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var statusLine: String {
        switch row.activity {
        case .running:
            if let warmUp = row.warmUp {
                let pages = String(format: L("profiles.row.warmUpShort"), warmUp.currentPage, warmUp.total)
                // The cookies' text starts with its own "·".
                return warmUp.cookies > 0 ? pages + " " + String(format: L("profiles.row.warmUpCookies"), warmUp.cookies) : pages
            }
            return L("profiles.row.running")
        case .starting: return L("profiles.row.starting")
        case .sealing: return L("profiles.row.encrypting")
        case .stopped:
            guard let date = row.lastUsed else { return L("profiles.row.neverLaunched") }
            return String(format: L("profiles.row.lastUsed"), date.shownRelative)
        }
    }

    // MARK: Network

    /// How it reaches the web: where it exits, through what, in which time zone, and what its
    /// WebRTC amounts to. The city and the latency are the proxy list's last check of its proxy,
    /// when that check reached it and found the same country.
    private func network(_ details: ProfileDetails) -> some View {
        let check = info.proxyCheck.flatMap { $0.isAlive ? $0 : nil }
        return section(L("inspector.network")) {
            fact(L("inspector.exit"), exitText(check: check), help: exitHelp)
            if case .proxy(_, nil) = row.exit, let note = row.exitNote {
                // Why the country is not known, said, not only on hover.
                Text(note)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            if case .direct = row.exit, row.directCountry == nil {
                // No country for a profile with no proxy: said why, never left empty.
                Text(row.exitNote ?? L("inspector.exit.directNotYet"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            if let ip = details.exitIP ?? check?.exitIP {
                fact(L("inspector.exitIP"), ip, mono: true)
            }
            if let endpoint = details.proxyEndpoint {
                fact(L("inspector.proxy"), [details.proxyKind, endpoint].compactMap { $0 }.joined(separator: " · "), mono: true)
            }
            if let latency = check?.latencyMilliseconds, let checked = check?.checkedAt {
                fact(L("inspector.latency"), String(format: L("inspector.latency.value"), latency),
                     help: String(format: L("inspector.latency.checked"), checked.shownRelative))
            }
            if details.proxyCarriesUDP, let check, let label = check.udpLabel {
                fact(L("inspector.udp"), ProxyUDPText.short(label), help: ProxyUDPText.help(check))
            }
            fact(L("inspector.timeZone"), details.timeZone)
            fact(L("inspector.webRTC"), webRTCText(details))
            if details.proxyEndpoint != nil {
                Button { actions.showProxy(row.id) } label: {
                    HStack(spacing: 4) {
                        Text(L("inspector.checkProxy"))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
    }

    private func exitText(check: ProxyCheckResult?) -> String {
        switch row.exit {
        case .direct:
            guard let code = row.directCountry else { return L("profiles.exit.direct") }
            return String(format: L("inspector.exit.directCountry"), CountryNames.name(for: code))
        case let .proxy(_, code?):
            let country = CountryNames.name(for: code)
            // The check's city only where the check found the same country.
            guard let city = check?.city, !city.isEmpty, check?.countryCode?.uppercased() == code.uppercased() else { return country }
            return country + " · " + city
        case .proxy(_, nil): return L("inspector.exit.unknown")
        case .unreadable: return L("profiles.exit.unreadable")
        }
    }

    private var exitHelp: String? {
        if case .proxy(_, nil) = row.exit { return row.exitNote ?? L("profiles.exit.unknownCountry") }
        return nil
    }

    /// As the editor says it (`ProfileEditorForm`): with a proxy, WebRTC goes only through the
    /// relay, held there by the network guard, and only for SOCKS5; otherwise it is off.
    private func webRTCText(_ details: ProfileDetails) -> String {
        if details.webRTCChoice == .disabled { return L("editor.webrtc.disabled") }
        guard details.proxyEndpoint != nil else {
            switch details.webRTCChoice {
            case .disabled: return L("editor.webrtc.disabled")
            case .relayOnly: return L("editor.webrtc.relay")
            case .unrestricted: return L("editor.webrtc.unrestricted")
            }
        }
        guard details.proxyCarriesUDP else { return L("inspector.webRTC.offHTTP") }
        if guardReady { return L("inspector.webRTC.viaProxy") }
        return BuildKind.carriesGuard ? L("inspector.webRTC.guardNotReady") : L("inspector.webRTC.noGuardInBuild")
    }

    // MARK: Automation

    /// The address a WebDriver client drives this profile at, to copy (docs/AUTOMATION.md,
    /// "WebDriver"). It holds the API's token, so it is shown as the settings show the token, as
    /// dots, on one line, and is not selectable: a selection would copy the dots, and without the
    /// concealed mark. Copy gives the whole address.
    private func automation(_ address: String) -> some View {
        section(L("inspector.webDriver")) {
            Text(verbatim: Self.tokenHidden(address)) // l10n: not text
                .font(.lumenMono)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
                .accessibilityLabel(L("inspector.webDriver.hidden"))
            LumenCopyButton(text: address)
                .padding(.top, 8)
            Text(L("inspector.webDriver.note"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// The address as it is shown: the API's token as dots. Split at "/", an address
    /// (`WebDriverRoute.address`) is "http:", "", host and port, "wd", the token, the profile; the
    /// token is base64url and has no "/" of its own. An address of any other shape is not shown at
    /// all: where its token is cannot be told.
    private static func tokenHidden(_ address: String) -> String {
        var parts = address.components(separatedBy: "/")
        guard parts.count == 6 else { return String(repeating: "•", count: 12) }
        parts[4] = String(repeating: "•", count: 6)
        return parts.joined(separator: "/")
    }

    /// With no address to show: what stands in the way, in a word, the same at length for the
    /// tooltip, and what opens the place where it is settled (the API's settings, the account).
    private var webDriverState: (note: String, warns: Bool, help: String, action: () -> Void)? {
        switch info.webDriver {
        case .apiOff?:
            return (note: L("inspector.webDriver.state.off"), warns: false,
                    help: L("inspector.webDriver.off"), action: actions.openAutomation)
        case .apiFailed?:
            return (note: L("inspector.webDriver.state.failed"), warns: true,
                    help: L("inspector.webDriver.failed"), action: actions.openAutomation)
        case .notInPlan?:
            return (note: L("inspector.webDriver.state.notInPlan"), warns: true,
                    help: L("inspector.webDriver.notInPlan"), action: actions.openAccount)
        case .address?, nil:
            return nil
        }
    }

    // MARK: What it keeps

    private var links: some View {
        let counts = info.counts
        return VStack(spacing: 0) {
            InspectorLink(title: L("inspector.passwords"), count: counts?.logins) { actions.passwords(row.id) }
            // Bookmarks and history each with its own count: one number for both read, on the owner's
            // Mac (4 November), as bookmarks the person never made — they were the history's entries.
            if row.isRunning {
                InspectorLink(title: L("inspector.bookmarks"), count: counts?.bookmarks) { actions.library(row.id) }
                InspectorLink(title: L("inspector.history"), count: counts?.historyEntries) { actions.history(row.id) }
            } else {
                // A stopped profile's bookmarks and history are opened in its window.
                if let bookmarks = counts?.bookmarks { InspectorCount(title: L("inspector.bookmarks"), count: bookmarks) }
                if let history = counts?.historyEntries { InspectorCount(title: L("inspector.history"), count: history) }
            }
            InspectorMenuLink(title: L("inspector.cookies"), count: counts?.syncedCookies) {
                Button(L("profiles.row.importCookies")) { actions.importCookies(row.id) }
                Button(L("profiles.row.exportCookies")) { actions.exportCookies(row.id) }
            }
            InspectorLink(title: L("profiles.row.warmUp"), count: nil) { actions.warmUp(row.id) }
            // No WebDriver address to show: one quiet row that says why and leads to where that is
            // settled. R1: a profile that does not start is not driven either.
            if row.exit != .unreadable, let state = webDriverState {
                InspectorLink(title: L("inspector.webDriver.link"), count: nil, note: state.note, warns: state.warns, action: state.action)
                    .help(state.help)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).lumenCaps().accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing {
                    Text(trailing).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            }
            .padding(.bottom, 8)
            content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func fact(_ key: String, _ value: String, mono: Bool = false, help: String? = nil) -> some View {
        Group {
            if mono {
                // An address that does not fit beside its key goes under it, whole, instead of breaking
                // inside a word ("proxy.northwind.examp / le:1080").
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(key)
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 104, alignment: .leading)
                        Text(value)
                            .font(.lumenMono)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize()
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key)
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textTertiary)
                        Text(value)
                            .font(.lumenMono)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(key)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 104, alignment: .leading)
                    Text(value)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .help(ifAny: help)
        .accessibilityElement(children: .combine)
    }

    private func advice(title: String, text: String) -> some View {
        advice(title: title, text: text) { EmptyView() }
    }

    /// A box that asks for the person (the design's `advice`): red's tint and its line.
    private func advice<Actions: View>(title: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.lumenLabel).foregroundStyle(Theme.danger)
            Text(text)
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            actions()
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.dangerTint))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.dangerLine, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}

/// One of the inspector's links (the design's `link`): its title, a count or a state, a chevron; a
/// tone of white under the pointer.
private struct InspectorLink: View {
    let title: String
    let count: Int?
    /// A state said at the row's end ("API off"); amber when it wants the person.
    var note: String? = nil
    var warns = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            InspectorLinkLabel(title: title, count: count, note: note, warns: warns, hovered: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.hover(hovered), value: hovered)
        .accessibilityLabel(spoken)
    }

    /// The row as VoiceOver reads it: the title, then the count and the state it has.
    private var spoken: String {
        let parts: [String?] = [title, count.map { "\($0)" }, note]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// A link whose choices are a menu (cookies: import or export).
private struct InspectorMenuLink<Items: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let items: () -> Items
    @State private var hovered = false

    var body: some View {
        Menu(content: items) {
            InspectorLinkLabel(title: title, count: count, hovered: hovered)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovered = $0 }
        .animation(Motion.hover(hovered), value: hovered)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

private struct InspectorLinkLabel: View {
    let title: String
    let count: Int?
    /// A state said at the row's end ("API off"); amber when it wants the person.
    var note: String? = nil
    var warns = false
    let hovered: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            if let count {
                Text(verbatim: "\(count)").font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            if let note {
                Text(note).font(.lumenSecondary).foregroundStyle(warns ? Theme.warning : Theme.textTertiary).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Theme.rowHover : Color.clear))
        .contentShape(Rectangle())
    }
}

/// A count without a place to open it.
private struct InspectorCount: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.lumenBody).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(verbatim: "\(count)").font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }
}

/// Several profiles selected: their letters, how many, and what can be done with all of them.
struct SelectionInspectorView: View {
    let rows: [ProfileRowItem]
    let actions: ProfileActions

    var body: some View {
        let stopped = rows.filter { $0.activity == .stopped && $0.exit != .unreadable }
        let running = rows.filter(\.isRunning)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: -8) {
                ForEach(rows.prefix(5)) { row in
                    ProfileAvatar(name: row.name, id: row.id, size: 30, style: row.avatar)
                        .background(Circle().fill(Theme.sidebar).padding(-2))
                }
            }
            .accessibilityHidden(true)
            Text(String(format: L("inspector.selected"), rows.count))
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(ProfileListView.listed(rows.map(\.name)))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .padding(.top, 4)
            // The single inspector's head: a leading row, the main action first; under each other
            // only when they do not fit side by side.
            if !stopped.isEmpty || !running.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actionButtons(stopped, running) }
                    VStack(alignment: .leading, spacing: 8) { actionButtons(stopped, running) }
                }
                .padding(.top, 18)
            }
            // Quiet, its text on the column's edge (a ghost button's 11 pt inset taken back); first
            // under the names when none can be launched or stopped (all starting, sealing, unreadable).
            Button(L("inspector.warmUpQueue")) { actions.warmUpSeveral(rows.map(\.id)) }
                .buttonStyle(.lumenGhost)
                .padding(.leading, -11)
                .padding(.top, stopped.isEmpty && running.isEmpty ? 18 : 10)
            if stopped.count > LaunchQueue.atOnce {
                Text(String(format: L("inspector.queueNote"), LaunchQueue.atOnce))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func actionButtons(_ stopped: [ProfileRowItem], _ running: [ProfileRowItem]) -> some View {
        if !stopped.isEmpty {
            Button { actions.launchSeveral(stopped.map(\.id)) } label: {
                Label(String(format: L("inspector.launchSome"), stopped.count), systemImage: "play.fill")
            }
            .buttonStyle(.lumenPrimary)
        }
        if !running.isEmpty {
            Button { actions.stopSeveral(running.map(\.id)) } label: {
                Label(String(format: L("inspector.stopSome"), running.count), systemImage: "stop.fill")
            }
            // Beside Launch, as tall as it.
            .buttonStyle(LumenButtonStyle(kind: .secondary, height: stopped.isEmpty ? nil : Theme.buttonHeight))
        }
    }
}

/// Nothing selected: what the inspector is for.
struct EmptyInspectorView: View {
    var body: some View {
        LumenEmptyHint(symbol: "sidebar.right", text: L("inspector.empty"))
            .padding(24)
    }
}

private extension View {
    /// A tooltip only where there is something to say.
    @ViewBuilder
    func help(ifAny text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// "Copy", which says "Copied" for a moment. What it copies holds the API's token (the token
/// itself, a WebDriver address, a command with it), so it goes to the clipboard marked as
/// concealed, as a password does (clipboard managers skip it).
struct LumenCopyButton: View {
    let text: String
    /// What the button says before it is pressed.
    var title = L("passwords.copy")
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            // Both titles are laid out and one of them is shown: the button keeps the wider one's
            // width, so what stands beside it does not move while it says "Copied".
            ZStack {
                Label(title, systemImage: "doc.on.doc").opacity(copied ? 0 : 1)
                Label(L("passwords.code.copied"), systemImage: "checkmark").opacity(copied ? 1 : 0)
            }
        }
        .buttonStyle(.lumenSecondary)
        .accessibilityLabel(copied ? L("passwords.code.copied") : title)
    }
}

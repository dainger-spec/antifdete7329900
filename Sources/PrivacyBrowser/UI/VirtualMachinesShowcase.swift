import BrowserCore
import SwiftUI

// The Virtual machines section before there are machines: its opening, and its setup while macOS
// is fetched and installed. Both take the section's whole width and show what a machine gives —
// one thing after another, lit in turn — so the minutes a download takes are spent on what the
// person is getting, not on a bar alone.

/// One thing a virtual machine gives, as the opening and the setup show it.
struct VMFeature: Identifiable, Equatable {
    let id: Int
    let symbol: String
    let title: String
    let text: String

    static var all: [VMFeature] {
        let items = [("macwindow.on.rectangle", "system"), ("network", "proxy"), ("cpu", "identity"),
                     ("display", "screen"), ("globe", "locale"), ("checkmark.shield", "real")]
        return items.enumerated().map { index, item in
            VMFeature(id: index, symbol: item.0, title: L("vm.feature.\(item.1).title"), text: L("vm.feature.\(item.1).text"))
        }
    }
}

/// Which feature is lit now: each for a few seconds, one after another, by the clock — so the
/// turn does not start over whenever the section draws itself again (a download's progress does
/// that twice a second). Still under Reduce Motion, and in a snapshot: the first one.
struct VMShowcaseClock<Content: View>: View {
    let count: Int
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    /// Seconds a feature stays lit.
    private var period: Double { 3.4 }

    var body: some View {
        if Motion.isReduced(reduceMotion) || stillFrame || count < 2 {
            content(0)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: period)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate / period) % count
                content(index)
                    .animation(Motion.entry(duration: 0.9), value: index)
            }
        }
    }
}

/// The features as tiles, as many in a row as the width has room for; the one whose turn it is
/// is lit.
struct VMFeatureGrid: View {
    let features: [VMFeature]
    let active: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(features) { feature in
                VMFeatureCard(feature: feature, active: feature.id == active)
            }
        }
    }
}

private struct VMFeatureCard: View {
    let feature: VMFeature
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: 17))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(active ? 0.13 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.32 : 0.10), lineWidth: 1))
                .shadow(color: Color.white.opacity(active ? 0.22 : 0), radius: 14)
            VStack(alignment: .leading, spacing: 5) {
                Text(feature.title)
                    .font(.lumenRowTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feature.text)
                    .font(.lumenSecondary)
                    .foregroundStyle(active ? Theme.textSecondary : Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? Theme.raisedInset : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(active ? 0.45 : 0.10), Color.white.opacity(active ? 0.08 : 0.10)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The picture beside the opening's words: a Mac's window inside a ring of the eclipse's light,
/// whose brightest part goes slowly round; in the window, the sign of the feature whose turn it is.
private struct VMShowcaseStage: View {
    let feature: VMFeature
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    private var still: Bool { Motion.isReduced(reduceMotion) || stillFrame }

    var body: some View {
        ZStack {
            ring
            window
        }
        .frame(width: 300, height: 300)
        .accessibilityHidden(true)
    }

    private var ring: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let turn = still ? 0.12 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18) / 18
            let light = AngularGradient(stops: [
                .init(color: Color.white.opacity(0.02), location: 0),
                .init(color: Color.white.opacity(0.80), location: 0.18),
                .init(color: Color.white.opacity(0.05), location: 0.42),
                .init(color: Color.white.opacity(0.30), location: 0.68),
                .init(color: Color.white.opacity(0.02), location: 1),
            ], center: .center, angle: .degrees(turn * 360))
            ZStack {
                Circle().strokeBorder(light, lineWidth: 18).blur(radius: 26).opacity(0.55)
                Circle().strokeBorder(light, lineWidth: 1.5)
            }
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 7, height: 7)
                }
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 12).padding(.leading, 8)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ZStack {
                Image(systemName: feature.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [Theme.textPrimary, Theme.textSecondary], startPoint: .top, endPoint: .bottom))
                    .id(feature.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 196, height: 132)
        .background(LinearGradient(colors: [Color(hex: 0x16171C), Color(hex: 0x0C0D10)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strongBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.6), radius: 24, y: 14)
    }
}

/// The section's opening: what a virtual machine is, the one button that adds them (or says what
/// is needed first — an account, the plan), and what a machine gives, lit in turn.
struct VMHero: View {
    let title: String
    let text: String
    let actionTitle: String
    var actionSymbol = "plus"
    var actionEnabled = true
    /// Under the button: what the setup takes, or why it cannot start yet.
    var footnote: String?
    var problems: [VMRequirements.Problem] = []
    var error: String?
    /// The section's width: a narrow one has no room for the picture beside the words.
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        let features = VMFeature.all
        VMShowcaseClock(count: features.count) { active in
            VStack(alignment: .leading, spacing: 34) {
                HStack(alignment: .center, spacing: 36) {
                    pitch
                    if width >= 900 {
                        Spacer(minLength: 0)
                        VMShowcaseStage(feature: features[active])
                            .padding(.trailing, 12)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("vm.hero.features")).lumenCaps()
                    VMFeatureGrid(features: features, active: active)
                }
            }
        }
    }

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("vm.hero.eyebrow")).lumenCaps()
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .tracking(-1)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        VMNote(VMText.problem(problem), tone: VMRequirements.stops(problem) ? .danger : .warning)
                    }
                }
            }
            if let error {
                VMNote(error, tone: .danger)
            }
            Button(action: action) { Label(actionTitle, systemImage: actionSymbol) }
                .buttonStyle(LumenButtonStyle(kind: .primary, height: 38))
                .disabled(!actionEnabled)
                .padding(.top, 4)
            if let footnote {
                Text(footnote)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// A progress bar the width it is given, with light running along what is filled.
struct VMProgressBar: View {
    /// 0…1
    let fraction: Double
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    private var still: Bool { Motion.isReduced(reduceMotion) || stillFrame }
    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            let filled = max(height, geometry.size.width * CGFloat(clamped))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(Color.white.opacity(0.78))
                    .frame(width: filled)
                    .overlay(alignment: .leading) { glint(over: filled) }
                    .clipShape(Capsule())
                    .shadow(color: Color.white.opacity(0.30), radius: 6)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: clamped)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((clamped * 100).rounded())) %"))
    }

    /// The light that runs along the bar every couple of seconds.
    @ViewBuilder
    private func glint(over filled: CGFloat) -> some View {
        if !still {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                LinearGradient(colors: [Color.white.opacity(0), Color.white, Color.white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 90)
                    .offset(x: -90 + (filled + 90) * CGFloat(phase))
            }
            .frame(width: filled, alignment: .leading)
        }
    }
}

/// The setup under way, or stopped part-way: where it stands among its three steps, the step at
/// work with its numbers and what can be done about it, and — while macOS is fetched and
/// installed — what the machines will give.
struct VMSetupPanel: View {
    @ObservedObject var center: VMCenter
    /// Under the panel, what a machine gives, lit in turn: in the section's own setup, not where
    /// the panel stands above a list of machines.
    var showsFeatures = true

    private enum StepState { case waiting, active, done }

    private var downloadState: StepState {
        switch center.activity {
        case .asking?, .downloading?: return .active
        case .installing?, .guestSetup?: return .done
        case nil: break
        }
        switch center.setup {
        case .downloaded, .needsGuestSetup, .ready: return .done
        case .downloading: return .active
        case .none: return .waiting
        }
    }

    private var installState: StepState {
        switch center.activity {
        case .installing?: return .active
        case .guestSetup?: return .done
        default: break
        }
        switch center.setup {
        case .needsGuestSetup, .ready: return .done
        case .downloaded: return center.activity == nil ? .active : .waiting
        default: return .waiting
        }
    }

    private var guestState: StepState {
        if center.activity == .guestSetup { return .active }
        switch center.setup {
        case .ready: return .done
        case .needsGuestSetup: return .active
        default: return .waiting
        }
    }

    /// The first-run setup is the person's own work in the machine's window: the tiles below
    /// would only be in its way.
    private var isGuestStep: Bool { guestState == .active }

    var body: some View {
        let features = VMFeature.all
        VMShowcaseClock(count: features.count) { active in
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 22) {
                    stepper
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    current
                    problems
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                if showsFeatures, !isGuestStep {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L("vm.setup.meanwhile")).lumenCaps()
                        VMFeatureGrid(features: features, active: active)
                    }
                }
            }
        }
    }

    // MARK: The three steps

    private var stepper: some View {
        HStack(spacing: 12) {
            stepChip(1, L("vm.setup.step.download"), downloadState)
            connector(done: downloadState == .done)
            stepChip(2, L("vm.setup.step.install"), installState)
            connector(done: installState == .done)
            stepChip(3, L("vm.setup.step.guest"), guestState)
        }
    }

    private func stepChip(_ number: Int, _ title: String, _ state: StepState) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(state == .done ? Theme.running.opacity(0.16) : Color.white.opacity(state == .active ? 0.14 : 0.05))
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.running)
                } else {
                    Text(verbatim: "\(number)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(state == .active ? Theme.textPrimary : Theme.textTertiary)
                }
            }
            .frame(width: 24, height: 24)
            Text(title)
                .font(.lumenLabel)
                .foregroundStyle(state == .waiting ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func connector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Theme.running.opacity(0.45) : Theme.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: The step at work

    @ViewBuilder
    private var current: some View {
        switch center.activity {
        case .asking?:
            asking
        case .downloading(let progress)?:
            downloading(progress)
        case .installing(let fraction)?:
            installing(fraction)
        case .guestSetup?:
            guest(isOpen: true)
        case nil:
            stopped
        }
    }

    @ViewBuilder
    private var stopped: some View {
        switch center.setup {
        case .downloading(let have, let total):
            paused(have: have, total: total)
        case .downloaded:
            readyToInstall
        case .needsGuestSetup:
            guest(isOpen: false)
        case .none, .ready:
            EmptyView()
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("vm.setup.asking"))
                .font(.lumenHeading)
                .foregroundStyle(Theme.textPrimary)
            LumenActivityLine(width: 260)
        }
    }

    private func downloading(_ progress: VMImageDownloader.Progress) -> some View {
        let fraction = progress.total.map { $0 > 0 ? Double(progress.have) / Double($0) : 0 } ?? 0
        return meter(percent: progress.total == nil ? nil : fraction, title: L("vm.setup.download"),
                     detail: downloadText(progress), note: L("vm.setup.download.note")) {
            Button(L("vm.setup.pause")) { center.pauseDownload() }
                .buttonStyle(.lumenSecondary)
        }
    }

    private func installing(_ fraction: Double) -> some View {
        meter(percent: fraction, title: L("vm.setup.install"), detail: L("vm.setup.install.note"), note: nil) {
            Button(L("common.cancel")) { center.cancelInstallation() }
                .buttonStyle(.lumenGhost)
        }
    }

    private func paused(have: Int64, total: Int64?) -> some View {
        let fraction = total.map { $0 > 0 ? Double(have) / Double($0) : 0 }
        let detail = total.map { String(format: L("vm.setup.paused.of"), VMText.bytes(have), VMText.bytes($0)) }
            ?? String(format: L("vm.setup.paused"), VMText.bytes(have))
        return meter(percent: fraction, title: L("vm.setup.download"), detail: detail, note: nil, glints: false) {
            HStack(spacing: 8) {
                Button(L("vm.setup.removeDownload")) { center.removeDownloadedImage() }
                    .buttonStyle(.lumenGhost)
                Button(L("vm.setup.continue")) { center.continueSetup() }
                    .buttonStyle(.lumenPrimary)
                    .disabled(center.requirements.contains(where: VMRequirements.stops))
            }
        }
    }

    private var readyToInstall: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("vm.setup.install"))
                    .font(.lumenHeading)
                    .foregroundStyle(Theme.textPrimary)
                caption(L("vm.setup.install.ready"))
            }
            Spacer(minLength: 12)
            Button(L("vm.setup.removeDownload")) { center.removeDownloadedImage() }
                .buttonStyle(.lumenGhost)
            Button(L("vm.setup.continue")) { center.continueSetup() }
                .buttonStyle(.lumenPrimary)
        }
    }

    /// A step that counts: its share done in large figures, what it is, its numbers, the bar.
    /// `percent` nil: the length is not known yet, and no figure is shown.
    private func meter<Trailing: View>(percent: Double?, title: String, detail: String, note: String?, glints: Bool = true,
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        let shown = percent.map { Int((min(max($0, 0), 1) * 100).rounded(.down)) }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                if let shown {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: "\(shown)")
                            .font(.system(size: 52, weight: .bold))
                            .tracking(-1.5)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.3), value: shown)
                        Text(verbatim: "%")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.lumenHeading)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    caption(detail)
                }
                Spacer(minLength: 12)
                trailing()
            }
            if glints {
                VMProgressBar(fraction: percent ?? 0)
            } else {
                VMProgressBar(fraction: percent ?? 0).environment(\.lumenStillFrame, true)
            }
            if let note {
                Text(note)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func downloadText(_ progress: VMImageDownloader.Progress) -> String {
        var parts: [String] = []
        if let total = progress.total {
            parts.append(String(format: L("vm.setup.progress.of"), VMText.bytes(progress.have), VMText.bytes(total)))
        } else {
            parts.append(VMText.bytes(progress.have))
        }
        if let speed = progress.speed, speed > 0 {
            parts.append(String(format: L("vm.setup.speed"), VMText.bytes(Int64(speed))))
        }
        if let total = progress.total, let left = VMText.remaining(bytes: total - progress.have, speed: progress.speed) {
            parts.append(left)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: The first-run setup

    private func guest(isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("vm.setup.guest"))
                .font(.lumenHeading)
                .foregroundStyle(Theme.textPrimary)
            instruction(1, L("vm.setup.guest.step1"))
            instruction(2, L("vm.setup.guest.step2"))
            instruction(3, L("vm.setup.guest.step3"))
            caption(L("vm.setup.guest.fallback"))
            Text(verbatim: #"sh "/Volumes/My Shared Files/install.sh""#)
                .font(.lumenMono)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            HStack(spacing: 10) {
                if isOpen {
                    ProgressView().controlSize(.small)
                    caption(L("vm.setup.guest.open"))
                } else {
                    Button(L("vm.setup.guest.openMachine")) { center.continueSetup() }
                        .buttonStyle(.lumenPrimary)
                    Button(L("vm.setup.guest.startOver")) { center.removeBase() }
                        .buttonStyle(.lumenGhost)
                }
            }
            .padding(.top, 4)
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.07)))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: What stands in the way

    @ViewBuilder
    private var problems: some View {
        if let error = center.setupError {
            VMNote(error, tone: .danger)
        }
        if center.activity == nil {
            let stopping = center.requirements.filter(VMRequirements.stops)
            ForEach(Array(stopping.enumerated()), id: \.offset) { _, problem in
                VMNote(VMText.problem(problem), tone: .danger)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.lumenBody)
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

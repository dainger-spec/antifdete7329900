import BrowserCore
import SwiftUI

// The Virtual machines section before there are machines: its opening, and its setup while macOS
// is fetched and installed. Both are one composition the width of the section — the words and
// what to press on the left; on the right a Mac's window on the eclipse's light. In the opening
// the window holds a machine's passport — what is its own, line by line, lit in turn; in the
// setup, the ring that fills as macOS comes, and under it the same lines, one at a time.

/// One line of a machine's passport: what a virtual machine has of its own.
struct VMPassportLine: Identifiable, Equatable {
    let id: Int
    let label: String
    /// An example of what the line holds — a serial number, an address: shown as a sample.
    let value: String
    /// The value is an identifier, set in the monospaced face.
    let isCode: Bool
    let tag: String
    /// The line as a sentence, for the setup's window.
    let tip: String

    static var all: [VMPassportLine] {
        let items: [(key: String, value: String?, isCode: Bool)] = [
            ("system", nil, false),
            ("serial", "F7Q4XK2LXM", true),
            ("card", "3a:9c:1e:07:b2:4f", true),
            ("screen", "1470 × 956 · MacBook Air 13″", false),
            ("locale", "Europe/Berlin · de-DE", false),
            ("exit", nil, false),
        ]
        return items.enumerated().map { index, item in
            VMPassportLine(id: index, label: L("vm.passport.\(item.key).label"),
                           value: item.value ?? L("vm.passport.\(item.key).value"), isCode: item.isCode,
                           tag: L("vm.passport.\(item.key).tag"), tip: L("vm.passport.\(item.key).tip"))
        }
    }
}

/// Which line is lit now: each for a few seconds, one after another, by the clock — so the turn
/// does not start over whenever the section draws itself again (a download's progress does that
/// twice a second). Still under Reduce Motion, and in a snapshot: the first one.
struct VMShowcaseClock<Content: View>: View {
    let count: Int
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    /// Seconds a line stays lit.
    private var period: Double { 3.2 }

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

// MARK: - The picture

/// The eclipse behind the machine's window: a disc of light of which a dark one hides all but a
/// crescent, upper right. The light's brightest part sways slowly along the rim.
private struct VMEclipseArc: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    private var still: Bool { Motion.isReduced(reduceMotion) || stillFrame }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let sway = still ? 0 : sin(context.date.timeIntervalSinceReferenceDate * 2 * Double.pi / 11) * 16
            let light = AngularGradient(stops: [
                .init(color: Color.white.opacity(0), location: 0),
                .init(color: Color.white.opacity(0.55), location: 0.12),
                .init(color: Color.white.opacity(0.95), location: 0.20),
                .init(color: Color.white.opacity(0.50), location: 0.30),
                .init(color: Color.white.opacity(0), location: 0.46),
                .init(color: Color.white.opacity(0), location: 1),
            ], center: .center, angle: .degrees(210 + sway))
            ZStack {
                Circle().fill(light).blur(radius: 34).opacity(0.5)
                Circle().strokeBorder(light, lineWidth: 1.5)
                Circle().fill(Theme.surface)
                    .padding(3)
                    .offset(x: -6, y: 8)
                    .blur(radius: 8)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A Mac's window, as the section draws one: its bar with what it is about, and what it holds.
private struct VMMachineWindow<Content: View>: View {
    let title: String
    var symbol = "lock.fill"
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.16)).frame(width: 9, height: 9)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 8.5))
                    Text(title).font(.system(size: 11.5)).lineLimit(1)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.055)))
                Spacer(minLength: 8)
                Color.clear.frame(width: 41, height: 1)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(Theme.divider).frame(height: 1)
            content()
        }
        .frame(width: width)
        .background(LinearGradient(colors: [Color(hex: 0x17181D), Color(hex: 0x0D0E11)], startPoint: .top, endPoint: .bottom))
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.05), Color.white.opacity(0.03)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.7), radius: 40, y: 28)
        .accessibilityElement(children: .contain)
    }
}

/// The machine's window on the eclipse: the light is behind it and takes no room of its own.
private struct VMStage<Content: View>: View {
    let title: String
    var symbol = "lock.fill"
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VMMachineWindow(title: title, symbol: symbol, width: width, content: content)
            .background(VMEclipseArc(diameter: width * 1.1).offset(x: width * 0.07, y: -width * 0.08))
    }
}

/// A machine's passport: its lines, the one whose turn it is lit.
private struct VMPassportRows: View {
    let lines: [VMPassportLine]
    let active: Int
    /// A narrow window has no room for the tags.
    let showsTags: Bool

    var body: some View {
        VStack(spacing: 1) {
            ForEach(lines) { line in
                row(line, lit: line.id == active)
            }
        }
        .padding(10)
    }

    private func row(_ line: VMPassportLine, lit: Bool) -> some View {
        HStack(spacing: 14) {
            Text(line.label)
                .font(.system(size: 12.5))
                .foregroundStyle(lit ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(1)
                .frame(width: 148, alignment: .leading)
            Text(line.value)
                .font(line.isCode ? Font.lumenMono : Font.system(size: 13))
                .foregroundStyle(lit ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if showsTags {
                Text(line.tag)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(lit ? Theme.textPrimary : Theme.textDisabled)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(lit ? 0.28 : 0.07), lineWidth: 1))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(lit ? 0.05 : 0)))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .frame(width: 2, height: 22)
                .shadow(color: Color.white.opacity(0.8), radius: 5)
                .opacity(lit ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The ring that fills as a step goes: its share in figures inside. `fraction` nil: how long is
/// not known yet, and a short arc goes round.
private struct VMProgressRing: View {
    let fraction: Double?
    /// The step is done: a tick in place of figures.
    var done = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame

    private var still: Bool { Motion.isReduced(reduceMotion) || stillFrame }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 3)
            arc
            inside
        }
        .frame(width: 168, height: 168)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: fraction.map { "\(Int(($0 * 100).rounded(.down))) %" } ?? ""))
    }

    @ViewBuilder
    private var arc: some View {
        if let fraction {
            let shown = done ? 1 : min(max(fraction, 0.004), 1)
            Circle()
                .trim(from: 0, to: CGFloat(shown))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Color.white.opacity(0.8), radius: 6)
                .animation(.easeOut(duration: 0.5), value: shown)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
                let turn = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90 + turn * 360))
                    .shadow(color: Color.white.opacity(0.8), radius: 6)
            }
        }
    }

    @ViewBuilder
    private var inside: some View {
        if done {
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        } else if let fraction {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: "\(percent)")
                    .font(.system(size: 42, weight: .bold))
                    .tracking(-1.4)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: percent)
                Text(verbatim: "%")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - The opening

/// One figure of what the machines take: the room on disk, the time, how many run at once.
struct VMFact: Identifiable, Equatable {
    let id: Int
    let value: String
    let label: String
}

/// The section's opening: what a virtual machine is, the one button that adds them — or says
/// what is needed first: an account, the plan — what it takes in three figures, and beside them
/// a machine's passport.
struct VMHero: View {
    /// Above the title, when the machines are not to be had yet: which plan has them.
    var badge: String?
    let title: String
    let text: String
    let actionTitle: String
    var actionSymbol = "plus"
    var actionEnabled = true
    /// Under the button: why it cannot be pressed yet, or what it leads to.
    var footnote: String?
    var facts: [VMFact] = []
    var problems: [VMRequirements.Problem] = []
    var error: String?
    /// The section's width: a narrow one puts the picture under the words.
    let width: CGFloat
    let action: () -> Void

    private var isWide: Bool { width >= 940 }

    var body: some View {
        let lines = VMPassportLine.all
        VMShowcaseClock(count: lines.count) { active in
            if isWide {
                HStack(alignment: .center, spacing: 48) {
                    pitch.frame(width: 430, alignment: .leading)
                    stage(lines, active: active, width: min(620, width - 56 - 430 - 48 - 40))
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 40) {
                    pitch.frame(maxWidth: 520, alignment: .leading)
                    stage(lines, active: active, width: max(300, min(560, width - 56)))
                }
            }
        }
    }

    private func stage(_ lines: [VMPassportLine], active: Int, width: CGFloat) -> some View {
        VMStage(title: L("vm.passport.title"), width: width) {
            VMPassportRows(lines: lines, active: active, showsTags: width >= 500)
        }
    }

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let badge {
                Label(badge, systemImage: "lock.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .padding(.bottom, 18)
            }
            Text(title)
                .font(.system(size: 46, weight: .bold))
                .tracking(-1.6)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400, alignment: .leading)
                .padding(.bottom, 26)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        VMNote(VMText.problem(problem), tone: VMRequirements.stops(problem) ? .danger : .warning)
                    }
                }
                .padding(.bottom, 16)
            }
            if let error {
                VMNote(error, tone: .danger).padding(.bottom, 16)
            }
            Button(action: action) { Label(actionTitle, systemImage: actionSymbol) }
                .buttonStyle(LumenButtonStyle(kind: .primary, height: 40))
                .disabled(!actionEnabled)
            if let footnote {
                Text(footnote)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if !facts.isEmpty {
                VMFacts(facts: facts).padding(.top, 34)
            }
        }
    }
}

/// What the machines take, as figures in a row under a line.
private struct VMFacts: View {
    let facts: [VMFact]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(facts) { fact in
                if fact.id != facts.first?.id {
                    Rectangle().fill(Theme.divider).frame(width: 1).padding(.trailing, 16)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.value)
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.5)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(fact.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

// MARK: - The setup

/// The setup under way, or stopped part-way. On the left the step at work — what it is, its
/// numbers, what can be done about it — and the three steps down a line; on the right the
/// machine's window with the ring that fills, and what a machine has of its own, a line at a
/// time. The first-run setup, which is the person's own work in the machine's window, has what
/// to do there in the window's place.
struct VMSetupPanel: View {
    @ObservedObject var center: VMCenter
    /// The section's width: a narrow one puts the window under the words.
    var width: CGFloat = 1000
    /// Above a list of machines: the words alone, in a tile.
    var compact = false

    private enum StepState { case waiting, active, done }

    /// 1: fetching, 2: installing, 3: the first-run setup in the machine's window.
    private var step: Int {
        switch center.activity {
        case .asking?, .downloading?: return 1
        case .installing?: return 2
        case .guestSetup?: return 3
        case nil: break
        }
        switch center.setup {
        case .none, .downloading: return 1
        case .downloaded: return 2
        case .needsGuestSetup, .ready: return 3
        }
    }

    private func state(of number: Int) -> StepState {
        if case .ready = center.setup { return .done }
        return number < step ? .done : (number == step ? .active : .waiting)
    }

    private var isWide: Bool { width >= 940 }

    var body: some View {
        if compact {
            words
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        } else {
            let lines = VMPassportLine.all
            VMShowcaseClock(count: lines.count) { active in
                if isWide {
                    HStack(alignment: .center, spacing: 48) {
                        words.frame(width: 430, alignment: .leading)
                        stage(lines, active: active, width: min(620, width - 56 - 430 - 48 - 40))
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 40) {
                        words.frame(maxWidth: 520, alignment: .leading)
                        stage(lines, active: active, width: max(300, min(560, width - 56)))
                    }
                }
            }
        }
    }

    // MARK: The words

    private var words: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: L("vm.setup.stepOf"), step, 3)).lumenCaps().padding(.bottom, 14)
            Text(headline)
                .font(.system(size: compact ? 22 : 34, weight: .bold))
                .tracking(compact ? -0.44 : -1.1)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            actions
            problems.padding(.top, 14)
            if !compact {
                timeline.padding(.top, 34)
            }
        }
    }

    private var headline: String {
        switch center.activity {
        case .asking?: return L("vm.setup.asking")
        case .downloading?: return L("vm.setup.download")
        case .installing?: return L("vm.setup.install")
        case .guestSetup?: return L("vm.setup.guest")
        case nil: break
        }
        switch center.setup {
        case .downloading: return L("vm.setup.paused.title")
        case .downloaded: return L("vm.setup.downloaded.title")
        case .needsGuestSetup: return L("vm.setup.guest")
        case .none, .ready: return L("vm.setup.download")
        }
    }

    private var detail: String {
        switch center.activity {
        case .asking?: return L("vm.setup.asking.detail")
        case .downloading(let progress)?: return downloadText(progress)
        case .installing?: return L("vm.setup.install.note")
        case .guestSetup?: return L("vm.setup.guest.detail")
        case nil: break
        }
        switch center.setup {
        case .downloading(let have, let total):
            return total.map { String(format: L("vm.setup.paused.of"), VMText.bytes(have), VMText.bytes($0)) }
                ?? String(format: L("vm.setup.paused"), VMText.bytes(have))
        case .downloaded: return L("vm.setup.install.ready")
        case .needsGuestSetup: return L("vm.setup.guest.detail")
        case .none, .ready: return ""
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            switch center.activity {
            case .asking?:
                EmptyView()
            case .downloading?:
                Button(L("vm.setup.pause")) { center.pauseDownload() }
                    .buttonStyle(.lumenSecondary)
            case .installing?:
                Button(L("common.cancel")) { center.cancelInstallation() }
                    .buttonStyle(.lumenSecondary)
            case .guestSetup?:
                ProgressView().controlSize(.small)
                Text(L("vm.setup.guest.open"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
            case nil:
                stoppedActions
            }
        }
    }

    @ViewBuilder
    private var stoppedActions: some View {
        switch center.setup {
        case .downloading, .downloaded:
            Button(L("vm.setup.continue")) { center.continueSetup() }
                .buttonStyle(.lumenPrimary)
                .disabled(center.requirements.contains(where: VMRequirements.stops))
            Button(L("vm.setup.removeDownload")) { center.removeDownloadedImage() }
                .buttonStyle(.lumenGhost)
        case .needsGuestSetup:
            Button(L("vm.setup.guest.openMachine")) { center.continueSetup() }
                .buttonStyle(.lumenPrimary)
            Button(L("vm.setup.guest.startOver")) { center.removeBase() }
                .buttonStyle(.lumenGhost)
        case .none, .ready:
            EmptyView()
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

    // MARK: The three steps

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineStep(1, L("vm.setup.step.download"), L("vm.setup.step.download.detail"), isLast: false)
            timelineStep(2, L("vm.setup.step.install"), L("vm.setup.step.install.detail"), isLast: false)
            timelineStep(3, L("vm.setup.step.guest"), L("vm.setup.step.guest.detail"), isLast: true)
        }
        .padding(.top, 20)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func timelineStep(_ number: Int, _ title: String, _ detail: String, isLast: Bool) -> some View {
        let stepState = state(of: number)
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().strokeBorder(stepState == .waiting ? Theme.textDisabled : Color.clear, lineWidth: 1.5)
                    Circle().fill(stepState == .done ? Theme.running : (stepState == .active ? Color.white : Color.clear))
                        .shadow(color: Color.white.opacity(stepState == .active ? 0.7 : 0), radius: 5)
                }
                .frame(width: 9, height: 9)
                .padding(.top, 4)
                if !isLast {
                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.lumenLabel)
                    .foregroundStyle(stepState == .waiting ? Theme.textTertiary : Theme.textPrimary)
                Text(detail)
                    .font(.lumenSecondary)
                    .foregroundStyle(stepState == .active ? Theme.textSecondary : Theme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The window

    @ViewBuilder
    private func stage(_ lines: [VMPassportLine], active: Int, width: CGFloat) -> some View {
        if step == 3 {
            VMStage(title: L("vm.setup.guest.window"), symbol: "macwindow", width: width) {
                guestSteps
            }
        } else {
            VMStage(title: windowTitle, symbol: "arrow.down", width: width) {
                VStack(spacing: 22) {
                    VMProgressRing(fraction: ringFraction, done: step == 2 && center.activity == nil)
                    VStack(spacing: 5) {
                        Text(lines[active].label + " — " + lines[active].tag)
                            .font(.lumenRowTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(lines[active].tip)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(height: 34, alignment: .top)
                    }
                    .id(active)
                    .transition(.opacity)
                    .padding(.horizontal, 24)
                    HStack(spacing: 6) {
                        ForEach(lines) { line in
                            Capsule()
                                .fill(Color.white.opacity(line.id == active ? 1 : 0.14))
                                .frame(width: line.id == active ? 16 : 5, height: 5)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 352)
            }
        }
    }

    private var windowTitle: String {
        if let image = center.offeredImage, !image.version.isEmpty {
            return String(format: L("vm.setup.window"), image.version)
        }
        return L("vm.setup.window.unknown")
    }

    /// The ring's share: nil while it is not known how much there is.
    private var ringFraction: Double? {
        switch center.activity {
        case .asking?: return nil
        case .downloading(let progress)?: return progress.total.map { $0 > 0 ? Double(progress.have) / Double($0) : 0 }
        case .installing(let fraction)?: return fraction
        case .guestSetup?: return 1
        case nil: break
        }
        switch center.setup {
        case .downloading(let have, let total): return total.map { $0 > 0 ? Double(have) / Double($0) : 0 } ?? 0
        case .downloaded: return 1
        case .none, .needsGuestSetup, .ready: return 0
        }
    }

    /// What to do in the machine's own window, in the order it is done.
    private var guestSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            instruction(1, L("vm.setup.guest.step1"))
            instruction(2, L("vm.setup.guest.step2"))
            instruction(3, L("vm.setup.guest.step3"))
            Rectangle().fill(Theme.divider).frame(height: 1)
            Text(L("vm.setup.guest.fallback"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: #"sh "/Volumes/My Shared Files/install.sh""#)
                .font(.lumenMono)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            Text(L("vm.setup.guest.wifi"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.09)))
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

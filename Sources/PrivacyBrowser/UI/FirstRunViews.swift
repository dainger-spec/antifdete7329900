import AppKit
import BrowserCore
import SwiftUI

/// The first run's step shown now (`AppModel.firstRunSteps`, `FirstRun`), on the lock screen's
/// backdrop and horizon, between the vault being made and the profiles.
struct FirstRunView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.firstRunSteps.first {
        case .touchID?: FirstRunTouchIDView(done: { model.finishFirstRunStep() }).transition(.opacity)
        case .protection?: FirstRunProtectionView(done: { model.finishFirstRunStep() }).transition(.opacity)
        case nil: EmptyView()
        }
    }
}

// MARK: - Touch ID

/// «Входить по Touch ID?»: a sentence on what it does, the fingerprint, «Включить» and «Не сейчас».
/// «Включить» asks the system's own Touch ID question, then keeps the key as Settings › Security
/// does (`AppModel.turnTouchIDOnAtFirstRun`); the outcome is said calmly under the fingerprint.
struct FirstRunTouchIDView: View {
    @EnvironmentObject private var model: AppModel
    let done: () -> Void
    /// The snapshots: the outcome to show.
    var preview: FirstRunTouchIDOutcome?
    @State private var working = false
    @State private var outcome: FirstRunTouchIDOutcome?

    private var shown: FirstRunTouchIDOutcome? { preview ?? outcome }

    var body: some View {
        LockScreen(title: L("firstRun.touchID.title"), subtitle: L("firstRun.touchID.subtitle")) {
            VStack(spacing: 0) {
                fingerprint
                    .padding(.top, 8)
                if let shown, shown != .cancelled {
                    outcomeLine(shown)
                        .padding(.top, 18)
                }
                VStack(spacing: 14) {
                    if shown == .on {
                        LockActionButton(title: L("firstRun.continue"), action: done)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        LockActionButton(title: L("firstRun.touchID.turnOn"), working: working,
                                         workingTitle: L("firstRun.touchID.waiting"), action: turnOn)
                            .keyboardShortcut(.defaultAction)
                        LockLink(title: L("firstRun.notNow"), action: done)
                            .disabled(working)
                    }
                }
                .padding(.top, 28)
                Text(L("firstRun.touchID.later"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The fingerprint, in a ring of the horizon's light; green once it is on.
    private var fingerprint: some View {
        ZStack {
            Circle()
                .fill(Theme.raised)
                .frame(width: 96, height: 96)
            Circle()
                .strokeBorder(shown == .on ? Theme.running.opacity(0.6) : Theme.edge, lineWidth: 1)
                .frame(width: 96, height: 96)
            Image(systemName: "touchid")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(shown == .on ? Theme.running : Theme.textPrimary)
        }
        .shadow(color: (shown == .on ? Theme.running : Theme.rim).opacity(0.25), radius: 22)
        .animation(Theme.appearAnimation, value: shown)
        .accessibilityHidden(true)
    }

    private func outcomeLine(_ outcome: FirstRunTouchIDOutcome) -> some View {
        let on = outcome == .on
        let text: String
        if case .failed(let problem) = outcome { text = problem } else { text = L("firstRun.touchID.on") }
        return Label(text, systemImage: on ? "checkmark.circle.fill" : "info.circle")
            .font(.system(size: 13))
            .foregroundStyle(on ? Theme.running : Theme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private func turnOn() {
        guard !working else { return }
        working = true
        outcome = nil
        Task {
            outcome = await model.turnTouchIDOnAtFirstRun()
            working = false
        }
    }
}

// MARK: - Protection

/// «Настройка защиты»: the network guard (WebRTC through the proxy) and, where the plan has it, the
/// virtual camera — each a card with what it does, «Установить», what to click in System Settings
/// while macOS waits, and a mark that turns green when it is done. Inside a virtual machine it says
/// once, plainly, that macOS installs neither there.
struct FirstRunProtectionView: View {
    @EnvironmentObject private var model: AppModel
    let done: () -> Void
    /// The snapshots: the states to show, in place of this Mac's.
    var preview: Preview?

    struct Preview {
        var guardState: NetworkGuardState
        var cameraState: SystemCamera.State?
        var cameraAllowed: Bool
        var virtualMachine = false
    }

    @ObservedObject private var networkGuard = NetworkGuard.shared
    @ObservedObject private var camera = SystemCamera.shared

    private var virtualMachine: Bool { preview?.virtualMachine ?? FirstRun.isVirtualMachine }
    private var guardState: NetworkGuardState? {
        if let preview { return preview.guardState }
        return FirstRun.guardInBuild ? networkGuard.state : nil
    }
    private var cameraState: SystemCamera.State? {
        if let preview { return preview.cameraState }
        return FirstRun.cameraInBuild ? camera.state : nil
    }
    private var cameraAllowed: Bool { preview?.cameraAllowed ?? model.license.allowsCamera }

    var body: some View {
        LockScreen(title: L("firstRun.protection.title"), subtitle: L("firstRun.protection.subtitle")) {
            VStack(alignment: .leading, spacing: 12) {
                if virtualMachine {
                    LockNote(symbol: "info.circle", text: L("firstRun.protection.virtualMachine"))
                } else {
                    if let guardState { guardCard(guardState) }
                    if let cameraState { cameraCard(cameraState) }
                }
                LockActionButton(title: L(allDone ? "firstRun.done" : "firstRun.continue"), action: done)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 16)
                Text(L("firstRun.protection.later"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
        .onAppear {
            guard preview == nil else { return }
            networkGuard.refresh()
            camera.refresh()
        }
    }

    private var allDone: Bool {
        let guardDone = guardState.map { $0 == .ready || $0 == .unproven } ?? true
        let cameraDone = cameraState.map { $0 == .active || !cameraAllowed } ?? true
        return guardDone && cameraDone
    }

    // MARK: The network guard

    private func guardCard(_ state: NetworkGuardState) -> some View {
        FirstRunCard(symbol: "network.badge.shield.half.filled", title: L("firstRun.guard.title"),
                     detail: guardDetail(state), status: guardStatus(state)) {
            switch state {
            case .notInstalled:
                Button(L("firstRun.install")) { networkGuard.install() }
                    .buttonStyle(.lumenPrimary)
                    .disabled(networkGuard.checking)
            case .off:
                Button(L("guard.enable")) { networkGuard.install() }
                    .buttonStyle(.lumenPrimary)
                    .disabled(networkGuard.checking)
            case .awaitingApproval:
                HStack(spacing: 8) {
                    Button(L("firstRun.openSystemSettings")) { networkGuard.openSystemSettings() }
                        .buttonStyle(.lumenPrimary)
                    Button(L("guard.refresh")) { networkGuard.checkAgain() }
                        .buttonStyle(.lumenGhost)
                        .disabled(networkGuard.checking)
                }
            case .notAnswering:
                Button(L("guard.refresh")) { networkGuard.checkAgain() }
                    .buttonStyle(.lumenSecondary)
                    .disabled(networkGuard.checking)
            case .notInBuild, .restartNeeded, .unproven, .ready:
                EmptyView()
            }
        }
    }

    private func guardDetail(_ state: NetworkGuardState) -> String {
        switch state {
        case .notInstalled: return L("firstRun.guard.detail")
        case .awaitingApproval: return L("firstRun.guard.approve")
        case .off: return L("guard.todo.off")
        case .notAnswering: return L("guard.todo.notAnswering")
        case .restartNeeded: return L("guard.problem.reboot")
        case .unproven: return L("guard.todo.unproven")
        case .ready, .notInBuild: return L("firstRun.guard.ready")
        }
    }

    private func guardStatus(_ state: NetworkGuardState) -> FirstRunCard.Status {
        switch state {
        case .ready, .unproven: return .done
        case .awaitingApproval, .restartNeeded: return .waiting
        case .notInstalled, .off, .notAnswering, .notInBuild: return .todo
        }
    }

    // MARK: The camera

    @ViewBuilder
    private func cameraCard(_ state: SystemCamera.State) -> some View {
        if !cameraAllowed {
            // Not in the plan: a hint, not a task and not an error.
            FirstRunCard(symbol: "video", title: L("firstRun.camera.title"), detail: L("firstRun.camera.notInPlan"), status: .unavailable) {
                EmptyView()
            }
        } else {
            FirstRunCard(symbol: "video", title: L("firstRun.camera.title"), detail: cameraDetail(state), status: cameraStatus(state)) {
                switch state {
                case .notInstalled, .failed:
                    Button(L("firstRun.install")) { camera.install() }
                        .buttonStyle(.lumenPrimary)
                case .awaitingApproval:
                    Button(L("firstRun.openSystemSettings")) { camera.openSystemSettings() }
                        .buttonStyle(.lumenPrimary)
                case .notInBuild, .installing, .active, .restartNeeded:
                    EmptyView()
                }
            }
        }
    }

    private func cameraDetail(_ state: SystemCamera.State) -> String {
        switch state {
        case .notInstalled, .notInBuild: return L("firstRun.camera.detail")
        case .installing: return L("firstRun.camera.installing")
        case .awaitingApproval: return L("firstRun.camera.approve")
        case .active: return L("firstRun.camera.ready")
        case .restartNeeded: return L("firstRun.camera.restart")
        case .failed: return L("firstRun.camera.failed")
        }
    }

    private func cameraStatus(_ state: SystemCamera.State) -> FirstRunCard.Status {
        switch state {
        case .active: return .done
        case .installing, .awaitingApproval, .restartNeeded: return .waiting
        case .notInstalled, .notInBuild, .failed: return .todo
        }
    }
}

/// One thing to set up: its symbol, title, a sentence that says what it does or what to click,
/// a mark (to do, waiting, done — green — or not in the plan), and its buttons.
struct FirstRunCard<Actions: View>: View {
    enum Status { case todo, waiting, done, unavailable }

    let symbol: String
    let title: String
    let detail: String
    let status: Status
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(status == .unavailable ? Theme.textTertiary : Theme.textPrimary)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(status == .unavailable ? Theme.textSecondary : Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    mark
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                actions()
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(status == .done ? Theme.running.opacity(0.45) : Theme.hairline, lineWidth: 1))
        .animation(Theme.appearAnimation, value: status)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var mark: some View {
        switch status {
        case .done:
            Label(L("firstRun.status.done"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.running)
        case .waiting:
            Label(L("firstRun.status.waiting"), systemImage: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.warning)
        case .todo, .unavailable:
            EmptyView()
        }
    }
}

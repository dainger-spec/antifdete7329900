import BrowserCore
import SwiftUI

/// Updates (Settings → Updates, docs/UPDATES.md §7): the version running, what the updater knows,
/// the release notes as text, automatic checks, what to do with a release, Check Now and Install
/// Now — which asks first, and lists what it stops.
struct UpdatesPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var updater: AppUpdater
    @State private var confirming = false

    /// "0.1.0 (1)": the running app's version and build.
    static var runningVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(L("updates.version"))
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                Text(verbatim: Self.runningVersion)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 12)
            Text(stateText)
                .font(.lumenBody)
                .foregroundStyle(stateColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let installed = installedNotice {
                Text(installed)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Button(L("updates.checkNow")) { Task { await updater.checkNow() } }
                    .buttonStyle(.lumenSecondary)
                    .disabled(isBusy)
                if case .available = updater.state {
                    Button(L("updates.download")) { Task { await updater.download() } }
                        .buttonStyle(.lumenSecondary)
                }
                if updater.isReady {
                    Button(L("updates.installNow")) { confirming = true }
                        .buttonStyle(.lumenPrimary)
                        .disabled(model.isInstallingUpdate)
                }
            }
            .padding(.vertical, 12)
            if let item = updater.state.item {
                Text(String(format: L("updates.notes"), item.version))
                    .font(.lumenSection)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 4)
                // Plain text, never a page: the notes come from the feed, and nothing of it is
                // rendered by WebKit outside a profile.
                ScrollView {
                    Text(verbatim: item.notes.isEmpty ? L("updates.notes.none") : item.notes) // l10n: the feed's own text
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            SettingRow(L("updates.automatic"), detail: L("updates.privacy"), effect: .now) {
                SettingSwitch(isOn: $updater.automaticChecks, label: L("updates.automatic"))
            }
            SettingRow(L("updates.policy"), detail: L("settings.updates.policy.detail"), effect: .now) {
                Picker(L("updates.policy"), selection: $updater.installPolicy) {
                    Text(L("updates.policy.atQuit")).tag(UpdateInstallPolicy.atQuit)
                    Text(L("updates.policy.notifyOnly")).tag(UpdateInstallPolicy.notifyOnly)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .alert(confirmTitle, isPresented: $confirming) {
            Button(model.updateStopsList().isEmpty ? L("updates.installNow.confirm") : L("updates.installNow.confirmStopping"),
                   role: .destructive) {
                Task { await model.installUpdateNow() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var confirmTitle: String {
        String(format: L("updates.installNow.title"), updater.state.item?.version ?? "")
    }

    /// What Install Now stops before anything is installed: every profile with a window, in its own
    /// process or not, every warm-up without one, every launch and seal under way.
    private var confirmMessage: String {
        let stops = model.updateStopsList()
        guard !stops.isEmpty else { return L("updates.installNow.nothingRuns") }
        return L("updates.installNow.stops") + "\n" + stops.map { "• " + $0 }.joined(separator: "\n")
    }

    private var stateText: String {
        switch updater.state {
        case .idle: return L(updater.automaticChecks ? "updates.state.idle" : "updates.state.idleManual")
        case .upToDate(let date): return String(format: L("updates.state.upToDate"), date.formatted(date: .abbreviated, time: .shortened))
        case .checking: return L("updates.state.checking")
        case .available(let item): return String(format: L("updates.state.available"), item.version)
        case .downloading(let item): return String(format: L("updates.state.downloading"), item.version)
        case .ready(let item): return String(format: L("updates.state.ready"), item.version)
        case .blocked(let item, .translocated): return String(format: L("updates.state.translocated"), item.version)
        case .blocked(let item, .notWritable): return String(format: L("updates.state.notWritable"), item.version)
        case .failed(let reason): return String(format: L("updates.state.failed"), reason)
        }
    }

    private var stateColor: Color {
        switch updater.state {
        case .ready, .available: return Theme.running
        case .blocked: return Theme.warning
        case .failed: return Theme.danger
        default: return Theme.textSecondary
        }
    }

    /// After an update: which one this launch is the result of.
    private var installedNotice: String? {
        guard case .outcome(let outcome)? = updater.notice, outcome.result == .installed else { return nil }
        return String(format: L("updates.installed"), outcome.version, outcome.at.formatted(date: .abbreviated, time: .shortened))
    }
}
